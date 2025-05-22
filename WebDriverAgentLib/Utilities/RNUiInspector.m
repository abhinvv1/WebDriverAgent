//
//  RNUiInspector.m
//  WebDriverAgentLib
//
//  Created by Abhinav Pandey on 18/05/25.
//  Adapted for WebDriverAgent: Fetches UI tree from an in-AUT HTTP server.
//

#import "RNUiInspector.h"
#import "FBLogger.h"

NSString * const LOG_PREFIX_RN_HTTP_CLIENT = @"[RNUiInspector_HttpClient] ";

extern NSString * const kRNUiInspectorNativeHandleKey;
 NSString * const kRNUiInspectorNativeHandleKey = @"nativeHandle";


@implementation RNUiInspector

+ (nullable NSDictionary *)fetchUiTreeFromAUTServerAtURL:(NSURL *)serverURL error:(NSError **)error {
    if (!serverURL) {
        if (error) {
            *error = [NSError errorWithDomain:@"RNUiInspectorErrorDomain"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Server URL cannot be nil."}];
        }
        NSLog(@"%@Server URL is nil.", LOG_PREFIX_RN_HTTP_CLIENT);
        return nil;
    }

    NSLog(@"%@Fetching UI tree from AUT server at: %@", LOG_PREFIX_RN_HTTP_CLIENT, serverURL.absoluteString);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:serverURL
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:10.0];
    [request setHTTPMethod:@"GET"];

    NSURLResponse *response = nil;
    NSError *networkError = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&networkError];

    if (networkError) {
        if (error) {
            *error = networkError;
        }
        NSLog(@"%@Network error fetching UI tree: %@", LOG_PREFIX_RN_HTTP_CLIENT, networkError.localizedDescription);
        return nil;
    }

    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            NSString *errorDescription = [NSString stringWithFormat:@"Server returned status code %ld. Response data: %@",
                                          (long)httpResponse.statusCode,
                                          [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"(no data)"];
            if (error) {
                *error = [NSError errorWithDomain:@"RNUiInspectorErrorDomain"
                                             code:httpResponse.statusCode
                                         userInfo:@{NSLocalizedDescriptionKey: errorDescription}];
            }
            NSLog(@"%@%@", LOG_PREFIX_RN_HTTP_CLIENT, errorDescription);
            return nil;
        }
    }

    if (!data || data.length == 0) {
        NSString *errorDescription = @"No data received from server.";
        if (error) {
            *error = [NSError errorWithDomain:@"RNUiInspectorErrorDomain"
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: errorDescription}];
        }
        NSLog(@"%@%@", LOG_PREFIX_RN_HTTP_CLIENT, errorDescription);
        return nil;
    }

    NSError *jsonError = nil;
    id jsonObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

    if (jsonError) {
        if (error) {
            *error = jsonError;
        }
        NSLog(@"%@JSON parsing error: %@. Raw data: %@", LOG_PREFIX_RN_HTTP_CLIENT, jsonError.localizedDescription, [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"(empty)");
        return nil;
    }

    if (![jsonObject isKindOfClass:[NSDictionary class]]) {
        NSString *errorDescription = @"Fetched JSON root is not a dictionary.";
        if (error) {
            *error = [NSError errorWithDomain:@"RNUiInspectorErrorDomain"
                                         code:1003
                                     userInfo:@{NSLocalizedDescriptionKey: errorDescription}];
        }
        NSLog(@"%@%@", LOG_PREFIX_RN_HTTP_CLIENT, errorDescription);
        return nil;
    }

    NSDictionary *serverResponse = (NSDictionary *)jsonObject;
    NSString *status = serverResponse[@"status"];
    if (![status isKindOfClass:[NSString class]] || ![status isEqualToString:@"success"]) {
        NSString *errorDescription = [NSString stringWithFormat:@"Server response status was not 'success'. Status: %@. Full response: %@", status ?: @"(nil)", serverResponse];
        if (error) {
            *error = [NSError errorWithDomain:@"RNUiInspectorErrorDomain"
                                         code:1004
                                     userInfo:@{NSLocalizedDescriptionKey: errorDescription}];
        }
        NSLog(@"%@%@", LOG_PREFIX_RN_HTTP_CLIENT, errorDescription);
        return nil;
    }

    NSDictionary *uiTree = serverResponse[@"data"];
    if (![uiTree isKindOfClass:[NSDictionary class]]) {
        NSString *errorDescription = [NSString stringWithFormat:@"'data' field in server response is not a dictionary. Full response: %@", serverResponse];
        if (error) {
            *error = [NSError errorWithDomain:@"RNUiInspectorErrorDomain"
                                         code:1005
                                     userInfo:@{NSLocalizedDescriptionKey: errorDescription}];
        }
        NSLog(@"%@%@", LOG_PREFIX_RN_HTTP_CLIENT, errorDescription);
        return nil;
    }

    NSLog(@"%@Successfully fetched, parsed, and extracted UI tree from AUT server's 'data' field.", LOG_PREFIX_RN_HTTP_CLIENT);
    return uiTree;
}

@end
