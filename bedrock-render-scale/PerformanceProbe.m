#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <sys/utsname.h>

// Observation-only profiler for Minecraft Bedrock on iPhone 13.
// No render-resolution, CAMetalLayer, queue-depth, FPS-cap, or game-state changes.
// Hot paths only update atomics. Disk I/O occurs on lifecycle/background summary dumps.

static NSString *gLogPath = nil;
static mach_timebase_info_data_t gTimebase;

static IMP gOriginalCommit = NULL;
static IMP gOriginalPresent = NULL;
static IMP gOriginalPresentAtTime = NULL;
static IMP gOriginalPresentAfterDuration = NULL;
static IMP gOriginalNewTexture = NULL;
static IMP gOriginalNewRenderPSO = NULL;
static IMP gOriginalNewComputePSO = NULL;

static atomic_uint_fast64_t gPresentCount;
static atomic_uint_fast64_t gPresentIntervalCount;
static atomic_uint_fast64_t gPresentIntervalSumUs;
static atomic_uint_fast64_t gPresentIntervalMaxUs;
static atomic_uint_fast64_t gLastPresentTick;
static atomic_uint_fast64_t gFrameLE17;
static atomic_uint_fast64_t gFrameLE20;
static atomic_uint_fast64_t gFrameLE25;
static atomic_uint_fast64_t gFrameLE33;
static atomic_uint_fast64_t gFrameLE50;
static atomic_uint_fast64_t gFrameGT50;

static atomic_uint_fast64_t gCommitCount;
static atomic_uint_fast64_t gGpuSampleCount;
static atomic_uint_fast64_t gGpuSampleSumUs;
static atomic_uint_fast64_t gGpuSampleMaxUs;

static atomic_uint_fast64_t gTextureCount;
static atomic_uint_fast64_t gTextureSlow500us;
static atomic_uint_fast64_t gTextureSlow2ms;
static atomic_uint_fast64_t gTextureSlow5ms;
static atomic_uint_fast64_t gTextureMaxUs;

static atomic_uint_fast64_t gRenderPSOCount;
static atomic_uint_fast64_t gRenderPSOSlow5ms;
static atomic_uint_fast64_t gRenderPSOSlow16ms;
static atomic_uint_fast64_t gRenderPSOMaxUs;

static atomic_uint_fast64_t gComputePSOCount;
static atomic_uint_fast64_t gComputePSOSlow5ms;
static atomic_uint_fast64_t gComputePSOSlow16ms;
static atomic_uint_fast64_t gComputePSOMaxUs;

static NSString *DeviceModel(void) {
    struct utsname u;
    uname(&u);
    return [NSString stringWithUTF8String:u.machine];
}

static inline uint64_t TicksToUs(uint64_t ticks) {
    __uint128_t ns = (__uint128_t)ticks * gTimebase.numer / gTimebase.denom;
    return (uint64_t)(ns / 1000u);
}

static inline void AtomicMax(atomic_uint_fast64_t *target, uint64_t value) {
    uint64_t cur = atomic_load_explicit(target, memory_order_relaxed);
    while (value > cur &&
           !atomic_compare_exchange_weak_explicit(target, &cur, value,
                                                  memory_order_relaxed,
                                                  memory_order_relaxed)) {}
}

static void AppendLine(NSString *line) {
    if (!line || !gLogPath) return;
    NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (!f) {
        [[NSFileManager defaultManager] createFileAtPath:gLogPath contents:d attributes:nil];
        return;
    }
    [f seekToEndOfFile];
    [f writeData:d];
    [f closeFile];
}

static inline void RecordDuration(uint64_t us,
                                  atomic_uint_fast64_t *count,
                                  atomic_uint_fast64_t *slowA,
                                  uint64_t thresholdA,
                                  atomic_uint_fast64_t *slowB,
                                  uint64_t thresholdB,
                                  atomic_uint_fast64_t *maxValue) {
    atomic_fetch_add_explicit(count, 1, memory_order_relaxed);
    if (slowA && us >= thresholdA) atomic_fetch_add_explicit(slowA, 1, memory_order_relaxed);
    if (slowB && us >= thresholdB) atomic_fetch_add_explicit(slowB, 1, memory_order_relaxed);
    AtomicMax(maxValue, us);
}

static inline void RecordPresent(void) {
    uint64_t now = mach_absolute_time();
    uint64_t prev = atomic_exchange_explicit(&gLastPresentTick, now, memory_order_relaxed);
    atomic_fetch_add_explicit(&gPresentCount, 1, memory_order_relaxed);
    if (!prev || now <= prev) return;

    uint64_t us = TicksToUs(now - prev);
    // Ignore lifecycle gaps; only classify plausible active rendering intervals.
    if (us > 500000) return;

    atomic_fetch_add_explicit(&gPresentIntervalCount, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&gPresentIntervalSumUs, us, memory_order_relaxed);
    AtomicMax(&gPresentIntervalMaxUs, us);

    if (us <= 17000) atomic_fetch_add_explicit(&gFrameLE17, 1, memory_order_relaxed);
    else if (us <= 20000) atomic_fetch_add_explicit(&gFrameLE20, 1, memory_order_relaxed);
    else if (us <= 25000) atomic_fetch_add_explicit(&gFrameLE25, 1, memory_order_relaxed);
    else if (us <= 33000) atomic_fetch_add_explicit(&gFrameLE33, 1, memory_order_relaxed);
    else if (us <= 50000) atomic_fetch_add_explicit(&gFrameLE50, 1, memory_order_relaxed);
    else atomic_fetch_add_explicit(&gFrameGT50, 1, memory_order_relaxed);
}

static void Perf_commit(id self, SEL _cmd) {
    uint64_t n = atomic_fetch_add_explicit(&gCommitCount, 1, memory_order_relaxed) + 1;

    // GPU completion instrumentation is intentionally sampled only once per 30 command buffers.
    // This avoids allocating a completion block on every frame/command buffer.
    if ((n % 30u) == 0u && [self respondsToSelector:@selector(addCompletedHandler:)]) {
        uint64_t start = mach_absolute_time();
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            (void)cb;
            uint64_t end = mach_absolute_time();
            if (end <= start) return;
            uint64_t us = TicksToUs(end - start);
            atomic_fetch_add_explicit(&gGpuSampleCount, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&gGpuSampleSumUs, us, memory_order_relaxed);
            AtomicMax(&gGpuSampleMaxUs, us);
        }];
    }

    ((void(*)(id, SEL))gOriginalCommit)(self, _cmd);
}

static void Perf_presentDrawable(id self, SEL _cmd, id<CAMetalDrawable> drawable) {
    RecordPresent();
    ((void(*)(id, SEL, id<CAMetalDrawable>))gOriginalPresent)(self, _cmd, drawable);
}

static void Perf_presentDrawableAtTime(id self, SEL _cmd, id<CAMetalDrawable> drawable, CFTimeInterval time) {
    RecordPresent();
    ((void(*)(id, SEL, id<CAMetalDrawable>, CFTimeInterval))gOriginalPresentAtTime)(self, _cmd, drawable, time);
}

static void Perf_presentDrawableAfterDuration(id self, SEL _cmd, id<CAMetalDrawable> drawable, CFTimeInterval duration) {
    RecordPresent();
    ((void(*)(id, SEL, id<CAMetalDrawable>, CFTimeInterval))gOriginalPresentAfterDuration)(self, _cmd, drawable, duration);
}

static id Perf_newTexture(id self, SEL _cmd, MTLTextureDescriptor *descriptor) {
    uint64_t t0 = mach_absolute_time();
    id result = ((id(*)(id, SEL, MTLTextureDescriptor *))gOriginalNewTexture)(self, _cmd, descriptor);
    uint64_t t1 = mach_absolute_time();
    uint64_t us = (t1 > t0) ? TicksToUs(t1 - t0) : 0;

    atomic_fetch_add_explicit(&gTextureCount, 1, memory_order_relaxed);
    if (us >= 500) atomic_fetch_add_explicit(&gTextureSlow500us, 1, memory_order_relaxed);
    if (us >= 2000) atomic_fetch_add_explicit(&gTextureSlow2ms, 1, memory_order_relaxed);
    if (us >= 5000) atomic_fetch_add_explicit(&gTextureSlow5ms, 1, memory_order_relaxed);
    AtomicMax(&gTextureMaxUs, us);
    return result;
}

static id Perf_newRenderPSO(id self, SEL _cmd, MTLRenderPipelineDescriptor *descriptor, NSError **error) {
    uint64_t t0 = mach_absolute_time();
    id result = ((id(*)(id, SEL, MTLRenderPipelineDescriptor *, NSError **))gOriginalNewRenderPSO)(self, _cmd, descriptor, error);
    uint64_t t1 = mach_absolute_time();
    uint64_t us = (t1 > t0) ? TicksToUs(t1 - t0) : 0;
    RecordDuration(us, &gRenderPSOCount, &gRenderPSOSlow5ms, 5000, &gRenderPSOSlow16ms, 16000, &gRenderPSOMaxUs);
    return result;
}

static id Perf_newComputePSO(id self, SEL _cmd, id<MTLFunction> function, NSError **error) {
    uint64_t t0 = mach_absolute_time();
    id result = ((id(*)(id, SEL, id<MTLFunction>, NSError **))gOriginalNewComputePSO)(self, _cmd, function, error);
    uint64_t t1 = mach_absolute_time();
    uint64_t us = (t1 > t0) ? TicksToUs(t1 - t0) : 0;
    RecordDuration(us, &gComputePSOCount, &gComputePSOSlow5ms, 5000, &gComputePSOSlow16ms, 16000, &gComputePSOMaxUs);
    return result;
}

static BOOL InstallHook(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls || !sel || !replacement || !original) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    *original = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!class_addMethod(cls, sel, replacement, types)) {
        Method local = class_getInstanceMethod(cls, sel);
        method_setImplementation(local, replacement);
    }
    return YES;
}

static void DumpSummary(NSString *reason) {
    uint64_t intervals = atomic_load_explicit(&gPresentIntervalCount, memory_order_relaxed);
    uint64_t presentSum = atomic_load_explicit(&gPresentIntervalSumUs, memory_order_relaxed);
    uint64_t gpuN = atomic_load_explicit(&gGpuSampleCount, memory_order_relaxed);
    uint64_t gpuSum = atomic_load_explicit(&gGpuSampleSumUs, memory_order_relaxed);

    double avgFrameMs = intervals ? ((double)presentSum / (double)intervals / 1000.0) : 0.0;
    double avgGpuMs = gpuN ? ((double)gpuSum / (double)gpuN / 1000.0) : 0.0;

    AppendLine(@"--- SUMMARY ---");
    AppendLine([NSString stringWithFormat:@"reason=%@", reason ?: @"unknown"]);
    AppendLine([NSString stringWithFormat:@"present_count=%llu interval_samples=%llu avg_interval_ms=%.3f max_interval_ms=%.3f",
                atomic_load_explicit(&gPresentCount, memory_order_relaxed), intervals, avgFrameMs,
                (double)atomic_load_explicit(&gPresentIntervalMaxUs, memory_order_relaxed) / 1000.0]);
    AppendLine([NSString stringWithFormat:@"frame_buckets_ms <=17:%llu 17-20:%llu 20-25:%llu 25-33:%llu 33-50:%llu >50:%llu",
                atomic_load_explicit(&gFrameLE17, memory_order_relaxed),
                atomic_load_explicit(&gFrameLE20, memory_order_relaxed),
                atomic_load_explicit(&gFrameLE25, memory_order_relaxed),
                atomic_load_explicit(&gFrameLE33, memory_order_relaxed),
                atomic_load_explicit(&gFrameLE50, memory_order_relaxed),
                atomic_load_explicit(&gFrameGT50, memory_order_relaxed)]);
    AppendLine([NSString stringWithFormat:@"command_buffers=%llu gpu_samples=%llu avg_gpu_completion_ms=%.3f max_gpu_completion_ms=%.3f",
                atomic_load_explicit(&gCommitCount, memory_order_relaxed), gpuN, avgGpuMs,
                (double)atomic_load_explicit(&gGpuSampleMaxUs, memory_order_relaxed) / 1000.0]);
    AppendLine([NSString stringWithFormat:@"textures=%llu >=0.5ms:%llu >=2ms:%llu >=5ms:%llu max_ms=%.3f",
                atomic_load_explicit(&gTextureCount, memory_order_relaxed),
                atomic_load_explicit(&gTextureSlow500us, memory_order_relaxed),
                atomic_load_explicit(&gTextureSlow2ms, memory_order_relaxed),
                atomic_load_explicit(&gTextureSlow5ms, memory_order_relaxed),
                (double)atomic_load_explicit(&gTextureMaxUs, memory_order_relaxed) / 1000.0]);
    AppendLine([NSString stringWithFormat:@"render_pso=%llu >=5ms:%llu >=16ms:%llu max_ms=%.3f",
                atomic_load_explicit(&gRenderPSOCount, memory_order_relaxed),
                atomic_load_explicit(&gRenderPSOSlow5ms, memory_order_relaxed),
                atomic_load_explicit(&gRenderPSOSlow16ms, memory_order_relaxed),
                (double)atomic_load_explicit(&gRenderPSOMaxUs, memory_order_relaxed) / 1000.0]);
    AppendLine([NSString stringWithFormat:@"compute_pso=%llu >=5ms:%llu >=16ms:%llu max_ms=%.3f",
                atomic_load_explicit(&gComputePSOCount, memory_order_relaxed),
                atomic_load_explicit(&gComputePSOSlow5ms, memory_order_relaxed),
                atomic_load_explicit(&gComputePSOSlow16ms, memory_order_relaxed),
                (double)atomic_load_explicit(&gComputePSOMaxUs, memory_order_relaxed) / 1000.0]);
    AppendLine(@"--- END SUMMARY ---");
}

static void InstallLifecycleDump(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n) {
        DumpSummary(@"did-enter-background");
    }];
    [nc addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n) {
        DumpSummary(@"will-terminate");
    }];
}

__attribute__((constructor))
static void BedrockPerformanceProbeInit(void) {
    @autoreleasepool {
        mach_timebase_info(&gTimebase);

        NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documents = docs.firstObject ?: NSTemporaryDirectory();
        gLogPath = [documents stringByAppendingPathComponent:@"BedrockPerformance.log"];

        NSString *model = DeviceModel();
        NSString *header = [NSString stringWithFormat:
                            @"BedrockPerformance diagnostic v1\ndevice=%@\niOS=%@\nmode=observation-only-low-overhead\nno-render-or-presentation-settings-modified\n---",
                            model, UIDevice.currentDevice.systemVersion];
        [header writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            AppendLine(@"ERROR no Metal device");
            return;
        }

        Class deviceClass = object_getClass(device);
        BOOL tex = InstallHook(deviceClass, @selector(newTextureWithDescriptor:), (IMP)Perf_newTexture, &gOriginalNewTexture);
        BOOL rpso = InstallHook(deviceClass, @selector(newRenderPipelineStateWithDescriptor:error:), (IMP)Perf_newRenderPSO, &gOriginalNewRenderPSO);
        BOOL cpso = InstallHook(deviceClass, @selector(newComputePipelineStateWithFunction:error:), (IMP)Perf_newComputePSO, &gOriginalNewComputePSO);

        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        Class cbClass = cb ? object_getClass(cb) : Nil;

        BOOL commit = InstallHook(cbClass, @selector(commit), (IMP)Perf_commit, &gOriginalCommit);
        BOOL present = InstallHook(cbClass, @selector(presentDrawable:), (IMP)Perf_presentDrawable, &gOriginalPresent);

        BOOL presentAt = NO;
        if (class_getInstanceMethod(cbClass, @selector(presentDrawable:atTime:))) {
            presentAt = InstallHook(cbClass, @selector(presentDrawable:atTime:), (IMP)Perf_presentDrawableAtTime, &gOriginalPresentAtTime);
        }

        BOOL presentDur = NO;
        if (class_getInstanceMethod(cbClass, @selector(presentDrawable:afterMinimumDuration:))) {
            presentDur = InstallHook(cbClass, @selector(presentDrawable:afterMinimumDuration:), (IMP)Perf_presentDrawableAfterDuration, &gOriginalPresentAfterDuration);
        }

        AppendLine([NSString stringWithFormat:@"GPU=%@ deviceClass=%@ commandBufferClass=%@", device.name ?: @"unknown", NSStringFromClass(deviceClass), NSStringFromClass(cbClass)]);
        AppendLine([NSString stringWithFormat:@"HOOKS texture=%@ renderPSO=%@ computePSO=%@ commit=%@ present=%@ presentAt=%@ presentDuration=%@",
                    tex ? @"YES" : @"NO", rpso ? @"YES" : @"NO", cpso ? @"YES" : @"NO",
                    commit ? @"YES" : @"NO", present ? @"YES" : @"NO",
                    presentAt ? @"YES" : @"NO", presentDur ? @"YES" : @"NO"]);

        InstallLifecycleDump();
        AppendLine(@"ACTIVE: counters remain in RAM during gameplay; summary is written when the app enters background.");
    }
}
