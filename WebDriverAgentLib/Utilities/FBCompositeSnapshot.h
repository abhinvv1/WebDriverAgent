#import <Foundation/Foundation.h>
#import <WebDriverAgentLib/FBXCElementSnapshot.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBCompositeSnapshot : NSObject <FBXCElementSnapshot>

@property (nonatomic, strong, readonly) id<FBXCElementSnapshot> baseSnapshot;
@property (nonatomic, strong, readonly) NSArray<id<FBXCElementSnapshot>> *children;

- (instancetype)initWithBaseSnapshot:(id<FBXCElementSnapshot>)baseSnapshot
                            children:(NSArray<id<FBXCElementSnapshot>> *)children;

@end

NS_ASSUME_NONNULL_END
