//
//  XCUIApplication+FBGridSampling.h
//  WebDriverAgent
//
//  Created by Abhinav Pandey on 23/05/25.
//  Copyright © 2025 Facebook. All rights reserved.
//

#import <XCTest/XCTest.h>
#import <WebDriverAgentLib/FBXCElementSnapshot.h>

NS_ASSUME_NONNULL_BEGIN

@interface XCUIApplication (FBGridSampling)

@property (nonatomic, strong) NSDate *samplingStartTime;
@property (nonatomic, assign) NSInteger samplingIterationCount;
@property (nonatomic, strong) NSMutableSet<NSString *> *processedElementIDs;

/**
 * Generates a complete UI tree using grid sampling to overcome XCUITest nesting limitations
 * @param parameters Dictionary containing sampling parameters (samplesX, samplesY, maxDepthForPoint, etc.)
 * @return Complete UI tree dictionary or nil if failed
 */
- (nullable NSDictionary *)fb_gridSampledTreeWithParameters:(NSDictionary *)parameters;

/**
 * Fetches element snapshot at a specific point with controlled depth
 * @param point The CGPoint to sample
 * @param parameters Sampling parameters including maxDepth
 * @param completion Completion block with snapshot or error
 */
- (void)fb_fetchElementSnapshotAtPoint:(CGPoint)point
                            parameters:(nullable NSDictionary<NSString *, id> *)parameters
                            completion:(void (^)(id<FBXCElementSnapshot> _Nullable snapshot, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
