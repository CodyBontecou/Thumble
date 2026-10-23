#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
NS_ASSUME_NONNULL_BEGIN
// Simulator UI-test runner only; fixed three-control trajectories, no product linkage.
void ThumbleBankPresentationGesture(XCUIApplication *application, NSArray<NSValue *> *points,
                                    void (^started)(void), void (^completion)(BOOL succeeded));
NS_ASSUME_NONNULL_END
