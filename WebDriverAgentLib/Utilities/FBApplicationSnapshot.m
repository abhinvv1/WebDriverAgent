//
//  FBApplicationSnapshot.m
//  WebDriverAgent
//
//  Created by Abhinav Pandey on 24/05/25.
//  Copyright © 2025 Facebook. All rights reserved.
//

#import "FBApplicationSnapshot.h"
#import "FBElementTypeTransformer.h"

#import "FBApplicationSnapshot.h"
#import "FBElementTypeTransformer.h"

@interface FBApplicationSnapshot ()
@property (nonatomic, strong, readwrite) XCUIApplication *application;
@end

@implementation FBApplicationSnapshot

- (instancetype)initWithApplication:(XCUIApplication *)application {
    if ((self = [super init])) {
        self.application = application;
        self.children = @[];
    }
    return self;
}

#pragma mark - FBXCElementSnapshot Protocol Implementation

- (XCUIElementType)elementType {
    return XCUIElementTypeApplication;
}

- (CGRect)frame {
    return self.application.frame;
}

- (CGRect)visibleFrame {
    return self.application.frame;
}

- (NSString *)identifier {
    return self.application.identifier ?: @"";
}

- (NSString *)label {
    return self.application.label ?: @"";
}

- (NSString *)title {
    return self.application.title ?: @"";
}

- (id)value {
    return @"";
}

- (NSString *)placeholderValue {
    return nil;
}

- (BOOL)enabled {
    return self.application.isEnabled;
}

- (BOOL)selected {
    return NO;
}

- (BOOL)hasFocus {
    return YES;
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    return self.application;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector] || [self.application respondsToSelector:aSelector];
}

@synthesize compactDescription;

@synthesize depth;

@synthesize enabled;

@synthesize generation;

@synthesize hasFocus;

@synthesize hasKeyboardFocus;

@synthesize additionalAttributes;

@synthesize hitPoint;

@synthesize hitPointForScrolling;

@synthesize horizontalSizeClass;

@synthesize identifiers;

@synthesize isMainWindow;

@synthesize isTopLevelTouchBarElement;

@synthesize isTouchBarElement;

@synthesize parent;

@synthesize parentAccessibilityElement;

@synthesize pathDescription;

@synthesize pathFromRoot;

@synthesize accessibilityElement;

@synthesize recursiveDescription;

@synthesize recursiveDescriptionIncludingAccessibilityElement;

@synthesize scrollView;

@synthesize selected;

@synthesize sparseTreeDescription;

@synthesize suggestedHitpoints;

@synthesize traits;

@synthesize truncatedValueString;

@synthesize userTestingAttributes;

@synthesize verticalSizeClass;

@synthesize children;

@end
