// SpliceKitBridgeAPI.h — self-introspection, runtime blocklist, crash
// retrieval, modal handling, metrics, and test ergonomics for MotionKit.
//
// These RPCs all exist so an AI agent (or human script) can iterate against
// Motion without having to rebuild the dylib or shell out to read logs /
// crash reports / ps every few seconds.

#import <Foundation/Foundation.h>

// Liveness
NSDictionary *SpliceKit_handleBridgeAlive(NSDictionary *params);
NSDictionary *SpliceKit_handleBridgeDescribe(NSDictionary *params);

// Metrics
void SpliceKit_metricsRecord(NSString *method, double ms, BOOL ok);
NSDictionary *SpliceKit_handleBridgeMetrics(NSDictionary *params);
NSDictionary *SpliceKit_handleBridgeResetMetrics(NSDictionary *params);

// Runtime blocklist — queried by the command palette.
BOOL SpliceKitBridge_isBlockedSelector(NSString *selector, NSString **reasonOut);
NSDictionary *SpliceKit_handlePaletteBlock(NSDictionary *params);
NSDictionary *SpliceKit_handlePaletteUnblock(NSDictionary *params);
NSDictionary *SpliceKit_handlePaletteListBlocked(NSDictionary *params);
NSDictionary *SpliceKit_handlePaletteIsBlocked(NSDictionary *params);

// Crash retrieval
NSDictionary *SpliceKit_handleDebugLastCrash(NSDictionary *params);

// Log introspection
NSDictionary *SpliceKit_handleLogTail(NSDictionary *params);
NSDictionary *SpliceKit_handleLogPath(NSDictionary *params);

// Modal window handling
NSDictionary *SpliceKit_handleWindowListModals(NSDictionary *params);
NSDictionary *SpliceKit_handleModalDismiss(NSDictionary *params);

// Batch dispatch
NSDictionary *SpliceKit_handleBatchExecute(NSDictionary *params);

// Main-thread diagnostics
NSDictionary *SpliceKit_handleDebugMainThreadBacktrace(NSDictionary *params);

// Session save/restore (Motion)
NSDictionary *SpliceKit_handleSessionSnapshot(NSDictionary *params);
NSDictionary *SpliceKit_handleSessionRestore(NSDictionary *params);
