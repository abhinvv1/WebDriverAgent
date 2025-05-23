/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBDebugCommands.h"

#import "FBRouteRequest.h"
#import "FBSession.h"
#import "FBConfiguration.h"
#import "FBXMLGenerationOptions.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIElement+FBUtilities.h"
#import "FBXPath.h"
#import "FBLogger.h"
#import "FBElementCache.h"
#import "FBExceptions.h"
#import "FBResponseJSONPayload.h"
#import "XCUIElement+FBWebDriverAttributes.h"
#import "XCUIScreen.h"

#import "RNUiInspector.h"
#import "FBRNViewXMLConverter.h"
#import "XCUIApplication+FBGridSampling.h"
#import "FBRNViewXMLConverter.h"

@implementation FBDebugCommands

//typedef NS_ENUM(NSInteger, FBSourceOutputFormat) {
//  FBSourceOutputFormatXML,
//  FBSourceOutputFormatJSON,
//};
//
//static FBXMLGenerationOptions* FBExtractXMLOptions(id excludedAttributesParam, id<FBResponsePayload> * _Nullable errorResponse)
//{
//  FBXMLGenerationOptions *options = [FBXMLGenerationOptions new];
//  if ([excludedAttributesParam isKindOfClass:NSArray.class]) {
//    options.excludedAttributes = (NSArray<NSString *> *)excludedAttributesParam;
//  } else if (excludedAttributesParam != nil) {
//    if (errorResponse) {
//      *errorResponse = FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:[NSString stringWithFormat:@"Excluded attributes argument must be an array. Got '%@' instead", excludedAttributesParam] traceback:nil]);
//    }
//    return nil;
//  }
//  if (errorResponse) {
//    *errorResponse = nil;
//  }
//  return options;
//}
//
//static FBSourceOutputFormat FBDetermineOutputFormat(id requestedFormatParam, id<FBResponsePayload> * _Nullable errorResponse)
//{
//  if (errorResponse) {
//    *errorResponse = nil;
//  }
//  if ([requestedFormatParam isKindOfClass:NSString.class]) {
//    NSString *requestedFormatString = (NSString *)requestedFormatParam;
//    if ([requestedFormatString caseInsensitiveCompare:@"xml"] == NSOrderedSame) {
//      return FBSourceOutputFormatXML;
//    } else if ([requestedFormatString caseInsensitiveCompare:@"json"] == NSOrderedSame) {
//      return FBSourceOutputFormatJSON;
//    } else {
//      if (errorResponse) {
//        *errorResponse = FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:[NSString stringWithFormat:@"Unknown source format '%@'. Only 'xml' and 'json' source formats are supported.", requestedFormatString] traceback:nil]);
//      }
//      return FBSourceOutputFormatXML;
//    }
//  }
//  return FBSourceOutputFormatXML;
//}

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/source"] respondWithTarget:self action:@selector(handleGetSourceCommand:)],
    [[FBRoute GET:@"/source"].withoutSession respondWithTarget:self action:@selector(handleGetSourceCommand:)],
    [[FBRoute GET:@"/wda/accessibleSource"] respondWithTarget:self action:@selector(handleGetAccessibleSourceCommand:)],
    [[FBRoute GET:@"/wda/accessibleSource"].withoutSession respondWithTarget:self action:@selector(handleGetAccessibleSourceCommand:)],
  ];
}


#pragma mark - Commands

static NSString *const SOURCE_FORMAT_XML = @"xml";
static NSString *const SOURCE_FORMAT_JSON = @"json";
static NSString *const SOURCE_FORMAT_DESCRIPTION = @"description";

+ (id<FBResponsePayload>)handleGetSourceCommand:(FBRouteRequest *)request
{
  XCUIApplication *application = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
  NSString *sourceType = request.parameters[@"format"] ?: SOURCE_FORMAT_XML;
  NSString *format = request.parameters[@"format"];
    BOOL useGridSampling = [format isEqualToString:@"grid"] ||
                           [request.parameters[@"gridSampling"] boolValue];
    
    if (true) {
      [FBLogger logFmt:@"Using grid sampling for page source"];
      
      // Extract grid sampling parameters
      NSMutableDictionary *samplingParams = [NSMutableDictionary dictionary];
      
       samplingParams[@"samplesX"] = request.parameters[@"samplesX"];
       samplingParams[@"samplesY"] = request.parameters[@"samplesY"];
       samplingParams[@"maxRecursionDepth"] = request.parameters[@"maxRecursionDepth"];
       
      
      NSDictionary *gridSampledTree = [application fb_gridSampledTreeWithParameters:samplingParams];
      
      [FBLogger logFmt:@"gridSampledTree page source %@", gridSampledTree];
      
//      return FBResponseWithObject(gridSampledTree);
      
//      if (gridSampledTree != nil) {
//        FBResponseWithObject(gridSampledTree);
//      }
      
//      // Convert to XML if requested
//      NSString *formatType = request.parameters[@"format"] ?: @"json";
//      if ([formatType isEqualToString:@"xml"]) {
//        NSString *xmlSource = [FBRNViewXMLConverter xmlStringFromRNTree:gridSampledTree];
//        return FBResponseWithObject(xmlSource);
//      } else {
//        return FBResponseWithObject(gridSampledTree);
//      }
    }
    
    // Fall back to standard page source
  NSString *sourceScope = request.parameters[@"scope"];


  id result;
  if ([sourceType caseInsensitiveCompare:SOURCE_FORMAT_XML] == NSOrderedSame) {
    NSArray<NSString *> *excludedAttributes = nil == request.parameters[@"excluded_attributes"]
      ? nil
      : [request.parameters[@"excluded_attributes"] componentsSeparatedByString:@","];
    result = [application fb_xmlRepresentationWithOptions:
        [[[FBXMLGenerationOptions new]
          withExcludedAttributes:excludedAttributes]
         withScope:sourceScope]];
  } else if ([sourceType caseInsensitiveCompare:SOURCE_FORMAT_JSON] == NSOrderedSame) {
    NSString *excludedAttributesString = request.parameters[@"excluded_attributes"];
    NSSet<NSString *> *excludedAttributes = (excludedAttributesString == nil)
          ? nil
          : [NSSet setWithArray:[excludedAttributesString componentsSeparatedByString:@","]];

    result = [application fb_tree:excludedAttributes];
  } else if ([sourceType caseInsensitiveCompare:SOURCE_FORMAT_DESCRIPTION] == NSOrderedSame) {
    result = application.fb_descriptionRepresentation;
  } else {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:[NSString stringWithFormat:@"Unknown source format '%@'. Only %@ source formats are supported.",
                                                                                  sourceType, @[SOURCE_FORMAT_XML, SOURCE_FORMAT_JSON, SOURCE_FORMAT_DESCRIPTION]] traceback:nil]);
  }
  if (nil == result) {
    return FBResponseWithUnknownErrorFormat(@"Cannot get '%@' source of the current application", sourceType);
  }
  return FBResponseWithObject(result);
}

+ (id<FBResponsePayload>)handleGetAccessibleSourceCommand:(FBRouteRequest *)request
{
  // This method might be called without session
  XCUIApplication *application = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
  return FBResponseWithObject(application.fb_accessibilityTree ?: @{});
}

@end
