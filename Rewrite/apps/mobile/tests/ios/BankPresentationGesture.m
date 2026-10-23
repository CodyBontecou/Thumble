#import "BankPresentationGesture.h"
#import <math.h>

// Installed XCTest runtime selectors. Missing APIs fail this tooling witness, never skip it.
@interface NSObject (ThumbleBankXCTest)
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(long long)orientation;
- (void)addPointerEventPath:(id)path;
- (id)eventSynthesizer;
- (void)synthesizeEvent:(id)record completion:(void (^)(BOOL, NSError *))completion;
@end

void ThumbleBankPresentationGesture(XCUIApplication *application, NSArray<NSValue *> *points,
                                    void (^started)(void), void (^completion)(BOOL)) {
  NSCAssert(NSThread.isMainThread, @"QA gesture owner thread");
  __block BOOL completed = NO;
  void (^finish)(BOOL) = ^(BOOL ok) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (completed) return;
      completed = YES;
      completion(ok);
    });
  };
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 72 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{ finish(NO); });
  @try {
    CGFloat limit = MAX(application.frame.size.width, application.frame.size.height);
    CGRect bounds = CGRectMake(0, 0, limit, limit);
    if (points.count != 7 || limit <= 0 || limit > 2000) { finish(NO); return; }
    for (NSValue *value in points) {
      if (![value isKindOfClass:NSValue.class] || strcmp(value.objCType, @encode(CGPoint)) != 0) {
        finish(NO); return;
      }
      CGPoint p = value.CGPointValue;
      if (!isfinite(p.x) || !isfinite(p.y) || !CGRectContainsPoint(bounds, p)) {
        finish(NO); return;
      }
    }
    Class paths = NSClassFromString(@"XCPointerEventPath");
    Class records = NSClassFromString(@"XCSynthesizedEventRecord");
    if (!paths || !records ||
        ![paths instancesRespondToSelector:@selector(initForTouchAtPoint:offset:)] ||
        ![paths instancesRespondToSelector:@selector(liftUpAtOffset:)] ||
        ![paths instancesRespondToSelector:@selector(moveToPoint:atOffset:)] ||
        ![records instancesRespondToSelector:@selector(initWithName:interfaceOrientation:)] ||
        ![records instancesRespondToSelector:@selector(addPointerEventPath:)] ||
        ![XCUIDevice.sharedDevice respondsToSelector:@selector(eventSynthesizer)]) {
      finish(NO); return;
    }
    id synthesizer = [XCUIDevice.sharedDevice eventSynthesizer];
    if (![synthesizer respondsToSelector:@selector(synthesizeEvent:completion:)]) {
      finish(NO); return;
    }
    NSNumber *orientation = [application valueForKey:@"interfaceOrientation"];
    if (![orientation isKindOfClass:NSNumber.class] || orientation.integerValue < 1 ||
        orientation.integerValue > 4) { finish(NO); return; }
    id record = [[records alloc] initWithName:@"Thumble bank artwork QA"
                              interfaceOrientation:orientation.longLongValue];
    // Start all three contacts together. Every keyframe contains all contacts,
    // avoiding installed XCTest's ambiguous partially overlapping path delivery.
    id south = [[paths alloc] initForTouchAtPoint:points[0].CGPointValue offset:0];
    id left = [[paths alloc] initForTouchAtPoint:points[1].CGPointValue offset:0];
    id right = [[paths alloc] initForTouchAtPoint:points[2].CGPointValue offset:0];
    const double offsets[] = {1.1, 6.1, 11, 17, 22, 27, 40, 45, 47, 52, 58};
    const NSUInteger l[] = {3, 3, 5, 5, 3, 3, 3, 5, 5, 3, 5};
    const NSUInteger r[] = {2, 4, 4, 6, 6, 4, 6, 6, 4, 4, 6};
    CGPoint previousLeft = points[1].CGPointValue;
    CGPoint previousRight = points[2].CGPointValue;
    for (NSUInteger i = 0; i < 11; i++) {
      // atOffset is arrival time: explicitly hold the previous position until
      // 100ms before transition, instead of dragging slowly across the whole gap.
      [south moveToPoint:points[0].CGPointValue atOffset:offsets[i] - 0.1];
      [left moveToPoint:previousLeft atOffset:offsets[i] - 0.1];
      [right moveToPoint:previousRight atOffset:offsets[i] - 0.1];
      [south moveToPoint:points[0].CGPointValue atOffset:offsets[i]];
      [left moveToPoint:points[l[i]].CGPointValue atOffset:offsets[i]];
      [right moveToPoint:points[r[i]].CGPointValue atOffset:offsets[i]];
      previousLeft = points[l[i]].CGPointValue;
      previousRight = points[r[i]].CGPointValue;
    }
    for (id path in @[south, left, right]) {
      [path liftUpAtOffset:62];
      [record addPointerEventPath:path];
    }
    started();
    [synthesizer synthesizeEvent:record completion:^(BOOL ok, NSError *error) {
      finish(ok && error == nil);
    }];
  } @catch (NSException *exception) {
    finish(NO); // No exception text, endpoint, invitation, or hierarchy leaves this helper.
  }
}
