// SPDX-License-Identifier: MPL-2.0
#import <AppKit/AppKit.h>
#include <stdio.h>
#include "NeutrinoEngineABI.h"

/// CEF requires these event-state selectors on the application's NSApplication.
/// The optional bridge adds its public CefAppProtocol conformance when loaded.
@interface NeutrinoApplication : NSApplication {
    BOOL _handlingSendEvent;
}
@end
@implementation NeutrinoApplication
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)value { _handlingSendEvent = value; }
- (void)sendEvent:(NSEvent *)event {
    BOOL previous = _handlingSendEvent;
    _handlingSendEvent = YES;
    @try { [super sendEvent:event]; }
    @finally { _handlingSendEvent = previous; }
}
@end

void NeutrinoBootstrapApplication(void) {
    // Retain diagnostic progress if native code aborts before Swift's buffered
    // stdout would otherwise be flushed at normal process termination.
    if ([[[NSProcessInfo processInfo] arguments] containsObject:@"--smoke-test"])
        setvbuf(stdout, NULL, _IONBF, 0);
    [NeutrinoApplication sharedApplication];
    NSCAssert([NSApp isKindOfClass:[NeutrinoApplication class]], @"Neutrino must create its application before SwiftUI starts.");
}
