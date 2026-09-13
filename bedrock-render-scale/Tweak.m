#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#import <math.h>

#ifndef BEDROCK_RENDER_SCALE
#define BEDROCK_RENDER_SCALE 0.50
#endif

static const CGFloat kRenderScale = BEDROCK_RENDER_SCALE;
static IMP gOriginalSetDrawableSize = NULL;
static BOOL gHookInstalled = NO;

static void BRS_setDrawableSize(id self, SEL _cmd, CGSize size) {
    if (gOriginalSetDrawableSize == NULL) {
        return;
    }

    // Leave tiny/auxiliary Metal surfaces completely untouched.
    // On iPhone 13 the main game drawable is well above this threshold.
    CGFloat longSide = MAX(size.width, size.height);
    CGFloat shortSide = MIN(size.width, size.height);
    BOOL looksLikeMainGameSurface = (longSide >= 1500.0 && shortSide >= 700.0);

    if (!looksLikeMainGameSurface) {
        ((void(*)(id, SEL, CGSize))gOriginalSetDrawableSize)(self, _cmd, size);
        return;
    }

    CGSize scaled = CGSizeMake(
        floor(size.width * kRenderScale),
        floor(size.height * kRenderScale)
    );

    scaled.width = MAX(2.0, scaled.width);
    scaled.height = MAX(2.0, scaled.height);

    NSLog(@"[BedrockRenderScale] Main drawable %.0fx%.0f -> %.0fx%.0f (%.2fx)",
          size.width, size.height,
          scaled.width, scaled.height,
          kRenderScale);

    ((void(*)(id, SEL, CGSize))gOriginalSetDrawableSize)(self, _cmd, scaled);
}

static void BRS_installHook(void) {
    if (gHookInstalled) return;

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
    gHookInstalled = YES;

    NSLog(@"[BedrockRenderScale] Hook installed after startup. Scale = %.2f", kRenderScale);
}

__attribute__((constructor))
static void BedrockRenderScaleInit(void) {
    @autoreleasepool {
        NSLog(@"[BedrockRenderScale] Loaded; delaying Metal hook.");

        // Do not touch RenderDragon/Metal during the Mojang startup sequence.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BRS_installHook();
        });
    }
}
