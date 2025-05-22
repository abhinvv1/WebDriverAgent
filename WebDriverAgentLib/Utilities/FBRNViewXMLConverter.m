/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBRNViewXMLConverter.h"
#import "FBXMLGenerationOptions.h" //
#import "NSString+FBXMLSafeString.h"

@implementation FBRNViewXMLConverter

// Helper method to recursively build XML string
static void appendXMLForNode(NSDictionary *node, NSMutableString *xmlString, FBXMLGenerationOptions *options, NSUInteger depth)
{
  if (!node || ![node isKindOfClass:[NSDictionary class]]) {
    return;
  }

  NSString *type = node[@"type"] ?: @"Unknown";
  NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
//  [xmlString appendFormat:@"%@<%@", indent, [type fb_xmlSafeString]];
  [xmlString appendFormat:@"%@<%@", indent, [type fb_xmlSafeStringWithReplacement:@""]];

  // Add attributes from the node, excluding 'children' and 'type'
  // and respecting options.excludedAttributes
  NSSet<NSString *> *excludedAttributesSet = options.excludedAttributes ? [NSSet setWithArray:options.excludedAttributes] : nil;

  for (NSString *key in node) {
    if ([key isEqualToString:@"children"] || [key isEqualToString:@"type"]) {
      continue;
    }
    if (excludedAttributesSet && [excludedAttributesSet containsObject:key]) {
      continue;
    }
    id value = node[key];
    if ([value isKindOfClass:[NSString class]]) {
//      [xmlString appendFormat:@" %@=\"%@\"", [key fb_xmlSafeString], [((NSString *)value) fb_xmlSafeString]];
      [xmlString appendFormat:@"%@<%@", [key fb_xmlSafeStringWithReplacement:@""], [((NSString *)value) fb_xmlSafeStringWithReplacement:@""]];

    } else if ([value isKindOfClass:[NSNumber class]]) {
      [xmlString appendFormat:@" %@=\"%@\"", [key fb_xmlSafeStringWithReplacement:@""], [((NSNumber *)value).stringValue fb_xmlSafeStringWithReplacement:@""]];
//      [xmlString appendFormat:@" %@=\"%@\"", [key fb_xmlSafeString], [((NSNumber *)value).stringValue fb_xmlSafeString]];
    }
    // Add more type handling if needed
  }

  NSArray *children = node[@"children"];
  if (children && [children isKindOfClass:[NSArray class]] && children.count > 0) {
    [xmlString appendString:@">\n"];
    for (NSDictionary *childNode in children) {
      appendXMLForNode(childNode, xmlString, options, depth + 1);
    }
    [xmlString appendFormat:@"%@</%@>\n", indent, [type fb_xmlSafeStringWithReplacement:@""]];
//    [xmlString appendFormat:@"%@</%@>\n", indent, [type fb_xmlSafeString]];
  } else {
    [xmlString appendString:@" />\n"];
  }
}

+ (nullable NSString *)xmlStringFromRNTree:(NSDictionary *)rnTree options:(FBXMLGenerationOptions *)options
{
  if (!rnTree) {
    return nil;
  }

  NSMutableString *xmlString = [NSMutableString string];
  [xmlString appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];

  FBXMLGenerationOptions *resolvedOptions = options ?: [FBXMLGenerationOptions new]; //

  if (resolvedOptions.scope) {
    [xmlString appendFormat:@"<%@>\n", [resolvedOptions.scope  fb_xmlSafeStringWithReplacement:@""]];
    
//    [xmlString appendFormat:@"<%@>\n", [resolvedOptions.scope fb_xmlSafeString]];
    appendXMLForNode(rnTree, xmlString, resolvedOptions, 1);
    
    [xmlString appendFormat:@"</%@>\n", [resolvedOptions.scope fb_xmlSafeStringWithReplacement:@""]];
//    [xmlString appendFormat:@"</%@>\n", [resolvedOptions.scope fb_xmlSafeString]];
  } else {
    appendXMLForNode(rnTree, xmlString, resolvedOptions, 0);
  }
  
  return [xmlString copy];
}

@end
