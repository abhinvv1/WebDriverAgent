//
//  FBCompositeSnapshot.m
//  WebDriverAgent
//
//  Created by Abhinav Pandey on 24/05/25.
//  Copyright © 2025 Facebook. All rights reserved.
//

#import "FBCompositeSnapshot.h"

@interface FBCompositeSnapshot ()
@property (nonatomic, strong, readwrite) id<FBXCElementSnapshot> baseSnapshot;
@property (nonatomic, strong, readwrite) NSArray<id<FBXCElementSnapshot>> *children;
@end

@implementation FBCompositeSnapshot

- (instancetype)initWithBaseSnapshot:(id<FBXCElementSnapshot>)baseSnapshot
                            children:(NSArray<id<FBXCElementSnapshot>> *)children {
    if ((self = [super init])) {
        self.baseSnapshot = baseSnapshot;
        self.children = children ?: @[];
    }
    return self;
}

#pragma mark - FBXCElementSnapshot Protocol Implementation

- (XCUIElementType)elementType {
    return self.baseSnapshot.elementType;
}

- (CGRect)frame {
    return self.baseSnapshot.frame;
}

- (CGRect)visibleFrame {
    return self.baseSnapshot.visibleFrame;
}

- (NSString *)identifier {
    return self.baseSnapshot.identifier;
}

- (NSString *)label {
    return self.baseSnapshot.label;
}

- (NSString *)title {
    return self.baseSnapshot.title;
}

- (id)value {
    return self.baseSnapshot.value;
}

- (NSString *)placeholderValue {
    if ([self.baseSnapshot respondsToSelector:@selector(placeholderValue)]) {
        return self.baseSnapshot.placeholderValue;
    }
    return nil;
}

- (BOOL)enabled {
    return self.baseSnapshot.enabled;
}

- (BOOL)selected {
    if ([self.baseSnapshot respondsToSelector:@selector(selected)]) {
        return self.baseSnapshot.selected;
    }
    return NO;
}

- (BOOL)hasFocus {
    if ([self.baseSnapshot respondsToSelector:@selector(hasFocus)]) {
        return self.baseSnapshot.hasFocus;
    }
    return NO;
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    if ([self.baseSnapshot respondsToSelector:[anInvocation selector]]) {
        [anInvocation invokeWithTarget:self.baseSnapshot];
    } else {
        [super forwardInvocation:anInvocation];
    }
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector] || [self.baseSnapshot respondsToSelector:aSelector];
}

@synthesize additionalAttributes;

@synthesize application;

@synthesize compactDescription;

@synthesize depth;

@synthesize enabled;

@synthesize generation;

@synthesize hasFocus;

@synthesize hasKeyboardFocus;

@synthesize hitPoint;

@synthesize hitPointForScrolling;

@synthesize accessibilityElement;

@synthesize horizontalSizeClass;

@synthesize identifiers;

@synthesize isMainWindow;

@synthesize isTopLevelTouchBarElement;

@synthesize isTouchBarElement;

@synthesize parent;

@synthesize parentAccessibilityElement;

@synthesize pathDescription;

@synthesize pathFromRoot;

@synthesize recursiveDescription;

@synthesize scrollView;

@synthesize selected;

@synthesize sparseTreeDescription;

@synthesize suggestedHitpoints;

@synthesize traits;

@synthesize truncatedValueString;

@synthesize userTestingAttributes;

@synthesize verticalSizeClass;

@synthesize recursiveDescriptionIncludingAccessibilityElement;

@end
