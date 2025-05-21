/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBElementCache.h"

#import "LRUCache.h"
#import "FBAlert.h"
#import "FBExceptions.h"
#import "FBXCodeCompatibility.h"
#import "XCTestPrivateSymbols.h"
#import "XCUIElement.h"
#import "XCUIElement+FBCaching.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIElement+FBWebDriverAttributes.h"
#import "XCUIElement+FBUID.h"
#import "XCUIElement+FBResolve.h"
#import "XCUIElementQuery.h"
#import <mach/mach.h>
#import <mach/mach_host.h>

// Default cache size
const int ELEMENT_CACHE_SIZE = 1024;
// Minimum cache size when under memory pressure
const int MIN_CACHE_SIZE = 256;
// Memory pressure threshold (in MB)
const double MEMORY_PRESSURE_THRESHOLD = 100.0;

@interface FBElementCache ()
@property (nonatomic, strong) LRUCache *elementCache;
@property (nonatomic) NSUInteger currentCacheSize;
@end

@implementation FBElementCache

- (instancetype)init
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _currentCacheSize = ELEMENT_CACHE_SIZE;
  _elementCache = [[LRUCache alloc] initWithCapacity:_currentCacheSize];
  [self registerForMemoryPressureNotifications];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)registerForMemoryPressureNotifications
{
  [[NSNotificationCenter defaultCenter] addObserver:self
                                         selector:@selector(handleMemoryWarning:)
                                             name:UIApplicationDidReceiveMemoryWarningNotification
                                           object:nil];
}

- (void)handleMemoryWarning:(NSNotification *)notification
{
  [self adjustCacheSizeForMemoryPressure];
}

- (void)adjustCacheSizeForMemoryPressure
{
  double availableMemory = [self getAvailableMemoryInMB];
  if (availableMemory < MEMORY_PRESSURE_THRESHOLD) {
    // Reduce cache size when under memory pressure
    NSUInteger newSize = MAX(MIN_CACHE_SIZE, _currentCacheSize / 2);
    if (newSize != _currentCacheSize) {
      _currentCacheSize = newSize;
      [self resizeCache];
    }
  } else {
    // Restore cache size when memory pressure is relieved
    if (_currentCacheSize < ELEMENT_CACHE_SIZE) {
      _currentCacheSize = ELEMENT_CACHE_SIZE;
      [self resizeCache];
    }
  }
}

- (void)resizeCache
{
  @synchronized (self.elementCache) {
    LRUCache *newCache = [[LRUCache alloc] initWithCapacity:_currentCacheSize];
    NSArray *allObjects = [self.elementCache allObjects];
    for (id object in allObjects) {
      NSString *uuid = [object fb_cacheId];
      if (uuid) {
        [newCache setObject:object forKey:uuid];
      }
    }
    self.elementCache = newCache;
  }
}

- (double)getAvailableMemoryInMB
{
  mach_port_t host_port = mach_host_self();
  mach_msg_type_number_t host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
  vm_size_t page_size;
  vm_statistics_data_t vm_stats;
  
  host_page_size(host_port, &page_size);
  host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stats, &host_size);
  
  natural_t mem_free = vm_stats.free_count * page_size;
  return (double)mem_free / (1024 * 1024);
}

- (void)clearCache
{
  @synchronized (self.elementCache) {
    self.elementCache = [[LRUCache alloc] initWithCapacity:_currentCacheSize];
  }
}

- (NSString *)storeElement:(XCUIElement *)element
{
  NSString *uuid = element.fb_cacheId;
  if (nil == uuid) {
    return nil;
  }
  @synchronized (self.elementCache) {
    [self.elementCache setObject:element forKey:uuid];
  }
  return uuid;
}

- (XCUIElement *)elementForUUID:(NSString *)uuid
{
  return [self elementForUUID:uuid checkStaleness:NO];
}

- (XCUIElement *)elementForUUID:(NSString *)uuid checkStaleness:(BOOL)checkStaleness
{
  if (!uuid) {
    NSString *reason = [NSString stringWithFormat:@"Cannot extract cached element for UUID: %@", uuid];
    @throw [NSException exceptionWithName:FBInvalidArgumentException reason:reason userInfo:@{}];
  }

  XCUIElement *element;
  @synchronized (self.elementCache) {
    element = [self.elementCache objectForKey:uuid];
  }
  if (nil == element) {
    NSString *reason = [NSString stringWithFormat:@"The element identified by \"%@\" is either not present or it has expired from the internal cache. Try to find it again", uuid];
    @throw [NSException exceptionWithName:FBStaleElementException reason:reason userInfo:@{}];
  }
  if (checkStaleness) {
    @try {
      [element fb_standardSnapshot];
    } @catch (NSException *exception) {
      //  if the snapshot method threw FBStaleElementException (implying the element is stale) we need to explicitly remove it from the cache, PR: https://github.com/appium/WebDriverAgent/pull/985
      if ([exception.name isEqualToString:FBStaleElementException]) {
        @synchronized (self.elementCache) {
          [self.elementCache removeObjectForKey:uuid];
        }
      }
      @throw exception;
    }
  }
  return element;
}

- (BOOL)hasElementWithUUID:(NSString *)uuid
{
  if (nil == uuid) {
    return NO;
  }
  @synchronized (self.elementCache) {
    return nil != [self.elementCache objectForKey:(NSString *)uuid];
  }
}

@end
