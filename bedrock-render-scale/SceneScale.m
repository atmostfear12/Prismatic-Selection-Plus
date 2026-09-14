#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
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

static NSString *gLogPath = nil;
static BOOL gEnabledForDevice = NO;
static NSUInteger gPatchCount = 0;
static NSUInteger gViewportPatchCount = 0;
static NSUInteger gScissorPatchCount = 0;
static NSHashTable *gPatchedTextures = nil;
static char kBRSPatchedEncoderKey;

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

static BOOL BRSEncoderIsPatched(id encoder) {
    return [objc_getAssociatedObject(encoder, &kBRSPatchedEncoderKey) boolValue];
}

static BOOL BRSTextureWasPatched(id<MTLTexture> texture) {
    if (!texture || !gPatchedTextures) return NO;
    @synchronized (gPatchedTextures) {
        return [gPatchedTextures containsObject:texture];
    }
}

static BOOL BRSRenderPassUsesPatchedTexture(MTLRenderPassDescriptor *descriptor) {
    if (!descriptor) return NO;

    for (NSUInteger i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *attachment = [descriptor.colorAttachments objectAtIndexedSubscript:i];
        if (BRSTextureWasPatched(attachment.texture) || BRSTextureWasPatched(attachment.resolveTexture)) {
            return YES;
        }
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
    NSUInteger oldW = patched.width;
    NSUInteger oldH = patched.height;
    patched.width = BRSScaledDimension(oldW);
    patched.height = BRSScaledDimension(oldH);

    id texture = ((id(*)(id, SEL, MTLTextureDescriptor *))gOriginalNewTexture)(self, _cmd, patched);

    if (texture) {
        @synchronized (gPatchedTextures) {
            [gPatchedTextures addObject:texture];
        }
    }

    NSUInteger count = ++gPatchCount;
    if (count <= 128) {
        BRSLog([NSString stringWithFormat:
                @"TARGET #%lu %lux%lu -> %lux%lu pf=%lu usage=0x%lx storage=%lu success=%@",
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
        if (BRSAdjustViewport(&adjusted)) {
            NSUInteger count = ++gViewportPatchCount;
            if (count <= 128) {
                BRSLog([NSString stringWithFormat:@"VIEWPORT #%lu %.0fx%.0f -> %.0fx%.0f",
                        (unsigned long)count,
                        viewport.width, viewport.height,
                        adjusted.width, adjusted.height]);
            }
            viewport = adjusted;
        }
    }
    ((void(*)(id, SEL, MTLViewport))gOriginalSetViewport)(self, _cmd, viewport);
}

static void BRS_setViewports(id self, SEL _cmd, const MTLViewport *viewports, NSUInteger count) {
    if (!BRSEncoderIsPatched(self) || !viewports || count == 0) {
        ((void(*)(id, SEL, const MTLViewport *, NSUInteger))gOriginalSetViewports)(self, _cmd, viewports, count);
        return;
    }

    MTLViewport *copy = malloc(sizeof(MTLViewport) * count);
    if (!copy) {
        ((void(*)(id, SEL, const MTLViewport *, NSUInteger))gOriginalSetViewports)(self, _cmd, viewports, count);
        return;
    }

    memcpy(copy, viewports, sizeof(MTLViewport) * count);
    for (NSUInteger i = 0; i < count; i++) {
        BRSAdjustViewport(&copy[i]);
    }
    ((void(*)(id, SEL, const MTLViewport *, NSUInteger))gOriginalSetViewports)(self, _cmd, copy, count);
    free(copy);
}

static void BRS_setScissorRect(id self, SEL _cmd, MTLScissorRect rect) {
    if (BRSEncoderIsPatched(self)) {
        MTLScissorRect adjusted = rect;
        if (BRSAdjustScissor(&adjusted)) {
            NSUInteger count = ++gScissorPatchCount;
            if (count <= 128) {
                BRSLog([NSString stringWithFormat:@"SCISSOR #%lu %lux%lu -> %lux%lu",
                        (unsigned long)count,
                        (unsigned long)rect.width, (unsigned long)rect.height,
                        (unsigned long)adjusted.width, (unsigned long)adjusted.height]);
            }
            rect = adjusted;
        }
    }
    ((void(*)(id, SEL, MTLScissorRect))gOriginalSetScissorRect)(self, _cmd, rect);
}

static void BRS_setScissorRects(id self, SEL _cmd, const MTLScissorRect *rects, NSUInteger count) {
    if (!BRSEncoderIsPatched(self) || !rects || count == 0) {
        ((void(*)(id, SEL, const MTLScissorRect *, NSUInteger))gOriginalSetScissorRects)(self, _cmd, rects, count);
        return;
    }

    MTLScissorRect *copy = malloc(sizeof(MTLScissorRect) * count);
    if (!copy) {
        ((void(*)(id, SEL, const MTLScissorRect *, NSUInteger))gOriginalSetScissorRects)(self, _cmd, rects, count);
        return;
    }

    memcpy(copy, rects, sizeof(MTLScissorRect) * count);
    for (NSUInteger i = 0; i < count; i++) {
        BRSAdjustScissor(&copy[i]);
    }
    ((void(*)(id, SEL, const MTLScissorRect *, NSUInteger))gOriginalSetScissorRects)(self, _cmd, copy, count);
    free(copy);
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
    if (!queue) {
        BRSLog(@"ERROR could not create diagnostic command queue");
        return NO;
    }

    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    if (!commandBuffer) {
        BRSLog(@"ERROR could not create diagnostic command buffer");
        return NO;
    }

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:4
                                                                                 height:4
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> tempTexture = [device newTextureWithDescriptor:td];
    if (!tempTexture) {
        BRSLog(@"ERROR could not create diagnostic texture");
        return NO;
    }

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tempTexture;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionDontCare;

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:rp];
    if (!encoder) {
        BRSLog(@"ERROR could not create diagnostic render encoder");
        return NO;
    }

    Class commandBufferClass = object_getClass(commandBuffer);
    Class encoderClass = object_getClass(encoder);

    [encoder endEncoding];

    BOOL okRender = BRSInstallInstanceHook(commandBufferClass,
                                           @selector(renderCommandEncoderWithDescriptor:),
                                           (IMP)BRS_renderCommandEncoderWithDescriptor,
                                           &gOriginalRenderEncoder);
    BOOL okViewport = BRSInstallInstanceHook(encoderClass,
                                             @selector(setViewport:),
                                             (IMP)BRS_setViewport,
                                             &gOriginalSetViewport);
    BOOL okScissor = BRSInstallInstanceHook(encoderClass,
                                            @selector(setScissorRect:),
                                            (IMP)BRS_setScissorRect,
                                            &gOriginalSetScissorRect);

    Method mv = class_getInstanceMethod(encoderClass, @selector(setViewports:count:));
    if (mv) {
        BRSInstallInstanceHook(encoderClass,
                               @selector(setViewports:count:),
                               (IMP)BRS_setViewports,
                               &gOriginalSetViewports);
    }

    Method ms = class_getInstanceMethod(encoderClass, @selector(setScissorRects:count:));
    if (ms) {
        BRSInstallInstanceHook(encoderClass,
                               @selector(setScissorRects:count:),
                               (IMP)BRS_setScissorRects,
                               &gOriginalSetScissorRects);
    }

    BRSLog([NSString stringWithFormat:@"ENCODER_HOOK commandBuffer=%@ encoder=%@ render=%@ viewport=%@ scissor=%@",
            NSStringFromClass(commandBufferClass),
            NSStringFromClass(encoderClass),
            okRender ? @"YES" : @"NO",
            okViewport ? @"YES" : @"NO",
            okScissor ? @"YES" : @"NO"]);

    return okRender && okViewport && okScissor;
}

static BOOL BRSInstallDeviceHook(id<MTLDevice> device) {
    Class cls = object_getClass(device);
    BOOL ok = BRSInstallInstanceHook(cls,
                                     @selector(newTextureWithDescriptor:),
                                     (IMP)BRS_newTextureWithDescriptor,
                                     &gOriginalNewTexture);
    if (!ok) {
        BRSLog([NSString stringWithFormat:@"ERROR %@ has no newTextureWithDescriptor:", NSStringFromClass(cls)]);
        return NO;
    }

    BRSLog([NSString stringWithFormat:@"DEVICE_HOOK class=%@ gpu=%@", NSStringFromClass(cls), device.name ?: @"unknown"]);
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
        gPatchedTextures = [NSHashTable weakObjectsHashTable];

        NSString *header = [NSString stringWithFormat:
                            @"BedrockSceneScale experimental v2\ndevice=%@\nscale=%.4f\nmode=coordinated-target-viewport-scissor\n---",
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

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            BRSLog(@"ERROR MTLCreateSystemDefaultDevice returned nil");
            return;
        }

        if (!BRSInstallEncoderHooks(device)) {
            BRSLog(@"DISABLED: encoder hooks incomplete; texture scaling was NOT installed.");
            return;
        }

        if (!BRSInstallDeviceHook(device)) {
            BRSLog(@"DISABLED: texture hook install failed.");
            return;
        }

        BRSLog(@"ACTIVE: native presentation remains untouched. Only tracked RenderDragon targets and their matching full-frame viewport/scissor state are scaled.");
    }
}
