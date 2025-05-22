//
//  FBRNViewXMLConverter.m
//  WebDriverAgent
//
//  Created by Abhinav Pandey on 22/05/25.
//  Copyright © 2025 Facebook. All rights reserved.
//

#import "FBRNViewXMLConverter.h"
#import "RNUiInspector.h"
#import "NSString+FBXMLSafeString.h"
#import "FBElementTypeTransformer.h"
#import "FBXMLGenerationOptions.h"
#import "FBLogger.h"
#import <UIKit/UIKit.h>

static void FB_AppendRNNodeToXMLRecursive(NSDictionary *node, NSMutableString *xmlString, FBXMLGenerationOptions *options, NSUInteger *elementUIDFallbackCounter, NSString *parentUID);

static NSString *FB_GetRNElementTypeStringFromNode(NSDictionary *rnNode) {
    NSString *rnType = [rnNode[@"type"] description];
    if (!rnType || rnType.length == 0) {
        return [FBElementTypeTransformer shortStringWithElementType:XCUIElementTypeOther];
    }

    if ([rnType isEqualToString:@"Button"] || [rnType containsString:@"Button"]) {
        return [FBElementTypeTransformer shortStringWithElementType:XCUIElementTypeButton];
    } else if ([rnType isEqualToString:@"Text"] || [rnType hasPrefix:@"RCTText"] || [rnType hasPrefix:@"ABIYYYText"]) {
        return [FBElementTypeTransformer shortStringWithElementType:XCUIElementTypeStaticText];
    } else if ([rnType isEqualToString:@"TextInput"] || [rnType hasPrefix:@"RCTTextInput"] || [rnType hasPrefix:@"ABIYYYTextInput"]) {
        NSDictionary *props = rnNode[@"props"];
        if (props && [props[@"multiline"] boolValue]) {
            return [FBElementTypeTransformer shortStringWithElementType:XCUIElementTypeTextView];
        }
        return [FBElementTypeTransformer shortStringWithElementType:XCUIElementTypeTextField];
    } else if ([rnType isEqualToString:@"Image"] || [rnType hasPrefix:@"RCTImage"] || [rnType hasPrefix:@"ABIYYYImage"]) {
        return [FBElementTypeTransformer shortStringWithElementType:XCUIElementTypeImage];
    } else if ([rnType isEqualToString:@"View"] || [rnType hasPrefix:@"RCTView"] || [rnType hasPrefix:@"ABIYYYView"]) {
        return [FBElementTypeTransformer shortStringWithElementType:XCUIElementTypeOther];
    } else if ([rnType isEqualToString:@"ScrollView"] || [rnType hasPrefix:@"RCTScrollView"] || [rnType hasPrefix:@"ABIYYYScrollView"]) {
        return [FBElementTypeTransformer shortStringWithElementType:XCUIElementTypeScrollView];
    }
    NSString *sanitizedRNType = [[rnType componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
    if (sanitizedRNType.length > 0) {
        return sanitizedRNType;
    }
    return [FBElementTypeTransformer shortStringWithElementType:XCUIElementTypeOther];
}

static NSString *FB_ConvertRNDictToRectXMLAttributesString(NSDictionary *rectDict) {
    if (!rectDict || ![rectDict isKindOfClass:[NSDictionary class]]) return @"";
    CGFloat x = [rectDict[@"x"] floatValue];
    CGFloat y = [rectDict[@"y"] floatValue];
    CGFloat width = [rectDict[@"width"] floatValue];
    CGFloat height = [rectDict[@"height"] floatValue];
    return [NSString stringWithFormat:@" x=\"%.f\" y=\"%.f\" width=\"%.f\" height=\"%.f\"", x, y, width, height];
}


static void FB_AppendRNNodeToXMLRecursive(NSDictionary *node, NSMutableString *xmlString, FBXMLGenerationOptions *options, NSUInteger *elementUIDFallbackCounter, NSString *parentUID) {
    if (!node || ![node isKindOfClass:[NSDictionary class]]) return;

    NSString *elementType = FB_GetRNElementTypeStringFromNode(node);
    NSMutableString *attributes = [NSMutableString string];

    id name = node[@"name"];
    if (name && [name isKindOfClass:[NSString class]] && ((NSString *)name).length > 0) {
      [
        attributes appendFormat:@" name=\"%@\"",
        [(NSString*)name fb_xmlSafeStringWithReplacement:@""]
      ];
    }

    id label = node[@"label"];
    if (label && [label isKindOfClass:[NSString class]] && ((NSString *)label).length > 0) {
      [
        attributes appendFormat:@" label=\"%@\"",
        [(NSString*)label fb_xmlSafeStringWithReplacement:@""]
      ];
    }
    
    id value = node[@"value"];
    if (!value && node[@"text"]) {
        value = node[@"text"];
    }
    if (value) {
        NSString *stringValue = [value description];
        if (options && false && // proper property add karni hai yahape
            ([elementType isEqualToString:[FBElementTypeTransformer shortStringWithElementType:XCUIElementTypeSecureTextField]] ||
             (name && [[(NSString*)name lowercaseString] containsString:@"password"]))) {
            stringValue = [@"" stringByPaddingToLength:stringValue.length withString:@"*" startingAtIndex:0];
        }
        [
          attributes appendFormat:@" value=\"%@\"",
          [stringValue fb_xmlSafeStringWithReplacement:@""]
        ];
    }
    
    id placeholder = node[@"placeholder"];
    if (placeholder && [placeholder isKindOfClass:[NSString class]] && ((NSString *)placeholder).length > 0) {
      [
        attributes appendFormat:@" placeholder=\"%@\"",
        [(NSString*)placeholder fb_xmlSafeStringWithReplacement:@""]
      ];
    }

    NSDictionary *rect = node[@"rect"];
    [attributes appendString:FB_ConvertRNDictToRectXMLAttributesString(rect)];

  NSString *uid = node[kRNUiInspectorNativeHandleKey];
    if (!uid || ![uid isKindOfClass:[NSString class]] || uid.length == 0) {
        uid = [NSString stringWithFormat:@"RN_generated_%@_%lu", parentUID ?: @"root", (unsigned long)(*elementUIDFallbackCounter)++];
        [FBLogger logFmt:@"Warning: Missing nativeHandle for node: %@. Generated fallback UID: %@", node[@"type"], uid];
    }
    [
      attributes appendFormat:@" UID=\"%@\"",
      [uid fb_xmlSafeStringWithReplacement:@""]
    ];

    BOOL isVisible = [node[@"visible"] boolValue];
    BOOL isEnabled = [node[@"enabled"] boolValue];
    
    [attributes appendFormat:@" visible=\"%@\"", isVisible ? @"true" : @"false"];
    [attributes appendFormat:@" enabled=\"%@\"", isEnabled ? @"true" : @"false"];
    
    // Type attribute (already used for the tag name, but can be added as an attribute too if desired for clarity)
    // [attributes appendFormat:@" type=\"%@\"", elementType];

    [xmlString appendFormat:@"<%@%@", elementType, attributes];

    NSArray *children = node[@"children"];
    if (children && [children isKindOfClass:[NSArray class]] && children.count > 0) {
        [xmlString appendString:@">\n"];
        for (NSDictionary *childNode in children) {
            FB_AppendRNNodeToXMLRecursive(childNode, xmlString, options, elementUIDFallbackCounter, uid);
        }
        [xmlString appendFormat:@"</%@>\n", elementType];
    } else {
        [xmlString appendString:@" />\n"];
    }
}


@implementation FBRNViewXMLConverter

+ (nullable NSString *)xmlStringFromRNTree:(NSDictionary *)rnTree options:(nullable FBXMLGenerationOptions *)options {
    if (!rnTree || rnTree.count == 0) {
        [FBLogger log:@"React Native tree is nil or empty. Cannot generate XML."];
        return nil;
    }

    NSMutableString *xmlOutput = [NSMutableString string];
    [xmlOutput appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    
    NSUInteger uidFallbackCounter = 0;
    FB_AppendRNNodeToXMLRecursive(rnTree, xmlOutput, options, &uidFallbackCounter, @"app");
    
    return [xmlOutput copy];
}

@end
