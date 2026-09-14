#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/utsname.h>
#import <math.h>

#ifndef BEDROCK_SCENE_SCALE
#define BEDROCK_SCENE_SCALE 0.66
#endif

static const double kSceneScale = BEDROCK_SCENE_SCALE;
static const NSUInteger kNativeW = 2532;
static const NSUInteger kNativeH = 1170;

static IMP gOriginalNewTexture = NULL;
static IMP gOriginalRenderEncoder = NULL;
static IMP gOriginalSetViewport = NULL;
static IMP gOriginalSetViewports = NULL;
static IMP gOriginalSetScissorRect = NULL;
static IMP gOriginalSetScissorRects = NULL;
static IMP gOriginalNewRenderPipeline = NULL;

static BOOL gEnabledForDevice = NO;
static char kBRSPatchedTextureKey;
static char kBRSPatchedEncoderKey;

static id<MTLBinaryArchive> gPipelineArchive = nil;
static NSString *gPipelineArchivePath = nil;
static NSMutableArray<MTLRenderPipelineDescriptor *> *gCapturedPipelineDescriptors = nil;
static dispatch_queue_t gArchiveQueue;
static BOOL gArchiveFlushStarted = NO;

static NSString *BRSDeviceModel(void) {
    struct utsname info;
    uname(&info);
    return [NSString stringWithUTF8String:info.machine];
}

static BOOL BRSIsKnownRenderTargetFormat(MTLPixelFormat pf) {
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

static BOOL BRSIsNativeSize(NSUInteger width, NSUInteger height) {
    return ((width == kNativeW && height == kNativeH) ||
            (width == kNativeH && height == kNativeW));
}

static BOOL BRSShouldScaleDescriptor(MTLTextureDescriptor *d) {
    if (!gEnabledForDevice || !d) return NO;
    if (!BRSIsNativeSize(d.width, d.height)) return NO;

    MTLTextureUsage required = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
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
    return (NSUInteger)MAX(2.0, scaled);
}

static BOOL BRSNear(double a, double b) {
    return fabs(a - b) <= 1.0;
}

static BOOL BRSAdjustViewport(MTLViewport *v) {
    if (!v) return NO;
    BOOL landscape = BRSNear(v->width, (double)kNativeW) && BRSNear(v->height, (double)kNativeH);
    BOOL portrait = BRSNear(v->width, (double)kNativeH) && BRSNear(v->height, (double)kNativeW);
    if (!landscape && !portrait) return NO;

    v->originX *= kSceneScale;
    v->originY *= kSceneScale;
    v->width = floor(v->width * kSceneScale);
    v->height = floor(v->height * kSceneScale);
    return YES;
}

static BOOL BRSAdjustScissor(MTLScissorRect *r) {
    if (!r) return NO;
    BOOL landscape = (r->width == kNativeW && r->height == kNativeH);
    BOOL portrait = (r->width == kNativeH && r->height == kNativeW);
    if (!landscape && !portrait) return NO;

    r->x = (NSUInteger)floor((double)r->x * kSceneScale);
    r->y = (NSUInteger)floor((double)r->y * kSceneScale);
    r->width = BRSScaledDimension(r->width);
    r->height = BRSScaledDimension(r->height);
    return YES;
}

static inline BOOL BRSTextureWasPatched(id<MTLTexture> texture) {
    return texture && objc_getAssociatedObject(texture, &kBRSPatchedTextureKey) != nil;
}

static inline BOOL BRSEncoderIsPatched(id encoder) {
    return encoder && objc_getAssociatedObject(encoder, &kBRSPatchedEncoderKey) != nil;
}

static BOOL BRSRenderPassUsesPatchedTexture(MTLRenderPassDescriptor *descriptor) {
    if (!descriptor) return NO;
    for (NSUInteger i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = descriptor.colorAttachments[i];
        if (BRSTextureWasPatched(a.texture) || BRSTextureWasPatched(a.resolveTexture)) return YES;
    }
    if (BRSTextureWasPatched(descriptor.depthAttachment.texture)) return YES;
    if (BRSTextureWasPatched(descriptor.stencilAttachment.texture)) return YES;
    return NO;
}

static id BRS_newTextureWithDescriptor(id self, SEL _cmd, MTLTextureDescriptor *descriptor) {
    if (!gOriginalNewTexture || !descriptor || !BRSShouldScaleDescriptor(descriptor)) {
        return ((id(*)(id, SEL, MTLTextureDescriptor *))gOriginalNewTexture)(self, _cmd, descriptor);
    }

    MTLTextureDescriptor *patched = [descriptor copy];
    patched.width = BRSScaledDimension(patched.width);
    patched.height = BRSScaledDimension(patched.height);

    id texture = ((id(*)(id, SEL, MTLTextureDescriptor *))gOriginalNewTexture)(self, _cmd, patched);
    if (texture) {
        objc_setAssociatedObject(texture, &kBRSPatchedTextureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return texture;
}

static id BRS_renderCommandEncoderWithDescriptor(id self, SEL _cmd, MTLRenderPassDescriptor *descriptor) {
    id encoder = ((id(*)(id, SEL, MTLRenderPassDescriptor *))gOriginalRenderEncoder)(self, _cmd, descriptor);
    if (encoder && BRSRenderPassUsesPatchedTexture(descriptor)) {
        objc_setAssociatedObject(encoder, &kBRSPatchedEncoderKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return encoder;
}

static void BRS_setViewport(id self, SEL _cmd, MTLViewport viewport) {
    if (BRSEncoderIsPatched(self)) {
        MTLViewport adjusted = viewport;
        if (BRSAdjustViewport(&adjusted)) viewport = adjusted;
    }
    ((void(*)(id, SEL, MTLViewport))gOriginalSetViewport)(self, _cmd, viewport);
}

static void BRS_setViewports(id self, SEL _cmd, const MTLViewport *viewports, NSUInteger count) {
    if (!BRSEncoderIsPatched(self) || !viewports || count == 0 || count > 16) {
        ((void(*)(id, SEL, const MTLViewport *, NSUInteger))gOriginalSetViewports)(self, _cmd, viewports, count);
        return;
    }

    MTLViewport local[16];
    memcpy(local, viewports, sizeof(MTLViewport) * count);
    for (NSUInteger i = 0; i < count; i++) BRSAdjustViewport(&local[i]);
    ((void(*)(id, SEL, const MTLViewport *, NSUInteger))gOriginalSetViewports)(self, _cmd, local, count);
}

static void BRS_setScissorRect(id self, SEL _cmd, MTLScissorRect rect) {
    if (BRSEncoderIsPatched(self)) {
        MTLScissorRect adjusted = rect;
        if (BRSAdjustScissor(&adjusted)) rect = adjusted;
    }
    ((void(*)(id, SEL, MTLScissorRect))gOriginalSetScissorRect)(self, _cmd, rect);
}

static void BRS_setScissorRects(id self, SEL _cmd, const MTLScissorRect *rects, NSUInteger count) {
    if (!BRSEncoderIsPatched(self) || !rects || count == 0 || count > 16) {
        ((void(*)(id, SEL, const MTLScissorRect *, NSUInteger))gOriginalSetScissorRects)(self, _cmd, rects, count);
        return;
    }

    MTLScissorRect local[16];
    memcpy(local, rects, sizeof(MTLScissorRect) * count);
    for (NSUInteger i = 0; i < count; i++) BRSAdjustScissor(&local[i]);
    ((void(*)(id, SEL, const MTLScissorRect *, NSUInteger))gOriginalSetScissorRects)(self, _cmd, local, count);
}

static id BRS_newRenderPipelineStateWithDescriptor(id self, SEL _cmd, MTLRenderPipelineDescriptor *descriptor, NSError **error) {
    if (!gOriginalNewRenderPipeline || !descriptor) {
        return ((id(*)(id, SEL, MTLRenderPipelineDescriptor *, NSError **))gOriginalNewRenderPipeline)(self, _cmd, descriptor, error);
    }

    MTLRenderPipelineDescriptor *patched = [descriptor copy];
    if (@available(iOS 14.0, *)) {
        if (gPipelineArchive) patched.binaryArchives = @[gPipelineArchive];
    }

    if (gCapturedPipelineDescriptors) {
        @synchronized (gCapturedPipelineDescriptors) {
            if (gCapturedPipelineDescriptors.count < 128) {
                [gCapturedPipelineDescriptors addObject:[descriptor copy]];
            }
        }
    }

    return ((id(*)(id, SEL, MTLRenderPipelineDescriptor *, NSError **))gOriginalNewRenderPipeline)(self, _cmd, patched, error);
}

static BOOL BRSInstallInstanceHook(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls || !original) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    *original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, sel, replacement, types)) {
        Method localMethod = class_getInstanceMethod(cls, sel);
        method_setImplementation(localMethod, replacement);
    }
    return YES;
}

static BOOL BRSInstallEncoderHooks(id<MTLDevice> device) {
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) return NO;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    if (!cb) return NO;

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> temp = [device newTextureWithDescriptor:td];
    if (!temp) return NO;

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = temp;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionDontCare;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    if (!enc) return NO;

    Class cbClass = object_getClass(cb);
    Class encClass = object_getClass(enc);
    [enc endEncoding];

    BOOL okRender = BRSInstallInstanceHook(cbClass, @selector(renderCommandEncoderWithDescriptor:), (IMP)BRS_renderCommandEncoderWithDescriptor, &gOriginalRenderEncoder);
    BOOL okViewport = BRSInstallInstanceHook(encClass, @selector(setViewport:), (IMP)BRS_setViewport, &gOriginalSetViewport);
    BOOL okScissor = BRSInstallInstanceHook(encClass, @selector(setScissorRect:), (IMP)BRS_setScissorRect, &gOriginalSetScissorRect);

    if (class_getInstanceMethod(encClass, @selector(setViewports:count:))) {
        BRSInstallInstanceHook(encClass, @selector(setViewports:count:), (IMP)BRS_setViewports, &gOriginalSetViewports);
    }
    if (class_getInstanceMethod(encClass, @selector(setScissorRects:count:))) {
        BRSInstallInstanceHook(encClass, @selector(setScissorRects:count:), (IMP)BRS_setScissorRects, &gOriginalSetScissorRects);
    }

    return okRender && okViewport && okScissor;
}

static void BRSPreparePipelineArchive(id<MTLDevice> device) {
    if (@available(iOS 14.0, *)) {
        NSArray<NSString *> *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *cacheDir = caches.firstObject ?: NSTemporaryDirectory();
        gPipelineArchivePath = [cacheDir stringByAppendingPathComponent:@"BedrockA15RenderPipelines.metalarc"];
        gCapturedPipelineDescriptors = [NSMutableArray array];
        gArchiveQueue = dispatch_queue_create("bedrock.a15.pipeline.archive", DISPATCH_QUEUE_SERIAL);

        MTLBinaryArchiveDescriptor *bd = [MTLBinaryArchiveDescriptor new];
        if ([[NSFileManager defaultManager] fileExistsAtPath:gPipelineArchivePath]) {
            bd.url = [NSURL fileURLWithPath:gPipelineArchivePath];
        }
        NSError *archiveError = nil;
        gPipelineArchive = [device newBinaryArchiveWithDescriptor:bd error:&archiveError];
        if (!gPipelineArchive) {
            bd.url = nil;
            gPipelineArchive = [device newBinaryArchiveWithDescriptor:bd error:nil];
        }
    }
}

static void BRSFlushPipelineArchive(void) {
    if (@available(iOS 14.0, *)) {
        if (!gPipelineArchive || !gPipelineArchivePath || gArchiveFlushStarted) return;
        gArchiveFlushStarted = YES;

        NSArray<MTLRenderPipelineDescriptor *> *snapshot = nil;
        @synchronized (gCapturedPipelineDescriptors) {
            snapshot = [gCapturedPipelineDescriptors copy];
        }
        if (snapshot.count == 0) {
            gArchiveFlushStarted = NO;
            return;
        }

        __block UIBackgroundTaskIdentifier bg = UIBackgroundTaskInvalid;
        bg = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"BedrockPipelineCache" expirationHandler:^{
            if (bg != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:bg];
                bg = UIBackgroundTaskInvalid;
            }
        }];

        dispatch_async(gArchiveQueue, ^{
            for (MTLRenderPipelineDescriptor *d in snapshot) {
                @autoreleasepool {
                    [gPipelineArchive addRenderPipelineFunctionsWithDescriptor:d error:nil];
                }
            }
            [gPipelineArchive serializeToURL:[NSURL fileURLWithPath:gPipelineArchivePath] error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                gArchiveFlushStarted = NO;
                if (bg != UIBackgroundTaskInvalid) {
                    [[UIApplication sharedApplication] endBackgroundTask:bg];
                    bg = UIBackgroundTaskInvalid;
                }
            });
        });
    }
}

static BOOL BRSInstallDeviceHooks(id<MTLDevice> device) {
    Class cls = object_getClass(device);
    BOOL textureOK = BRSInstallInstanceHook(cls, @selector(newTextureWithDescriptor:), (IMP)BRS_newTextureWithDescriptor, &gOriginalNewTexture);
    BOOL pipelineOK = YES;
    if (class_getInstanceMethod(cls, @selector(newRenderPipelineStateWithDescriptor:error:))) {
        pipelineOK = BRSInstallInstanceHook(cls, @selector(newRenderPipelineStateWithDescriptor:error:), (IMP)BRS_newRenderPipelineStateWithDescriptor, &gOriginalNewRenderPipeline);
    }
    return textureOK && pipelineOK;
}

__attribute__((constructor))
static void BedrockSceneScaleInit(void) {
    @autoreleasepool {
        NSString *model = BRSDeviceModel();
        gEnabledForDevice = [model isEqualToString:@"iPhone14,5"];
        if (!gEnabledForDevice) return;
        if (kSceneScale < 0.50 || kSceneScale > 1.00) return;

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return;

        BRSPreparePipelineArchive(device);

        if (!BRSInstallEncoderHooks(device)) return;
        if (!BRSInstallDeviceHooks(device)) return;

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            BRSFlushPipelineArchive();
        }];
    }
}
