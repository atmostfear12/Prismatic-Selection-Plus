#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static IMP gBRSOriginalLayerSetName = NULL;
static IMP gBRSOriginalLayerAddSublayer = NULL;

static BOOL BRSIsHynisLayerName(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return NO;
    return [name isEqualToString:@"HLBannerContainer"] ||
           [name isEqualToString:@"HLBannerBG"] ||
           [name isEqualToString:@"HLBannerText"];
}

static void BRS_layerSetName(CALayer *self, SEL _cmd, NSString *name) {
    ((void(*)(id, SEL, NSString *))gBRSOriginalLayerSetName)(self, _cmd, name);
    if (!BRSIsHynisLayerName(name)) return;

    self.hidden = YES;
    self.opacity = 0.0f;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self removeFromSuperlayer];
    });
}

static void BRS_layerAddSublayer(CALayer *self, SEL _cmd, CALayer *layer) {
    if (layer && BRSIsHynisLayerName(layer.name)) {
        layer.hidden = YES;
        layer.opacity = 0.0f;
        return;
    }
    ((void(*)(id, SEL, CALayer *))gBRSOriginalLayerAddSublayer)(self, _cmd, layer);
}

static void BRSRemoveNamedBannerLayers(CALayer *layer) {
    if (!layer) return;

    NSArray<CALayer *> *children = [layer.sublayers copy];
    for (CALayer *child in children) {
        if (BRSIsHynisLayerName(child.name)) {
            child.hidden = YES;
            child.opacity = 0.0f;
            [child removeFromSuperlayer];
            continue;
        }
        BRSRemoveNamedBannerLayers(child);
    }
}

static void BRSSweepHynisBanner(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;
        for (UIWindow *window in app.windows) {
            BRSRemoveNamedBannerLayers(window.layer);
        }

        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in app.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *window in ws.windows) {
                    BRSRemoveNamedBannerLayers(window.layer);
                }
            }
        }
    });
}

static void BRSInstallLayerHooks(void) {
    Class cls = [CALayer class];

    Method setName = class_getInstanceMethod(cls, @selector(setName:));
    if (setName) {
        gBRSOriginalLayerSetName = method_getImplementation(setName);
        method_setImplementation(setName, (IMP)BRS_layerSetName);
    }

    Method addSublayer = class_getInstanceMethod(cls, @selector(addSublayer:));
    if (addSublayer) {
        gBRSOriginalLayerAddSublayer = method_getImplementation(addSublayer);
        method_setImplementation(addSublayer, (IMP)BRS_layerAddSublayer);
    }
}

__attribute__((constructor))
static void BedrockHynisBannerSuppressInit(void) {
    @autoreleasepool {
        BRSInstallLayerHooks();

        // Covers either constructor order: banner already exists, or Hynis creates it later.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BRSSweepHynisBanner();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BRSSweepHynisBanner();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.00 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BRSSweepHynisBanner();
        });
    }
}
