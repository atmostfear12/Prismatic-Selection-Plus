#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <sys/utsname.h>

#ifndef BEDROCK_SCENE_SCALE
#define BEDROCK_SCENE_SCALE 0.66
#endif

static const double kSceneScale = BEDROCK_SCENE_SCALE;
static IMP gOriginalNewTexture = NULL;
static NSString *gLogPath = nil;
static BOOL gEnabledForDevice = NO;
static NSUInteger gPatchCount = 0;

static NSString *BRSDeviceModel(void) {
    struct utsname info;
    uname(&info);
    return [NSString stringWithUTF8String:info.machine];
}

static void BRSLog(NSString *line) {
    if (!line || !gLogPath) return;
    @synchronized ([NSFileManager class]) {
        NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:data attributes:nil];
            return;
        }
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    }
}

static BOOL BRSIsKnownRenderTargetFormat(MTLPixelFormat pf) {
    // Formats observed in the repeating RenderDragon full/0.66/0.37 render-target families.
    switch ((NSUInteger)pf) {
        case 25:
        case 55:
        case 70:
        case 92:
        case 110:
        case 113:
        case 115:
        case 260:
            return YES;
        default:
            return NO;
    }
}

static BOOL BRSShouldScaleDescriptor(MTLTextureDescriptor *d) {
    if (!gEnabledForDevice || !d) return NO;

    // Extremely narrow guard: only the exact iPhone 13 native landscape/portrait family.
    BOOL nativeSize = ((d.width == 2532 && d.height == 1170) ||
                       (d.width == 1170 && d.height == 2532));
    if (!nativeSize) return NO;

    // RenderDragon family seen in Probe v2: ShaderRead | RenderTarget (0x5), 2D, single-sample.
    MTLTextureUsage required = (MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
    if ((d.usage & required) != required) return NO;
    if (d.textureType != MTLTextureType2D) return NO;
    if (d.sampleCount != 1) return NO;
    if (d.mipmapLevelCount != 1) return NO;
    if (d.arrayLength != 1) return NO;
    if (!BRSIsKnownRenderTargetFormat(d.pixelFormat)) return NO;

    return YES;
}

static NSUInteger BRSScaledDimension(NSUInteger value) {
    double scaled = floor((double)value * kSceneScale);
    if (scaled < 2.0) scaled = 2.0;
    return (NSUInteger)scaled;
}

static id BRS_newTextureWithDescriptor(id self, SEL _cmd, MTLTextureDescriptor *descriptor) {
    if (!gOriginalNewTexture || !descriptor || !BRSShouldScaleDescriptor(descriptor)) {
        return ((id(*)(id, SEL, MTLTextureDescriptor *))gOriginalNewTexture)(self, _cmd, descriptor);
    }

    // Never mutate Minecraft's descriptor object in-place. Pass Metal a private copy instead.
    MTLTextureDescriptor *patched = [descriptor copy];
    NSUInteger oldW = patched.width;
    NSUInteger oldH = patched.height;
    patched.width = BRSScaledDimension(oldW);
    patched.height = BRSScaledDimension(oldH);

    id texture = ((id(*)(id, SEL, MTLTextureDescriptor *))gOriginalNewTexture)(self, _cmd, patched);

    NSUInteger count = ++gPatchCount;
    if (count <= 128) {
        BRSLog([NSString stringWithFormat:
                @"PATCH #%lu %lux%lu -> %lux%lu pf=%lu usage=0x%lx storage=%lu success=%@",
                (unsigned long)count,
                (unsigned long)oldW, (unsigned long)oldH,
                (unsigned long)patched.width, (unsigned long)patched.height,
                (unsigned long)descriptor.pixelFormat,
                (unsigned long)descriptor.usage,
                (unsigned long)descriptor.storageMode,
                texture ? @"YES" : @"NO"]);
    }

    return texture;
}

static BOOL BRSInstallDeviceHook(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        BRSLog(@"ERROR MTLCreateSystemDefaultDevice returned nil");
        return NO;
    }

    Class cls = object_getClass(device);
    SEL sel = @selector(newTextureWithDescriptor:);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        BRSLog([NSString stringWithFormat:@"ERROR %@ has no newTextureWithDescriptor:", NSStringFromClass(cls)]);
        return NO;
    }

    gOriginalNewTexture = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);

    // If the method is inherited, add a class-local override. Otherwise replace only this class's method.
    if (!class_addMethod(cls, sel, (IMP)BRS_newTextureWithDescriptor, types)) {
        method_setImplementation(class_getInstanceMethod(cls, sel), (IMP)BRS_newTextureWithDescriptor);
    }

    BRSLog([NSString stringWithFormat:@"HOOK class=%@ gpu=%@", NSStringFromClass(cls), device.name ?: @"unknown"]);
    return YES;
}

__attribute__((constructor))
static void BedrockSceneScaleInit(void) {
    @autoreleasepool {
        NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documents = docs.firstObject ?: NSTemporaryDirectory();
        gLogPath = [documents stringByAppendingPathComponent:@"BedrockSceneScale.log"];

        NSString *model = BRSDeviceModel();
        gEnabledForDevice = [model isEqualToString:@"iPhone14,5"];

        NSString *header = [NSString stringWithFormat:
                            @"BedrockSceneScale experimental v1\ndevice=%@\nscale=%.4f\nmode=max-native-render-target-cap\n---",
                            model, kSceneScale];
        [header writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        if (!gEnabledForDevice) {
            BRSLog(@"DISABLED: this experimental build is gated to iPhone14,5 only.");
            return;
        }

        if (kSceneScale < 0.50 || kSceneScale > 1.00) {
            BRSLog(@"DISABLED: scale outside safe experimental range 0.50...1.00");
            gEnabledForDevice = NO;
            return;
        }

        if (BRSInstallDeviceHook()) {
            BRSLog(@"ACTIVE: final CAMetalLayer drawable is untouched; only recognized native-size RenderDragon render-target allocations are capped.");
        }
    }
}
