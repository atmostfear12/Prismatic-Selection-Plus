// Ultra-minimal diagnostic dylib.
// No Objective-C, Foundation, QuartzCore, Metal, logging, or constructor code.
// If this still crashes when injected, the issue is injection/load/signing rather than tweak logic.

int BedrockRenderScale_DiagnosticSymbol = 1;
