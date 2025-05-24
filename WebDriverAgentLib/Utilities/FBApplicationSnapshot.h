//
//  FBApplicationSnapshot.h
//  WebDriverAgent
//
//  Created by Abhinav Pandey on 24/05/25.
//  Copyright © 2025 Facebook. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>
#import <WebDriverAgentLib/FBXCElementSnapshot.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBApplicationSnapshot : NSObject <FBXCElementSnapshot>

@property (nonatomic, strong, readonly) XCUIApplication *application;
@property (nonatomic, strong) NSArray<id<FBXCElementSnapshot>> *children;

- (instancetype)initWithApplication:(XCUIApplication *)application;

@end

NS_ASSUME_NONNULL_END
