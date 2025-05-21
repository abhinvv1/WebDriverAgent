/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBXPath.h"

#import "FBConfiguration.h"
#import "FBExceptions.h"
#import "FBElementUtils.h"
#import "FBLogger.h"
#import "FBMacros.h"
#import "FBXMLGenerationOptions.h"
#import "FBXCElementSnapshotWrapper+Helpers.h"
#import "NSString+FBXMLSafeString.h"
#import "XCUIElement.h"
#import "XCUIElement+FBCaching.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBWebDriverAttributes.h"
#import "XCTestPrivateSymbols.h"

#define DEFAULT_MAX_DEPTH 50
#define DEFAULT_BATCH_SIZE 10
#define ATTRIBUTE_CACHE_SIZE 1000
#define ATTRIBUTE_CACHE_EXPIRY 30.0 // seconds

@interface FBElementAttribute : NSObject

@property (nonatomic, readonly) id<FBElement> element;
@property (nonatomic, strong) NSMutableDictionary *attributeCache;
@property (nonatomic, strong) NSMutableDictionary *attributeExpiry;

+ (nonnull NSString *)name;
+ (nullable NSString *)valueForElement:(id<FBElement>)element;

+ (int)recordWithWriter:(xmlTextWriterPtr)writer forElement:(id<FBElement>)element;

+ (NSArray<Class> *)supportedAttributes;

@end

@interface FBTypeAttribute : FBElementAttribute

@end

@interface FBValueAttribute : FBElementAttribute

@end

@interface FBNameAttribute : FBElementAttribute

@end

@interface FBLabelAttribute : FBElementAttribute

@end

@interface FBEnabledAttribute : FBElementAttribute

@end

@interface FBVisibleAttribute : FBElementAttribute

@end

@interface FBAccessibleAttribute : FBElementAttribute

@end

@interface FBDimensionAttribute : FBElementAttribute

@end

@interface FBXAttribute : FBDimensionAttribute

@end

@interface FBYAttribute : FBDimensionAttribute

@end

@interface FBWidthAttribute : FBDimensionAttribute

@end

@interface FBHeightAttribute : FBDimensionAttribute

@end

@interface FBIndexAttribute : FBElementAttribute

@end

@interface FBHittableAttribute : FBElementAttribute

@end

@interface FBInternalIndexAttribute : FBElementAttribute

@property (nonatomic, nonnull, readonly) NSString* indexValue;

+ (int)recordWithWriter:(xmlTextWriterPtr)writer forValue:(NSString *)value;

@end

@interface FBPlaceholderValueAttribute : FBElementAttribute

@end

#if TARGET_OS_TV

@interface FBFocusedAttribute : FBElementAttribute

@end

#endif

// New structure to hold streaming context data
@interface FBXPathStreamingContext : NSObject

@property (nonatomic, strong) id<FBXCElementSnapshot> rootSnapshot;
@property (nonatomic, copy) NSString *xpathQuery;
@property (nonatomic, strong) NSMutableArray<id<FBXCElementSnapshot>> *matchingSnapshots;
@property (nonatomic, strong) NSMapTable<NSString *, id<FBXCElementSnapshot>> *elementStore;
@property (nonatomic) NSUInteger maxDepth;
@property (nonatomic) NSUInteger batchSize;
@property (nonatomic) BOOL limitContextScope;

@end

@implementation FBXPathStreamingContext

- (instancetype)initWithRootSnapshot:(id<FBXCElementSnapshot>)rootSnapshot
                         xpathQuery:(NSString *)xpathQuery
                           maxDepth:(NSUInteger)maxDepth
                          batchSize:(NSUInteger)batchSize {
    self = [super init];
    if (self) {
        _rootSnapshot = rootSnapshot;
        _xpathQuery = xpathQuery;
        _matchingSnapshots = [NSMutableArray array];
        _elementStore = [NSMapTable strongToWeakObjectsMapTable];
        _maxDepth = maxDepth;
        _batchSize = batchSize;
        _limitContextScope = FBConfiguration.limitXpathContextScope;
    }
    return self;
}

@end

const static char *_UTF8Encoding = "UTF-8";

static NSString *const kXMLIndexPathKey = @"private_indexPath";
static NSString *const topNodeIndexPath = @"top";

@implementation FBXPath

+ (id)throwException:(NSString *)name forQuery:(NSString *)xpathQuery
{
  NSString *reason = [NSString stringWithFormat:@"Cannot evaluate results for XPath expression \"%@\"", xpathQuery];
  @throw [NSException exceptionWithName:name reason:reason userInfo:@{}];
  return nil;
}

+ (nullable NSString *)xmlStringWithRootElement:(id<FBElement>)root
                                        options:(nullable FBXMLGenerationOptions *)options
{
  xmlDocPtr doc;
  xmlTextWriterPtr writer = xmlNewTextWriterDoc(&doc, 0);
  if (NULL == writer) {
    [FBLogger log:@"Failed to invoke libxml2>xmlNewTextWriterDoc"];
    return nil;
  }

  @try {
    int rc = xmlTextWriterStartDocument(writer, NULL, _UTF8Encoding, NULL);
    if (rc < 0) {
      [FBLogger logFmt:@"Failed to invoke libxml2>xmlTextWriterStartDocument. Error code: %d", rc];
      return nil;
    }

    BOOL hasScope = nil != options.scope && [options.scope length] > 0;
    if (hasScope) {
      rc = xmlTextWriterStartElement(writer,
                                     (xmlChar *)[[self safeXmlStringWithString:options.scope] UTF8String]);
      if (rc < 0) {
        [FBLogger logFmt:@"Failed to invoke libxml2>xmlTextWriterStartElement for the tag value '%@'. Error code: %d", options.scope, rc];
        return nil;
      }
    }

    // Use batched processing instead of building the entire tree at once
    id<FBXCElementSnapshot> rootSnapshot = [self snapshotWithRoot:root];
    rc = [self streamingXmlRepresentationWithRootElement:rootSnapshot
                                                 writer:writer
                                           elementStore:nil
                                                  query:nil
                                    excludingAttributes:options.excludedAttributes
                                               maxDepth:DEFAULT_MAX_DEPTH
                                              batchSize:DEFAULT_BATCH_SIZE];

    if (rc < 0) {
      return nil;
    }

    if (rc >= 0 && hasScope) {
      rc = xmlTextWriterEndElement(writer);
      if (rc < 0) {
        [FBLogger logFmt:@"Failed to invoke libxml2>xmlTextWriterEndElement. Error code: %d", rc];
        return nil;
      }
    }

    if (rc >= 0) {
      rc = xmlTextWriterEndDocument(writer);
      if (rc < 0) {
        [FBLogger logFmt:@"Failed to invoke libxml2>xmlXPathNewContext. Error code: %d", rc];
        return nil;
      }
    }

    int buffersize;
    xmlChar *xmlbuff;
    xmlDocDumpFormatMemory(doc, &xmlbuff, &buffersize, 1);
    NSString *result = [NSString stringWithCString:(const char *)xmlbuff encoding:NSUTF8StringEncoding];
    xmlFree(xmlbuff);
    return result;
  } @finally {
    if (writer) {
      xmlFreeTextWriter(writer);
    }
    if (doc) {
      xmlFreeDoc(doc);
    }
  }
}

+ (NSArray<id<FBXCElementSnapshot>> *)matchesWithRootElement:(id<FBElement>)root
                                                    forQuery:(NSString *)xpathQuery
{
  return [self matchesWithRootElement:root forQuery:xpathQuery maxDepth:DEFAULT_MAX_DEPTH batchSize:DEFAULT_BATCH_SIZE];
}

+ (NSArray<id<FBXCElementSnapshot>> *)matchesWithRootElement:(id<FBElement>)root
                                                    forQuery:(NSString *)xpathQuery
                                                    maxDepth:(NSUInteger)maxDepth
                                                   batchSize:(NSUInteger)batchSize
{
  // Prepare the snapshot that will serve as the lookup source
  id<FBXCElementSnapshot> lookupScopeSnapshot = nil;
  id<FBXCElementSnapshot> contextRootSnapshot = nil;

  if (FBConfiguration.limitXpathContextScope) {
    lookupScopeSnapshot = [self snapshotWithRoot:root];
  } else {
    if ([root isKindOfClass:XCUIElement.class]) {
      lookupScopeSnapshot = [self snapshotWithRoot:[(XCUIElement *)root application]];
      contextRootSnapshot = [root isKindOfClass:XCUIApplication.class]
      ? nil
      : ([(XCUIElement *)root lastSnapshot] ?: [(XCUIElement *)root fb_customSnapshot]);
    } else {
      lookupScopeSnapshot = (id<FBXCElementSnapshot>)root;
      contextRootSnapshot = nil == lookupScopeSnapshot.parent ? nil : (id<FBXCElementSnapshot>)root;
      while (nil != lookupScopeSnapshot.parent) {
        lookupScopeSnapshot = lookupScopeSnapshot.parent;
      }
    }
  }

  // Create streaming context
  FBXPathStreamingContext *context = [[FBXPathStreamingContext alloc]
                                     initWithRootSnapshot:lookupScopeSnapshot
                                              xpathQuery:xpathQuery
                                                maxDepth:maxDepth
                                               batchSize:batchSize];

  // Process using the streaming approach
  if (![self streamingProcessWithContext:context contextRootSnapshot:contextRootSnapshot]) {
    return [self throwException:FBXPathQueryEvaluationException forQuery:xpathQuery];
  }

  return context.matchingSnapshots.copy;
}

+ (BOOL)streamingProcessWithContext:(FBXPathStreamingContext *)context
              contextRootSnapshot:(nullable id<FBXCElementSnapshot>)contextRootSnapshot
{
  // Use batched processing to avoid building the entire XML tree at once
  NSMutableArray<id<FBXCElementSnapshot>> *pendingBatch = [NSMutableArray arrayWithObject:context.rootSnapshot];
  [context.elementStore setObject:context.rootSnapshot forKey:topNodeIndexPath];

  NSMutableArray<NSString *> *pendingPaths = [NSMutableArray arrayWithObject:topNodeIndexPath];
  NSUInteger currentDepth = 0;

  while (pendingBatch.count > 0 && currentDepth <= context.maxDepth) {
    @autoreleasepool {
      NSMutableArray<id<FBXCElementSnapshot>> *nextBatch = [NSMutableArray array];
      NSMutableArray<NSString *> *nextPaths = [NSMutableArray array];

      // Process current batch
      for (NSUInteger i = 0; i < pendingBatch.count; i++) {
        id<FBXCElementSnapshot> snapshot = pendingBatch[i];
        NSString *indexPath = pendingPaths[i];

        // Process this node's children and add to next batch
        NSArray<id<FBXCElementSnapshot>> *children = snapshot.children;
        for (NSUInteger j = 0; j < [children count]; j++) {
          @autoreleasepool {
            id<FBXCElementSnapshot> childSnapshot = [children objectAtIndex:j];
            NSString *newIndexPath = [indexPath stringByAppendingFormat:@",%lu", (unsigned long)j];

            // Store element for later lookup
            [context.elementStore setObject:childSnapshot forKey:newIndexPath];

            // Add to next batch
            [nextBatch addObject:childSnapshot];
            [nextPaths addObject:newIndexPath];
          }
        }
      }

      // Break batch into chunks to evaluate XPath
      for (NSUInteger offset = 0; offset < pendingBatch.count; offset += context.batchSize) {
        @autoreleasepool {
          NSUInteger limit = MIN(offset + context.batchSize, pendingBatch.count);
          NSArray<id<FBXCElementSnapshot>> *batchChunk = [pendingBatch subarrayWithRange:NSMakeRange(offset, limit - offset)];
          NSArray<NSString *> *pathChunk = [pendingPaths subarrayWithRange:NSMakeRange(offset, limit - offset)];

          if (![self evaluateXPathForBatch:batchChunk withPaths:pathChunk context:context]) {
            return NO;
          }
        }
      }

      // Set up for next iteration
      pendingBatch = nextBatch;
      pendingPaths = nextPaths;
      currentDepth++;
    }
  }

  return YES;
}

+ (BOOL)evaluateXPathForBatch:(NSArray<id<FBXCElementSnapshot>> *)batch
                    withPaths:(NSArray<NSString *> *)paths
                      context:(FBXPathStreamingContext *)context
{
  if (batch.count == 0) {
    return YES;
  }

  xmlDocPtr doc = NULL;
  xmlTextWriterPtr writer = NULL;

  @try {
    writer = xmlNewTextWriterDoc(&doc, 0);
    if (NULL == writer) {
      [FBLogger log:@"Failed to invoke libxml2>xmlNewTextWriterDoc"];
      return NO;
    }

    int rc = xmlTextWriterStartDocument(writer, NULL, _UTF8Encoding, NULL);
    if (rc < 0) {
      [FBLogger logFmt:@"Failed to invoke libxml2>xmlTextWriterStartDocument. Error code: %d", rc];
      return NO;
    }

    // Create a temporary document containing just this batch
    for (NSUInteger i = 0; i < batch.count; i++) {
      id<FBXCElementSnapshot> snapshot = batch[i];
      NSString *indexPath = paths[i];

      rc = [self writeElementNode:snapshot
                        indexPath:indexPath
                      elementStore:context.elementStore
                            writer:writer
              excludingAttributes:nil];

      if (rc < 0) {
        return NO;
      }
    }

    rc = xmlTextWriterEndDocument(writer);
    if (rc < 0) {
      [FBLogger logFmt:@"Failed to invoke libxml2>xmlTextWriterEndDocument. Error code: %d", rc];
      return NO;
    }

    // Now evaluate the XPath query against this batch document
    xmlXPathObjectPtr queryResult = [self evaluate:context.xpathQuery
                                          document:doc
                                       contextNode:NULL];

    if (NULL == queryResult) {
      return NO;
    }

    // Collect results
    NSArray *batchResults = [self collectMatchingSnapshots:queryResult->nodesetval
                                             elementStore:context.elementStore];
    if (nil == batchResults) {
      xmlXPathFreeObject(queryResult);
      return NO;
    }

    [context.matchingSnapshots addObjectsFromArray:batchResults];
    xmlXPathFreeObject(queryResult);
    return YES;
  } @finally {
    if (writer) {
      xmlFreeTextWriter(writer);
    }
    if (doc) {
      xmlFreeDoc(doc);
    }
  }
}

+ (int)streamingXmlRepresentationWithRootElement:(id<FBXCElementSnapshot>)root
                                         writer:(xmlTextWriterPtr)writer
                                   elementStore:(nullable NSMutableDictionary *)elementStore
                                          query:(nullable NSString*)query
                            excludingAttributes:(nullable NSArray<NSString *> *)excludedAttributes
                                       maxDepth:(NSUInteger)maxDepth
                                      batchSize:(NSUInteger)batchSize
{
  NSMutableSet<Class> *includedAttributes = [self determineIncludedAttributesForQuery:query
                                                              excludingAttributes:excludedAttributes];
  
  // Process in batches using an iterative approach instead of recursion
  NSMutableArray<id<FBXCElementSnapshot>> *queue = [NSMutableArray arrayWithObject:root];
  NSMutableArray<NSString *> *pathQueue = nil;
  NSMutableArray<NSNumber *> *depthQueue = [NSMutableArray arrayWithObject:@0];
  
  if (elementStore) {
    pathQueue = [NSMutableArray arrayWithObject:topNodeIndexPath];
    [elementStore setObject:root forKey:topNodeIndexPath];
  }
  
  while (queue.count > 0) {
    @autoreleasepool {
      NSUInteger batchLimit = MIN(batchSize, queue.count);
      NSMutableArray<id<FBXCElementSnapshot>> *nextQueue = [NSMutableArray array];
      NSMutableArray<NSString *> *nextPathQueue = elementStore ? [NSMutableArray array] : nil;
      NSMutableArray<NSNumber *> *nextDepthQueue = [NSMutableArray array];
      
      // Process current batch
      for (NSUInteger i = 0; i < batchLimit; i++) {
        id<FBXCElementSnapshot> element = queue[i];
        NSUInteger depth = [depthQueue[i] unsignedIntegerValue];
        NSString *path = pathQueue ? pathQueue[i] : nil;
        
        // Write current element
        FBXCElementSnapshotWrapper *wrappedSnapshot = [FBXCElementSnapshotWrapper ensureWrapped:element];
        int rc = xmlTextWriterStartElement(writer, (xmlChar *)[wrappedSnapshot.wdType UTF8String]);
        if (rc < 0) {
          [FBLogger logFmt:@"Failed to invoke libxml2>xmlTextWriterStartElement for the tag value '%@'. Error code: %d",
             wrappedSnapshot.wdType, rc];
          return rc;
        }
        
        // Write attributes with caching
        rc = [self recordElementAttributesWithCaching:writer
                                          forElement:element
                                           indexPath:path
                                  includedAttributes:includedAttributes];
        if (rc < 0) {
          return rc;
        }
        
        // Enqueue children if not at max depth
        if (depth < maxDepth) {
          NSArray<id<FBXCElementSnapshot>> *children = element.children;
          for (NSUInteger j = 0; j < [children count]; j++) {
            @autoreleasepool {
              id<FBXCElementSnapshot> childSnapshot = [children objectAtIndex:j];
              [nextQueue addObject:childSnapshot];
              [nextDepthQueue addObject:@(depth + 1)];
              
              if (pathQueue) {
                NSString *newIndexPath = [path stringByAppendingFormat:@",%lu", (unsigned long)j];
                [nextPathQueue addObject:newIndexPath];
                [elementStore setObject:childSnapshot forKey:newIndexPath];
              }
            }
          }
        }
        
        // Close current element tag
        rc = xmlTextWriterEndElement(writer);
        if (rc < 0) {
          [FBLogger logFmt:@"Failed to invoke libxml2>xmlTextWriterEndElement. Error code: %d", rc];
          return rc;
        }
      }
      
      // Remove processed items from queues
      [queue removeObjectsInRange:NSMakeRange(0, batchLimit)];
      [depthQueue removeObjectsInRange:NSMakeRange(0, batchLimit)];
      if (pathQueue) {
        [pathQueue removeObjectsInRange:NSMakeRange(0, batchLimit)];
      }
      
      // Add next batch
      [queue addObjectsFromArray:nextQueue];
      [depthQueue addObjectsFromArray:nextDepthQueue];
      if (pathQueue) {
        [pathQueue addObjectsFromArray:nextPathQueue];
      }
    }
  }
  
  return 0;
}

+ (int)writeElementNode:(id<FBXCElementSnapshot>)element
              indexPath:(nullable NSString *)indexPath
           elementStore:(nullable NSMapTable *)elementStore
                 writer:(xmlTextWriterPtr)writer
    excludingAttributes:(nullable NSArray<NSString *> *)excludedAttributes
{
  FBXCElementSnapshotWrapper *wrappedSnapshot = [FBXCElementSnapshotWrapper ensureWrapped:element];
  int rc = xmlTextWriterStartElement(writer, (xmlChar *)[wrappedSnapshot.wdType UTF8String]);
  if (rc < 0) {
    [FBLogger logFmt:@"Failed to invoke libxml2>xmlTextWriterStartElement for the tag value '%@'. Error code: %d",
       wrappedSnapshot.wdType, rc];
    return rc;
  }

  NSMutableSet<Class> *includedAttributes = [self determineIncludedAttributesForQuery:nil
                                                              excludingAttributes:excludedAttributes];

  rc = [self recordElementAttributes:writer
                          forElement:element
                           indexPath:indexPath
                  includedAttributes:includedAttributes];
  if (rc < 0) {
    return rc;
  }

  rc = xmlTextWriterEndElement(writer);
  if (rc < 0) {
    [FBLogger logFmt:@"Failed to invoke libxml2>xmlTextWriterEndElement. Error code: %d", rc];
    return rc;
  }

  return 0;
}

+ (NSMutableSet<Class> *)determineIncludedAttributesForQuery:(nullable NSString *)query
                                        excludingAttributes:(nullable NSArray<NSString *> *)excludedAttributes
{
  NSMutableSet<Class> *includedAttributes;

  if (nil == query) {
    includedAttributes = [NSMutableSet setWithArray:FBElementAttribute.supportedAttributes];
    // The hittable attribute is expensive to calculate for each snapshot item
    // thus we only include it when requested by an xPath query
    [includedAttributes removeObject:FBHittableAttribute.class];

    if (nil != excludedAttributes) {
      for (NSString *excludedAttributeName in excludedAttributes) {
        for (Class supportedAttribute in FBElementAttribute.supportedAttributes) {
          if ([[supportedAttribute name] caseInsensitiveCompare:excludedAttributeName] == NSOrderedSame) {
            [includedAttributes removeObject:supportedAttribute];
            break;
          }
        }
      }
    }
  } else {
    includedAttributes = [self.class elementAttributesWithXPathQuery:query].mutableCopy;
  }

  return includedAttributes;
}

+ (NSArray *)collectMatchingSnapshots:(xmlNodeSetPtr)nodeSet
                         elementStore:(NSMapTable *)elementStore
{
  if (xmlXPathNodeSetIsEmpty(nodeSet)) {
    return @[];
  }
  NSMutableArray *matchingSnapshots = [NSMutableArray array];
  const xmlChar *indexPathKeyName = (xmlChar *)[kXMLIndexPathKey UTF8String];
  for (NSInteger i = 0; i < nodeSet->nodeNr; i++) {
    @autoreleasepool {
      xmlNodePtr currentNode = nodeSet->nodeTab[i];
      xmlChar *attrValue = xmlGetProp(currentNode, indexPathKeyName);
      if (NULL == attrValue) {
        [FBLogger log:@"Failed to invoke libxml2>xmlGetProp"];
        return nil;
      }
      NSString *indexPath = [NSString stringWithCString:(const char *)attrValue encoding:NSUTF8StringEncoding];
      id<FBXCElementSnapshot> element = [elementStore objectForKey:indexPath];
      if (element) {
        [matchingSnapshots addObject:element];
      }
      xmlFree(attrValue);
    }
  }
  return matchingSnapshots.copy;
}

+ (nullable xmlXPathObjectPtr)matchNodeInDocument:(xmlDocPtr)doc
                                     elementStore:(NSDictionary<NSString *, id<FBXCElementSnapshot>> *)elementStore
                                      forSnapshot:(nullable id<FBXCElementSnapshot>)snapshot
{
  if (nil == snapshot) {
    return NULL;
  }

  NSString *contextRootUid = [FBElementUtils uidWithAccessibilityElement:[(id)snapshot accessibilityElement]];
  if (nil == contextRootUid) {
    return NULL;
  }

  for (NSString *key in elementStore) {
    @autoreleasepool {
      id<FBXCElementSnapshot> value = [elementStore objectForKey:key];
      NSString *snapshotUid = [FBElementUtils uidWithAccessibilityElement:[value accessibilityElement]];
      if (nil == snapshotUid || ![snapshotUid isEqualToString:contextRootUid]) {
        continue;
      }
      NSString *indexQuery = [NSString stringWithFormat:@"//*[@%@=\"%@\"]", kXMLIndexPathKey, key];
      xmlXPathObjectPtr queryResult = [self evaluate:indexQuery
                                            document:doc
                                         contextNode:NULL];
      if (NULL != queryResult) {
        return queryResult;
      }
    }
  }
  return NULL;
}

+ (NSSet<Class> *)elementAttributesWithXPathQuery:(NSString *)query
{
  if ([query rangeOfString:@"[^\\w@]@\\*[^\\w]" options:NSRegularExpressionSearch].location != NSNotFound) {
    // read all element attributes if 'star' attribute name pattern is used in xpath query
    return [NSSet setWithArray:FBElementAttribute.supportedAttributes];
  }
  NSMutableSet<Class> *result = [NSMutableSet set];
  for (Class attributeCls in FBElementAttribute.supportedAttributes) {
    if ([query rangeOfString:[NSString stringWithFormat:@"[^\\w@]@%@[^\\w]", [attributeCls name]] options:NSRegularExpressionSearch].location != NSNotFound) {
      [result addObject:attributeCls];
    }
  }
  return result.copy;
}

+ (xmlXPathObjectPtr)evaluate:(NSString *)xpathQuery
                     document:(xmlDocPtr)doc
                  contextNode:(nullable xmlNodePtr)contextNode
{
  xmlXPathContextPtr xpathCtx = xmlXPathNewContext(doc);
  if (NULL == xpathCtx) {
    [FBLogger logFmt:@"Failed to invoke libxml2>xmlXPathNewContext for XPath query \"%@\"", xpathQuery];
    return NULL;
  }
  xpathCtx->node = NULL == contextNode ? doc->children : contextNode;

  xmlXPathObjectPtr xpathObj = xmlXPathEvalExpression((const xmlChar *)[xpathQuery UTF8String], xpathCtx);
  if (NULL == xpathObj) {
    xmlXPathFreeContext(xpathCtx);
    [FBLogger logFmt:@"Failed to invoke libxml2>xmlXPathEvalExpression for XPath query \"%@\"", xpathQuery];
    return NULL;
  }
  xmlXPathFreeContext(xpathCtx);
  return xpathObj;
}

+ (nullable NSString *)safeXmlStringWithString:(NSString *)str
{
  return [str fb_xmlSafeStringWithReplacement:@""];
}

+ (int)recordElementAttributes:(xmlTextWriterPtr)writer
                    forElement:(id<FBXCElementSnapshot>)element
                     indexPath:(nullable NSString *)indexPath
            includedAttributes:(nullable NSSet<Class> *)includedAttributes
{
  for (Class attributeCls in FBElementAttribute.supportedAttributes) {
    // include all supported attributes by default unless enumerated explicitly
    if (includedAttributes && ![includedAttributes containsObject:attributeCls]) {
      continue;
    }
    int rc = [attributeCls recordWithWriter:writer
                                 forElement:[FBXCElementSnapshotWrapper ensureWrapped:element]];
    if (rc < 0) {
      return rc;
    }
  }

  if (nil != indexPath) {
    // index path is the special case
    return [FBInternalIndexAttribute recordWithWriter:writer forValue:indexPath];
  }
  return 0;
}

+ (int)recordElementAttributesWithCaching:(xmlTextWriterPtr)writer
                               forElement:(id<FBXCElementSnapshot>)element
                                indexPath:(nullable NSString *)indexPath
                       includedAttributes:(nullable NSSet<Class> *)includedAttributes
{
  FBElementAttributeCache *cache = [FBElementAttributeCache sharedCache];
  
  for (Class attributeCls in FBElementAttribute.supportedAttributes) {
    if (includedAttributes && ![includedAttributes containsObject:attributeCls]) {
      continue;
    }
    
    NSString *cacheKey = [NSString stringWithFormat:@"%@_%@", [attributeCls name], element.fb_uid];
    id cachedValue = [cache valueForKey:cacheKey];
    
    if (cachedValue) {
      // Use cached value
      int rc = [attributeCls recordWithWriter:writer forValue:cachedValue];
      if (rc < 0) {
        return rc;
      }
    } else {
      // Calculate and cache new value
      int rc = [attributeCls recordWithWriter:writer
                                   forElement:[FBXCElementSnapshotWrapper ensureWrapped:element]];
      if (rc < 0) {
        return rc;
      }
      
      // Cache the value for future use
      NSString *value = [attributeCls valueForElement:[FBXCElementSnapshotWrapper ensureWrapped:element]];
      if (value) {
        [cache setValue:value forKey:cacheKey];
      }
    }
  }
  
  if (nil != indexPath) {
    return [FBInternalIndexAttribute recordWithWriter:writer forValue:indexPath];
  }
  return 0;
}

+ (id<FBXCElementSnapshot>)snapshotWithRoot:(id<FBElement>)root
{
  if (![root isKindOfClass:XCUIElement.class]) {
    return (id<FBXCElementSnapshot>)root;
  }

  // If the app is not idle state while we retrieve the visiblity state
  // then the snapshot retrieval operation might freeze and time out
  [[(XCUIElement *)root application] fb_waitUntilStableWithTimeout:FBConfiguration.animationCoolOffTimeout];
  return [root isKindOfClass:XCUIApplication.class]
    ? [(XCUIElement *)root fb_standardSnapshot]
    : [(XCUIElement *)root fb_customSnapshot];
}

@end


static NSString *const FBAbstractMethodInvocationException = @"AbstractMethodInvocationException";

@implementation FBElementAttribute

- (instancetype)initWithElement:(id<FBElement>)element
{
  self = [super init];
  if (self) {
    _element = element;
    _attributeCache = [NSMutableDictionary dictionary];
    _attributeExpiry = [NSMutableDictionary dictionary];
  }
  return self;
}

+ (NSString *)name
{
  NSString *errMsg = [NSString stringWithFormat:@"The abstract method +(NSString *)name is expected to be overriden by %@", NSStringFromClass(self.class)];
  @throw [NSException exceptionWithName:FBAbstractMethodInvocationException reason:errMsg userInfo:nil];
}

+ (NSString *)valueForElement:(id<FBElement>)element
{
  NSString *errMsg = [NSString stringWithFormat:@"The abstract method -(NSString *)value is expected to be overriden by %@", NSStringFromClass(self.class)];
  @throw [NSException exceptionWithName:FBAbstractMethodInvocationException reason:errMsg userInfo:nil];
}

+ (int)recordWithWriter:(xmlTextWriterPtr)writer forElement:(id<FBElement>)element
{
  NSString *value = [self valueForElement:element];
  if (nil == value) {
    // Skip the attribute if the value equals to nil
    return 0;
  }
  int rc = xmlTextWriterWriteAttribute(writer,
                                       (xmlChar *)[[FBXPath safeXmlStringWithString:[self name]] UTF8String],
                                       (xmlChar *)[[FBXPath safeXmlStringWithString:value] UTF8String]);
  if (rc < 0) {
    [FBLogger logFmt:@"Failed to invoke libxml2>xmlTextWriterWriteAttribute(%@='%@'). Error code: %d", [self name], value, rc];
  }
  return rc;
}

+ (NSArray<Class> *)supportedAttributes
{
  // The list of attributes to be written for each XML node
  // The enumeration order does matter here
  return @[FBTypeAttribute.class,
           FBValueAttribute.class,
           FBNameAttribute.class,
           FBLabelAttribute.class,
           FBEnabledAttribute.class,
           FBVisibleAttribute.class,
           FBAccessibleAttribute.class,
#if TARGET_OS_TV
           FBFocusedAttribute.class,
#endif
           FBXAttribute.class,
           FBYAttribute.class,
           FBWidthAttribute.class,
           FBHeightAttribute.class,
           FBIndexAttribute.class,
           FBHittableAttribute.class,
           FBPlaceholderValueAttribute.class,
          ];
}

@end

@implementation FBTypeAttribute

+ (NSString *)name
{
  return @"type";
}

+ (NSString *)valueForElement:(id<FBElement>)element
{
  return element.wdType;
}

@end

@implementation FBValueAttribute

+ (NSString *)name
{
  return @"value";
}

+ (NSString *)valueForElement:(id<FBElement>)element
{
  id idValue = element.wdValue;
  if ([idValue isKindOfClass:[NSValue class]]) {
    return [idValue stringValue];
  } else if ([idValue isKindOfClass:[NSString class]]) {
    return idValue;
  }
  return [idValue description];
}

@end

@implementation FBNameAttribute

+ (NSString *)name
{
  return @"name";
}

+ (NSString *)valueForElement:(id<FBElement>)element
{
  return element.wdName;
}

@end

@implementation FBLabelAttribute

+ (NSString *)name
{
  return @"label";
}

+ (NSString *)valueForElement:(id<FBElement>)element
{
  return element.wdLabel;
}

@end

@implementation FBEnabledAttribute

+ (NSString *)name
{
  return @"enabled";
}

+ (NSString *)valueForElement:(id<FBElement>)element
{
  return FBBoolToString(element.wdEnabled);
}

@end

@implementation FBVisibleAttribute

+ (NSString *)name
{
  return @"visible";
}

+ (NSString *)valueForElement:(id<FBElement>)element
{
  return FBBoolToString(element.wdVisible);
}

@end

@implementation FBAccessibleAttribute

+ (NSString *)name
{
  return @"accessible";
}

+ (NSString *)valueForElement:(id<FBElement>)element
{
  return FBBoolToString(element.wdAccessible);
}

@end

#if TARGET_OS_TV

@implementation FBFocusedAttribute

+ (NSString *)name
{
  return @"focused";
}

+ (NSString *)valueForElement:(id<FBElement>)element
{
  return FBBoolToString(element.wdFocused);
}

@end

#endif

@implementation FBDimensionAttribute

+ (NSString *)valueForElement:(id<FBElement>)element
{
  return [NSString stringWithFormat:@"%@", [element.wdRect objectForKey:[self name]]];
}

@end

@implementation FBXAttribute

+ (NSString *)name
{
  return @"x";
}

@end

@implementation FBYAttribute

+ (NSString *)name
{
  return @"y";
}

@end

@implementation FBWidthAttribute

+ (NSString *)name
{
  return @"width";
}

@end

@implementation FBHeightAttribute

+ (NSString *)name
{
  return @"height";
}

@end

@implementation FBIndexAttribute

+ (NSString *)name
{
  return @"index";
}

+ (NSString *)valueForElement:(id<FBElement>)element
{
  return [NSString stringWithFormat:@"%lu", element.wdIndex];
}

@end

@implementation FBHittableAttribute

+ (NSString *)name
{
  return @"hittable";
}

+ (NSString *)valueForElement:(id<FBElement>)element
{
  return FBBoolToString(element.wdHittable);
}

@end

@implementation FBInternalIndexAttribute

+ (NSString *)name
{
  return kXMLIndexPathKey;
}

+ (int)recordWithWriter:(xmlTextWriterPtr)writer forValue:(NSString *)value
{
  if (nil == value) {
    // Skip the attribute if the value equals to nil
    return 0;
  }
  int rc = xmlTextWriterWriteAttribute(writer,
                                       (xmlChar *)[[FBXPath safeXmlStringWithString:[self name]] UTF8String],
                                       (xmlChar *)[[FBXPath safeXmlStringWithString:value] UTF8String]);
  if (rc < 0) {
    [FBLogger logFmt:@"Failed to invoke libxml2>xmlTextWriterWriteAttribute(%@='%@'). Error code: %d", [self name], value, rc];
  }
  return rc;
}
@end


@implementation FBPlaceholderValueAttribute

+ (NSString *)name
{
  return @"placeholderValue";
}

+ (NSString *)valueForElement:(id<FBElement>)element
{
  return element.wdPlaceholderValue;
}

@end

@implementation FBElementAttributeCache

+ (instancetype)sharedCache
{
  static FBElementAttributeCache *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[self alloc] init];
  });
  return instance;
}

- (instancetype)init
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _cache = [NSMutableDictionary dictionary];
  _expiry = [NSMutableDictionary dictionary];
  _maxSize = ATTRIBUTE_CACHE_SIZE;
  _expiryTime = ATTRIBUTE_CACHE_EXPIRY;
  return self;
}

- (void)setValue:(id)value forKey:(NSString *)key
{
  @synchronized (self.cache) {
    if (self.cache.count >= self.maxSize) {
      [self cleanup];
    }
    self.cache[key] = value;
    self.expiry[key] = @([[NSDate date] timeIntervalSince1970] + self.expiryTime);
  }
}

- (id)valueForKey:(NSString *)key
{
  @synchronized (self.cache) {
    NSNumber *expiryTime = self.expiry[key];
    if (expiryTime && [expiryTime doubleValue] > [[NSDate date] timeIntervalSince1970]) {
      return self.cache[key];
    }
    [self.cache removeObjectForKey:key];
    [self.expiry removeObjectForKey:key];
    return nil;
  }
}

- (void)cleanup
{
  @synchronized (self.cache) {
    NSDate *now = [NSDate date];
    NSMutableArray *keysToRemove = [NSMutableArray array];
    
    [self.expiry enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *expiryTime, BOOL *stop) {
      if ([expiryTime doubleValue] <= [now timeIntervalSince1970]) {
        [keysToRemove addObject:key];
      }
    }];
    
    [self.cache removeObjectsForKeys:keysToRemove];
    [self.expiry removeObjectsForKeys:keysToRemove];
  }
}

@end
