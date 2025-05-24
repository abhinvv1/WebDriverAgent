#import <Foundation/Foundation.h>
#import <WebDriverAgentLib/FBXCElementSnapshot.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBGridSampledXMLConverter : NSObject

/**
 * Converts a grid-sampled snapshot tree to XML page source
 */
+ (NSString *)xmlStringFromGridSampledSnapshot:(id<FBXCElementSnapshot>)rootSnapshot;

@end

NS_ASSUME_NONNULL_END
