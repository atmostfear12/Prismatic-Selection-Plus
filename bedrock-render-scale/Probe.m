#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/utsname.h>
#import <dlfcn.h>

static IMP gOriginalDrawableSize = NULL;
static IMP gOriginalFactory2D = NULL;
static IMP gOriginalSetWidth = NULL;
static IMP gOriginalSetHeight = NULL;
static IMP gOriginalSetUsage = NULL;
static IMP gOriginalSetSampleCount = NULL;
static IMP gOriginalSetPixelFormat = NULL;
static IMP gOriginalDeviceNewTexture = NULL;
static IMP gOriginalDeviceNewHeap = NULL;

static NSMutableSet<NSString *> *gSeen = nil;
static NSMutableDictionary<NSString *, NSValue *> *gHeapOriginals = nil;
static NSMutableSet<NSString *> *gHookedHeapClasses = nil;
static NSString *gLogPath = nil;
static NSUInteger gLoggedCount = 0;
static const NSUInteger kMaxUniqueRecords = 1024;

static NSString *BRSDeviceModel(void) {
    struct utsname systemInfo;
    uname(&systemInfo);
    return [NSString stringWithUTF8String:systemInfo.machine];
}

static void BRSAppendLine(NSString *line) {
    if (!line || !gLogPath) return;

    @synchronized (gSeen) {
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

static NSString *BRSCallerString(void *returnAddress) {
    if (!returnAddress) return @"caller=unknown";

    Dl_info info;
    if (dladdr(returnAddress, &info) == 0 || info.dli_fbase == NULL) {
        return [NSString stringWithFormat:@"caller=%p", returnAddress];
    }

    NSString *image = info.dli_fname ? [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent] : @"unknown";
    uintptr_t offset = (uintptr_t)returnAddress - (uintptr_t)info.dli_fbase;

    if (info.dli_sname) {
        return [NSString stringWithFormat:@"caller=%@+0x%llx symbol=%s",
                image,
                (unsigned long long)offset,
                info.dli_sname];
    }

    return [NSString stringWithFormat:@"caller=%@+0x%llx",
            image,
            (unsigned long long)offset];
}

static NSString *BRSDescriptorKey(MTLTextureDescriptor *descriptor) {
    if (!descriptor) return nil;

    return [NSString stringWithFormat:
            @"%lux%lux%lu pf=%lu usage=0x%lx samples=%lu type=%lu storage=%lu mip=%lu array=%lu",
            (unsigned long)descriptor.width,
            (unsigned long)descriptor.height,
            (unsigned long)descriptor.depth,
            (unsigned long)descriptor.pixelFormat,
            (unsigned long)descriptor.usage,
            (unsigned long)descriptor.sampleCount,
            (unsigned long)descriptor.textureType,
            (unsigned long)descriptor.storageMode,
            (unsigned long)descriptor.mipmapLevelCount,
            (unsigned long)descriptor.arrayLength];
}

static BOOL BRSDescriptorIsInteresting(MTLTextureDescriptor *descriptor) {
    if (!descriptor) return NO;

    NSUInteger width = descriptor.width;
    NSUInteger height = descriptor.height;
    if (width < 128 || height < 128) return NO;

    unsigned long long area = (unsigned long long)width * (unsigned long long)height;
    return area >= 131072ULL;
}

static void BRSRecordDescriptor(MTLTextureDescriptor *descriptor,
                                NSString *source,
                                void *returnAddress) {
    if (!descriptor || !gSeen || !BRSDescriptorIsInteresting(descriptor)) return;

    NSString *descriptorKey = BRSDescriptorKey(descriptor);
    NSString *caller = BRSCallerString(returnAddress);
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@",
                     source ?: @"unknown",
                     descriptorKey ?: @"descriptor=nil",
                     caller ?: @"caller=unknown"];

    BOOL shouldLog = NO;
    @synchronized (gSeen) {
        if (gLoggedCount < kMaxUniqueRecords && ![gSeen containsObject:key]) {
            [gSeen addObject:key];
            gLoggedCount++;
            shouldLog = YES;
        }
    }

    if (!shouldLog) return;

    BRSAppendLine([NSString stringWithFormat:@"TEXTURE source=%@ %@ %@",
                   source ?: @"unknown",
                   descriptorKey,
                   caller]);
}

static void BRS_setDrawableSize(id self, SEL _cmd, CGSize size) {
    static CGSize lastSize = {0, 0};
    if (size.width != lastSize.width || size.height != lastSize.height) {
        lastSize = size;
        BRSAppendLine([NSString stringWithFormat:@"DRAWABLE requested=%.0fx%.0f %@",
                       size.width,
                       size.height,
                       BRSCallerString(__builtin_return_address(0))]);
    }

    ((void(*)(id, SEL, CGSize))gOriginalDrawableSize)(self, _cmd, size);
}

static id BRS_texture2DDescriptor(id self, SEL _cmd, MTLPixelFormat pixelFormat,
                                  NSUInteger width, NSUInteger height, BOOL mipmapped) {
    id descriptor = ((id(*)(id, SEL, MTLPixelFormat, NSUInteger, NSUInteger, BOOL))gOriginalFactory2D)
                    (self, _cmd, pixelFormat, width, height, mipmapped);
    BRSRecordDescriptor((MTLTextureDescriptor *)descriptor,
                        @"descriptorFactory2D",
                        __builtin_return_address(0));
    return descriptor;
}

static void BRS_setWidth(id self, SEL _cmd, NSUInteger value) {
    ((void(*)(id, SEL, NSUInteger))gOriginalSetWidth)(self, _cmd, value);
    BRSRecordDescriptor((MTLTextureDescriptor *)self,
                        @"descriptorSetWidth",
                        __builtin_return_address(0));
}

static void BRS_setHeight(id self, SEL _cmd, NSUInteger value) {
    ((void(*)(id, SEL, NSUInteger))gOriginalSetHeight)(self, _cmd, value);
    BRSRecordDescriptor((MTLTextureDescriptor *)self,
                        @"descriptorSetHeight",
                        __builtin_return_address(0));
}

static void BRS_setUsage(id self, SEL _cmd, MTLTextureUsage value) {
    ((void(*)(id, SEL, MTLTextureUsage))gOriginalSetUsage)(self, _cmd, value);
    BRSRecordDescriptor((MTLTextureDescriptor *)self,
                        @"descriptorSetUsage",
                        __builtin_return_address(0));
}

static void BRS_setSampleCount(id self, SEL _cmd, NSUInteger value) {
    ((void(*)(id, SEL, NSUInteger))gOriginalSetSampleCount)(self, _cmd, value);
    BRSRecordDescriptor((MTLTextureDescriptor *)self,
                        @"descriptorSetSampleCount",
                        __builtin_return_address(0));
}

static void BRS_setPixelFormat(id self, SEL _cmd, MTLPixelFormat value) {
    ((void(*)(id, SEL, MTLPixelFormat))gOriginalSetPixelFormat)(self, _cmd, value);
    BRSRecordDescriptor((MTLTextureDescriptor *)self,
                        @"descriptorSetPixelFormat",
                        __builtin_return_address(0));
}

static void BRSSwapInstance(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls || !sel || !replacement || !original) return;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;

    *original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);

    if (!class_addMethod(cls, sel, replacement, types)) {
        method_setImplementation(method, replacement);
    }
}

static void BRSSwapClass(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getClassMethod(cls, sel);
    if (!method || !original) return;
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static id BRS_heapNewTexture(id self, SEL _cmd, MTLTextureDescriptor *descriptor) {
    Class cls = object_getClass(self);
    NSString *className = NSStringFromClass(cls);
    IMP original = NULL;

    @synchronized (gHeapOriginals) {
        original = [gHeapOriginals[className] pointerValue];
    }

    BRSRecordDescriptor(descriptor,
                        [NSString stringWithFormat:@"heap:%@", className],
                        __builtin_return_address(0));

    if (!original) return nil;
    return ((id(*)(id, SEL, MTLTextureDescriptor *))original)(self, _cmd, descriptor);
}

static void BRSInstallHeapHookForObject(id heap) {
    if (!heap) return;

    Class cls = object_getClass(heap);
    NSString *className = NSStringFromClass(cls);

    @synchronized (gHookedHeapClasses) {
        if ([gHookedHeapClasses containsObject:className]) return;

        SEL sel = @selector(newTextureWithDescriptor:);
        Method method = class_getInstanceMethod(cls, sel);
        if (!method) return;

        IMP original = method_getImplementation(method);
        const char *types = method_getTypeEncoding(method);

        if (!class_addMethod(cls, sel, (IMP)BRS_heapNewTexture, types)) {
            method_setImplementation(method, (IMP)BRS_heapNewTexture);
        }

        gHeapOriginals[className] = [NSValue valueWithPointer:original];
        [gHookedHeapClasses addObject:className];
        BRSAppendLine([NSString stringWithFormat:@"HOOK heapClass=%@", className]);
    }
}

static id BRS_deviceNewTexture(id self, SEL _cmd, MTLTextureDescriptor *descriptor) {
    BRSRecordDescriptor(descriptor,
                        [NSString stringWithFormat:@"device:%@", NSStringFromClass(object_getClass(self))],
                        __builtin_return_address(0));

    return ((id(*)(id, SEL, MTLTextureDescriptor *))gOriginalDeviceNewTexture)(self, _cmd, descriptor);
}

static id BRS_deviceNewHeap(id self, SEL _cmd, MTLHeapDescriptor *descriptor) {
    id heap = ((id(*)(id, SEL, MTLHeapDescriptor *))gOriginalDeviceNewHeap)(self, _cmd, descriptor);
    BRSInstallHeapHookForObject(heap);

    if (heap) {
        BRSAppendLine([NSString stringWithFormat:@"HEAP created class=%@ size=%llu storage=%lu cpuCache=%lu",
                       NSStringFromClass(object_getClass(heap)),
                       (unsigned long long)descriptor.size,
                       (unsigned long)descriptor.storageMode,
                       (unsigned long)descriptor.cpuCacheMode]);
    }

    return heap;
}

static void BRSInstallProbe(void) {
    if (gSeen) return;

    gSeen = [NSMutableSet set];
    gHeapOriginals = [NSMutableDictionary dictionary];
    gHookedHeapClasses = [NSMutableSet set];

    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                     NSUserDomainMask,
                                                                     YES);
    NSString *documents = docs.firstObject ?: NSTemporaryDirectory();
    gLogPath = [documents stringByAppendingPathComponent:@"BedrockRenderProbe.log"];

    NSString *header = [NSString stringWithFormat:
                        @"BedrockRenderProbe v2\ndevice=%@\niOS=%@\n---",
                        BRSDeviceModel(),
                        UIDevice.currentDevice.systemVersion];
    [header writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    Class metalLayer = NSClassFromString(@"CAMetalLayer");
    if (metalLayer) {
        BRSSwapInstance(metalLayer,
                        @selector(setDrawableSize:),
                        (IMP)BRS_setDrawableSize,
                        &gOriginalDrawableSize);
    }

    Class desc = [MTLTextureDescriptor class];
    BRSSwapClass(desc,
                 @selector(texture2DDescriptorWithPixelFormat:width:height:mipmapped:),
                 (IMP)BRS_texture2DDescriptor,
                 &gOriginalFactory2D);
    BRSSwapInstance(desc, @selector(setWidth:), (IMP)BRS_setWidth, &gOriginalSetWidth);
    BRSSwapInstance(desc, @selector(setHeight:), (IMP)BRS_setHeight, &gOriginalSetHeight);
    BRSSwapInstance(desc, @selector(setUsage:), (IMP)BRS_setUsage, &gOriginalSetUsage);
    BRSSwapInstance(desc, @selector(setSampleCount:), (IMP)BRS_setSampleCount, &gOriginalSetSampleCount);
    BRSSwapInstance(desc, @selector(setPixelFormat:), (IMP)BRS_setPixelFormat, &gOriginalSetPixelFormat);

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device) {
        Class deviceClass = object_getClass(device);
        BRSAppendLine([NSString stringWithFormat:@"DEVICE class=%@ name=%@",
                       NSStringFromClass(deviceClass),
                       device.name ?: @"unknown"]);

        BRSSwapInstance(deviceClass,
                        @selector(newTextureWithDescriptor:),
                        (IMP)BRS_deviceNewTexture,
                        &gOriginalDeviceNewTexture);

        BRSSwapInstance(deviceClass,
                        @selector(newHeapWithDescriptor:),
                        (IMP)BRS_deviceNewHeap,
                        &gOriginalDeviceNewHeap);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect nativeBounds = UIScreen.mainScreen.nativeBounds;
        BRSAppendLine([NSString stringWithFormat:@"SCREEN native=%.0fx%.0f scale=%.2f nativeScale=%.2f",
                       nativeBounds.size.width,
                       nativeBounds.size.height,
                       UIScreen.mainScreen.scale,
                       UIScreen.mainScreen.nativeScale]);
    });

    BRSAppendLine(@"PROBE v2 installed immediately; observation only, no render sizes modified.");
}

__attribute__((constructor))
static void BedrockRenderProbeInit(void) {
    @autoreleasepool {
        // Install immediately so we can see render targets created during Minecraft startup.
        BRSInstallProbe();
    }
}
