// XCUIApplication+FBSampling.h
#import <XCTest/XCTest.h>
#import <WebDriverAgentLib/FBXCElementSnapshot.h> // This should bring in FBXCElementSnapshot
#import "XCUIElement+FBWebDriverAttributes.h"

NS_ASSUME_NONNULL_BEGIN

// Forward declare if FBFrameworks.h doesn't expose it, though it should.
// @protocol FBXCElementSnapshot; // Only uncomment if FBFrameworks.h doesn't make it visible.

@interface XCUIApplication (FBSampling)

/**
 * Asynchronously fetches a "skeleton" snapshot of the UI element at a given point.
 * A skeleton snapshot contains the element's direct attributes and a controlled, shallow depth.
 *
 * @param point The coordinate on the screen.
 * @param parameters Optional parameters to control snapshot generation (e.g., maxDepth).
 * For a skeleton, this might be @{ @"maxDepth": @0 } or similar.
 * @param completion A block called with the skeleton snapshot (conforming to FBXCElementSnapshot) or an error.
 */
- (void)fb_fetchSkeletonSnapshotAtPoint:(CGPoint)point
                             parameters:(nullable NSDictionary<NSString *, id> *)parameters
                             completion:(void (^)(id<FBXCElementSnapshot> _Nullable snapshot, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
