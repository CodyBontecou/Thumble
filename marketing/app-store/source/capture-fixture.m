// Optional fixture loader for a disposable, ad-hoc-signed Mac capture app.
// Set THUMBLE_CAPTURE_FIXTURE to a generated *-preferences.plist.
// Never inject into a personal or production app instance.
#import <Foundation/Foundation.h>
__attribute__((constructor)) static void loadCaptureFixture(void) {
    @autoreleasepool {
        NSString *path = NSProcessInfo.processInfo.environment[@"THUMBLE_CAPTURE_FIXTURE"];
        NSDictionary *preferences = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        if (preferences) {
            [[NSUserDefaults standardUserDefaults] setVolatileDomain:preferences forName:NSArgumentDomain];
        }
    }
}
