#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/utsname.h>

static IMP gOriginalDrawableSize = NULL;
static IMP gOriginalFactory2D = NULL;
static IMP gOriginalSetWidth = NULL;
static IMP gOriginalSetHeight = NULL;
static IMP gOriginalSetUsage = NULL;
static IMP gOriginalSetSampleCount = NULL;
static IMP gOriginalSetPixelFormat = NULL;

static NSMutableSet<NSString *> *gSeen = nil;
static NSString *gLogPath = nil;
static NSUInteger gLoggedCount = 0;
static const NSUInteger kMaxUniqueRecords = 256;

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

static void BRSRecordDescriptor(MTLTextureDescriptor *descriptor, NSString *source) {
    if (!descriptor || !gSeen) return;

    NSUInteger width = descriptor.width;
    NSUInteger height = descriptor.height;
    if (width < 256 || height < 256) return;

    unsigned long long area = (unsigned long long)width * (unsigned long long)height;
    if (area < 300000ULL) return;

    NSString *key = [NSString stringWithFormat:@"%lux%lu|pf=%lu|usage=%lu|samples=%lu|type=%lu|storage=%lu",
                     (unsigned long)width,
                     (unsigned long)height,
                     (unsigned long)descriptor.pixelFormat,
                     (unsigned long)descriptor.usage,
                     (unsigned long)descriptor.sampleCount,
                     (unsigned long)descriptor.textureType,
                     (unsigned long)descriptor.storageMode];

    BOOL shouldLog = NO;
    @synchronized (gSeen) {
        if (gLoggedCount < kMaxUniqueRecords && ![gSeen containsObject:key]) {
            [gSeen addObject:key];
            gLoggedCount++;
            shouldLog = YES;
        }
    }

    if (!shouldLog) return;

    BRSAppendLine([NSString stringWithFormat:@"TEXTURE source=%@ %@",
                   source ?: @"unknown", key]);
}

static void BRS_setDrawableSize(id self, SEL _cmd, CGSize size) {
    static CGSize lastSize = {0, 0};
    if (size.width != lastSize.width || size.height != lastSize.height) {
        lastSize = size;
        BRSAppendLine([NSString stringWithFormat:@"DRAWABLE requested=%.0fx%.0f",
                       size.width, size.height]);
    }

    ((void(*)(id, SEL, CGSize))gOriginalDrawableSize)(self, _cmd, size);
}

static id BRS_texture2DDescriptor(id self, SEL _cmd, MTLPixelFormat pixelFormat,
                                  NSUInteger width, NSUInteger height, BOOL mipmapped) {
    id descriptor = ((id(*)(id, SEL, MTLPixelFormat, NSUInteger, NSUInteger, BOOL))gOriginalFactory2D)
                    (self, _cmd, pixelFormat, width, height, mipmapped);
    BRSRecordDescriptor((MTLTextureDescriptor *)descriptor, @"factory2D");
    return descriptor;
}

static void BRS_setWidth(id self, SEL _cmd, NSUInteger value) {
    ((void(*)(id, SEL, NSUInteger))gOriginalSetWidth)(self, _cmd, value);
    BRSRecordDescriptor((MTLTextureDescriptor *)self, @"setWidth");
}

static void BRS_setHeight(id self, SEL _cmd, NSUInteger value) {
    ((void(*)(id, SEL, NSUInteger))gOriginalSetHeight)(self, _cmd, value);
    BRSRecordDescriptor((MTLTextureDescriptor *)self, @"setHeight");
}

static void BRS_setUsage(id self, SEL _cmd, MTLTextureUsage value) {
    ((void(*)(id, SEL, MTLTextureUsage))gOriginalSetUsage)(self, _cmd, value);
    BRSRecordDescriptor((MTLTextureDescriptor *)self, @"setUsage");
}

static void BRS_setSampleCount(id self, SEL _cmd, NSUInteger value) {
    ((void(*)(id, SEL, NSUInteger))gOriginalSetSampleCount)(self, _cmd, value);
    BRSRecordDescriptor((MTLTextureDescriptor *)self, @"setSampleCount");
}

static void BRS_setPixelFormat(id self, SEL _cmd, MTLPixelFormat value) {
    ((void(*)(id, SEL, MTLPixelFormat))gOriginalSetPixelFormat)(self, _cmd, value);
    BRSRecordDescriptor((MTLTextureDescriptor *)self, @"setPixelFormat");
}

static void BRSSwapInstance(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || !original) return;
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static void BRSSwapClass(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getClassMethod(cls, sel);
    if (!method || !original) return;
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static void BRSInstallProbe(void) {
    gSeen = [NSMutableSet set];

    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                     NSUserDomainMask,
                                                                     YES);
    NSString *documents = docs.firstObject ?: NSTemporaryDirectory();
    gLogPath = [documents stringByAppendingPathComponent:@"BedrockRenderProbe.log"];

    CGRect nativeBounds = UIScreen.mainScreen.nativeBounds;
    NSString *header = [NSString stringWithFormat:
                        @"BedrockRenderProbe v1\ndevice=%@\niOS=%@\nnative=%.0fx%.0f scale=%.2f nativeScale=%.2f\n---",
                        BRSDeviceModel(),
                        UIDevice.currentDevice.systemVersion,
                        nativeBounds.size.width,
                        nativeBounds.size.height,
                        UIScreen.mainScreen.scale,
                        UIScreen.mainScreen.nativeScale];
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

    BRSAppendLine(@"PROBE installed; no render sizes are modified.");
}

__attribute__((constructor))
static void BedrockRenderProbeInit(void) {
    @autoreleasepool {
        // This build is observation-only. Delay slightly to avoid touching early app startup.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BRSInstallProbe();
        });
    }
}
