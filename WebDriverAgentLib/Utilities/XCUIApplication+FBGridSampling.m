
#import "XCUIApplication+FBGridSampling.h"
#import "FBLogger.h"
#import "FBErrorBuilder.h"
#import "XCUIElement+FBUtilities.h"
#import "FBElementTypeTransformer.h"
#import <WebDriverAgentLib/FBXCTestDaemonsProxy.h>
#import "FBCompositeSnapshot.h"
#import <WebDriverAgentLib/XCTestManager_ManagerInterface-Protocol.h>
#import <WebDriverAgentLib/XCUIElement+FBWebDriverAttributes.h>
#import "FBElementUtils.h"
#import <objc/runtime.h>
#import "FBApplicationSnapshot.h"

static void *SamplingStartTimeKey = &SamplingStartTimeKey;
static void *SamplingIterationCountKey = &SamplingIterationCountKey;
static void *ProcessedElementIDsKey = &ProcessedElementIDsKey;


static const NSTimeInterval kFBGridSamplingTimeout = 0.05;
static const NSInteger kFBInitialSamplesX = 10;
static const NSInteger kFBInitialSamplesY = 20;
static const NSInteger kFBMaxRecursionDepth = 1;
static const NSInteger kFBMaxElementsLimit = 1000;
static const NSInteger kFBAdaptiveSubsamples = 5;
static const CGFloat kFBMinElementSize = 0.5;

static const NSTimeInterval kFBMaxTotalExecutionTime = 30.0; // Max 30 seconds total
static const NSInteger kFBMaxAccessibilityTraversalDepth = 2; // Limit accessibility depth
static const NSInteger kFBMaxChildrenPerElement = 10; // Limit children per element
static const NSInteger kFBMaxSamplingIterations = 1000; // Max sampling iterations

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

- (nullable id<FBXCElementSnapshot>)fb_gridSampledSnapshotTreeWithParameters:(NSDictionary *)parameters {
    
    self.samplingStartTime = [NSDate date];
    self.samplingIterationCount = 0;
    self.processedElementIDs = [NSMutableSet set];
    
    NSInteger samplesX = [parameters[@"samplesX"] integerValue] ?: kFBInitialSamplesX;
    NSInteger samplesY = [parameters[@"samplesY"] integerValue] ?: kFBInitialSamplesY;
    
    [FBLogger logFmt:@"Starting React Native optimized sampling with samplesX:%ld, samplesY:%ld",
     (long)samplesX, (long)samplesY];
    
    CGRect appFrame = self.frame;
    if (CGRectIsEmpty(appFrame)) {
        appFrame = [[UIScreen mainScreen] bounds];
    }
    
    NSMutableDictionary *snapshotRegistry = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *processedPoints = [NSMutableSet set];
    NSMutableArray<id<FBXCElementSnapshot>> *discoveredSnapshots = [NSMutableArray array];
    
    // Phase 1: Fast grid sampling with children extraction
    [self fb_performFastGridSamplingWithChildrenExtraction:appFrame
                                                  samplesX:samplesX
                                                  samplesY:samplesY
                                         discoveredSnapshots:discoveredSnapshots
                                           snapshotRegistry:snapshotRegistry
                                           processedPoints:processedPoints];
    
    // Phase 2: Process existing children from discovered snapshots
    [self fb_processExistingChildrenFromSnapshots:discoveredSnapshots
                                  snapshotRegistry:snapshotRegistry];
    
    // Build final tree
    id<FBXCElementSnapshot> rootSnapshot = [self fb_buildOptimizedSnapshotTree:[snapshotRegistry allValues]];
    
    NSUInteger totalElements = [self fb_countTotalSnapshotsInTree:rootSnapshot];
    [FBLogger logFmt:@"React Native sampling completed. Found %lu unique elements total", (unsigned long)totalElements];
    
    return rootSnapshot;
}

- (id<FBXCElementSnapshot>)fb_buildOptimizedSnapshotTree:(NSArray<NSDictionary *> *)snapshotMetadataArray {
    [FBLogger logFmt:@"Building optimized snapshot tree for React Native with %lu snapshots", (unsigned long)snapshotMetadataArray.count];
    
    if (snapshotMetadataArray.count == 0) {
        return [self fb_createRootSnapshot];
    }
    
    // Create root snapshot
    FBApplicationSnapshot *rootSnapshot = (FBApplicationSnapshot *)[self fb_createRootSnapshot];
    
    // Create a map of all snapshots by ID
    NSMutableDictionary<NSString *, id<FBXCElementSnapshot>> *snapshotMap = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<id<FBXCElementSnapshot>> *> *parentChildMap = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *childrenSet = [NSMutableSet set];
    
    // First pass: populate snapshot map and identify explicit parent-child relationships
    for (NSDictionary *metadata in snapshotMetadataArray) {
        id<FBXCElementSnapshot> snapshot = metadata[@"snapshot"];
        NSString *snapshotID = [self fb_createSnapshotIdentifier:snapshot];
        snapshotMap[snapshotID] = snapshot;
        
        NSString *parentID = metadata[@"parentID"];
        if (parentID) {
            if (!parentChildMap[parentID]) {
                parentChildMap[parentID] = [NSMutableArray array];
            }
            [parentChildMap[parentID] addObject:snapshot];
            [childrenSet addObject:snapshotID];
        }
    }
    
    // Second pass: use existing children from snapshots to build relationships
    for (NSDictionary *metadata in snapshotMetadataArray) {
        id<FBXCElementSnapshot> snapshot = metadata[@"snapshot"];
        NSString *parentID = [self fb_createSnapshotIdentifier:snapshot];
        
        NSArray *existingChildren = snapshot.children;
        if (existingChildren && [existingChildren isKindOfClass:[NSArray class]] && existingChildren.count > 0) {
            NSMutableArray<id<FBXCElementSnapshot>> *validChildren = [NSMutableArray array];
            
            for (id<FBXCElementSnapshot> childSnapshot in existingChildren) {
                if ([childSnapshot conformsToProtocol:@protocol(FBXCElementSnapshot)]) {
                    NSString *childID = [self fb_createSnapshotIdentifier:childSnapshot];
                    if (snapshotMap[childID]) { // Only include children that were discovered
                        [validChildren addObject:childSnapshot];
                        [childrenSet addObject:childID];
                    }
                }
            }
            
            if (validChildren.count > 0) {
                if (!parentChildMap[parentID]) {
                    parentChildMap[parentID] = [NSMutableArray array];
                }
                [parentChildMap[parentID] addObjectsFromArray:validChildren];
            }
        }
    }
    
    // Third pass: create composite snapshots with children
    NSMutableDictionary<NSString *, id<FBXCElementSnapshot>> *finalSnapshots = [NSMutableDictionary dictionary];
    
    for (NSDictionary *metadata in snapshotMetadataArray) {
        id<FBXCElementSnapshot> snapshot = metadata[@"snapshot"];
        NSString *snapshotID = [self fb_createSnapshotIdentifier:snapshot];
        
        NSArray<id<FBXCElementSnapshot>> *children = parentChildMap[snapshotID];
        if (children && children.count > 0) {
            // Sort children by position for proper order
            NSArray *sortedChildren = [children sortedArrayUsingComparator:^NSComparisonResult(id<FBXCElementSnapshot> obj1, id<FBXCElementSnapshot> obj2) {
                CGFloat y1 = obj1.frame.origin.y;
                CGFloat y2 = obj2.frame.origin.y;
                
                if (ABS(y1 - y2) > 5) { // Same row threshold
                    return y1 < y2 ? NSOrderedAscending : NSOrderedDescending;
                } else {
                    CGFloat x1 = obj1.frame.origin.x;
                    CGFloat x2 = obj2.frame.origin.x;
                    return x1 < x2 ? NSOrderedAscending : NSOrderedDescending;
                }
            }];
            
            finalSnapshots[snapshotID] = [self fb_createCompositeSnapshot:snapshot withChildren:sortedChildren];
        } else {
            finalSnapshots[snapshotID] = snapshot;
        }
    }
    
    // Find top-level elements (those not in childrenSet)
    NSMutableArray<id<FBXCElementSnapshot>> *topLevelSnapshots = [NSMutableArray array];
    for (NSDictionary *metadata in snapshotMetadataArray) {
        id<FBXCElementSnapshot> snapshot = metadata[@"snapshot"];
        NSString *snapshotID = [self fb_createSnapshotIdentifier:snapshot];
        
        if (![childrenSet containsObject:snapshotID]) {
            id<FBXCElementSnapshot> finalSnapshot = finalSnapshots[snapshotID];
            [topLevelSnapshots addObject:finalSnapshot];
        }
    }
    
    // Sort top-level elements
    [topLevelSnapshots sortUsingComparator:^NSComparisonResult(id<FBXCElementSnapshot> obj1, id<FBXCElementSnapshot> obj2) {
        CGFloat y1 = obj1.frame.origin.y;
        CGFloat y2 = obj2.frame.origin.y;
        
        if (ABS(y1 - y2) > 5) {
            return y1 < y2 ? NSOrderedAscending : NSOrderedDescending;
        } else {
            CGFloat x1 = obj1.frame.origin.x;
            CGFloat x2 = obj2.frame.origin.x;
            return x1 < x2 ? NSOrderedAscending : NSOrderedDescending;
        }
    }];
    
    rootSnapshot.children = topLevelSnapshots;
    
    [FBLogger logFmt:@"Built tree with %lu top-level elements", (unsigned long)topLevelSnapshots.count];
    
    return rootSnapshot;
}

// Process existing children from all discovered snapshots
- (void)fb_processExistingChildrenFromSnapshots:(NSMutableArray<id<FBXCElementSnapshot>> *)discoveredSnapshots
                                snapshotRegistry:(NSMutableDictionary *)snapshotRegistry {
    
    [FBLogger logFmt:@"Processing existing children from %lu discovered snapshots", (unsigned long)discoveredSnapshots.count];
    
    NSMutableArray<id<FBXCElementSnapshot>> *snapshotsToProcess = [discoveredSnapshots mutableCopy];
    
    while (snapshotsToProcess.count > 0 && [self fb_shouldContinueExecution]) {
        id<FBXCElementSnapshot> snapshot = [snapshotsToProcess firstObject];
        [snapshotsToProcess removeObjectAtIndex:0];
        
        NSArray *children = snapshot.children;
        if (children && [children isKindOfClass:[NSArray class]]) {
            for (id<FBXCElementSnapshot> childSnapshot in children) {
                if ([childSnapshot conformsToProtocol:@protocol(FBXCElementSnapshot)]) {
                    NSString *childID = [self fb_createSnapshotIdentifier:childSnapshot];
                    
                    if (![snapshotRegistry objectForKey:childID]) {
                        NSMutableDictionary *childMetadata = [NSMutableDictionary dictionary];
                        childMetadata[@"snapshot"] = childSnapshot;
                        childMetadata[@"parentID"] = [self fb_createSnapshotIdentifier:snapshot];
                        childMetadata[@"discoveryMethod"] = @"children";
                        childMetadata[@"depth"] = @1;
                        
                        snapshotRegistry[childID] = childMetadata;
                        [snapshotsToProcess addObject:childSnapshot]; // Process children of children
                    }
                }
            }
        }
    }
}

#pragma mark - Updated Phase 1: Grid Sampling for Snapshots
- (void)fb_performFastGridSamplingWithChildrenExtraction:(CGRect)frame
                                                samplesX:(NSInteger)samplesX
                                                samplesY:(NSInteger)samplesY
                                       discoveredSnapshots:(NSMutableArray<id<FBXCElementSnapshot>> *)discoveredSnapshots
                                         snapshotRegistry:(NSMutableDictionary *)snapshotRegistry
                                         processedPoints:(NSMutableSet<NSString *> *)processedPoints {
    
    [FBLogger logFmt:@"Grid sampling with immediate children extraction"];
    
    NSArray<NSValue *> *gridPoints = [self fb_generateStratifiedGridPoints:frame
                                                                  samplesX:samplesX
                                                                  samplesY:samplesY];
    
    for (NSValue *pointValue in gridPoints) {
        if (![self fb_shouldContinueExecution] || [snapshotRegistry count] > kFBMaxElementsLimit) {
            break;
        }
        
        CGPoint point = [pointValue CGPointValue];
        NSString *pointKey = NSStringFromCGPoint(point);
        
        if ([processedPoints containsObject:pointKey]) {
            continue;
        }
        [processedPoints addObject:pointKey];
        
        [self fb_samplePointAndExtractChildren:point
                             discoveredSnapshots:discoveredSnapshots
                               snapshotRegistry:snapshotRegistry];
    }
}

- (void)fb_samplePointAndExtractChildren:(CGPoint)point
                       discoveredSnapshots:(NSMutableArray<id<FBXCElementSnapshot>> *)discoveredSnapshots
                         snapshotRegistry:(NSMutableDictionary *)snapshotRegistry {
    
    __block id<FBXCElementSnapshot> elementSnapshot = nil;
    __block BOOL completed = NO;
    
    id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
    if (!proxy) return;
    
    [proxy _XCT_requestElementAtPoint:point reply:^(id axElement, NSError *error) {
        if (error || !axElement) {
            completed = YES;
            return;
        }
        
        // Get snapshot with maximum children depth for React Native
        NSDictionary *reactNativeParams = @{
            @"maxDepth": @10, // Increased for React Native
            @"maxArrayCount": @50, // Increased for React Native
            @"maxChildren": @50, // Increased for React Native
            @"includeInvisible": @NO, // Only visible elements
            @"snapshotKeyHonorModalViews": @YES
        };
        
        NSArray<NSString *> *basicAttributes = [self fb_getBasicAttributes];
        
        [proxy _XCT_requestSnapshotForElement:axElement
                                   attributes:basicAttributes
                                   parameters:reactNativeParams
                                        reply:^(id snapshotObject, NSError *snapshotError) {
            if (!snapshotError && snapshotObject) {
                elementSnapshot = snapshotObject;
            }
            completed = YES;
        }];
    }];
    
    // Wait for completion with shorter timeout
    NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:kFBGridSamplingTimeout];
    while (!completed && [timeoutDate timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    
    if (elementSnapshot) {
        [self fb_processSnapshotAndAllChildren:elementSnapshot
                             discoveredSnapshots:discoveredSnapshots
                               snapshotRegistry:snapshotRegistry
                                  discoveryPoint:point];
    }
}

- (void)fb_processSnapshotAndAllChildren:(id<FBXCElementSnapshot>)snapshot
                       discoveredSnapshots:(NSMutableArray<id<FBXCElementSnapshot>> *)discoveredSnapshots
                         snapshotRegistry:(NSMutableDictionary *)snapshotRegistry
                            discoveryPoint:(CGPoint)point {
    
    if (!snapshot) return;
    
    NSString *snapshotID = [self fb_createSnapshotIdentifier:snapshot];
    
    // Add current snapshot if not already processed
    if (![snapshotRegistry objectForKey:snapshotID]) {
        NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
        metadata[@"snapshot"] = snapshot;
        metadata[@"discoveryPoint"] = NSStringFromCGPoint(point);
        metadata[@"discoveryMethod"] = @"grid";
        metadata[@"depth"] = @0;
        
        snapshotRegistry[snapshotID] = metadata;
        [discoveredSnapshots addObject:snapshot];
    }
    
    // Process all children recursively
    NSArray *children = snapshot.children;
    if (children && [children isKindOfClass:[NSArray class]]) {
        for (id<FBXCElementSnapshot> childSnapshot in children) {
            if ([childSnapshot conformsToProtocol:@protocol(FBXCElementSnapshot)]) {
                [self fb_processSnapshotAndAllChildren:childSnapshot
                                     discoveredSnapshots:discoveredSnapshots
                                       snapshotRegistry:snapshotRegistry
                                          discoveryPoint:point];
            }
        }
    }
}

#pragma mark - Updated Phase 2: Adaptive Dense Sampling for Snapshots

- (void)fb_performAdaptiveDenseSamplingForSnapshots:(NSMutableArray<id<FBXCElementSnapshot>> *)discoveredSnapshots
                                    snapshotRegistry:(NSMutableDictionary *)snapshotRegistry
                                    processedPoints:(NSMutableSet<NSString *> *)processedPoints
                                           maxDepth:(NSInteger)maxDepth {
    
    [FBLogger logFmt:@"Phase 2: Starting Adaptive dense sampling for snapshots"];
    
    // Filter large snapshots for dense sampling
    NSArray<id<FBXCElementSnapshot>> *largeSnapshots = [self fb_filterSnapshotsByMinimumSize:discoveredSnapshots
                                                                                    minWidth:10
                                                                                   minHeight:10];
    
    for (id<FBXCElementSnapshot> snapshot in largeSnapshots) {
        if ([snapshotRegistry count] > kFBMaxElementsLimit) {
            [FBLogger logFmt:@"Reached element limit, stopping adaptive sampling"];
            break;
        }
        
        [self fb_performDenseSamplingInSnapshotArea:snapshot
                                  discoveredSnapshots:discoveredSnapshots
                                    snapshotRegistry:snapshotRegistry
                                    processedPoints:processedPoints
                                           maxDepth:maxDepth];
    }
}

- (void)fb_performDenseSamplingInSnapshotArea:(id<FBXCElementSnapshot>)snapshot
                            discoveredSnapshots:(NSMutableArray<id<FBXCElementSnapshot>> *)discoveredSnapshots
                              snapshotRegistry:(NSMutableDictionary *)snapshotRegistry
                              processedPoints:(NSMutableSet<NSString *> *)processedPoints
                                     maxDepth:(NSInteger)maxDepth {
    
    CGRect elementFrame = snapshot.frame;
    
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
    
    [self fb_samplePointsInBatchesForSnapshots:denseGridPoints
                             discoveredSnapshots:discoveredSnapshots
                               snapshotRegistry:snapshotRegistry
                               processedPoints:processedPoints
                                         depth:5];
}

#pragma mark - Phase 3: Accessibility Traversal

- (void)fb_performAccessibilityTraversalForSnapshots:(NSMutableArray<id<FBXCElementSnapshot>> *)initialSnapshots
                                     snapshotRegistry:(NSMutableDictionary *)snapshotRegistry
                                             maxDepth:(NSInteger)maxAccessibilityRelativeDepth {
    
    [FBLogger logFmt:@"Phase 3: Accessibility Traversal for snapshots starting with %lu initial elements",
     (unsigned long)initialSnapshots.count];

    NSMutableArray<NSDictionary *> *processingQueue = [NSMutableArray array];
    
    for (id<FBXCElementSnapshot> snapshot in initialSnapshots) {
        NSString *snapshotID = [self fb_createSnapshotIdentifier:snapshot];
        if (![self.processedElementIDs containsObject:snapshotID]) {
            [processingQueue addObject:@{
                @"snapshot": snapshot,
                @"accessibilityDepth": @0
            }];
        }
    }

    NSUInteger processedParentsInThisPhase = 0;
    NSInteger iterationSafetyNet = kFBMaxElementsLimit * 2;

    while (processingQueue.count > 0 &&
           [self fb_shouldContinueExecution] &&
           [snapshotRegistry count] < kFBMaxElementsLimit &&
           processedParentsInThisPhase < (NSUInteger) iterationSafetyNet) {

        NSDictionary *currentItem = [processingQueue firstObject];
        [processingQueue removeObjectAtIndex:0];

        id<FBXCElementSnapshot> parentSnapshot = currentItem[@"snapshot"];
        NSInteger parentAccessibilityRelativeDepth = [currentItem[@"accessibilityDepth"] integerValue];

        NSString *parentID = [self fb_createSnapshotIdentifier:parentSnapshot];

        if ([self.processedElementIDs containsObject:parentID]) {
            continue;
        }
        [self.processedElementIDs addObject:parentID];
        processedParentsInThisPhase++;

        if (parentAccessibilityRelativeDepth >= maxAccessibilityRelativeDepth) {
            continue;
        }

        // Process existing children from snapshot.children
        NSArray *existingChildren = parentSnapshot.children;
        if (existingChildren && [existingChildren isKindOfClass:[NSArray class]]) {
            for (id childSnapshot in existingChildren) {
                if ([childSnapshot conformsToProtocol:@protocol(FBXCElementSnapshot)]) {
                    NSString *childID = [self fb_createSnapshotIdentifier:childSnapshot];
                    
                    if (![snapshotRegistry objectForKey:childID]) {
                        // Store the snapshot directly with metadata
                        NSMutableDictionary *snapshotMetadata = [NSMutableDictionary dictionary];
                        snapshotMetadata[@"snapshot"] = childSnapshot;
                        snapshotMetadata[@"parentID"] = parentID;
                        snapshotMetadata[@"discoveryMethod"] = @"accessibility";
                        snapshotMetadata[@"depth"] = @(parentAccessibilityRelativeDepth + 1);
                        
                        snapshotRegistry[childID] = snapshotMetadata;
                        
                        if (parentAccessibilityRelativeDepth + 1 < maxAccessibilityRelativeDepth) {
                            [processingQueue addObject:@{
                                @"snapshot": childSnapshot,
                                @"accessibilityDepth": @(parentAccessibilityRelativeDepth + 1)
                            }];
                        }
                    }
                }
            }
        }
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
    
    for (NSInteger i = 0; i < (long) mutableElements.count; i++) {
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

- (NSArray<NSValue *> *)fb_generateStratifiedGridPoints:(CGRect)frame
                                               samplesX:(NSInteger)samplesX
                                               samplesY:(NSInteger)samplesY {
  [FBLogger logFmt:@"Obtaining grid points."];
  NSMutableArray<NSValue *> *points = [NSMutableArray array];

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

#pragma mark - Enhanced Element Processing

- (NSString *)fb_cleanString:(NSString *)string {
    if (!string || ![string isKindOfClass:[NSString class]]) {
        return @"";
    }

    NSString *cleaned = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    cleaned = [regex stringByReplacingMatchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length) withTemplate:@" "];
    
    return cleaned;
}

#pragma mark - Utility Methods

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

- (void)fb_samplePointsInBatchesForSnapshots:(NSArray<NSValue *> *)points
                           discoveredSnapshots:(NSMutableArray<id<FBXCElementSnapshot>> *)discoveredSnapshots
                             snapshotRegistry:(NSMutableDictionary *)snapshotRegistry
                             processedPoints:(NSMutableSet<NSString *> *)processedPoints
                                       depth:(NSInteger)depth {

    const NSInteger batchSize = 20;
    [FBLogger logFmt:@"Processing sample points for snapshots in batch size of: %ld", (long)batchSize];
    
    for (NSInteger i = 0; i < (long) points.count; i += batchSize) {
        if ([snapshotRegistry count] > kFBMaxElementsLimit) {
            [FBLogger logFmt:@"Reached max element limit during batch processing"];
            break;
        }

        NSInteger endIndex = MIN(i + batchSize, (long) points.count);
        NSArray<NSValue *> *batch = [points subarrayWithRange:NSMakeRange(i, endIndex - i)];
        
        for (NSValue *pointValue in batch) {
            CGPoint point = [pointValue CGPointValue];
            NSString *pointKey = NSStringFromCGPoint(point);
            
            if ([processedPoints containsObject:pointKey]) {
                continue;
            }
            [processedPoints addObject:pointKey];
            
            [self fb_sampleSinglePointForSnapshot:point
                                discoveredSnapshots:discoveredSnapshots
                                  snapshotRegistry:snapshotRegistry
                                             depth:depth];
        }
    }
}

- (void)fb_sampleSinglePointForSnapshot:(CGPoint)point
                      discoveredSnapshots:(NSMutableArray<id<FBXCElementSnapshot>> *)discoveredSnapshots
                        snapshotRegistry:(NSMutableDictionary *)snapshotRegistry
                                   depth:(NSInteger)depth {

    __block id<FBXCElementSnapshot> elementSnapshot = nil;
    __block NSError *fetchError = nil;
    __block BOOL completed = NO;
    
    [self fb_findTopmostSnapshotAtPoint:point completion:^(id<FBXCElementSnapshot> snapshot, NSError *error) {
        elementSnapshot = snapshot;
        fetchError = error;
        completed = YES;
    }];
    
    NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:kFBGridSamplingTimeout];
    while (!completed && [timeoutDate timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    
    if (!completed || fetchError || !elementSnapshot) {
        return;
    }
    
    // Filter out tiny elements
    CGRect frame = elementSnapshot.frame;
    if (frame.size.width < kFBMinElementSize || frame.size.height < kFBMinElementSize) {
        return;
    }
    
    NSString *snapshotID = [self fb_createSnapshotIdentifier:elementSnapshot];
    
    if (![snapshotRegistry objectForKey:snapshotID]) {
        NSMutableDictionary *snapshotMetadata = [NSMutableDictionary dictionary];
        snapshotMetadata[@"snapshot"] = elementSnapshot;
        snapshotMetadata[@"discoveryPoint"] = NSStringFromCGPoint(point);
        snapshotMetadata[@"depth"] = @(depth);
        snapshotMetadata[@"discoveryMethod"] = @"grid";
        
        snapshotRegistry[snapshotID] = snapshotMetadata;
        [discoveredSnapshots addObject:elementSnapshot];
    }
}

- (void)fb_findTopmostSnapshotAtPoint:(CGPoint)point
                           completion:(void (^)(id<FBXCElementSnapshot> _Nullable snapshot, NSError * _Nullable error))completion {
    
    id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
    if (!proxy) {
        NSError *error = [[[FBErrorBuilder builder]
                          withDescription:@"Failed to get XCTest daemon proxy"] build];
        completion(nil, error);
        return;
    }
    
    [proxy _XCT_requestElementAtPoint:point reply:^(id axElement, NSError *error) {
        if (error || !axElement) {
            completion(nil, error);
            return;
        }
        
        NSDictionary *optimizedParams = @{
            @"maxDepth": @2,
            @"maxArrayCount": @5,
            @"maxChildren": @2,
            @"includeInvisible": @YES,
            @"snapshotKeyHonorModalViews": @YES
        };
        
        NSArray<NSString *> *enhancedAttributes = [self fb_getEnhancedAttributes];
        
        [proxy _XCT_requestSnapshotForElement:axElement
                                   attributes:enhancedAttributes
                                   parameters:optimizedParams
                                        reply:^(id snapshotObject, NSError *snapshotError) {
            if (snapshotError || !snapshotObject) {
                completion(nil, snapshotError);
                return;
            }
            
            completion(snapshotObject, nil);
        }];
    }];
}


- (NSString *)fb_createSnapshotIdentifier:(id<FBXCElementSnapshot>)snapshot {
    NSString *type = [FBElementTypeTransformer stringWithElementType:snapshot.elementType] ?: @"Unknown";
    CGRect rect = snapshot.frame;
    NSString *label = [self fb_cleanString:snapshot.label] ?: @"";
    NSString *testID = [self fb_cleanString:snapshot.identifier] ?: @"";
    NSString *value = [self fb_cleanString:snapshot.value] ?: @"";
    
    NSString *rectString = [NSString stringWithFormat:@"%.0f_%.0f_%.0f_%.0f",
                           rect.origin.x, rect.origin.y, rect.size.width, rect.size.height];
    
    NSString *combinedString = [NSString stringWithFormat:@"%@_%@_%@_%@_%@", type, rectString, label, testID, value];
    NSUInteger hash = [combinedString hash];
    
    return [NSString stringWithFormat:@"%@_%lu", type, (unsigned long)hash];
}

- (NSArray<id<FBXCElementSnapshot>> *)fb_filterSnapshotsByMinimumSize:(NSArray<id<FBXCElementSnapshot>> *)snapshots
                                                             minWidth:(CGFloat)minWidth
                                                            minHeight:(CGFloat)minHeight {
    NSMutableArray<id<FBXCElementSnapshot>> *filteredSnapshots = [NSMutableArray array];
    
    for (id<FBXCElementSnapshot> snapshot in snapshots) {
        CGRect frame = snapshot.frame;
        if (frame.size.width >= minWidth && frame.size.height >= minHeight) {
            [filteredSnapshots addObject:snapshot];
        }
    }
    
    return filteredSnapshots;
}

- (id<FBXCElementSnapshot>)fb_buildHierarchicalSnapshotTree:(NSArray<NSDictionary *> *)snapshotMetadataArray {
    [FBLogger logFmt:@"Phase 4: Building hierarchical snapshot tree"];
    
    // Create root snapshot from application
    FBApplicationSnapshot *rootSnapshot = (FBApplicationSnapshot *)[self fb_createRootSnapshot];
    
    // Extract snapshots and sort by area (largest first for parent-child relationships)
    NSMutableArray<NSDictionary *> *sortedMetadata = [snapshotMetadataArray mutableCopy];
    [sortedMetadata sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
        id<FBXCElementSnapshot> snapshot1 = obj1[@"snapshot"];
        id<FBXCElementSnapshot> snapshot2 = obj2[@"snapshot"];
        
        CGFloat area1 = snapshot1.frame.size.width * snapshot1.frame.size.height;
        CGFloat area2 = snapshot2.frame.size.width * snapshot2.frame.size.height;
        
        if (area1 > area2) return NSOrderedAscending;
        if (area1 < area2) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    
    // Build parent-child relationships
    NSMutableDictionary<NSString *, NSMutableArray<id<FBXCElementSnapshot>> *> *parentChildMap = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *snapshotsWithParents = [NSMutableSet set];
    
    for (NSInteger i = 0; i < sortedMetadata.count; i++) {
        NSDictionary *currentMetadata = sortedMetadata[i];
        id<FBXCElementSnapshot> currentSnapshot = currentMetadata[@"snapshot"];
        NSString *currentID = [self fb_createSnapshotIdentifier:currentSnapshot];
        
        // Check for explicit parent relationship
        NSString *explicitParentID = currentMetadata[@"parentID"];
        if (explicitParentID) {
            if (!parentChildMap[explicitParentID]) {
                parentChildMap[explicitParentID] = [NSMutableArray array];
            }
            [parentChildMap[explicitParentID] addObject:currentSnapshot];
            [snapshotsWithParents addObject:currentID];
            continue;
        }
        
        // Find geometric parent
        BOOL foundParent = NO;
        for (NSInteger j = 0; j < i && !foundParent; j++) {
            NSDictionary *potentialParentMetadata = sortedMetadata[j];
            id<FBXCElementSnapshot> potentialParent = potentialParentMetadata[@"snapshot"];
            NSString *parentID = [self fb_createSnapshotIdentifier:potentialParent];
            
            if ([self fb_doesSnapshot:potentialParent containSnapshot:currentSnapshot strictContainment:YES]) {
                if (!parentChildMap[parentID]) {
                    parentChildMap[parentID] = [NSMutableArray array];
                }
                [parentChildMap[parentID] addObject:currentSnapshot];
                [snapshotsWithParents addObject:currentID];
                foundParent = YES;
            }
        }
    }
    
    // Create composite snapshots with proper children
    NSMutableDictionary<NSString *, id<FBXCElementSnapshot>> *compositeSnapshots = [NSMutableDictionary dictionary];
    
    for (NSDictionary *metadata in sortedMetadata) {
        id<FBXCElementSnapshot> snapshot = metadata[@"snapshot"];
        NSString *snapshotID = [self fb_createSnapshotIdentifier:snapshot];
        
        // If this snapshot has children, create a composite snapshot
        NSArray<id<FBXCElementSnapshot>> *children = parentChildMap[snapshotID];
        if (children && children.count > 0) {
            // Sort children by position
            NSArray *sortedChildren = [children sortedArrayUsingComparator:^NSComparisonResult(id<FBXCElementSnapshot> obj1, id<FBXCElementSnapshot> obj2) {
                CGFloat y1 = obj1.frame.origin.y;
                CGFloat y2 = obj2.frame.origin.y;
                CGFloat x1 = obj1.frame.origin.x;
                CGFloat x2 = obj2.frame.origin.x;
                
                if (ABS(y1 - y2) > 10) {
                    return y1 < y2 ? NSOrderedAscending : NSOrderedDescending;
                } else {
                    return x1 < x2 ? NSOrderedAscending : NSOrderedDescending;
                }
            }];
            
            id<FBXCElementSnapshot> compositeSnapshot = [self fb_createCompositeSnapshot:snapshot withChildren:sortedChildren];
            compositeSnapshots[snapshotID] = compositeSnapshot;
        } else {
            compositeSnapshots[snapshotID] = snapshot;
        }
    }
    
    // Collect top-level elements (those without parents)
    NSMutableArray<id<FBXCElementSnapshot>> *topLevelSnapshots = [NSMutableArray array];
    for (NSDictionary *metadata in sortedMetadata) {
        id<FBXCElementSnapshot> snapshot = metadata[@"snapshot"];
        NSString *snapshotID = [self fb_createSnapshotIdentifier:snapshot];
        
        if (![snapshotsWithParents containsObject:snapshotID]) {
            id<FBXCElementSnapshot> finalSnapshot = compositeSnapshots[snapshotID];
            [topLevelSnapshots addObject:finalSnapshot];
        }
    }
    
    // Sort top-level snapshots by position
    [topLevelSnapshots sortUsingComparator:^NSComparisonResult(id<FBXCElementSnapshot> obj1, id<FBXCElementSnapshot> obj2) {
        CGFloat y1 = obj1.frame.origin.y;
        CGFloat y2 = obj2.frame.origin.y;
        CGFloat x1 = obj1.frame.origin.x;
        CGFloat x2 = obj2.frame.origin.x;
        
        if (ABS(y1 - y2) > 10) {
            return y1 < y2 ? NSOrderedAscending : NSOrderedDescending;
        } else {
            return x1 < x2 ? NSOrderedAscending : NSOrderedDescending;
        }
    }];
    
    // Set children on root snapshot
    rootSnapshot.children = topLevelSnapshots;
    
    return rootSnapshot;
}

- (BOOL)fb_doesSnapshot:(id<FBXCElementSnapshot>)parent containSnapshot:(id<FBXCElementSnapshot>)child strictContainment:(BOOL)strict {
    CGRect pFrame = parent.frame;
    CGRect cFrame = child.frame;
    
    // Avoid self-containment
    if (CGRectEqualToRect(pFrame, cFrame)) {
        return NO;
    }
    
    if (strict) {
        CGRect strictParentFrame = CGRectInset(pFrame, 1, 1);
        return CGRectContainsRect(strictParentFrame, cFrame);
    } else {
        CGRect looseParentFrame = CGRectInset(pFrame, -5, -5);
        return CGRectContainsRect(looseParentFrame, cFrame);
    }
}

- (NSUInteger)fb_countTotalSnapshotsInTree:(id<FBXCElementSnapshot>)rootSnapshot {
    NSUInteger count = 1;
    [FBLogger logFmt:@"Parent Element: %@ - %@ - %@ - %@ - %@ - %@", rootSnapshot.label, rootSnapshot.value, rootSnapshot.description, rootSnapshot.identifier, rootSnapshot.children, rootSnapshot.title];
    if (rootSnapshot.children && [rootSnapshot.children isKindOfClass:[NSArray class]]) {
        for (id<FBXCElementSnapshot> childSnapshot in rootSnapshot.children) {
          [FBLogger logFmt:@"Child Elements: %@ - %@ - %@ - %@ - %@ - %@", childSnapshot.label, childSnapshot.value, childSnapshot.description, childSnapshot.identifier, childSnapshot.children, childSnapshot.title];
            count += [self fb_countTotalSnapshotsInTree:childSnapshot];
        }
    }
    
    return count;
}

#pragma mark - Updated Snapshot Creation Helper Methods

- (id<FBXCElementSnapshot>)fb_createRootSnapshot {
  return [[FBApplicationSnapshot alloc] initWithApplication:self];
}

- (id<FBXCElementSnapshot>)fb_createCompositeSnapshot:(id<FBXCElementSnapshot>)parentSnapshot
                                         withChildren:(NSArray<id<FBXCElementSnapshot>> *)children {
    return [[FBCompositeSnapshot alloc] initWithBaseSnapshot:parentSnapshot children:children];
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

@end
