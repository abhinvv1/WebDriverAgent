
#import "XCUIApplication+FBGridSampling.h"
#import "FBLogger.h"
#import "FBErrorBuilder.h"
#import "XCUIElement+FBUtilities.h"
#import "FBElementTypeTransformer.h"
#import <WebDriverAgentLib/FBXCTestDaemonsProxy.h>
#import <WebDriverAgentLib/XCTestManager_ManagerInterface-Protocol.h>
#import <WebDriverAgentLib/XCUIElement+FBWebDriverAttributes.h>
#import "FBElementUtils.h"
#import <objc/runtime.h>

static void *SamplingStartTimeKey = &SamplingStartTimeKey;
static void *SamplingIterationCountKey = &SamplingIterationCountKey;
static void *ProcessedElementIDsKey = &ProcessedElementIDsKey;


static const NSTimeInterval kFBGridSamplingTimeout = 0.1;
static const NSInteger kFBInitialSamplesX = 100;
static const NSInteger kFBInitialSamplesY = 200;
static const NSInteger kFBMaxRecursionDepth = 50;
static const NSInteger kFBMaxElementsLimit = 5000;
static const NSInteger kFBAdaptiveSubsamples = 20;
static const CGFloat kFBMinElementSize = 1.0;

static const NSTimeInterval kFBMaxTotalExecutionTime = 30.0; // Max 30 seconds total
static const NSInteger kFBMaxAccessibilityTraversalDepth = 50; // Limit accessibility depth
static const NSInteger kFBMaxChildrenPerElement = 100; // Limit children per element
static const NSInteger kFBMaxSamplingIterations = 1500; // Max sampling iterations

// Forward declarations for XCTest private APIs
@interface NSObject (XCTestPrivateAPI)
- (void)_XCT_requestElementAtPoint:(CGPoint)point reply:(void (^)(id axElement, NSError *error))reply;
- (void)_XCT_requestSnapshotForElement:(id)element
                           attributes:(NSArray<NSString *> *)attributes
                           parameters:(NSDictionary *)parameters
                                reply:(void (^)(id snapshot, NSError *error))reply;
- (void)_XCT_requestElementAtPoint:(CGPoint)point
                          withReply:(void (^)(id axElement, NSError *error))reply;
@end

// Forward declaration for accessibility element
@interface NSObject (AccessibilityPrivateAPI)
- (NSArray *)accessibilityElements;
- (id)accessibilityContainer;
- (NSInteger)accessibilityElementCount;
- (id)accessibilityElementAtIndex:(NSInteger)index;
@end

@implementation XCUIApplication (FBGridSampling)
#pragma mark - Associated Object Properties

- (void)setSamplingStartTime:(NSDate *)samplingStartTime {
    objc_setAssociatedObject(self, SamplingStartTimeKey, samplingStartTime, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSDate *)samplingStartTime {
    return objc_getAssociatedObject(self, SamplingStartTimeKey);
}

- (void)setSamplingIterationCount:(NSInteger)samplingIterationCount {
    objc_setAssociatedObject(self, SamplingIterationCountKey, @(samplingIterationCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSInteger)samplingIterationCount {
    NSNumber *count = objc_getAssociatedObject(self, SamplingIterationCountKey);
    return [count integerValue];
}

- (void)setProcessedElementIDs:(NSMutableSet<NSString *> *)processedElementIDs {
    objc_setAssociatedObject(self, ProcessedElementIDsKey, processedElementIDs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSMutableSet<NSString *> *)processedElementIDs {
    NSMutableSet<NSString *> *set = objc_getAssociatedObject(self, ProcessedElementIDsKey);
    if (!set) {
        set = [NSMutableSet set];
        [self setProcessedElementIDs:set]; // Associate it so it persists
    }
    return set;
}

#pragma mark - Public Methods

- (nullable NSDictionary *)fb_gridSampledTreeWithParameters:(NSDictionary *)parameters {
  
    self.samplingStartTime = [NSDate date];
    self.samplingIterationCount = 0;
    self.processedElementIDs = [NSMutableSet set];
  
    NSInteger samplesX = [parameters[@"samplesX"] integerValue] ?: kFBInitialSamplesX;
    NSInteger samplesY = [parameters[@"samplesY"] integerValue] ?: kFBInitialSamplesY;
    NSInteger maxRecursionDepth = [parameters[@"maxRecursionDepth"] integerValue] ?: kFBMaxRecursionDepth;
    
//    maxRecursionDepth = MIN(maxRecursionDepth, kFBMaxRecursionDepth);

    [FBLogger logFmt:@"Starting optimized grid sampling with samplesX:%ld, samplesY:%ld, maxRecursion:%ld",
     (long)samplesX, (long)samplesY, (long)maxRecursionDepth];
    
    CGRect appFrame = self.frame;
    if (CGRectIsEmpty(appFrame)) {
        [FBLogger logFmt:@"Application frame is empty, using screen bounds"];
        appFrame = [[UIScreen mainScreen] bounds];
    }
    
    NSMutableDictionary *elementRegistry = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *processedPoints = [NSMutableSet set];
    NSMutableArray<NSDictionary *> *discoveredElements = [NSMutableArray array];
    
    if ([self fb_shouldContinueExecution]) {
      [self fb_performCoarseGridSampling:appFrame
                                samplesX:samplesX
                                samplesY:samplesY
                      discoveredElements:discoveredElements
                         elementRegistry:elementRegistry
                         processedPoints:processedPoints];
      }
      
      if ([self fb_shouldContinueExecution] && discoveredElements.count < kFBMaxElementsLimit) {
          [self fb_performAdaptiveDenseSampling:discoveredElements
                                  elementRegistry:elementRegistry
                                  processedPoints:processedPoints
                                         maxDepth:MIN(maxRecursionDepth, 10)];
      }
      
      if ([self fb_shouldContinueExecution] && discoveredElements.count < kFBMaxElementsLimit) {
          [self fb_performAccessibilityTraversal:discoveredElements
                                 elementRegistry:elementRegistry
                                        maxDepth:kFBMaxAccessibilityTraversalDepth];
      }
    
    NSArray<NSDictionary *> *hierarchicalTree = [self fb_buildOptimizedHierarchy:[elementRegistry allValues]];
    
    NSMutableDictionary *rootElement = [self fb_createMinimalRootElement];
    if (hierarchicalTree.count > 0) {
        rootElement[@"children"] = hierarchicalTree;
    }
    
    NSUInteger totalElements = [self fb_countTotalElements:hierarchicalTree];
    [FBLogger logFmt:@"Optimized grid sampling completed. Found %lu unique elements total", (unsigned long)totalElements];
    
    return rootElement;
}

#pragma mark - Phase 1: Coarse Grid Sampling

- (void)fb_performCoarseGridSampling:(CGRect)frame
                            samplesX:(NSInteger)samplesX
                            samplesY:(NSInteger)samplesY
                   discoveredElements:(NSMutableArray<NSDictionary *> *)discoveredElements
                     elementRegistry:(NSMutableDictionary *)elementRegistry
                     processedPoints:(NSMutableSet<NSString *> *)processedPoints {
    
    [FBLogger logFmt:@"Phase 1: Grid sampling"];
    
    NSArray<NSValue *> *gridPoints = [self fb_generateStratifiedGridPoints:frame
                                                                  samplesX:samplesX
                                                                  samplesY:samplesY];
    
    [self fb_samplePointsInBatches:gridPoints
                 discoveredElements:discoveredElements
                   elementRegistry:elementRegistry
                   processedPoints:processedPoints
                             depth:0];
}

#pragma mark - Phase 2: Adaptive Dense Sampling

- (void)fb_performAdaptiveDenseSampling:(NSMutableArray<NSDictionary *> *)discoveredElements
                        elementRegistry:(NSMutableDictionary *)elementRegistry
                        processedPoints:(NSMutableSet<NSString *> *)processedPoints
                               maxDepth:(NSInteger)maxDepth {
    
    [FBLogger logFmt:@"Phase 2: Adaptive dense sampling"];
    
    // Group elements by area to identify element-dense regions
    NSArray<NSDictionary *> *largeElements = [self fb_filterElementsByMinimumSize:discoveredElements
                                                                       minWidth:50
                                                                      minHeight:50];
    
    for (NSDictionary *element in largeElements) {
        if ([elementRegistry count] > kFBMaxElementsLimit) {
            [FBLogger logFmt:@"Reached element limit, stopping adaptive sampling"];
            break;
        }
        
        [self fb_performDenseSamplingInElementArea:element
                                 discoveredElements:discoveredElements
                                   elementRegistry:elementRegistry
                                   processedPoints:processedPoints
                                          maxDepth:maxDepth];
    }
}

- (void)fb_performDenseSamplingInElementArea:(NSDictionary *)element
                           discoveredElements:(NSMutableArray<NSDictionary *> *)discoveredElements
                             elementRegistry:(NSMutableDictionary *)elementRegistry
                             processedPoints:(NSMutableSet<NSString *> *)processedPoints
                                    maxDepth:(NSInteger)maxDepth {
    
    NSDictionary *rect = element[@"rect"];
    CGRect elementFrame = CGRectMake(
        [rect[@"x"] floatValue],
        [rect[@"y"] floatValue],
        [rect[@"width"] floatValue],
        [rect[@"height"] floatValue]
    );
    
    if (elementFrame.size.width < 0.01 || elementFrame.size.height < 0.01) {
        return;
    }
    
    NSInteger adaptiveSamplesX = MIN(kFBAdaptiveSubsamples, (NSInteger)(elementFrame.size.width / 20));
    NSInteger adaptiveSamplesY = MIN(kFBAdaptiveSubsamples, (NSInteger)(elementFrame.size.height / 20));
    
    adaptiveSamplesX = MAX(3, adaptiveSamplesX);
    adaptiveSamplesY = MAX(3, adaptiveSamplesY);
    
    NSArray<NSValue *> *denseGridPoints = [self fb_generateStratifiedGridPoints:elementFrame
                                                                       samplesX:adaptiveSamplesX
                                                                       samplesY:adaptiveSamplesY];
    
    [self fb_samplePointsInBatches:denseGridPoints
                 discoveredElements:discoveredElements
                   elementRegistry:elementRegistry
                   processedPoints:processedPoints
                             depth:1];
}

#pragma mark - Phase 3: Accessibility Traversal

- (void)fb_performAccessibilityTraversal:(NSMutableArray<NSDictionary *> *)discoveredElements
                         elementRegistry:(NSMutableDictionary *)elementRegistry
                                maxDepth:(NSInteger)maxDepth {
    
    [FBLogger logFmt:@"Phase 3: Accessibility traversal"];
    
    NSInteger maxElementsToTraverse = discoveredElements.count;
    NSArray<NSDictionary *> *elementsToTraverse = [discoveredElements subarrayWithRange:NSMakeRange(0, maxElementsToTraverse)];

    for (NSDictionary *elementDict in elementsToTraverse) {
        if (![self fb_shouldContinueExecution] || [elementRegistry count] > kFBMaxElementsLimit) {
            [FBLogger logFmt:@"Reached element limit, stopping accessibility traversal"];
            break;
        }
        
        [self fb_traverseAccessibilityChildren:elementDict
                               elementRegistry:elementRegistry
                                      maxDepth:maxDepth
                                  currentDepth:0];
    }
}

- (void)fb_traverseAccessibilityChildren:(NSDictionary *)parentElement
                         elementRegistry:(NSMutableDictionary *)elementRegistry
                                maxDepth:(NSInteger)maxDepth
                            currentDepth:(NSInteger)currentDepth {
    
    if (currentDepth >= maxDepth || [elementRegistry count] > kFBMaxElementsLimit || ![self fb_shouldContinueExecution]) {
        return;
    }
    NSString *parentID = [self fb_createElementIdentifier:parentElement];
    if ([self.processedElementIDs containsObject:parentID]) {
        return;
    }
    [self.processedElementIDs addObject:parentID];
    // Get the center point of the parent element to query its accessibility element
    NSDictionary *rect = parentElement[@"rect"];
    CGPoint centerPoint = CGPointMake(
        [rect[@"x"] floatValue] + [rect[@"width"] floatValue] / 2,
        [rect[@"y"] floatValue] + [rect[@"height"] floatValue] / 2
    );
    
    [self fb_findAccessibilityChildrenAtPoint:centerPoint
                              elementRegistry:elementRegistry
                                 parentElement:parentElement
                                  currentDepth:currentDepth + 1
                                      maxDepth:maxDepth];
}

- (void)fb_findAccessibilityChildrenAtPoint:(CGPoint)point
                            elementRegistry:(NSMutableDictionary *)elementRegistry
                             parentElement:(NSDictionary *)parentElement
                              currentDepth:(NSInteger)currentDepth
                                  maxDepth:(NSInteger)maxDepth {
    
    id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
    if (!proxy) {
        return;
    }
    if (![self fb_shouldContinueExecution]) {
      return;
    }
    
    __block BOOL completed = NO;
    
    [proxy _XCT_requestElementAtPoint:point reply:^(id axElement, NSError *error) {
        if (error || !axElement) {
            completed = YES;
            return;
        }
        
        @try {
            NSInteger childCount = 0;
            if ([axElement respondsToSelector:@selector(accessibilityElementCount)]) {
                childCount = [axElement accessibilityElementCount];
            }
            
            if (childCount > 0
                //&& childCount < 50
                ) {
                for (NSInteger i = 0; i < childCount; i++) {
                    if ([elementRegistry count] > kFBMaxElementsLimit || ![self fb_shouldContinueExecution]) {
                        break;
                    }
                    
                    @try {
                        id childElement = [axElement accessibilityElementAtIndex:i];
                        if (childElement) {
                            [self fb_processAccessibilityChild:childElement
                                               elementRegistry:elementRegistry
                                                  parentElement:parentElement
                                                   currentDepth:currentDepth
                                                       maxDepth:maxDepth];
                        }
                    } @catch (NSException *exception) {
                        // Continue with next child
                        continue;
                    }
                }
            }
        } @catch (NSException *exception) {
            [FBLogger logFmt:@"Exception traversing accessibility children: %@", exception.reason];
        }
        
        completed = YES;
    }];
    
    // Wait for completion with timeout
    NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (!completed && [timeoutDate timeIntervalSinceNow] > 0 && [self fb_shouldContinueExecution]) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

- (void)fb_processAccessibilityChild:(id)childElement
                     elementRegistry:(NSMutableDictionary *)elementRegistry
                        parentElement:(NSDictionary *)parentElement
                         currentDepth:(NSInteger)currentDepth
                             maxDepth:(NSInteger)maxDepth {
    
    id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
    if (!proxy) {
        return;
    }
    if (![self fb_shouldContinueExecution]) {
      return;
    }
    
    NSDictionary *minimalParams = @{
        @"maxDepth": @5,
        @"maxArrayCount": @1,
        @"maxChildren": @5,
        @"includeInvisible": @YES
    };
    
    NSArray<NSString *> *basicAttributes = [self fb_getBasicAttributes];
    
    __block BOOL completed = NO;
    
    [proxy _XCT_requestSnapshotForElement:childElement
                               attributes:basicAttributes
                               parameters:minimalParams
                                    reply:^(id snapshotObject, NSError *snapshotError) {
        if (!snapshotError && snapshotObject) {
            @try {
                CGPoint elementCenter = CGPointMake(0, 0);
                if ([snapshotObject respondsToSelector:@selector(frame)]) {
                    CGRect frame = [snapshotObject frame];
                    elementCenter = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
                }
                
                NSDictionary *childElementDict = [self fb_minimalDictionaryFromSnapshot:snapshotObject point:elementCenter];
                NSString *childElementID = [self fb_createElementIdentifier:childElementDict];
                
              if (![elementRegistry objectForKey:childElementID] && ![self.processedElementIDs containsObject:childElementID]) {
                    NSMutableDictionary *enrichedChild = [childElementDict mutableCopy];
                    enrichedChild[@"depth"] = @(currentDepth);
                    enrichedChild[@"discoveryMethod"] = @"accessibility";
                    enrichedChild[@"parentID"] = [self fb_createElementIdentifier:parentElement];
                    
                    elementRegistry[childElementID] = enrichedChild;
                    [self.processedElementIDs addObject:childElementID];

                    
                    [FBLogger logFmt:@"Discovered accessibility child: %@ (depth %ld)",
                     childElementDict[@"type"], (long)currentDepth];
                    
                  if (currentDepth < maxDepth && [self fb_shouldContinueExecution]) {
                        [self fb_traverseAccessibilityChildren:enrichedChild
                                               elementRegistry:elementRegistry
                                                      maxDepth:maxDepth
                                                  currentDepth:currentDepth];
                    }
                }
            } @catch (NSException *exception) {
                // Continue processing
            }
        }
        completed = YES;
    }];
    
    NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:0.5];
    while (!completed && [timeoutDate timeIntervalSinceNow] > 0 && [self fb_shouldContinueExecution]) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

#pragma mark - Phase 4: Optimized Hierarchy Building

- (NSArray<NSDictionary *> *)fb_buildOptimizedHierarchy:(NSArray<NSDictionary *> *)elements {
    [FBLogger logFmt:@"Phase 4: Building optimized hierarchy"];
    
    NSMutableArray<NSMutableDictionary *> *mutableElements = [NSMutableArray array];
    for (NSDictionary *element in elements) {
        [mutableElements addObject:[element mutableCopy]];
    }
    
    [mutableElements sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
        CGFloat area1 = [obj1[@"rect"][@"width"] floatValue] * [obj1[@"rect"][@"height"] floatValue];
        CGFloat area2 = [obj2[@"rect"][@"width"] floatValue] * [obj2[@"rect"][@"height"] floatValue];
        
        if (area1 > area2) return NSOrderedAscending;
        if (area1 < area2) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    
    NSMutableDictionary<NSString *, NSMutableArray *> *parentChildMap = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *elementsWithParents = [NSMutableSet set];
    
    for (NSInteger i = 0; i < mutableElements.count; i++) {
        NSMutableDictionary *currentElement = mutableElements[i];
        NSString *currentID = [self fb_createElementIdentifier:currentElement];
        
        // Check for explicit parent relationship (from accessibility traversal)
        NSString *explicitParentID = currentElement[@"parentID"];
        if (explicitParentID) {
            if (!parentChildMap[explicitParentID]) {
                parentChildMap[explicitParentID] = [NSMutableArray array];
            }
            [parentChildMap[explicitParentID] addObject:currentElement];
            [elementsWithParents addObject:currentID];
            continue;
        }
        
        // Find geometric parent (largest element that contains this one)
        BOOL foundParent = NO;
        for (NSInteger j = 0; j < i && !foundParent; j++) {
            NSMutableDictionary *potentialParent = mutableElements[j];
            NSString *parentID = [self fb_createElementIdentifier:potentialParent];
            
            if ([self fb_doesElement:potentialParent containElement:currentElement strictContainment:YES]) {
                if (!parentChildMap[parentID]) {
                    parentChildMap[parentID] = [NSMutableArray array];
                }
                [parentChildMap[parentID] addObject:currentElement];
                [elementsWithParents addObject:currentID];
                foundParent = YES;
            }
        }
    }
    
    // Assign parent IDs and children arrays
    for (NSString *parentID in parentChildMap) {
        // Find the parent element
        NSMutableDictionary *parentElement = nil;
        for (NSMutableDictionary *element in mutableElements) {
            if ([[self fb_createElementIdentifier:element] isEqualToString:parentID]) {
                parentElement = element;
                break;
            }
        }
        
        if (parentElement) {
            // Sort children by position (top-to-bottom, left-to-right)
            NSArray *sortedChildren = [parentChildMap[parentID] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
                CGFloat y1 = [obj1[@"rect"][@"y"] floatValue];
                CGFloat y2 = [obj2[@"rect"][@"y"] floatValue];
                CGFloat x1 = [obj1[@"rect"][@"x"] floatValue];
                CGFloat x2 = [obj2[@"rect"][@"x"] floatValue];
                
                if (ABS(y1 - y2) > 10) { // Different rows
                    return y1 < y2 ? NSOrderedAscending : NSOrderedDescending;
                } else { // Same row, compare x
                    return x1 < x2 ? NSOrderedAscending : NSOrderedDescending;
                }
            }];
            
            parentElement[@"children"] = sortedChildren;
        }
    }
    
    // Return top-level elements (those without parents)
    NSMutableArray<NSDictionary *> *topLevelElements = [NSMutableArray array];
    for (NSMutableDictionary *element in mutableElements) {
        NSString *elementID = [self fb_createElementIdentifier:element];
        if (![elementsWithParents containsObject:elementID]) {
            [topLevelElements addObject:element];
        }
    }
    
    // Sort top-level elements by position
    [topLevelElements sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
        CGFloat y1 = [obj1[@"rect"][@"y"] floatValue];
        CGFloat y2 = [obj2[@"rect"][@"y"] floatValue];
        CGFloat x1 = [obj1[@"rect"][@"x"] floatValue];
        CGFloat x2 = [obj2[@"rect"][@"x"] floatValue];
        
        if (ABS(y1 - y2) > 10) {
            return y1 < y2 ? NSOrderedAscending : NSOrderedDescending;
        } else {
            return x1 < x2 ? NSOrderedAscending : NSOrderedDescending;
        }
    }];
    
    return topLevelElements;
}

#pragma mark - Helper Methods

- (NSDictionary *)fb_minimalDictionaryFromSnapshot:(id<FBXCElementSnapshot>)snapshot point:(CGPoint)point {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    
    @try {
        // Basic properties
        dict[@"type"] = [FBElementTypeTransformer stringWithElementType:snapshot.elementType] ?: @"Unknown";
        dict[@"label"] = [self fb_cleanString:snapshot.label];
        dict[@"name"] = [self fb_cleanString:snapshot.title];
        dict[@"value"] = [self fb_cleanString:snapshot.value];
        dict[@"rect"] = [self fb_rectDictionary:snapshot.frame];
        dict[@"isEnabled"] = @(snapshot.enabled);
        dict[@"isVisible"] = @(!CGRectIsEmpty(snapshot.visibleFrame));
        
        // Minimal additional properties
        if (snapshot.identifier && snapshot.identifier.length > 0) {
            dict[@"testID"] = snapshot.identifier;
        }
        
        // Element classification for better hierarchy building
        dict[@"elementClass"] = [self fb_classifyElement:dict];
        
    } @catch (NSException *exception) {
        [FBLogger logFmt:@"Exception processing minimal snapshot at %@: %@", NSStringFromCGPoint(point), exception.reason];
        dict[@"error"] = exception.reason;
        dict[@"type"] = @"Unknown";
    }
    
    return dict;
}

- (NSArray<NSValue *> *)fb_generateStratifiedGridPoints:(CGRect)frame
                                               samplesX:(NSInteger)samplesX
                                               samplesY:(NSInteger)samplesY {
    NSMutableArray<NSValue *> *points = [NSMutableArray array];
    
    // Add minimal padding to avoid edge cases
    CGFloat padding = 2.0;
    CGRect insetFrame = CGRectInset(frame, padding, padding);
    
    if (insetFrame.size.width <= 0 || insetFrame.size.height <= 0) {
        CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        [points addObject:[NSValue valueWithCGPoint:center]];
        return points;
    }
    
    // Use stratified sampling for better coverage
    for (NSInteger i = 0; i < samplesX; i++) {
        for (NSInteger j = 0; j < samplesY; j++) {
            // Add some randomness within each cell for better distribution
            CGFloat cellWidth = insetFrame.size.width / samplesX;
            CGFloat cellHeight = insetFrame.size.height / samplesY;
            
            CGFloat baseX = insetFrame.origin.x + (i * cellWidth);
            CGFloat baseY = insetFrame.origin.y + (j * cellHeight);
            
            // Add some jitter within the cell (25% of cell size)
            CGFloat jitterX = (arc4random_uniform(100) / 100.0 - 0.5) * cellWidth * 0.5;
            CGFloat jitterY = (arc4random_uniform(100) / 100.0 - 0.5) * cellHeight * 0.5;
            
            CGFloat finalX = baseX + cellWidth/2 + jitterX;
            CGFloat finalY = baseY + cellHeight/2 + jitterY;
            
            // Ensure point is within bounds
            finalX = MAX(insetFrame.origin.x, MIN(finalX, CGRectGetMaxX(insetFrame)));
            finalY = MAX(insetFrame.origin.y, MIN(finalY, CGRectGetMaxY(insetFrame)));
            
            CGPoint point = CGPointMake(finalX, finalY);
            [points addObject:[NSValue valueWithCGPoint:point]];
        }
    }
    
    return points;
}

- (void)fb_samplePointsInBatches:(NSArray<NSValue *> *)points
               discoveredElements:(NSMutableArray<NSDictionary *> *)discoveredElements
                 elementRegistry:(NSMutableDictionary *)elementRegistry
                 processedPoints:(NSMutableSet<NSString *> *)processedPoints
                           depth:(NSInteger)depth {
    
    const NSInteger batchSize = 20; // Process points in smaller batches
    
    for (NSInteger i = 0; i < points.count; i += batchSize) {
        if ([elementRegistry count] > kFBMaxElementsLimit) {
            [FBLogger logFmt:@"Reached element limit during batch processing"];
            break;
        }
        
        NSInteger endIndex = MIN(i + batchSize, points.count);
        NSArray<NSValue *> *batch = [points subarrayWithRange:NSMakeRange(i, endIndex - i)];
        
        for (NSValue *pointValue in batch) {
            CGPoint point = [pointValue CGPointValue];
            NSString *pointKey = NSStringFromCGPoint(point);
            
            if ([processedPoints containsObject:pointKey]) {
                continue;
            }
            [processedPoints addObject:pointKey];
            
            [self fb_sampleSinglePoint:point
                     discoveredElements:discoveredElements
                       elementRegistry:elementRegistry
                                 depth:depth];
        }

//        [NSThread sleepForTimeInterval:0.01];
    }
}

- (void)fb_sampleSinglePoint:(CGPoint)point
           discoveredElements:(NSMutableArray<NSDictionary *> *)discoveredElements
             elementRegistry:(NSMutableDictionary *)elementRegistry
                       depth:(NSInteger)depth {
    
    __block NSDictionary *elementInfo = nil;
    __block NSError *fetchError = nil;
    __block BOOL completed = NO;
    
    [self fb_findTopmostElementAtPoint:point completion:^(NSDictionary *info, NSError *error) {
        elementInfo = info;
        fetchError = error;
        completed = YES;
    }];
    
    NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:kFBGridSamplingTimeout];
    while (!completed && [timeoutDate timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    
    if (!completed || fetchError || !elementInfo) {
        return;
    }
    
    // Filter out tiny elements that are likely noise
    NSDictionary *rect = elementInfo[@"rect"];
    CGFloat width = [rect[@"width"] floatValue];
    CGFloat height = [rect[@"height"] floatValue];
    
    if (width < kFBMinElementSize || height < kFBMinElementSize) {
        return;
    }
    
    NSString *elementID = [self fb_createElementIdentifier:elementInfo];
    
    if (![elementRegistry objectForKey:elementID]) {
        NSMutableDictionary *enrichedElement = [elementInfo mutableCopy];
        enrichedElement[@"discoveryPoint"] = NSStringFromCGPoint(point);
        enrichedElement[@"depth"] = @(depth);
        enrichedElement[@"discoveryMethod"] = @"grid";
        
        elementRegistry[elementID] = enrichedElement;
        [discoveredElements addObject:enrichedElement];
    }
}

- (NSArray<NSDictionary *> *)fb_filterElementsByMinimumSize:(NSArray<NSDictionary *> *)elements
                                                    minWidth:(CGFloat)minWidth
                                                   minHeight:(CGFloat)minHeight {
    NSMutableArray<NSDictionary *> *filteredElements = [NSMutableArray array];
    
    for (NSDictionary *element in elements) {
        NSDictionary *rect = element[@"rect"];
        CGFloat width = [rect[@"width"] floatValue];
        CGFloat height = [rect[@"height"] floatValue];
        
        if (width >= minWidth && height >= minHeight) {
            [filteredElements addObject:element];
        }
    }
    
    return filteredElements;
}

- (BOOL)fb_doesElement:(NSDictionary *)parent containElement:(NSDictionary *)child strictContainment:(BOOL)strict {
    NSDictionary *parentRect = parent[@"rect"];
    NSDictionary *childRect = child[@"rect"];
    
    CGRect pFrame = CGRectMake(
        [parentRect[@"x"] floatValue],
        [parentRect[@"y"] floatValue],
        [parentRect[@"width"] floatValue],
        [parentRect[@"height"] floatValue]
    );
    
    CGRect cFrame = CGRectMake(
        [childRect[@"x"] floatValue],
        [childRect[@"y"] floatValue],
        [childRect[@"width"] floatValue],
        [childRect[@"height"] floatValue]
    );
    
    // Avoid self-containment
    if (CGRectEqualToRect(pFrame, cFrame)) {
        return NO;
    }
    
    if (strict) {
        // Strict containment - child must be fully inside parent with some margin
        CGRect strictParentFrame = CGRectInset(pFrame, 1, 1);
        return CGRectContainsRect(strictParentFrame, cFrame);
    } else {
        // Loose containment - allow some overlap
        CGRect looseParentFrame = CGRectInset(pFrame, -5, -5);
        return CGRectContainsRect(looseParentFrame, cFrame);
    }
}

- (void)fb_findTopmostElementAtPoint:(CGPoint)point
                          completion:(void (^)(NSDictionary * _Nullable elementInfo, NSError * _Nullable error))completion {
    
    id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
    if (!proxy) {
        NSError *error = [[[FBErrorBuilder builder]
                          withDescription:@"Failed to get XCTest daemon proxy"] build];
        completion(nil, error);
        return;
    }
    
    [proxy _XCT_requestElementAtPoint:point reply:^(id axElement, NSError *error) {
        if (error) {
            [FBLogger logFmt:@"Error requesting element at %@: %@", NSStringFromCGPoint(point), error.localizedDescription];
            completion(nil, error);
            return;
        }
        
        if (!axElement) {
            completion(nil, nil);
            return;
        }
        
        NSDictionary *optimizedParams = @{
            @"maxDepth": @5,
            @"maxArrayCount": @5,
            @"maxChildren": @5,
            @"includeInvisible": @YES,
            @"snapshotKeyHonorModalViews": @YES
        };
        
        NSArray<NSString *> *enhancedAttributes = [self fb_getEnhancedAttributes];
        
        [proxy _XCT_requestSnapshotForElement:axElement
                                   attributes:enhancedAttributes
                                   parameters:optimizedParams
                                        reply:^(id snapshotObject, NSError *snapshotError) {
            if (snapshotError) {
                [FBLogger logFmt:@"Failed to get snapshot at %@: %@",
                 NSStringFromCGPoint(point), snapshotError.localizedDescription];
                completion(nil, snapshotError);
                return;
            }
            
            if (!snapshotObject) {
                completion(nil, nil);
                return;
            }
            
            NSDictionary *elementInfo = [self fb_enhancedDictionaryFromSnapshot:snapshotObject point:point];
            completion(elementInfo, nil);
        }];
    }];
}

#pragma mark - Enhanced Element Processing

- (NSDictionary *)fb_enhancedDictionaryFromSnapshot:(id<FBXCElementSnapshot>)snapshot point:(CGPoint)point {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    
    @try {
        dict[@"type"] = [FBElementTypeTransformer stringWithElementType:snapshot.elementType] ?: @"Unknown";
        dict[@"label"] = [self fb_cleanString:snapshot.label];
        dict[@"name"] = [self fb_cleanString:snapshot.title];
        dict[@"value"] = [self fb_cleanString:snapshot.value];
        dict[@"rect"] = [self fb_rectDictionary:snapshot.frame];
        dict[@"isEnabled"] = @(snapshot.enabled);
        dict[@"isVisible"] = @(!CGRectIsEmpty(snapshot.visibleFrame));
        
        if (snapshot.identifier && snapshot.identifier.length > 0) {
            dict[@"testID"] = snapshot.identifier;
        }
        
        if ([snapshot respondsToSelector:@selector(placeholderValue)] && snapshot.placeholderValue) {
            dict[@"hint"] = [self fb_cleanString:snapshot.placeholderValue];
        }
        
        if ([snapshot respondsToSelector:@selector(selected)]) {
            dict[@"isSelected"] = @(snapshot.selected);
        }
        
        if ([snapshot respondsToSelector:@selector(hasFocus)]) {
            dict[@"hasFocus"] = @(snapshot.hasFocus);
        }
        
        dict[@"elementClass"] = [self fb_classifyElement:dict];
        
        dict[@"visibilityScore"] = [self fb_calculateVisibilityScore:snapshot];
        
    } @catch (NSException *exception) {
        [FBLogger logFmt:@"Exception processing enhanced snapshot at %@: %@", NSStringFromCGPoint(point), exception.reason];
        dict[@"error"] = exception.reason;
        dict[@"type"] = @"Unknown";
    }
    
    return dict;
}

- (NSString *)fb_cleanString:(NSString *)string {
    if (!string || ![string isKindOfClass:[NSString class]]) {
        return @"";
    }

    NSString *cleaned = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    cleaned = [regex stringByReplacingMatchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length) withTemplate:@" "];
    
    return cleaned;
}

- (NSString *)fb_classifyElement:(NSDictionary *)elementDict {
    NSString *type = elementDict[@"type"];
    NSString *label = elementDict[@"label"];
    NSString *value = elementDict[@"value"];
    NSDictionary *rect = elementDict[@"rect"];
    
    CGFloat width = [rect[@"width"] floatValue];
    CGFloat height = [rect[@"height"] floatValue];
    CGFloat area = width * height;
    
    if ([type isEqualToString:@"Button"] || [type isEqualToString:@"Link"]) {
        return @"interactive";
    } else if ([type isEqualToString:@"TextField"] || [type isEqualToString:@"SecureTextField"]) {
        return @"input";
    } else if ([type isEqualToString:@"StaticText"] || [type isEqualToString:@"Text"]) {
        if (label.length > 50 || value.length > 50) {
            return @"content";
        } else {
            return @"label";
        }
    } else if ([type isEqualToString:@"Image"]) {
        return @"media";
    } else if ([type containsString:@"Cell"] || [type containsString:@"Table"] || [type containsString:@"Collection"]) {
        return @"container";
    } else if (area > 10000) {
        return @"container";
    } else {
        return @"other";
    }
}

- (NSNumber *)fb_calculateVisibilityScore:(id<FBXCElementSnapshot>)snapshot {
    CGRect frame = snapshot.frame;
    CGRect visibleFrame = snapshot.visibleFrame;
    
    if (CGRectIsEmpty(frame)) {
        return @0;
    }
    
    if (CGRectIsEmpty(visibleFrame)) {
        return @0;
    }
    
    CGFloat frameArea = frame.size.width * frame.size.height;
    CGFloat visibleArea = visibleFrame.size.width * visibleFrame.size.height;
    
    CGFloat visibilityRatio = visibleArea / frameArea;
    return @(MIN(1.0, MAX(0.0, visibilityRatio)));
}

#pragma mark - Utility Methods

- (NSMutableDictionary *)fb_createMinimalRootElement {
    NSMutableDictionary *rootDict = [NSMutableDictionary dictionary];
    
    @try {
        rootDict[@"type"] = @"Application";
        rootDict[@"label"] = [self fb_cleanString:self.label];
        rootDict[@"rect"] = [self fb_rectDictionary:self.frame];
        rootDict[@"isEnabled"] = @(self.isEnabled);
        rootDict[@"isVisible"] = @YES;
        rootDict[@"path"] = @"/0";
        rootDict[@"depth"] = @0;
        rootDict[@"elementClass"] = @"container";
        rootDict[@"visibilityScore"] = @1.0;
        
        if (self.identifier && self.identifier.length > 0) {
            rootDict[@"testID"] = self.identifier;
        }
        
    } @catch (NSException *exception) {
        [FBLogger logFmt:@"Exception creating root element: %@", exception.reason];
        rootDict[@"type"] = @"Application";
        rootDict[@"error"] = exception.reason;
    }
    
    return rootDict;
}

- (NSString *)fb_createElementIdentifier:(NSDictionary *)element {
    NSString *type = element[@"type"] ?: @"Unknown";
    NSDictionary *rect = element[@"rect"];
    NSString *label = element[@"label"] ?: @"";
    NSString *testID = element[@"testID"] ?: @"";
    NSString *value = element[@"value"] ?: @"";
    
    NSString *rectString = [NSString stringWithFormat:@"%.0f_%.0f_%.0f_%.0f",
                           [rect[@"x"] floatValue],
                           [rect[@"y"] floatValue],
                           [rect[@"width"] floatValue],
                           [rect[@"height"] floatValue]];
    
    NSString *combinedString = [NSString stringWithFormat:@"%@_%@_%@_%@_%@", type, rectString, label, testID, value];
    NSUInteger hash = [combinedString hash];
    
    return [NSString stringWithFormat:@"%@_%lu", type, (unsigned long)hash];
}

- (NSDictionary *)fb_rectDictionary:(CGRect)rect {
    return @{
        @"x": @(rect.origin.x),
        @"y": @(rect.origin.y),
        @"width": @(rect.size.width),
        @"height": @(rect.size.height)
    };
}

- (NSArray<NSString *> *)fb_getBasicAttributes {
    return @[
        @"XC_kAXXCAttributeElementType",
        @"XC_kAXXCAttributeFrame",
        @"XC_kAXXCAttributeLabel",
        @"XC_kAXXCAttributeTitle",
        @"XC_kAXXCAttributeValue",
        @"XC_kAXXCAttributeIdentifier",
        @"XC_kAXXCAttributeEnabled",
        @"XC_kAXXCAttributeVisibleFrame"
    ];
}

- (NSArray<NSString *> *)fb_getEnhancedAttributes {
    return @[
        @"XC_kAXXCAttributeElementType",
        @"XC_kAXXCAttributeFrame",
        @"XC_kAXXCAttributeVisibleFrame",
        @"XC_kAXXCAttributeLabel",
        @"XC_kAXXCAttributeTitle",
        @"XC_kAXXCAttributeValue",
        @"XC_kAXXCAttributeIdentifier",
        @"XC_kAXXCAttributeEnabled",
        @"XC_kAXXCAttributePlaceholderValue",
        @"XC_kAXXCAttributeSelected",
        @"XC_kAXXCAttributeHasFocus"
    ];
}

- (BOOL)fb_shouldContinueExecution {
  NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:self.samplingStartTime];
  if (elapsed > kFBMaxTotalExecutionTime) {
    [FBLogger logFmt:@"Grid sampling stopped: Maximum execution time exceeded (%.2f seconds)", elapsed];
    return NO;
  }
  
  self.samplingIterationCount++;
  if (self.samplingIterationCount > kFBMaxSamplingIterations) {
    [FBLogger logFmt:@"Grid sampling stopped: Maximum iterations exceeded (%ld)", (long)self.samplingIterationCount];
    return NO;
  }
  
  return YES;
}

- (NSUInteger)fb_countTotalElements:(NSArray<NSDictionary *> *)elements {
    NSUInteger count = elements.count;
    
    for (NSDictionary *element in elements) {
      [FBLogger logFmt:@"Grid sampling stopped: Maximum iterations exceeded %@", element];
      NSArray *children = element[@"children"];
        if (children && [children isKindOfClass:[NSArray class]]) {
            count += [self fb_countTotalElements:children];
        }
    }
    
    return count;
}

@end
