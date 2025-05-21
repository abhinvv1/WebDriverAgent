#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBElementAttributeManager : NSObject

@property (nonatomic, readonly) NSUInteger maxCacheSize;
@property (nonatomic, readonly) NSTimeInterval cacheExpiryTime;

+ (instancetype)sharedManager;

- (void)setAttributeValue:(id)value forKey:(NSString *)key element:(XCUIElement *)element;
- (nullable id)attributeValueForKey:(NSString *)key element:(XCUIElement *)element;
- (void)clearCache;
- (void)clearCacheForElement:(XCUIElement *)element;
- (void)setMaxCacheSize:(NSUInteger)size;
- (void)setCacheExpiryTime:(NSTimeInterval)time;

@end

NS_ASSUME_NONNULL_END 