// Focused application-delivery evidence; no global event monitor.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include <signal.h>
static volatile sig_atomic_t stopping = 0;
static void stopProbe(int signalNumber) { stopping = 1; }

@interface PointerProbe : NSView
@property NSFileHandle *log;
@property NSMutableSet<NSNumber *> *held;
@property pid_t receiverPID;
- (BOOL)isReceiverEvent:(NSEvent *)event;
- (void)record:(NSDictionary *)row;
@end
@implementation PointerProbe
- (BOOL)acceptsFirstResponder { return YES; }
- (void)record:(NSDictionary *)row {
    NSData *data = [NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
    [self.log writeData:data];
    [self.log writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}
- (BOOL)isReceiverEvent:(NSEvent *)event {
    return event.CGEvent && CGEventGetIntegerValueField(event.CGEvent, kCGEventSourceUnixProcessID) == self.receiverPID;
}
- (void)mouseMoved:(NSEvent *)event {
    if (![self isReceiverEvent:event]) return;
    [self record:@{@"kind":@"move", @"x":@(event.locationInWindow.x), @"y":@(event.locationInWindow.y)}];
}
- (void)scrollWheel:(NSEvent *)event {
    if (![self isReceiverEvent:event]) return;
    [self record:@{@"kind":@"scroll", @"x":@(event.scrollingDeltaX), @"y":@(event.scrollingDeltaY)}];
}
- (void)button:(NSEvent *)event down:(BOOL)down {
    if (![self isReceiverEvent:event]) return;
    NSNumber *button = @(event.buttonNumber);
    if (down) [self.held addObject:button]; else [self.held removeObject:button];
    [self record:@{@"kind":down ? @"down" : @"up", @"button":button, @"held":self.held.allObjects}];
}
- (void)mouseDown:(NSEvent *)event { [self button:event down:YES]; }
- (void)mouseUp:(NSEvent *)event { [self button:event down:NO]; }
- (void)rightMouseDown:(NSEvent *)event { [self button:event down:YES]; }
- (void)rightMouseUp:(NSEvent *)event { [self button:event down:NO]; }
- (void)otherMouseDown:(NSEvent *)event { [self button:event down:YES]; }
- (void)otherMouseUp:(NSEvent *)event { [self button:event down:NO]; }
- (void)mouseDragged:(NSEvent *)event { if (![self isReceiverEvent:event]) return; [self record:@{@"kind":@"drag", @"held":self.held.allObjects}]; }
- (void)keyDown:(NSEvent *)event {} // Other fixture controls must not invoke system shortcuts.
- (void)keyUp:(NSEvent *)event {}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3 || atoi(argv[2]) <= 0) return 2;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        [[NSFileManager defaultManager] createFileAtPath:path contents:[NSData data] attributes:nil];
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        PointerProbe *view = [[PointerProbe alloc] initWithFrame:NSMakeRect(0, 0, 1000, 700)];
        view.log = [NSFileHandle fileHandleForWritingAtPath:path];
        view.held = [NSMutableSet set];
        view.receiverPID = atoi(argv[2]);
        NSWindow *window = [[NSWindow alloc] initWithContentRect:view.bounds styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.title = @"Thumble Android Pointer Test";
        window.contentView = view;
        window.acceptsMouseMovedEvents = YES;
        [window center];
        [window makeKeyAndOrderFront:nil];
        [window makeFirstResponder:view];
        [app activateIgnoringOtherApps:YES];
        CGEventRef originalEvent = CGEventCreate(NULL);
        CGPoint originalPosition = CGEventGetLocation(originalEvent);
        CFRelease(originalEvent);
        signal(SIGTERM, stopProbe);
        __block BOOL positioned = NO;
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
            if (stopping) {
                CGWarpMouseCursorPosition(originalPosition);
                [app terminate:nil];
                return;
            }
            BOOL focused = window.isKeyWindow && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == NSProcessInfo.processInfo.processIdentifier;
            if (focused && !positioned) {
                NSPoint point = [window convertPointToScreen:NSMakePoint(400, 350)];
                CGWarpMouseCursorPosition(CGPointMake(point.x, NSMaxY(NSScreen.screens.firstObject.frame) - point.y));
                positioned = YES;
            }
            [view record:@{@"kind":@"focus", @"focused":@(focused), @"held":view.held.allObjects}];
        }];
        [app run];
    }
}
