#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>

#ifndef BEDROCK_RENDER_SCALE
#define BEDROCK_RENDER_SCALE 0.50
#endif

static const CGFloat kRenderScale = BEDROCK_RENDER_SCALE;
static IMP gOriginalSetDrawableSize = NULL;

static void BRS_setDrawableSize(id self, SEL _cmd, CGSize size) {
    if (gOriginalSetDrawableSize == NULL) {
        return;
    }

    if (size.width <= 1.0 || size.height <= 1.0) {
        ((void(*)(id, SEL, CGSize))gOriginalSetDrawableSize)(self, _cmd, size);
        return;
    }

    CGSize scaled = CGSizeMake(
        floor(size.width * kRenderScale),
        floor(size.height * kRenderScale)
    );

    scaled.width = MAX(2.0, scaled.width);
    scaled.height = MAX(2.0, scaled.height);

    NSLog(@"[BedrockRenderScale] %.0fx%.0f -> %.0fx%.0f (%.2fx)",
          size.width, size.height,
          scaled.width, scaled.height,
          kRenderScale);

    ((void(*)(id, SEL, CGSize))gOriginalSetDrawableSize)(self, _cmd, scaled);
}

__attribute__((constructor))
static void BedrockRenderScaleInit(void) {
    @autoreleasepool {
        Class cls = NSClassFromString(@"CAMetalLayer");
        SEL sel = @selector(setDrawableSize:);

        if (!cls) {
            NSLog(@"[BedrockRenderScale] CAMetalLayer class not found.");
            return;
        }

        Method method = class_getInstanceMethod(cls, sel);
        if (!method) {
            NSLog(@"[BedrockRenderScale] setDrawableSize: not found.");
            return;
        }

        gOriginalSetDrawableSize = method_getImplementation(method);
        method_setImplementation(method, (IMP)BRS_setDrawableSize);

        NSLog(@"[BedrockRenderScale] Loaded. Scale = %.2f", kRenderScale);
    }
}
