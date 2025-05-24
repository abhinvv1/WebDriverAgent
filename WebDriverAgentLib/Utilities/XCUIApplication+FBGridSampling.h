#import <XCTest/XCTest.h>
#import "FBXCElementSnapshot.h"

@class FBElementCache;

NS_ASSUME_NONNULL_BEGIN

@interface XCUIApplication (FBGridSampling)

/**
 * Performs comprehensive grid sampling and populates FBElementCache
 * @param parameters Dictionary containing sampling parameters
 * @return YES if sampling completed successfully
 */
- (nullable id<FBXCElementSnapshot>)fb_gridSampledSnapshotTreeWithParameters:(NSDictionary *)parameters;

@end

NS_ASSUME_NONNULL_END
