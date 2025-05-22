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

@class XCUIApplication;

/**
 Utility to inspect React Native UI hierarchy using private XCTest APIs.
 */
@interface RNUiInspector : NSObject

/**
 Retrieves the React Native element tree for the given application.

 @param application The application to inspect.
 @return A dictionary representing the React Native element tree.
         Returns nil if the tree cannot be retrieved.
 */
+ (nullable NSDictionary *)treeForApplication:(XCUIApplication *)application;

@end

NS_ASSUME_NONNULL_END
