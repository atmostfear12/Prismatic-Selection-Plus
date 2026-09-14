#import <Foundation/Foundation.h>

// Diagnostic build: intentionally does not hook CAMetalLayer or RenderDragon.
// This verifies that the dylib itself can be injected, signed, loaded, and
// launched inside Minecraft without crashing.

__attribute__((constructor))
static void BedrockRenderScaleDiagnosticInit(void) {
    @autoreleasepool {
        NSLog(@"[BedrockRenderScale] Diagnostic dylib loaded successfully. No hooks installed.");
    }
}
