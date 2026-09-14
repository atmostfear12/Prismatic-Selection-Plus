// Ultra-minimal diagnostic dylib for Hynis/Minecraft iOS.
// Plain C only: no Objective-C runtime, no Foundation, no Metal, no constructors.
// Purpose: verify that Sideloadly can inject and load our dylib at all.

__attribute__((visibility("default")))
int BedrockRenderScale_DiagnosticSymbol = 1;
