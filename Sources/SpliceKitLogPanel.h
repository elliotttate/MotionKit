//
//  SpliceKitLogPanel.h
//  Lightweight in-app log viewer for the injected SpliceKit runtime.
//

#ifndef SpliceKitLogPanel_h
#define SpliceKitLogPanel_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface SpliceKitLogPanel : NSObject

+ (instancetype)sharedPanel;

- (void)showPanel;
- (void)hidePanel;
- (void)togglePanel;
- (BOOL)isVisible;

@end

#endif /* SpliceKitLogPanel_h */
