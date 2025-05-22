// RNUiInspector.m

#import "RNUiInspector.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIElement+FBUtilities.h"
#import "FBErrorBuilder.h"
#import "FBLogger.h"
#import "FBRNViewXMLConverter.h" // To understand expected output structure
#import "FBElementTypeTransformer.h"
#import "XCUIApplication+FBSampling.h"
#import "XCUIElement+FBWebDriverAttributes.h"
#import <WebDriverAgentLib/XCUIElement+FBUtilities.h>

// Forward declarations for potential private API usage (use with caution)
@interface XCAccessibilityElement : NSObject
+ (id)_XCT_requestElementAtPoint:(CGPoint)point; // Example private API
- (NSDictionary *)fb_accessibilityAttributes; // Existing WDA helper
- (NSArray<XCAccessibilityElement *> *)_XCT_children; // Example private API for children
// Add other private API declarations if needed and known
@end

static NSDictionary *dictionaryForSnapshot(id<FBXCElementSnapshot> snapshot, XCUIApplication *application, int maxDepthLimit, int currentDepth, NSMutableSet<NSString *> *visitedElementIdentities);

static NSDictionary *dictionaryForRootAppElement(XCUIApplication *element, int maxDepth, int currentDepth, NSMutableSet<NSString *> *visitedElementDescriptions) {
    if (!element || currentDepth > maxDepth) {
        return nil;
    }

    NSString *elementDescription = [element debugDescription];
    if ([visitedElementDescriptions containsObject:elementDescription]) {
        return nil;
    }
    [visitedElementDescriptions addObject:elementDescription];

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    @try {
        dict[@"type"] = [FBElementTypeTransformer shortStringWithElementType:element.elementType];
        dict[@"label"] = element.label;
        dict[@"name"] = element.wdName;
        dict[@"value"] = element.value;
        dict[@"rect"] = element.wdRect;
        dict[@"isEnabled"] = @(element.isEnabled);
        dict[@"isVisible"] = @(element.isWDVisible);
        NSString *testID = element.identifier;
        if (testID && testID.length > 0) {
            dict[@"testID"] = testID;
        }
    } @catch (NSException *exception) {
        [FBLogger logFmt:@"Exception getting attributes for root element %@: %@", elementDescription, exception.reason];
        dict[@"error"] = exception.reason;
        dict[@"description"] = elementDescription;
        [visitedElementDescriptions removeObject:elementDescription];
        return dict;
    }

    // For the root, we might not want to eagerly fetch children this way
    // This part can be adapted based on how deep we want to go from the root XCUIElement itself
    if (currentDepth < maxDepth) {
        // Children fetching for XCUIElement (use cautiously for root)
        // Consider if children should be populated from grid sampling instead for the root's children
    }
    
    [visitedElementDescriptions removeObject:elementDescription];
    return dict;
}


// New helper to convert an id<FBXCElementSnapshot> and its children (fetched via XCUIElement)
// to a dictionary with controlled depth.
static NSDictionary *dictionaryForSnapshot(id<FBXCElementSnapshot> snapshot, XCUIApplication *application, int maxDepthLimit, int currentDepth, NSMutableSet<NSString *> *visitedElementIdentities) {
  if (!snapshot || currentDepth > maxDepthLimit) { // maxDepthLimit is the original maxDepthForPoint
        return nil;
    }

    // Use the snapshot's identifier (often testID) or a composite key for visited tracking
    NSString *elementIdentity = snapshot.identifier;
    if (!elementIdentity || elementIdentity.length == 0) {
        // Fallback if direct identifier is not available or empty
        elementIdentity = [NSString stringWithFormat:@"%lu-%@-%@",
                           (unsigned long)snapshot.elementType,
                           NSStringFromCGRect(snapshot.frame),
                           snapshot.label ?: @"nolabel"];
    }

    if ([visitedElementIdentities containsObject:elementIdentity]) {
        return nil; // Already processed this element (identified by its properties)
    }
    [visitedElementIdentities addObject:elementIdentity];

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    @try {
        dict[@"type"] = [FBElementTypeTransformer stringWithElementType:snapshot.elementType];
        dict[@"label"] = snapshot.label;
        dict[@"name"] = snapshot.title;
        dict[@"value"] = snapshot.value;
        dict[@"rect"] = [NSValue valueWithCGRect:snapshot.frame];
        dict[@"isEnabled"] = @(snapshot.enabled);
        dict[@"isVisible"] = @(!CGRectIsEmpty(snapshot.visibleFrame));

        NSString *testID = snapshot.identifier;
        if (testID && testID.length > 0) {
            dict[@"testID"] = testID;
        }

    } @catch (NSException *exception) {
        [FBLogger logFmt:@"Exception getting attributes from snapshot (id: %@): %@", elementIdentity, exception.reason];
        dict[@"error"] = exception.reason;
        dict[@"description"] = [snapshot description]; // Basic description
        [visitedElementIdentities removeObject:elementIdentity];
        return dict;
    }

    NSMutableArray *childrenArray = [NSMutableArray array];
    if (currentDepth < maxDepthLimit && snapshot.children && snapshot.children.count > 0) {
        for (id<FBXCElementSnapshot> childSnapshot in snapshot.children) {
            NSDictionary *childDict = dictionaryForSnapshot(childSnapshot, application, maxDepthLimit, currentDepth + 1, visitedElementIdentities);
            if (childDict) {
                [childrenArray addObject:childDict];
            }
        }
    }
    if (childrenArray.count > 0) {
        dict[@"children"] = childrenArray;
    }
    return dict;
}


@implementation RNUiInspector

+ (nullable NSDictionary *)treeForApplication:(XCUIApplication *)application
                                withParameters:(NSDictionary *)parameters // Pass parameters from the request
{
  NSInteger samplesX = [parameters[@"samplesX"] integerValue] ?: 5;
  NSInteger samplesY = [parameters[@"samplesY"] integerValue] ?: 12;
  // maxDepthForPoint now dictates the depth of the snapshot fetched at each point
  NSInteger maxDepthForPoint = [parameters[@"maxDepthForPoint"] integerValue] ?: 1; // Default to 1 to get immediate children. 0 for just the element.

  // Parameters for fb_fetchSkeletonSnapshotAtPoint:
  // The 'maxDepth' here will determine how deep each partial tree from a point is.
  NSDictionary<NSString *, id> *snapshotFetchParameters = @{
      @"maxDepth": @(maxDepthForPoint),
  };

  CGRect appFrame = application.frame;
  if (CGRectIsEmpty(appFrame)) {
      [FBLogger logFmt:@"Application frame is empty."];
      return @{@"error": @"Application frame empty."};
  }

  NSMutableDictionary *mergedTree = [NSMutableDictionary dictionary];
  // This set tracks unique elements found across *all* grid points to avoid redundant processing
  // if the same element (or its shallow tree) is picked up by multiple sample points.
  NSMutableSet<NSString *> *globallyProcessedElementIdentities = [NSMutableSet set];
  NSMutableArray<NSDictionary *> *childNodes = [NSMutableArray array];

  NSMutableSet<NSString *> *visitedForAppElement = [NSMutableSet set];
  NSDictionary *appElementDict = dictionaryForRootAppElement(application, 0, 0, visitedForAppElement);
  if (appElementDict) {
      [mergedTree addEntriesFromDictionary:appElementDict];
  } else {
      mergedTree[@"type"] = [FBElementTypeTransformer shortStringWithElementType:application.elementType];
      mergedTree[@"label"] = application.label;
  }
  
  CGFloat stepX = (samplesX > 1) ? appFrame.size.width / (samplesX - 1) : appFrame.size.width / 2.0;
  CGFloat stepY = (samplesY > 1) ? appFrame.size.height / (samplesY - 1) : appFrame.size.height / 2.0;
  if (samplesX <= 1) stepX = appFrame.size.width / 2.0;
  if (samplesY <= 1) stepY = appFrame.size.height / 2.0;

  for (NSInteger i = 0; i < samplesX; ++i) {
      for (NSInteger j = 0; j < samplesY; ++j) {
          CGFloat x = appFrame.origin.x + ( (samplesX == 1) ? (appFrame.size.width / 2.0) : (i * stepX) );
          CGFloat y = appFrame.origin.y + ( (samplesY == 1) ? (appFrame.size.height / 2.0) : (j * stepY) );
          CGPoint point = CGPointMake(x, y);

          __block id<FBXCElementSnapshot> pointSnapshotWithChildren = nil; // Renamed for clarity
          __block NSError *fetchError = nil;
          dispatch_semaphore_t sem = dispatch_semaphore_create(0);

          [application fb_fetchSkeletonSnapshotAtPoint:point
                                           parameters:snapshotFetchParameters // maxDepthForPoint is used here
                                           completion:^(id<FBXCElementSnapshot> snapshot, NSError *error) {
              pointSnapshotWithChildren = snapshot;
              fetchError = error;
              dispatch_semaphore_signal(sem);
          }];
          
          if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC))) != 0) { // Increased timeout slightly
              [FBLogger logFmt:@"Timeout waiting for snapshot at point %@", NSStringFromCGPoint(point)];
              fetchError = [[[FBErrorBuilder builder]
                                 withDescription:@"Timeout fetching snapshot at point."] build];
          }

          if (fetchError) {
              [FBLogger logFmt:@"Error getting snapshot at point %@: %@", NSStringFromCGPoint(point), fetchError.localizedDescription];
              continue;
          }

          if (pointSnapshotWithChildren) {
              // Filter out the main application/window element itself if it's picked up by a point
              if ((pointSnapshotWithChildren.elementType == XCUIElementTypeApplication || pointSnapshotWithChildren.elementType == XCUIElementTypeWindow) &&
                  CGRectContainsRect(pointSnapshotWithChildren.frame, CGRectInset(application.frame, -5, -5))) {
                  continue;
              }
              
              // Use .identifier for the identity of the root of this partial tree
              NSString *rootPartialTreeIdentity = pointSnapshotWithChildren.identifier;
              if (!rootPartialTreeIdentity || rootPartialTreeIdentity.length == 0) {
                  rootPartialTreeIdentity = [NSString stringWithFormat:@"%lu-%@-%@",
                                     (unsigned long)pointSnapshotWithChildren.elementType,
                                     NSStringFromCGRect(pointSnapshotWithChildren.frame),
                                     pointSnapshotWithChildren.label ?: @"nolabel"];
              }

              // If this specific element (as the root of a partial tree) hasn't been processed from another point
              if (![globallyProcessedElementIdentities containsObject:rootPartialTreeIdentity]) {
                  // The `dictionaryForSnapshot` will use its own visited set for its internal recursion
                  // to build the tree from `pointSnapshotWithChildren`.
                  // `globallyProcessedElementIdentities` is for the top-level elements found at sample points.
                  NSMutableSet<NSString *> *visitedForThisPartialTree = [NSMutableSet set];
                  NSDictionary *partialTree = dictionaryForSnapshot(pointSnapshotWithChildren, application, maxDepthForPoint, 0, visitedForThisPartialTree);
                  
                  if (partialTree && partialTree.count > 0) {
                      [childNodes addObject:partialTree];
                      [globallyProcessedElementIdentities addObject:rootPartialTreeIdentity]; // Mark this root as processed
                  } else {
                       [FBLogger logFmt:@"dictionaryForSnapshot returned empty or nil for snapshot (identity: %@).", rootPartialTreeIdentity];
                  }
              }
          }
      }
  }

  if (childNodes.count > 0) {
      mergedTree[@"children"] = childNodes;
  }
  
  if (mergedTree.count <= 1 && childNodes.count == 0) { // e.g. only app type/label, no actual children found
       [FBLogger logFmt:@"No substantial UI elements found through grid sampling."];
       // Return the basic app shell, or nil if that's preferred for "empty"
       if (mergedTree.count == 0) return nil;
  }

  return mergedTree;
}

+ (nullable NSDictionary *)treeForApplication:(XCUIApplication *)application
{
    // This is the original entry point, call the new one with empty parameters for now
    // In a real scenario, parameters would come from the route request.
    return [self treeForApplication:application withParameters:@{}];
}

@end


// In FBRouteRequest.m or a new file for command handling:
// Modify handleGetSourceCommand
/*
+ (id<FBResponsePayload>)handleGetSourceCommand:(FBRouteRequest *)request
{
  XCUIApplication *application = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
  NSString *sourceType = request.parameters[@"format"] ?: SOURCE_FORMAT_XML;
  NSString *sourceScope = request.parameters[@"scope"]; // Potentially use for scoping the grid sampling or depth

  [FBLogger logFmt:@"Attempting to generate React Native page source using Grid Sampling."];

  // Pass parameters from the request to the treeForApplication method
  NSDictionary *rnTree = [RNUiInspector treeForApplication:application withParameters:request.parameters];

  if (!rnTree) {
    return FBResponseWithUnknownErrorFormat(@"Cannot get React Native source of the current application. RN Tree was nil after grid sampling.");
  }

  NSArray<NSString *> *excludedAttributes = nil == request.parameters[@"excluded_attributes"]
    ? nil
    : [request.parameters[@"excluded_attributes"] componentsSeparatedByString:@","];
  FBXMLGenerationOptions *xmlOptions = [[[FBXMLGenerationOptions new]
                                         withExcludedAttributes:excludedAttributes]
                                        withScope:sourceScope];

  NSString *rnXmlSource = [FBRNViewXMLConverter xmlStringFromRNTree:rnTree options:xmlOptions];
  return FBResponseWithObject(rnXmlSource);
}
*/
