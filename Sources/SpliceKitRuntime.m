//
//  SpliceKitRuntime.m
//  ObjC runtime utilities — the foundation everything else is built on.
//
//  FCP doesn't have a public API, so we talk to it through raw objc_msgSend
//  calls and runtime introspection. This file provides the plumbing:
//  - Safe message sending (nil-checks before dispatch)
//  - Main thread execution (tricky because of FCP's modal dialogs)
//  - Class/method discovery for reverse-engineering FCP's internals
//

#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <os/lock.h>
#import <stdatomic.h>

#pragma mark - Safe Message Sending
//
// These look trivial, but they save us from scattered nil-checks everywhere.
// When you're chasing a 5-deep KVC chain through FCP's object graph,
// any link can be nil and sending a message to nil silently returns 0/nil.
// That's fine for ObjC, but we want to *know* when something's missing.
//

id SpliceKit_sendMsg(id target, SEL selector) {
    if (!target) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

id SpliceKit_sendMsg1(id target, SEL selector, id arg1) {
    if (!target) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, arg1);
}

id SpliceKit_sendMsg2(id target, SEL selector, id arg1, id arg2) {
    if (!target) return nil;
    return ((id (*)(id, SEL, id, id))objc_msgSend)(target, selector, arg1, arg2);
}

BOOL SpliceKit_sendMsgBool(id target, SEL selector) {
    if (!target) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
}

#pragma mark - Main Thread Dispatch
//
// Almost everything in FCP's UI layer (timeline, inspector, viewer) is main-thread-only.
// Our JSON-RPC requests arrive on background threads, so we need to hop over.
//
// The wrinkle: dispatch_sync(dispatch_get_main_queue(), ...) deadlocks when FCP
// is showing a modal dialog (sheet, save panel, etc.) because the main queue
// doesn't drain during modal run loops. CFRunLoopPerformBlock + kCFRunLoopCommonModes
// sidesteps this by scheduling directly on the run loop instead of the GCD queue.
//

// Reentrancy counter: incremented while the main thread is executing a block
// dispatched from our RPC handler via executeOnMainThread. If a breakpoint
// fires while this is > 0, pausing would deadlock (an RPC thread is blocked
// on a semaphore waiting for this block to finish). We use a counter instead
// of a flag because multiple RPC calls can nest on the main thread.
// Timer/notification callbacks fire with depth == 0, so breakpoints work on them.
static _Atomic int sMainThreadRPCDispatchDepth = 0;

@interface SpliceKitCocoaUIInvocation : NSObject
@property (nonatomic, copy) dispatch_block_t block;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, copy) NSString *label;
@end

@implementation SpliceKitCocoaUIInvocation
@end

@interface SpliceKitCocoaUITrampoline : NSObject
+ (instancetype)sharedTrampoline;
- (void)executeInvocation:(SpliceKitCocoaUIInvocation *)invocation;
@end

@implementation SpliceKitCocoaUITrampoline

+ (instancetype)sharedTrampoline {
    static SpliceKitCocoaUITrampoline *trampoline = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        trampoline = [[self alloc] init];
    });
    return trampoline;
}

- (void)executeInvocation:(SpliceKitCocoaUIInvocation *)invocation {
    if (!invocation) return;

    // The invocation.block handles its own sMainThreadRPCDispatchDepth tracking
    // when called from executeOnMainThread. For standalone CocoaUI callers, the
    // block is wrapped with depth tracking by SpliceKit_executeCocoaUIBlock.
    @try {
        if (invocation.block) invocation.block();
    } @finally {
        if (invocation.semaphore) {
            dispatch_semaphore_signal(invocation.semaphore);
        }
    }
}

@end

BOOL SpliceKit_isMainThreadInRPCDispatch(void) {
    return [NSThread isMainThread] && sMainThreadRPCDispatchDepth > 0;
}

// Tracks consecutive main-thread timeouts. When the main thread is stuck
// (e.g. Motion is in a modal state or deadlocked), back-to-back RPC requests
// will each block for the full timeout. The counter lets us log a warning
// once and then fail fast for subsequent requests until the main thread
// recovers.
static _Atomic int sConsecutiveMainThreadTimeouts = 0;
#define MOTIONKIT_MAIN_THREAD_TIMEOUT_SECONDS 8
#define MOTIONKIT_MAX_CONSECUTIVE_TIMEOUTS 3

int SpliceKit_consecutiveMainThreadTimeouts(void) {
    return atomic_load(&sConsecutiveMainThreadTimeouts);
}

void SpliceKit_resetMainThreadTimeouts(void) {
    atomic_store(&sConsecutiveMainThreadTimeouts, 0);
}

// Schedule a block on the main thread asynchronously (fire-and-forget).
// Uses CFRunLoopPerformBlock + dispatch_async + CFRunLoopWakeUp.
// These don't reliably fire in Motion's idle state, but they're safe and
// don't cause instability. Used only for non-critical async work.
static void SpliceKit_scheduleOnMainThread(dispatch_block_t block) {
    if (!block) return;

    if ([NSThread isMainThread]) {
        sMainThreadRPCDispatchDepth++;
        @try {
            block();
        } @finally {
            sMainThreadRPCDispatchDepth--;
        }
        return;
    }

    dispatch_block_t wrappedBlock = ^{
        sMainThreadRPCDispatchDepth++;
        @try {
            block();
        } @finally {
            sMainThreadRPCDispatchDepth--;
        }
    };

    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    if (mainRunLoop) {
        CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, wrappedBlock);
        CFRunLoopWakeUp(mainRunLoop);
    }
    dispatch_async(dispatch_get_main_queue(), wrappedBlock);
}

void SpliceKit_executeOnMainThread(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        sMainThreadRPCDispatchDepth++;
        @try {
            block();
        } @finally {
            sMainThreadRPCDispatchDepth--;
        }
        return;
    }

    BOOL motionHost = SpliceKit_isMotionHost();
    int timeout = motionHost ? 8 : MOTIONKIT_MAIN_THREAD_TIMEOUT_SECONDS;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_block_t wrappedBlock = ^{
        sMainThreadRPCDispatchDepth++;
        @try {
            block();
        } @finally {
            sMainThreadRPCDispatchDepth--;
            dispatch_semaphore_signal(sem);
        }
    };

    if (motionHost) {
        // Motion's OZTimelineView spends most of its time in drawRect, fired by
        // the CA::Transaction run-loop observer. CFRunLoopPerformBlock and
        // dispatch_async(main) both wait until the observer releases, but
        // Motion just queues the next transaction immediately. The event-pump
        // queue is drained from the swizzled nextEventMatchingMask: hook,
        // which fires once per event-loop iteration — between transactions.
        SpliceKit_enqueueMainThreadBlock(wrappedBlock);
    } else {
        CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
        if (mainRunLoop) {
            CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, wrappedBlock);
            CFRunLoopWakeUp(mainRunLoop);
        }
        dispatch_async(dispatch_get_main_queue(), wrappedBlock);
    }

    long waitResult = dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout) * NSEC_PER_SEC));
    if (waitResult != 0) {
        atomic_fetch_add(&sConsecutiveMainThreadTimeouts, 1);
    } else {
        atomic_store(&sConsecutiveMainThreadTimeouts, 0);
    }
}

void SpliceKit_executeOnMainThreadAsync(dispatch_block_t block) {
    SpliceKit_scheduleOnMainThread(block);
}

#pragma mark - Event-Pump Work Queue (lightweight)
//
// A FIFO drained from a CFRunLoopObserver on the main run loop, plus a
// nextEvent hook as backup. The observer fires on every kCFRunLoopBeforeWaiting
// transition — that happens many times per second even when Motion is idle
// (CA::Transaction commits cycle the run loop), so blocks get serviced
// regardless of whether NSEvents are actually being delivered.
//

static NSMutableArray<dispatch_block_t> *sMainThreadBlockQueue = nil;
static os_unfair_lock sMainThreadBlockQueueLock = OS_UNFAIR_LOCK_INIT;
static CFRunLoopObserverRef sMainThreadDrainObserver = NULL;
static _Atomic uint64_t sMainThreadDrainObserverFireCount = 0;
static _Atomic uint64_t sMainThreadDrainBlocksRun = 0;

uint64_t SpliceKit_mainThreadDrainObserverFireCount(void) {
    return atomic_load(&sMainThreadDrainObserverFireCount);
}

uint64_t SpliceKit_mainThreadDrainBlocksRunCount(void) {
    return atomic_load(&sMainThreadDrainBlocksRun);
}

static void SpliceKit_mainThreadDrainObserverCallback(CFRunLoopObserverRef observer,
                                                       CFRunLoopActivity activity,
                                                       void *info) {
    atomic_fetch_add(&sMainThreadDrainObserverFireCount, 1);
    SpliceKit_drainMainThreadBlockQueue();

    // Refresh the Motion state cache opportunistically (~ every 500ms). The
    // RPC server reads this cache from background threads — without periodic
    // main-thread refresh, the cache stays empty and clients see stale
    // state_pending=YES placeholders.
    static _Atomic uint64_t sLastRefreshNs = 0;
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    uint64_t last = atomic_load(&sLastRefreshNs);
    if (now - last >= 500ULL * NSEC_PER_MSEC) {
        if (atomic_compare_exchange_strong(&sLastRefreshNs, &last, now)) {
            Class palette = objc_getClass("SpliceKitCommandPalette");
            SEL refresh = @selector(refreshMotionStateCacheFromMainThreadIfReady);
            if (palette && [palette respondsToSelector:refresh]) {
                ((void (*)(id, SEL))objc_msgSend)((id)palette, refresh);
            }
        }
    }
}

static void SpliceKit_installMainThreadDrainObserverIfNeeded(void) {
    if (sMainThreadDrainObserver) return;
    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    if (!mainRunLoop) return;
    // Fire on every meaningful run-loop activity. BeforeWaiting alone is not
    // enough on Motion because the loop rarely actually sleeps — CA::Transaction
    // commits keep firing as Source1 callbacks. BeforeSources fires every
    // iteration of source processing.
    CFRunLoopActivity activities =
        kCFRunLoopBeforeTimers | kCFRunLoopBeforeSources |
        kCFRunLoopBeforeWaiting | kCFRunLoopAfterWaiting;
    sMainThreadDrainObserver = CFRunLoopObserverCreate(
        kCFAllocatorDefault, activities, /*repeats=*/true, /*order=*/0,
        SpliceKit_mainThreadDrainObserverCallback, NULL);
    if (sMainThreadDrainObserver) {
        CFRunLoopAddObserver(mainRunLoop, sMainThreadDrainObserver, kCFRunLoopCommonModes);
    }
}

void SpliceKit_enqueueMainThreadBlock(dispatch_block_t block) {
    if (!block) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sMainThreadBlockQueue = [NSMutableArray array];
    });
    dispatch_block_t copied = [block copy];
    os_unfair_lock_lock(&sMainThreadBlockQueueLock);
    [sMainThreadBlockQueue addObject:copied];
    os_unfair_lock_unlock(&sMainThreadBlockQueueLock);
    SpliceKit_installMainThreadDrainObserverIfNeeded();
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

void SpliceKit_drainMainThreadBlockQueue(void) {
    if (!sMainThreadBlockQueue) return;
    if (![NSThread isMainThread]) return;

    NSArray<dispatch_block_t> *pending = nil;
    os_unfair_lock_lock(&sMainThreadBlockQueueLock);
    if (sMainThreadBlockQueue.count > 0) {
        pending = [sMainThreadBlockQueue copy];
        [sMainThreadBlockQueue removeAllObjects];
    }
    os_unfair_lock_unlock(&sMainThreadBlockQueueLock);

    if (!pending) return;
    for (dispatch_block_t blk in pending) {
        @autoreleasepool {
            @try {
                blk();
                atomic_fetch_add(&sMainThreadDrainBlocksRun, 1);
            } @catch (NSException *e) {
                SpliceKit_log(@"[MainThreadQueue] Exception: %@", e.reason);
            }
        }
    }
}

void SpliceKit_installMainThreadDrainInfrastructure(void) {
    SpliceKit_installMainThreadDrainObserverIfNeeded();
}

uint64_t SpliceKit_drainCallCount(void) { return 0; }
uint64_t SpliceKit_drainBlocksExecuted(void) { return 0; }

BOOL SpliceKit_executeCocoaUIBlock(dispatch_block_t block, NSTimeInterval timeoutSeconds,
                                   NSString *label) {
    if (!block) return YES;

    if ([NSThread isMainThread]) {
        sMainThreadRPCDispatchDepth++;
        @try {
            block();
        } @finally {
            sMainThreadRPCDispatchDepth--;
        }
        return YES;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_block_t wrappedBlock = ^{
        sMainThreadRPCDispatchDepth++;
        @try {
            block();
        } @finally {
            sMainThreadRPCDispatchDepth--;
            dispatch_semaphore_signal(sem);
        }
    };

    if (SpliceKit_isMotionHost()) {
        SpliceKit_enqueueMainThreadBlock(wrappedBlock);
    } else {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, wrappedBlock);
        CFRunLoopWakeUp(CFRunLoopGetMain());
        dispatch_async(dispatch_get_main_queue(), wrappedBlock);
    }

    NSTimeInterval effectiveTimeout = timeoutSeconds > 0 ? timeoutSeconds : 8.0;
    long waitResult = dispatch_semaphore_wait(
        sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(effectiveTimeout * NSEC_PER_SEC)));
    return (waitResult == 0);
}

#pragma mark - Class Discovery
//
// These are the reverse-engineering tools. FCP has 78K+ ObjC classes across
// dozens of frameworks. We can enumerate them by Mach-O image (to see what
// came from Flexo vs ProAppSupport vs TimelineKit) or grab the full list.
//

NSArray *SpliceKit_classesInImage(const char *imageName) {
    NSMutableArray *result = [NSMutableArray array];
    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(imageName, &count);
    if (names) {
        for (unsigned int i = 0; i < count; i++) {
            const char *className = names[i];
            if (className && className[0] != '\0') {
                NSString *classNameString = [NSString stringWithCString:className
                                                               encoding:NSUTF8StringEncoding];
                if (classNameString.length > 0) {
                    [result addObject:classNameString];
                }
            }
        }
        free(names);
    }
    return result;
}

// Returns every method on a class: selector name, type encoding, and IMP address.
// The IMP address is useful for setting breakpoints or cross-referencing with
// disassembly when you're trying to figure out what a method actually does.
NSDictionary *SpliceKit_methodsForClass(Class cls) {
    NSMutableDictionary *methods = [NSMutableDictionary dictionary];
    unsigned int count = 0;
    Method *methodList = class_copyMethodList(cls, &count);
    if (methodList) {
        for (unsigned int i = 0; i < count; i++) {
            SEL sel = method_getName(methodList[i]);
            NSString *name = NSStringFromSelector(sel);
            const char *types = method_getTypeEncoding(methodList[i]);
            methods[name] = @{
                @"selector": name,
                @"typeEncoding": types ? @(types) : @"",
                @"imp": [NSString stringWithFormat:@"0x%lx",
                         (unsigned long)method_getImplementation(methodList[i])]
            };
        }
        free(methodList);
    }
    return methods;
}

// Grab every class in the process, sorted alphabetically.
// Using objc_copyClassList() is unsafe in Motion during launch and can force
// Swift metadata realization on partially initialized classes. Enumerating
// classes image-by-image via objc_copyClassNamesForImage() is slower but much
// more stable for the Motion port.
NSArray *SpliceKit_allLoadedClasses(void) {
    NSMutableOrderedSet<NSString *> *classNames = [NSMutableOrderedSet orderedSet];
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t imageIndex = 0; imageIndex < imageCount; imageIndex++) {
        const char *imageName = _dyld_get_image_name(imageIndex);
        if (!imageName || imageName[0] == '\0') {
            continue;
        }

        NSArray *imageClasses = SpliceKit_classesInImage(imageName);
        if (imageClasses.count == 0) {
            continue;
        }

        for (NSString *className in imageClasses) {
            if (className.length > 0) {
                [classNames addObject:className];
            }
        }
    }

    NSArray *result = [classNames.array sortedArrayUsingSelector:@selector(compare:)];
    return result;
}
