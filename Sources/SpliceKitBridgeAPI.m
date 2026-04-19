// SpliceKitBridgeAPI.m — implementation.

#import "SpliceKitBridgeAPI.h"
#import "SpliceKit.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <pthread.h>
#import <execinfo.h>

// ============================================================================
#pragma mark - Process liveness
// ============================================================================

static NSDate *sBridgeStartTime = nil;

__attribute__((constructor))
static void SpliceKitBridgeAPI_recordStart(void) {
    sBridgeStartTime = [NSDate date];
}

NSDictionary *SpliceKit_handleBridgeAlive(__unused NSDictionary *params) {
    // Deliberately does not touch the main thread — cheap liveness probe.
    NSTimeInterval uptime = sBridgeStartTime
        ? [[NSDate date] timeIntervalSinceDate:sBridgeStartTime]
        : 0;
    return @{
        @"alive": @YES,
        @"pid": @(getpid()),
        @"uptimeSeconds": @(uptime),
        @"motionHost": SpliceKit_isMotionHost() ? @YES : @NO,
        @"consecutiveMainThreadTimeouts": @(SpliceKit_consecutiveMainThreadTimeouts()),
    };
}

// ============================================================================
#pragma mark - Metrics
// ============================================================================

@interface SKMethodStats : NSObject
@property (nonatomic, assign) uint64_t calls;
@property (nonatomic, assign) uint64_t errors;
@property (nonatomic, assign) double totalMs;
@property (nonatomic, assign) double minMs;
@property (nonatomic, assign) double maxMs;
@property (nonatomic, assign) double lastMs;
@end
@implementation SKMethodStats
- (instancetype)init {
    if ((self = [super init])) {
        _minMs = INFINITY;
    }
    return self;
}
@end

static NSMutableDictionary<NSString *, SKMethodStats *> *sMetrics = nil;
static os_unfair_lock sMetricsLock = OS_UNFAIR_LOCK_INIT;

void SpliceKit_metricsRecord(NSString *method, double ms, BOOL ok) {
    if (!method.length) return;
    os_unfair_lock_lock(&sMetricsLock);
    if (!sMetrics) sMetrics = [NSMutableDictionary dictionary];
    SKMethodStats *s = sMetrics[method];
    if (!s) {
        s = [[SKMethodStats alloc] init];
        sMetrics[method] = s;
    }
    s.calls += 1;
    if (!ok) s.errors += 1;
    s.totalMs += ms;
    s.lastMs = ms;
    if (ms < s.minMs) s.minMs = ms;
    if (ms > s.maxMs) s.maxMs = ms;
    os_unfair_lock_unlock(&sMetricsLock);
}

NSDictionary *SpliceKit_handleBridgeMetrics(__unused NSDictionary *params) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    os_unfair_lock_lock(&sMetricsLock);
    for (NSString *method in sMetrics) {
        SKMethodStats *s = sMetrics[method];
        out[method] = @{
            @"calls": @(s.calls),
            @"errors": @(s.errors),
            @"avgMs": s.calls > 0 ? @(s.totalMs / s.calls) : @0,
            @"minMs": isfinite(s.minMs) ? @(s.minMs) : @0,
            @"maxMs": @(s.maxMs),
            @"lastMs": @(s.lastMs),
            @"totalMs": @(s.totalMs),
        };
    }
    os_unfair_lock_unlock(&sMetricsLock);
    return @{@"methods": out};
}

NSDictionary *SpliceKit_handleBridgeResetMetrics(__unused NSDictionary *params) {
    os_unfair_lock_lock(&sMetricsLock);
    [sMetrics removeAllObjects];
    os_unfair_lock_unlock(&sMetricsLock);
    return @{@"ok": @YES};
}

// ============================================================================
#pragma mark - Runtime blocklist (persistent)
// ============================================================================
//
// The command palette has a hard-coded blocklist in SpliceKitCommandPalette.m
// for selectors that reliably SIGSEGV Motion or open modal dialogs. Adding a
// new entry used to require a rebuild. This RPC-backed, plist-persisted
// blocklist sits alongside the hard-coded one — selectors in either are
// rejected. Changes survive restarts.

static NSMutableDictionary<NSString *, NSString *> *sRuntimeBlocklist = nil;
static os_unfair_lock sBlocklistLock = OS_UNFAIR_LOCK_INIT;
static dispatch_once_t sBlocklistLoadOnce;

static NSString *SpliceKitBridge_blocklistPath(void) {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [appSupport stringByAppendingPathComponent:@"MotionKit"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"blocklist.plist"];
}

static void SpliceKitBridge_loadBlocklistLocked(void) {
    if (sRuntimeBlocklist) return;
    sRuntimeBlocklist = [NSMutableDictionary dictionary];
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:
                           SpliceKitBridge_blocklistPath()];
    if ([saved isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in saved) {
            id val = saved[key];
            if ([key isKindOfClass:[NSString class]] && [val isKindOfClass:[NSString class]]) {
                sRuntimeBlocklist[key] = val;
            }
        }
    }
}

static void SpliceKitBridge_ensureBlocklistLoaded(void) {
    dispatch_once(&sBlocklistLoadOnce, ^{
        os_unfair_lock_lock(&sBlocklistLock);
        SpliceKitBridge_loadBlocklistLocked();
        os_unfair_lock_unlock(&sBlocklistLock);
    });
}

static void SpliceKitBridge_saveBlocklistLocked(void) {
    if (!sRuntimeBlocklist) return;
    [sRuntimeBlocklist writeToFile:SpliceKitBridge_blocklistPath() atomically:YES];
}

BOOL SpliceKitBridge_isBlockedSelector(NSString *selector, NSString **reasonOut) {
    if (!selector.length) return NO;
    SpliceKitBridge_ensureBlocklistLoaded();
    os_unfair_lock_lock(&sBlocklistLock);
    NSString *reason = sRuntimeBlocklist[selector];
    os_unfair_lock_unlock(&sBlocklistLock);
    if (reason && reasonOut) *reasonOut = reason;
    return reason != nil;
}

NSDictionary *SpliceKit_handlePaletteBlock(NSDictionary *params) {
    NSString *selector = [params[@"selector"] isKindOfClass:[NSString class]]
        ? params[@"selector"] : nil;
    NSString *reason = [params[@"reason"] isKindOfClass:[NSString class]]
        ? params[@"reason"] : @"Runtime-added by palette.block.";
    if (!selector.length) {
        return @{@"error": @"selector parameter required (non-empty string)"};
    }
    SpliceKitBridge_ensureBlocklistLoaded();
    os_unfair_lock_lock(&sBlocklistLock);
    sRuntimeBlocklist[selector] = reason;
    SpliceKitBridge_saveBlocklistLocked();
    NSUInteger total = sRuntimeBlocklist.count;
    os_unfair_lock_unlock(&sBlocklistLock);
    return @{@"ok": @YES, @"selector": selector, @"reason": reason,
             @"totalRuntimeBlocked": @(total)};
}

NSDictionary *SpliceKit_handlePaletteUnblock(NSDictionary *params) {
    NSString *selector = [params[@"selector"] isKindOfClass:[NSString class]]
        ? params[@"selector"] : nil;
    if (!selector.length) {
        return @{@"error": @"selector parameter required (non-empty string)"};
    }
    SpliceKitBridge_ensureBlocklistLoaded();
    os_unfair_lock_lock(&sBlocklistLock);
    BOOL existed = (sRuntimeBlocklist[selector] != nil);
    [sRuntimeBlocklist removeObjectForKey:selector];
    SpliceKitBridge_saveBlocklistLocked();
    NSUInteger total = sRuntimeBlocklist.count;
    os_unfair_lock_unlock(&sBlocklistLock);
    return @{@"ok": @YES, @"selector": selector, @"existed": @(existed),
             @"totalRuntimeBlocked": @(total)};
}

NSDictionary *SpliceKit_handlePaletteListBlocked(__unused NSDictionary *params) {
    SpliceKitBridge_ensureBlocklistLoaded();
    NSMutableArray *list = [NSMutableArray array];
    os_unfair_lock_lock(&sBlocklistLock);
    for (NSString *sel in sRuntimeBlocklist) {
        [list addObject:@{@"selector": sel,
                          @"reason": sRuntimeBlocklist[sel] ?: @"",
                          @"source": @"runtime"}];
    }
    os_unfair_lock_unlock(&sBlocklistLock);
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"selector"] compare:b[@"selector"]];
    }];
    return @{@"selectors": list, @"path": SpliceKitBridge_blocklistPath()};
}

// Declared in SpliceKitCommandPalette.m — combined hardcoded + runtime check.
extern BOOL SpliceKitPalette_isBlockedSelector(NSString *selector, NSString **reasonOut);

NSDictionary *SpliceKit_handlePaletteIsBlocked(NSDictionary *params) {
    NSString *selector = [params[@"selector"] isKindOfClass:[NSString class]]
        ? params[@"selector"] : nil;
    if (!selector.length) {
        return @{@"error": @"selector parameter required"};
    }
    NSString *runtimeReason = nil;
    BOOL runtimeBlocked = SpliceKitBridge_isBlockedSelector(selector, &runtimeReason);
    NSString *combinedReason = nil;
    BOOL combinedBlocked = SpliceKitPalette_isBlockedSelector(selector, &combinedReason);
    NSString *source = @"none";
    if (runtimeBlocked) source = @"runtime";
    else if (combinedBlocked) source = @"hardcoded";
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"selector"] = selector;
    r[@"blocked"] = @(combinedBlocked);
    r[@"source"] = source;
    if (combinedReason) r[@"reason"] = combinedReason;
    return r;
}

// ============================================================================
#pragma mark - Crash report retrieval
// ============================================================================

static NSURL *SpliceKitBridge_findLatestCrashForProc(NSString *procPrefix) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSURL *> *dirs = @[
        [fm.homeDirectoryForCurrentUser
            URLByAppendingPathComponent:@"Library/Logs/DiagnosticReports"],
        [NSURL fileURLWithPath:@"/Library/Logs/DiagnosticReports"]
    ];
    NSURL *newest = nil;
    NSDate *newestDate = nil;
    for (NSURL *dir in dirs) {
        NSArray *entries = [fm contentsOfDirectoryAtURL:dir
                            includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                 error:nil];
        for (NSURL *url in entries) {
            NSString *name = url.lastPathComponent;
            if (!procPrefix.length || [name hasPrefix:procPrefix]) {
                NSString *ext = url.pathExtension.lowercaseString;
                if (![@[@"ips", @"crash", @"txt"] containsObject:ext]) continue;
                NSDate *modified = nil;
                [url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
                if (modified && (!newestDate || [modified compare:newestDate] == NSOrderedDescending)) {
                    newest = url;
                    newestDate = modified;
                }
            }
        }
    }
    return newest;
}

NSDictionary *SpliceKit_handleDebugLastCrash(NSDictionary *params) {
    NSString *procPrefix = [params[@"process"] isKindOfClass:[NSString class]]
        ? params[@"process"]
        : (SpliceKit_isMotionHost() ? @"Motion" : @"Final Cut Pro");
    NSURL *url = SpliceKitBridge_findLatestCrashForProc(procPrefix);
    if (!url) {
        return @{@"found": @NO, @"process": procPrefix};
    }
    NSError *err = nil;
    NSString *raw = [NSString stringWithContentsOfURL:url
                                             encoding:NSUTF8StringEncoding
                                                error:&err];
    if (!raw) {
        return @{@"found": @YES, @"path": url.path,
                 @"error": err.localizedDescription ?: @"unreadable"};
    }
    // IPS format: first line is small JSON header, rest is a larger JSON body.
    NSUInteger split = [raw rangeOfString:@"\n"].location;
    NSString *header = (split != NSNotFound) ? [raw substringToIndex:split] : raw;
    NSString *body   = (split != NSNotFound) ? [raw substringFromIndex:split + 1] : @"";
    NSDictionary *headerJSON = nil;
    NSDictionary *bodyJSON = nil;
    NSData *hdrData = [header dataUsingEncoding:NSUTF8StringEncoding];
    if (hdrData) {
        headerJSON = [NSJSONSerialization JSONObjectWithData:hdrData options:0 error:nil];
    }
    NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (bodyData) {
        bodyJSON = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
    }

    NSDictionary *exception = bodyJSON[@"exception"];
    NSNumber *faulting = bodyJSON[@"faultingThread"];
    NSArray *threads = bodyJSON[@"threads"];
    NSMutableArray *topFrames = [NSMutableArray array];
    if ([threads isKindOfClass:[NSArray class]]) {
        for (NSDictionary *t in threads) {
            if ([t[@"triggered"] boolValue]) {
                NSArray *frames = t[@"frames"];
                NSInteger limit = MIN((NSInteger)frames.count, (NSInteger)20);
                for (NSInteger i = 0; i < limit; i++) {
                    NSDictionary *f = frames[i];
                    [topFrames addObject:@{
                        @"symbol": f[@"symbol"] ?: @"?",
                        @"symbolLocation": f[@"symbolLocation"] ?: @0,
                        @"imageOffset": f[@"imageOffset"] ?: @0,
                    }];
                }
                break;
            }
        }
    }

    return @{
        @"found": @YES,
        @"path": url.path,
        @"timestamp": headerJSON[@"timestamp"] ?: [NSNull null],
        @"bugType": headerJSON[@"bug_type"] ?: [NSNull null],
        @"exception": exception ?: [NSNull null],
        @"faultingThread": faulting ?: [NSNull null],
        @"topFrames": topFrames,
    };
}

// ============================================================================
#pragma mark - Log introspection
// ============================================================================

static NSString *SpliceKitBridge_logPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Logs/MotionKit/motionkit.log"];
}

NSDictionary *SpliceKit_handleLogPath(__unused NSDictionary *params) {
    NSString *path = SpliceKitBridge_logPath();
    return @{
        @"path": path,
        @"dir": [path stringByDeletingLastPathComponent],
        @"exists": @([[NSFileManager defaultManager] fileExistsAtPath:path]),
    };
}

NSDictionary *SpliceKit_handleLogTail(NSDictionary *params) {
    NSInteger lines = [params[@"lines"] isKindOfClass:[NSNumber class]]
        ? [params[@"lines"] integerValue] : 200;
    if (lines < 1) lines = 1;
    if (lines > 5000) lines = 5000;
    NSString *path = SpliceKitBridge_logPath();
    NSError *err = nil;
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:&err];
    if (!text) {
        return @{@"path": path, @"lines": @[],
                 @"error": err.localizedDescription ?: @"log unreadable"};
    }
    NSArray *all = [text componentsSeparatedByString:@"\n"];
    // Drop trailing empty line from split.
    if (all.count > 0 && ((NSString *)all.lastObject).length == 0) {
        all = [all subarrayWithRange:NSMakeRange(0, all.count - 1)];
    }
    NSInteger start = MAX((NSInteger)0, (NSInteger)all.count - lines);
    NSArray *tail = [all subarrayWithRange:NSMakeRange(start, all.count - start)];
    return @{@"path": path, @"lines": tail, @"totalLines": @(all.count)};
}

// ============================================================================
#pragma mark - Modal window handling
// ============================================================================

static BOOL SpliceKitBridge_windowLooksModal(NSWindow *w) {
    if (!w || !w.isVisible) return NO;
    if ([NSApp modalWindow] == w) return YES;
    NSWindowLevel level = w.level;
    if (w.sheet) return YES;
    if (level == NSModalPanelWindowLevel) return YES;
    NSString *cls = NSStringFromClass([w class]);
    // NSOpenPanel / NSSavePanel
    if ([cls containsString:@"SavePanel"] || [cls containsString:@"OpenPanel"]) return YES;
    // Motion's Project Browser + similar launcher / settings dialogs render
    // inside LKKeyablePanel (a Helium subclass). Treat any LKKeyablePanel /
    // NSPanel subclass that's explicitly modal-looking as a dismissible
    // modal.
    if ([cls containsString:@"KeyablePanel"]) return YES;
    // Title heuristic: explicit launcher / browser / onboarding windows.
    NSString *title = (w.title ?: @"").lowercaseString;
    if ([title containsString:@"project browser"] ||
        [title containsString:@"welcome"] ||
        [title containsString:@"onboarding"] ||
        [title containsString:@"tip of the day"]) return YES;
    return NO;
}

static NSDictionary *SpliceKitBridge_describeWindow(NSWindow *w, NSInteger idx) {
    return @{
        @"index": @(idx),
        @"windowNumber": @(w.windowNumber),
        @"title": w.title ?: @"",
        @"className": NSStringFromClass([w class]) ?: @"?",
        @"isVisible": @(w.isVisible),
        @"isSheet": @(w.sheet ? YES : NO),
        @"isKey": @(w.isKeyWindow),
        @"isAppModal": @([NSApp modalWindow] == w),
        @"level": @(w.level),
    };
}

static NSArray *SpliceKitBridge_listModalsOnMain(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSInteger idx = 0;
    for (NSWindow *w in [NSApp windows]) {
        if (!SpliceKitBridge_windowLooksModal(w)) continue;
        [out addObject:SpliceKitBridge_describeWindow(w, idx)];
        idx += 1;
    }
    return out;
}

static NSArray *SpliceKitBridge_listAllWindowsOnMain(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSInteger idx = 0;
    for (NSWindow *w in [NSApp windows]) {
        [out addObject:SpliceKitBridge_describeWindow(w, idx)];
        idx += 1;
    }
    return out;
}

NSDictionary *SpliceKit_handleWindowList(__unused NSDictionary *params) {
    __block NSArray *result = nil;
    BOOL ok = SpliceKit_executeCocoaUIBlock(^{
        result = SpliceKitBridge_listAllWindowsOnMain();
    }, 0.5, @"window.list");
    if (ok) return @{@"windows": result ?: @[], @"source": @"main"};
    // Off-thread fallback
    @try {
        NSMutableArray *out = [NSMutableArray array];
        NSArray *windows = [NSApp valueForKey:@"windows"];
        NSInteger idx = 0;
        for (NSWindow *w in windows) {
            [out addObject:SpliceKitBridge_describeWindow(w, idx)];
            idx += 1;
        }
        return @{@"windows": out, @"source": @"fallback-offthread"};
    } @catch (NSException *e) {
        return @{@"error": [NSString stringWithFormat:
                  @"main thread blocked AND off-thread read failed: %@",
                  e.reason ?: @"unknown"]};
    }
}

NSDictionary *SpliceKit_handleWindowListModals(__unused NSDictionary *params) {
    __block NSArray *result = nil;
    BOOL ok = SpliceKit_executeCocoaUIBlock(^{
        result = SpliceKitBridge_listModalsOnMain();
    }, 0.5, @"window.listModals");
    if (ok) return @{@"modals": result ?: @[], @"source": @"main"};

    @try {
        NSMutableArray *out = [NSMutableArray array];
        NSArray *windows = [NSApp valueForKey:@"windows"];
        NSInteger idx = 0;
        for (NSWindow *w in windows) {
            if (!SpliceKitBridge_windowLooksModal(w)) continue;
            [out addObject:SpliceKitBridge_describeWindow(w, idx)];
            idx += 1;
        }
        return @{@"modals": out, @"source": @"fallback-offthread"};
    } @catch (NSException *e) {
        return @{@"error": [NSString stringWithFormat:
                     @"main thread blocked AND off-thread read failed: %@",
                     e.reason ?: @"unknown"]};
    }
}

NSDictionary *SpliceKit_handleModalDismiss(NSDictionary *params) {
    NSInteger index = [params[@"index"] isKindOfClass:[NSNumber class]]
        ? [params[@"index"] integerValue] : -1;
    NSString *titleMatch = [params[@"title"] isKindOfClass:[NSString class]]
        ? params[@"title"] : nil;
    BOOL emergency = [params[@"emergency"] boolValue];

    // Emergency path: main thread is blocked by a nested modal loop. Call
    // [NSApp abortModal] off-thread to break out. This is documented as
    // safe to call from background threads.
    if (emergency) {
        @try {
            [NSApp performSelectorOnMainThread:@selector(abortModal)
                                    withObject:nil waitUntilDone:NO];
            return @{@"dismissed": @YES, @"mode": @"emergency-abortModal"};
        } @catch (NSException *e) {
            return @{@"dismissed": @NO,
                     @"reason": e.reason ?: @"abortModal failed"};
        }
    }

    __block NSDictionary *result = nil;
    BOOL ok = SpliceKit_executeCocoaUIBlock(^{
        NSArray *modals = SpliceKitBridge_listModalsOnMain();
        if (modals.count == 0) {
            result = @{@"dismissed": @NO, @"reason": @"no modal windows visible"};
            return;
        }
        NSInteger targetIdx = -1;
        if (titleMatch.length > 0) {
            for (NSInteger i = 0; i < (NSInteger)modals.count; i++) {
                NSString *title = modals[i][@"title"];
                if ([title.lowercaseString containsString:titleMatch.lowercaseString]) {
                    targetIdx = i;
                    break;
                }
            }
            if (targetIdx < 0) {
                result = @{@"dismissed": @NO,
                           @"reason": [NSString stringWithFormat:
                                       @"no visible modal title matches '%@'", titleMatch]};
                return;
            }
        } else if (index >= 0) {
            targetIdx = index;
        } else {
            targetIdx = (NSInteger)modals.count - 1; // top-most
        }
        if (targetIdx >= (NSInteger)modals.count) {
            result = @{@"dismissed": @NO, @"reason":
                       [NSString stringWithFormat:@"index %ld out of range (%lu modals)",
                                                  (long)targetIdx, (unsigned long)modals.count]};
            return;
        }
        NSDictionary *info = modals[targetIdx];
        NSInteger windowNumber = [info[@"windowNumber"] integerValue];
        NSWindow *target = nil;
        for (NSWindow *w in [NSApp windows]) {
            if (w.windowNumber == windowNumber) { target = w; break; }
        }
        if (!target) {
            result = @{@"dismissed": @NO, @"reason": @"window vanished"};
            return;
        }

        // Prefer -cancel: -> -cancelOperation: -> -close
        SEL cancel = NSSelectorFromString(@"cancel:");
        SEL cancelOp = @selector(cancelOperation:);
        @try {
            if ([target respondsToSelector:cancel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(target, cancel, target);
            } else if ([target respondsToSelector:cancelOp]) {
                ((void (*)(id, SEL, id))objc_msgSend)(target, cancelOp, target);
            } else if (target.sheet) {
                [target.sheetParent endSheet:target returnCode:NSModalResponseCancel];
            } else if ([NSApp modalWindow] == target) {
                [NSApp stopModalWithCode:NSModalResponseCancel];
                [target close];
            } else {
                [target close];
            }
            result = @{@"dismissed": @YES, @"info": info};
        } @catch (NSException *e) {
            result = @{@"dismissed": @NO,
                       @"reason": [NSString stringWithFormat:@"exception: %@", e.reason]};
        }
    }, 2.0, @"modal.dismiss");
    if (!ok) return @{@"error": @"main thread unavailable"};
    return result ?: @{@"dismissed": @NO, @"reason": @"unknown"};
}

// ============================================================================
#pragma mark - Batch dispatch
// ============================================================================

// Forward decl — the existing request dispatcher.
NSDictionary *SpliceKit_handleRequest(NSDictionary *request);

NSDictionary *SpliceKit_handleBatchExecute(NSDictionary *params) {
    NSArray *calls = params[@"calls"];
    if (![calls isKindOfClass:[NSArray class]]) {
        return @{@"error": @"calls must be an array of {method, params}"};
    }
    NSInteger max = calls.count;
    if (max > 500) {
        return @{@"error": @"batch size too large (max 500)"};
    }
    BOOL stopOnError = [params[@"stopOnError"] boolValue];
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:max];
    for (NSDictionary *call in calls) {
        if (![call isKindOfClass:[NSDictionary class]]) {
            [results addObject:@{@"error": @"item must be an object with {method, params}"}];
            if (stopOnError) break;
            continue;
        }
        NSString *method = call[@"method"];
        NSDictionary *p = [call[@"params"] isKindOfClass:[NSDictionary class]]
            ? call[@"params"] : @{};
        if (![method isKindOfClass:[NSString class]] || method.length == 0) {
            [results addObject:@{@"error": @"item missing 'method'"}];
            if (stopOnError) break;
            continue;
        }
        NSDictionary *fake = @{@"method": method, @"params": p};
        NSDictionary *r = SpliceKit_handleRequest(fake);
        [results addObject:r ?: @{@"error": @"null result"}];
        if (stopOnError && r[@"error"]) break;
    }
    return @{@"count": @(results.count), @"results": results};
}

// ============================================================================
#pragma mark - Main-thread backtrace (best-effort)
// ============================================================================

NSDictionary *SpliceKit_handleDebugMainThreadBacktrace(__unused NSDictionary *params) {
    __block NSArray *frames = nil;
    BOOL got = SpliceKit_executeCocoaUIBlock(^{
        void *stack[64];
        int n = backtrace(stack, 64);
        char **symbols = backtrace_symbols(stack, n);
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
        for (int i = 0; i < n; i++) {
            [out addObject:symbols && symbols[i]
                ? [NSString stringWithUTF8String:symbols[i]]
                : @"<?>"];
        }
        if (symbols) free(symbols);
        frames = out;
    }, 1.0, @"debug.mainThreadBacktrace");
    if (!got) {
        return @{@"captured": @NO,
                 @"reason": @"main thread unresponsive (bridge likely blocked)",
                 @"consecutiveTimeouts":
                    @(SpliceKit_consecutiveMainThreadTimeouts())};
    }
    return @{@"captured": @YES, @"frames": frames ?: @[]};
}

// ============================================================================
#pragma mark - Session snapshot / restore (Motion-first)
// ============================================================================

NSDictionary *SpliceKit_handleSessionSnapshot(__unused NSDictionary *params) {
    __block NSDictionary *snapshot = nil;
    BOOL ok = SpliceKit_executeCocoaUIBlock(^{
        NSMutableDictionary *s = [NSMutableDictionary dictionary];
        s[@"capturedAt"] = [[NSDate date] description];

        Class docCtlClass = objc_getClass("NSDocumentController");
        NSMutableArray *docs = [NSMutableArray array];
        if (docCtlClass) {
            id controller = ((id (*)(id, SEL))objc_msgSend)(
                docCtlClass, @selector(sharedDocumentController));
            if (controller) {
                NSArray *all = ((NSArray *(*)(id, SEL))objc_msgSend)(
                    controller, @selector(documents));
                for (id doc in all) {
                    NSString *path = nil;
                    NSString *display = nil;
                    if ([doc respondsToSelector:@selector(fileURL)]) {
                        NSURL *u = ((NSURL *(*)(id, SEL))objc_msgSend)(doc, @selector(fileURL));
                        path = u.path;
                    }
                    if ([doc respondsToSelector:@selector(displayName)]) {
                        display = ((NSString *(*)(id, SEL))objc_msgSend)(doc, @selector(displayName));
                    }
                    [docs addObject:@{
                        @"displayName": display ?: @"",
                        @"path": path ?: [NSNull null],
                        @"class": NSStringFromClass([doc class]),
                    }];
                }
            }
        }
        s[@"documents"] = docs;

        // Key window / main window info for basic UI state.
        NSWindow *key = [NSApp keyWindow];
        s[@"keyWindow"] = key ? @{
            @"title": key.title ?: @"",
            @"class": NSStringFromClass([key class]),
            @"number": @(key.windowNumber),
        } : (id)[NSNull null];

        snapshot = s;
    }, 2.0, @"session.snapshot");
    if (!ok) return @{@"error": @"main thread unavailable for snapshot"};
    return @{@"snapshot": snapshot ?: @{}};
}

NSDictionary *SpliceKit_handleSessionRestore(NSDictionary *params) {
    NSDictionary *snap = [params[@"snapshot"] isKindOfClass:[NSDictionary class]]
        ? params[@"snapshot"] : nil;
    if (!snap) return @{@"error": @"snapshot parameter required"};
    NSArray *docs = snap[@"documents"];
    if (![docs isKindOfClass:[NSArray class]]) docs = @[];
    __block NSMutableArray *opened = [NSMutableArray array];
    __block NSMutableArray *skipped = [NSMutableArray array];
    BOOL ok = SpliceKit_executeCocoaUIBlock(^{
        Class docCtlClass = objc_getClass("NSDocumentController");
        if (!docCtlClass) return;
        id controller = ((id (*)(id, SEL))objc_msgSend)(
            docCtlClass, @selector(sharedDocumentController));
        if (!controller) return;
        for (NSDictionary *doc in docs) {
            id pathVal = doc[@"path"];
            if (![pathVal isKindOfClass:[NSString class]]) {
                [skipped addObject:@{@"doc": doc, @"reason": @"no path"}];
                continue;
            }
            NSString *path = pathVal;
            NSURL *url = [NSURL fileURLWithPath:path];
            SEL openSel = @selector(openDocumentWithContentsOfURL:display:completionHandler:);
            if (![controller respondsToSelector:openSel]) {
                [skipped addObject:@{@"path": path, @"reason": @"controller lacks open selector"}];
                continue;
            }
            @try {
                void (^_completion)(id, BOOL, NSError *) = ^(id doc2, BOOL alreadyOpen, NSError *err) {
                    (void)doc2; (void)alreadyOpen; (void)err;
                };
                ((void (*)(id, SEL, NSURL *, BOOL, id))objc_msgSend)(
                    controller, openSel, url, YES, _completion);
                [opened addObject:path];
            } @catch (NSException *e) {
                [skipped addObject:@{@"path": path,
                                     @"reason": e.reason ?: @"exception"}];
            }
        }
    }, 10.0, @"session.restore");
    if (!ok) return @{@"error": @"main thread unavailable for restore"};
    return @{@"opened": opened ?: @[], @"skipped": skipped ?: @[]};
}

// ============================================================================
#pragma mark - Self-describe (catalog of RPC methods)
// ============================================================================
//
// Small hand-maintained catalog. Keeping it static rather than auto-generated
// from string matches so each entry can have a deliberate safety class +
// param shape.

typedef struct {
    const char *name;
    const char *safety;      // safe | stateful | modal | destructive | dangerous
    const char *category;
    const char *summary;
} SKBridgeMethodDescriptor;

static const SKBridgeMethodDescriptor kMethodCatalog[] = {
    // Meta
    {"bridge.alive",              "safe",    "meta",   "Liveness probe; does not touch main thread."},
    {"bridge.describe",           "safe",    "meta",   "Lists every documented RPC method with safety class."},
    {"bridge.metrics",            "safe",    "meta",   "Returns per-method call / error / latency counters."},
    {"bridge.resetMetrics",       "safe",    "meta",   "Clears the metrics counters."},
    {"bridge.options.get",        "safe",    "meta",   "Returns bridge configuration options."},
    {"bridge.options.set",        "stateful","meta",   "Sets a bridge configuration option."},

    // Palette
    {"command.search",            "safe",    "palette","Searches Motion/FCP commands by name/keyword."},
    {"command.execute",           "stateful","palette","Dispatches a Motion command; accepts dryRun."},
    {"command.status",            "safe",    "palette","Reports whether the command palette is visible."},
    {"command.show",              "stateful","palette","Shows the palette window."},
    {"command.hide",              "stateful","palette","Hides the palette window."},
    {"palette.block",             "stateful","palette","Adds a selector to the persistent runtime blocklist."},
    {"palette.unblock",           "stateful","palette","Removes a selector from the runtime blocklist."},
    {"palette.listBlocked",       "safe",    "palette","Lists all runtime-blocked selectors."},
    {"palette.isBlocked",         "safe",    "palette","Reports whether a selector is blocked and why."},

    // Modal handling
    {"window.listModals",         "safe",    "ui",     "Enumerates visible modal windows."},
    {"modal.dismiss",             "stateful","ui",     "Cancels / closes a modal window by index."},

    // Crash + logs
    {"debug.lastCrash",           "safe",    "debug",  "Returns parsed metadata from the newest IPS crash report."},
    {"debug.mainThreadBacktrace", "safe",    "debug",  "Best-effort backtrace of the host app's main thread."},
    {"debug.getConfig",           "safe",    "debug",  "Returns current TLK/log/CFPrefs debug flags."},
    {"debug.setConfig",           "stateful","debug",  "Sets a debug flag."},
    {"debug.resetConfig",         "stateful","debug",  "Resets debug flags to defaults."},
    {"debug.threads",             "safe",    "debug",  "Lists threads in the host process."},
    {"log.tail",                  "safe",    "debug",  "Returns the last N lines of the MotionKit log."},
    {"log.path",                  "safe",    "debug",  "Returns the filesystem path to the MotionKit log."},

    // Batch / sessions
    {"batch.execute",             "stateful","meta",   "Runs many RPCs in order; returns array of results."},
    {"session.snapshot",          "safe",    "session","Captures open documents + key-window info."},
    {"session.restore",           "stateful","session","Reopens the documents listed in a snapshot."},

    // Lua
    {"lua.execute",               "stateful","lua",    "Runs a Lua expression or script."},
    {"lua.executeFile",           "stateful","lua",    "Runs a Lua file from ~/Library/Application Support/SpliceKit/lua."},
    {"lua.reset",                 "stateful","lua",    "Recreates the Lua VM."},
    {"lua.getState",              "safe",    "lua",    "Inspects the Lua global table."},
    {"lua.watch",                 "stateful","lua",    "Controls the file watcher."},

    // Runtime introspection
    {"runtime.getClasses",        "safe",    "runtime","Returns ObjC class names matching a filter."},
    {"runtime.exploreClass",      "safe",    "runtime","Detailed metadata for one class."},
    {"runtime.getMethods",        "safe",    "runtime","Lists all methods on a class."},
    {"runtime.getIvars",          "safe",    "runtime","Lists ivars + byte offsets on a class."},
    {"runtime.getProperties",     "safe",    "runtime","Lists declared properties + attributes."},
    {"runtime.getProtocols",      "safe",    "runtime","Lists protocol conformances."},
    {"runtime.getSuperchain",     "safe",    "runtime","Walks a class's inheritance chain."},
    {"runtime.searchMethods",     "safe",    "runtime","Searches methods on a class by name."},
    {"system.callMethod",         "dangerous","runtime","Invokes a simple ObjC method on a class/handle."},
    {"system.callMethodWithArgs", "dangerous","runtime","Invokes an ObjC method with typed arguments."},

    // Menus
    {"menu.list",                 "safe",    "ui",     "Returns the host-app's menu structure."},
    {"menu.execute",              "stateful","ui",     "Fires a specific menu item."},

    // Dialog automation
    {"dialog.detect",             "safe",    "ui",     "Reports open AppKit dialogs + their controls."},
    {"dialog.click",              "stateful","ui",     "Clicks a button in the front dialog."},
    {"dialog.fill",               "stateful","ui",     "Fills a text field in the front dialog."},
    {"dialog.checkbox",           "stateful","ui",     "Toggles a checkbox in the front dialog."},
    {"dialog.popup",              "stateful","ui",     "Selects an item in a popup menu."},
    {"dialog.dismiss",            "stateful","ui",     "Closes the front dialog."},
};

NSDictionary *SpliceKit_handleBridgeDescribe(__unused NSDictionary *params) {
    NSMutableArray *methods = [NSMutableArray array];
    size_t count = sizeof(kMethodCatalog) / sizeof(kMethodCatalog[0]);
    for (size_t i = 0; i < count; i++) {
        [methods addObject:@{
            @"name":     @(kMethodCatalog[i].name),
            @"safety":   @(kMethodCatalog[i].safety),
            @"category": @(kMethodCatalog[i].category),
            @"summary":  @(kMethodCatalog[i].summary),
        }];
    }
    [methods sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"]];
    }];
    return @{
        @"methods": methods,
        @"count": @(methods.count),
        @"safetyClasses": @[
            @"safe",        // idempotent, does not touch state
            @"stateful",    // mutates host state but safe to invoke
            @"modal",       // may open modal UI — bridge continues but user sees dialog
            @"destructive", // deletes, overwrites, or signs off on data loss
            @"dangerous",   // can crash the host if misused (e.g. raw ObjC dispatch)
        ],
    };
}
