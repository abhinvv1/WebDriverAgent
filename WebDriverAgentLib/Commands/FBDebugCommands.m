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
  NSString *sourceScope = request.parameters[@"scope"];

//  id<FBResponsePayload> formatError = nil;
//  FBSourceOutputFormat outputFormat = FBDetermineOutputFormat(request.arguments[@"format"], &formatError);
//  if (formatError) {
//    return formatError;
//  }
//
//  id<FBResponsePayload> optionsError = nil;
//  FBXMLGenerationOptions *xmlOptions = FBExtractXMLOptions(request.arguments[@"excludedAttributes"], &optionsError);
//  if (optionsError) {
//    return optionsError;
//  }
  
  [FBLogger logFmt:@"Attempting to generate React Native page source."];
    id result;

  NSDictionary *rnTree = [RNUiInspector treeForApplication:application];
      if (!rnTree) {
        return FBResponseWithUnknownErrorFormat(@"Cannot get React Native source of the current application. RN Tree was nil.");
      }
  
      [FBLogger logFmt:@"React Native page source. %@", rnTree];

      NSArray<NSString *> *excludedAttributes = nil == request.parameters[@"excluded_attributes"]
        ? nil
        : [request.parameters[@"excluded_attributes"] componentsSeparatedByString:@","];
      FBXMLGenerationOptions *xmlOptions = [[[FBXMLGenerationOptions new]
                                             withExcludedAttributes:excludedAttributes] //
                                            withScope:sourceScope]; //

//      NSString *rnXmlSource = [FBRNViewXMLConverter xmlStringFromRNTree:rnTree options:xmlOptions];
//      result = rnXmlSource;
    return FBResponseWithObject(rnTree);
//  NSURL *autServerURL = [NSURL URLWithString:@"http://localhost:8082/tree"];
//
//  @try {
//      rnTree = [RNUiInspector fetchUiTreeFromAUTServerAtURL:autServerURL error:&fetchError];
//    } @catch (NSException *exception) {
//      [FBLogger logFmt:@"Exception calling RNUiInspector fetchUiTreeFromAUTServer: %@. Details: %@", exception.name, exception.reason];
//      rnTree = nil;
//      if (!fetchError) {
//          fetchError = [NSError errorWithDomain:@"RNUiInspectorFetchDomain" code:2001 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Exception during fetch: %@", exception.reason]}];
//      }
//    }
//    FBXMLGenerationOptions *xmlOptions = nil;
//    if (rnTree && rnTree.count > 0) {
//      [FBLogger logFmt:@"Successfully fetched React Native tree from in-AUT server."];
//      NSString *iter = [FBRNViewXMLConverter xmlStringFromRNTree:rnTree options:xmlOptions];
//      if (rnXmlSource) {
//          [FBLogger logFmt:@"Successfully converted fetched React Native tree to XML."];
//          return FBResponseWithObject(rnXmlSource);
//      } else {
//          [FBLogger log:@"Failed to convert fetched React Native tree to XML. Falling back to XCUITest source."];
//          fetchError = [NSError errorWithDomain:@"RNXMLConversionDomain" code:3001 userInfo:@{NSLocalizedDescriptionKey: @"Failed to convert fetched RN tree to XML."}];
//      }
//    } else {
//      NSString *errorMsg = @"React Native tree not fetched or was empty.";
//      if (fetchError) {
//          errorMsg = [NSString stringWithFormat:@"%@ Error: %@", errorMsg, fetchError.localizedDescription];
//      }
//      [FBLogger logFmt:@"%@ Falling back to XCUITest source.", errorMsg];
//    }

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
