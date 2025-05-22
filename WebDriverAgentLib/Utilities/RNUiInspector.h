//
//  RNUiInspector.h
//  WebDriverAgentLib
//
//  Created by Abhinav Pandey on 18/05/25.
//  Adapted for WebDriverAgent: Fetches UI tree from an in-AUT HTTP server.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

 extern NSString * const kRNUiInspectorNativeHandleKey;

@interface RNUiInspector : NSObject

+ (nullable NSDictionary *)fetchUiTreeFromAUTServerAtURL:(NSURL *)serverURL error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
