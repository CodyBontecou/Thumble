// Isolated application fixture. It records launch receipt, then exits itself.
#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
@interface LaunchFixture : NSObject <NSApplicationDelegate>
@property BOOL activated;
@end
@implementation LaunchFixture
- (void)applicationDidBecomeActive:(NSNotification *)notification { self.activated = YES; }
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.activated |= NSApplication.sharedApplication.isActive;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 5;
    [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        self.activated |= NSApplication.sharedApplication.isActive;
        if (!self.activated && NSProcessInfo.processInfo.systemUptime < deadline) return;
        [timer invalidate];
        NSDictionary *receipt = @{@"bundleID": NSBundle.mainBundle.bundleIdentifier,
                                   @"active": @(self.activated), @"pid": @(NSProcessInfo.processInfo.processIdentifier)};
        NSData *data = [NSJSONSerialization dataWithJSONObject:receipt options:0 error:nil];
        [data writeToFile:[NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"receipt.json"] atomically:YES];
        [NSApplication.sharedApplication terminate:nil];
    }];
}
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--register") == 0) {
            NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
            printf("%d\n", (int)LSRegisterURL((__bridge CFURLRef)url, true));
            return 0;
        }
        if (argc == 3 && strcmp(argv[1], "--lookup") == 0) {
            NSURL *url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:[NSString stringWithUTF8String:argv[2]]];
            puts(url ? "found" : "missing");
            return 0;
        }
        if (argc == 3 && strcmp(argv[1], "--bookmark") == 0) {
            NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
            NSData *data = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
            if (!data) return 2;
            puts([data base64EncodedStringWithOptions:0].UTF8String);
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        LaunchFixture *delegate = [LaunchFixture new];
        app.delegate = delegate;
        [app run];
    }
}
