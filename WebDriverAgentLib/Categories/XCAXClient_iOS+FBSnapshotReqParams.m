/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "XCAXClient_iOS+FBSnapshotReqParams.h"

#import <objc/runtime.h>

/**
 Available parameters with their default values for XCTest:
  @"maxChildren" : (int)2147483647
  @"traverseFromParentsToChildren" : YES
  @"maxArrayCount" : (int)2147483647
  @"snapshotKeyHonorModalViews" : NO
  @"maxDepth" : (int)2147483647
 */
NSString *const FBSnapshotMaxDepthKey = @"maxDepth";
NSString *const FBSnapshotMaxChildrenKey = @"maxChildren";
NSString *const FBSnapshotMaxArrayCountKey = @"maxArrayCount";

static id (*original_defaultParameters)(id, SEL);
static id (*original_snapshotParameters)(id, SEL);
static NSDictionary *defaultRequestParameters;
static NSDictionary *defaultAdditionalRequestParameters;
static NSMutableDictionary *customRequestParameters;
static NSMutableDictionary *snapshotParameterCache;
static NSMutableDictionary *snapshotParameterExpiry;

#define SNAPSHOT_PARAM_CACHE_SIZE 100
#define SNAPSHOT_PARAM_EXPIRY 60.0 // seconds

@interface FBSnapshotParameterManager : NSObject

@property (nonatomic, strong) NSMutableDictionary *cache;
@property (nonatomic, strong) NSMutableDictionary *expiry;
@property (nonatomic) NSUInteger maxSize;
@property (nonatomic) NSTimeInterval expiryTime;

+ (instancetype)sharedManager;
- (void)setParameters:(NSDictionary *)parameters forElementType:(XCUIElementType)type;
- (NSDictionary *)parametersForElementType:(XCUIElementType)type;
- (void)cleanup;

@end

@implementation FBSnapshotParameterManager

+ (instancetype)sharedManager
{
  static FBSnapshotParameterManager *instance = nil;
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
  _maxSize = SNAPSHOT_PARAM_CACHE_SIZE;
  _expiryTime = SNAPSHOT_PARAM_EXPIRY;
  return self;
}

- (void)setParameters:(NSDictionary *)parameters forElementType:(XCUIElementType)type
{
  @synchronized (self.cache) {
    if (self.cache.count >= self.maxSize) {
      [self cleanup];
    }
    NSString *key = [NSString stringWithFormat:@"%lu", (unsigned long)type];
    self.cache[key] = parameters;
    self.expiry[key] = @([[NSDate date] timeIntervalSince1970] + self.expiryTime);
  }
}

- (NSDictionary *)parametersForElementType:(XCUIElementType)type
{
  @synchronized (self.cache) {
    NSString *key = [NSString stringWithFormat:@"%lu", (unsigned long)type];
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

void FBSetCustomParameterForElementSnapshot(NSString *name, id value)
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    customRequestParameters = [NSMutableDictionary new];
  });
  customRequestParameters[name] = value;
}

id FBGetCustomParameterForElementSnapshot(NSString *name)
{
  return customRequestParameters[name];
}

static NSDictionary *getOptimizedParametersForElementType(XCUIElementType type)
{
  FBSnapshotParameterManager *manager = [FBSnapshotParameterManager sharedManager];
  NSDictionary *cachedParams = [manager parametersForElementType:type];
  if (cachedParams) {
    return cachedParams;
  }
  
  // Define optimized parameters based on element type
  NSMutableDictionary *params = [NSMutableDictionary dictionary];
  
  // Set default values
  params[FBSnapshotMaxDepthKey] = @50;
  params[FBSnapshotMaxChildrenKey] = @100;
  params[FBSnapshotMaxArrayCountKey] = @100;
  
  // Adjust parameters based on element type
  switch (type) {
    case XCUIElementTypeApplication:
      params[FBSnapshotMaxDepthKey] = @100;
      params[FBSnapshotMaxChildrenKey] = @500;
      break;
      
    case XCUIElementTypeWindow:
      params[FBSnapshotMaxDepthKey] = @50;
      params[FBSnapshotMaxChildrenKey] = @200;
      break;
      
    case XCUIElementTypeScrollView:
      params[FBSnapshotMaxDepthKey] = @30;
      params[FBSnapshotMaxChildrenKey] = @100;
      break;
      
    case XCUIElementTypeTable:
      params[FBSnapshotMaxDepthKey] = @20;
      params[FBSnapshotMaxChildrenKey] = @50;
      break;
      
    default:
      params[FBSnapshotMaxDepthKey] = @10;
      params[FBSnapshotMaxChildrenKey] = @20;
      break;
  }
  
  // Cache the parameters
  [manager setParameters:params forElementType:type];
  
  return params;
}

static id swizzledDefaultParameters(id self, SEL _cmd)
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    defaultRequestParameters = original_defaultParameters(self, _cmd);
  });
  
  NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:defaultRequestParameters];
  [result addEntriesFromDictionary:defaultAdditionalRequestParameters ?: @{}];
  [result addEntriesFromDictionary:customRequestParameters ?: @{}];
  
  // Add optimized parameters if element type is available
  if ([self isKindOfClass:[XCUIElement class]]) {
    XCUIElementType type = [(XCUIElement *)self elementType];
    [result addEntriesFromDictionary:getOptimizedParametersForElementType(type)];
  }
  
  return result.copy;
}

static id swizzledSnapshotParameters(id self, SEL _cmd)
{
  NSDictionary *result = original_snapshotParameters(self, _cmd);
  defaultAdditionalRequestParameters = result;
  return result;
}

@implementation XCAXClient_iOS (FBSnapshotReqParams)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-load-method"
#pragma clang diagnostic ignored "-Wcast-function-type-strict"

+ (void)load
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    Class class = [self class];
    
    Method originalMethod = class_getClassMethod(class, @selector(defaultParameters));
    Method swizzledMethod = class_getClassMethod(class, @selector(swizzledDefaultParameters));
    original_defaultParameters = (id (*)(id, SEL))method_getImplementation(originalMethod);
    method_exchangeImplementations(originalMethod, swizzledMethod);
    
    originalMethod = class_getClassMethod(class, @selector(snapshotParameters));
    swizzledMethod = class_getClassMethod(class, @selector(swizzledSnapshotParameters));
    original_snapshotParameters = (id (*)(id, SEL))method_getImplementation(originalMethod);
    method_exchangeImplementations(originalMethod, swizzledMethod);
  });
}

#pragma clang diagnostic pop

@end
