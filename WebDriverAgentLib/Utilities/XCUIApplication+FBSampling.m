//
//  XCUIApplication.m
//  WebDriverAgent
//
//  Created by Abhinav Pandey on 22/05/25.
//


#import "XCUIApplication+FBSampling.h"
#import "FBLogger.h"
#import "FBErrorBuilder.h"
#import "XCUIElement+FBUtilities.h"
#import <WebDriverAgentLib/FBXCTestDaemonsProxy.h>
#import <WebDriverAgentLib/XCTestManager_ManagerInterface-Protocol.h>
#import <WebDriverAgentLib/XCUIElement+FBWebDriverAttributes.h>
#import "FBElementUtils.h"
#import "FBXCElementSnapshot.h"
#import <WebDriverAgentLib/FBXCElementSnapshot.h>

static const NSTimeInterval kFBSamplingTimeout = 5.0;

@implementation XCUIApplication (FBSampling)

- (void)fb_fetchSkeletonSnapshotAtPoint:(CGPoint)point
                             parameters:(nullable NSDictionary<NSString *, id> *)parameters
                             completion:(void (^)(id<FBXCElementSnapshot> _Nullable snapshot, NSError * _Nullable error))completion;
{
  id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
  [proxy _XCT_requestElementAtPoint:point reply:^(id axElement, NSError *error) {
    if (error) {
      [FBLogger logFmt:@"Failed to request element at point %@: %@", NSStringFromCGPoint(point), error.localizedDescription];
      if (completion) {
        completion(nil, error);
      }
      return;
    }

    if (!axElement) {
      [FBLogger logFmt:@"No element found at point %@.", NSStringFromCGPoint(point)];
      NSError *notFoundError = [[[FBErrorBuilder builder]
                                        withDescription:[NSString stringWithFormat:@"No element found at point %@", NSStringFromCGPoint(point)]]
                                      build];
      if (completion) {
        completion(nil, notFoundError);
      }
      return;
    }

    // Step 2: Request a snapshot for the found accessibility element
    // We need to define what attributes constitute a "skeleton".
    // Using `[XCUIElement fb_minimalRequestAttributes]` or similar from WDA if available,
    // or a predefined minimal set. For now, let's pass nil, which might fetch default attributes.
    // The `parameters` argument is crucial for controlling depth.
    // SeeTest used keys like "maxDepth", "maxChildren".
    // For a true skeleton, we'd want maxDepth: 0 (just the element itself).
      
    NSMutableDictionary *snapshotParams = [NSMutableDictionary dictionary];
    if (parameters) {
        [snapshotParams addEntriesFromDictionary:parameters];
    }
     snapshotParams[@"maxDepth"] = @100;
     snapshotParams[@"maxArrayCount"] = @100;
     snapshotParams[@"maxChildren"] = @5;

    NSArray<NSString *> *minimalAttributeNames = @[@"type", @"frame", @"label", @"value", @"accessibilityContainer", @"visible", @"enabled", @"rect", ];
    NSMutableArray<NSString *> *attributesToFetch = [NSMutableArray array];
    for (NSString *attributeName in minimalAttributeNames) {
        NSString *wdAttributeName = [FBElementUtils wdAttributeNameForAttributeName:attributeName];
        if (wdAttributeName) {
            [attributesToFetch addObject:wdAttributeName];
        }
    }

    [FBLogger logFmt:@"Requesting snapshot for element at point %@ with params: %@ and attributes: %@", NSStringFromCGPoint(point), snapshotParams, attributesToFetch];
    
    [FBLogger logFmt:@"Requesting snapshot for element at point %@ with params: %@ and attributes: %@", NSStringFromCGPoint(point), snapshotParams, attributesToFetch];

        [proxy _XCT_requestSnapshotForElement:axElement
                                   attributes:attributesToFetch
                                   parameters:snapshotParams
                                        reply:^(id snapshotObject, NSError *snapshotError) {
        if (snapshotError) {
          [FBLogger logFmt:@"Failed to request snapshot for element: %@", snapshotError.localizedDescription];
          if (completion) {
            completion(nil, snapshotError);
          }
          return;
        }

        if (!snapshotObject) {
          [FBLogger logFmt:@"Received nil snapshot for element at point %@.", NSStringFromCGPoint(point)];
          if (completion) {
            completion(nil, nil);
          }
          return;
        }
        
        id<FBXCElementSnapshot> actualSnapshot = (id<FBXCElementSnapshot>)snapshotObject;

        if (completion) {
          completion(actualSnapshot, nil);
        }
    }];
  }];
}

@end
