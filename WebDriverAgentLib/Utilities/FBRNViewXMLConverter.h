/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FBXMLGenerationOptions;

/**
 Converts a React Native element tree (NSDictionary) to an XML string.
 */
@interface FBRNViewXMLConverter : NSObject

/**
 Converts the given React Native element tree to an XML string.

 @param rnTree The React Native element tree (as an NSDictionary).
 @param options XML generation options.
 @return An XML string representation of the React Native tree.
         Returns nil if conversion fails.
 */
+ (nullable NSString *)xmlStringFromRNTree:(NSDictionary *)rnTree options:(FBXMLGenerationOptions *)options;

@end

NS_ASSUME_NONNULL_END
