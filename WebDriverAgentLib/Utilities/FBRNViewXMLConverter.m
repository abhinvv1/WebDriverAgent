
#import "FBRNViewXMLConverter.h"
#import "FBElementTypeTransformer.h"
#import "FBApplicationSnapshot.h"
#import "FBCompositeSnapshot.h"
#import "FBLogger.h"

@implementation FBGridSampledXMLConverter
+ (NSString *)fb_xmlStringFromSnapshot:(id<FBXCElementSnapshot>)snapshot atIndex:(NSInteger)index depth:(NSInteger)depth {
    NSMutableString *xml = [NSMutableString string];
    
    // Create element tag
    NSString *elementType = [self fb_elementTypeStringFromSnapshot:snapshot];
    NSString *indentation = [self fb_indentationForDepth:depth];
    
    [xml appendFormat:@"%@<%@", indentation, elementType];
    
    // Add attributes
    [xml appendString:[self fb_attributesStringFromSnapshot:snapshot atIndex:index]];
    
    // Get children - handle both regular snapshots and custom composite snapshots
    NSArray *children = [self fb_getChildrenFromSnapshot:snapshot];
    BOOL hasChildren = children && children.count > 0;
    
    if (hasChildren) {
        [xml appendString:@">\n"];
        
        [FBLogger logFmt:@"Processing element %@ with %lu children at depth %ld",
         elementType, (unsigned long)children.count, (long)depth];
        
        // Add children
        for (NSInteger i = 0; i < children.count; i++) {
            id childSnapshot = children[i];
//            if ([childSnapshot conformsToProtocol:@protocol(FBXCElementSnapshot)]) {
                [xml appendString:[self fb_xmlStringFromSnapshot:childSnapshot atIndex:i depth:depth + 1]];
//            } else {
//                [FBLogger logFmt:@"Skipping non-snapshot child at index %ld", (long)i];
//            }
        }
        
        [xml appendFormat:@"%@</%@>\n", indentation, elementType];
    } else {
        [xml appendString:@"/>\n"];
        [FBLogger logFmt:@"Element %@ has no children", elementType];
    }
    
    return xml;
}

// New helper method to properly extract children from any snapshot type
+ (NSArray *)fb_getChildrenFromSnapshot:(id<FBXCElementSnapshot>)snapshot {
    if (!snapshot) {
        return nil;
    }
    
    // Try to get children property directly
    if ([snapshot respondsToSelector:@selector(children)]) {
        NSArray *children = [snapshot children];
        if (children && [children isKindOfClass:[NSArray class]]) {
            [FBLogger logFmt:@"Found %lu children via children property", (unsigned long)children.count];
            return children;
        }
    }
    
    // For FBApplicationSnapshot specifically
    if ([snapshot isKindOfClass:[FBApplicationSnapshot class]]) {
        FBApplicationSnapshot *appSnapshot = (FBApplicationSnapshot *)snapshot;
        NSArray *children = appSnapshot.children;
        [FBLogger logFmt:@"FBApplicationSnapshot has %lu children", (unsigned long)children.count];
        return children;
    }
    
    // For FBCompositeSnapshot specifically
    if ([snapshot isKindOfClass:[FBCompositeSnapshot class]]) {
        FBCompositeSnapshot *compositeSnapshot = (FBCompositeSnapshot *)snapshot;
        NSArray *children = compositeSnapshot.children;
        [FBLogger logFmt:@"FBCompositeSnapshot has %lu children", (unsigned long)children.count];
        return children;
    }
    
    [FBLogger logFmt:@"No children found for snapshot type: %@", NSStringFromClass([snapshot class])];
    return nil;
}

// Updated main conversion method with better logging
+ (NSString *)xmlStringFromGridSampledSnapshot:(id<FBXCElementSnapshot>)rootSnapshot {
    if (!rootSnapshot) {
        [FBLogger logFmt:@"Root snapshot is nil, returning empty hierarchy"];
        return @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<hierarchy/>";
    }
    
    [FBLogger logFmt:@"Starting XML conversion for root snapshot: %@", NSStringFromClass([rootSnapshot class])];
    
    // Check if root has children
    NSArray *rootChildren = [self fb_getChildrenFromSnapshot:rootSnapshot];
    [FBLogger logFmt:@"Root snapshot has %lu children", (unsigned long)rootChildren.count];
    
    NSMutableString *xmlString = [NSMutableString string];
    [xmlString appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xmlString appendString:[self fb_xmlStringFromSnapshot:rootSnapshot atIndex:0 depth:0]];
    
    [FBLogger logFmt:@"Generated XML page source with length: %lu", (unsigned long)xmlString.length];
    
    // Debug: print first 500 chars of XML
    NSString *preview = xmlString.length > 500 ? [xmlString substringToIndex:500] : xmlString;
    [FBLogger logFmt:@"XML Preview: %@", preview];
    
    return [xmlString copy];
}

+ (NSString *)fb_elementTypeStringFromSnapshot:(id<FBXCElementSnapshot>)snapshot {
    NSString *elementType = [FBElementTypeTransformer stringWithElementType:snapshot.elementType];
    
    // Map XCUIElement types to more readable XML element names
    static NSDictionary *typeMapping = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        typeMapping = @{
            @"XCUIElementTypeApplication": @"application",
            @"XCUIElementTypeWindow": @"window",
            @"XCUIElementTypeSheet": @"sheet",
            @"XCUIElementTypeDrawer": @"drawer",
            @"XCUIElementTypeAlert": @"alert",
            @"XCUIElementTypeDialog": @"dialog",
            @"XCUIElementTypeButton": @"button",
            @"XCUIElementTypeRadioButton": @"radio",
            @"XCUIElementTypeRadioGroup": @"radiogroup",
            @"XCUIElementTypeCheckBox": @"checkbox",
            @"XCUIElementTypeDisclosureTriangle": @"disclosure",
            @"XCUIElementTypePopUpButton": @"popup",
            @"XCUIElementTypeComboBox": @"combobox",
            @"XCUIElementTypeMenuButton": @"menubutton",
            @"XCUIElementTypeToolbarButton": @"toolbarbutton",
            @"XCUIElementTypePopover": @"popover",
            @"XCUIElementTypeKeyboard": @"keyboard",
            @"XCUIElementTypeKey": @"key",
            @"XCUIElementTypeNavigationBar": @"navbar",
            @"XCUIElementTypeTabBar": @"tabbar",
            @"XCUIElementTypeTabGroup": @"tabgroup",
            @"XCUIElementTypeToolbar": @"toolbar",
            @"XCUIElementTypeStatusBar": @"statusbar",
            @"XCUIElementTypeTable": @"table",
            @"XCUIElementTypeTableRow": @"row",
            @"XCUIElementTypeTableColumn": @"column",
            @"XCUIElementTypeOutline": @"outline",
            @"XCUIElementTypeOutlineRow": @"outlinerow",
            @"XCUIElementTypeBrowser": @"browser",
            @"XCUIElementTypeCollectionView": @"collection",
            @"XCUIElementTypeSlider": @"slider",
            @"XCUIElementTypePageIndicator": @"pageindicator",
            @"XCUIElementTypeProgressIndicator": @"progress",
            @"XCUIElementTypeActivityIndicator": @"activity",
            @"XCUIElementTypeSegmentedControl": @"segmented",
            @"XCUIElementTypePicker": @"picker",
            @"XCUIElementTypePickerWheel": @"pickerwheel",
            @"XCUIElementTypeSwitch": @"switch",
            @"XCUIElementTypeToggle": @"toggle",
            @"XCUIElementTypeLink": @"link",
            @"XCUIElementTypeImage": @"image",
            @"XCUIElementTypeIcon": @"icon",
            @"XCUIElementTypeSearchField": @"searchfield",
            @"XCUIElementTypeScrollView": @"scrollview",
            @"XCUIElementTypeScrollBar": @"scrollbar",
            @"XCUIElementTypeStaticText": @"text",
            @"XCUIElementTypeTextField": @"textfield",
            @"XCUIElementTypeSecureTextField": @"securetextfield",
            @"XCUIElementTypeDatePicker": @"datepicker",
            @"XCUIElementTypeTextView": @"textview",
            @"XCUIElementTypeMenu": @"menu",
            @"XCUIElementTypeMenuItem": @"menuitem",
            @"XCUIElementTypeMenuBar": @"menubar",
            @"XCUIElementTypeMenuBarItem": @"menubaritem",
            @"XCUIElementTypeMap": @"map",
            @"XCUIElementTypeWebView": @"webview",
            @"XCUIElementTypeIncrementArrow": @"increment",
            @"XCUIElementTypeDecrementArrow": @"decrement",
            @"XCUIElementTypeTimeline": @"timeline",
            @"XCUIElementTypeRatingIndicator": @"rating",
            @"XCUIElementTypeValueIndicator": @"value",
            @"XCUIElementTypeSplitGroup": @"splitgroup",
            @"XCUIElementTypeSplitter": @"splitter",
            @"XCUIElementTypeRelevanceIndicator": @"relevance",
            @"XCUIElementTypeColorWell": @"colorwell",
            @"XCUIElementTypeHelpTag": @"help",
            @"XCUIElementTypeMatte": @"matte",
            @"XCUIElementTypeDockItem": @"dockitem",
            @"XCUIElementTypeRuler": @"ruler",
            @"XCUIElementTypeRulerMarker": @"rulermarker",
            @"XCUIElementTypeGrid": @"grid",
            @"XCUIElementTypeLevelIndicator": @"levelindicator",
            @"XCUIElementTypeCell": @"cell",
            @"XCUIElementTypeLayoutArea": @"layoutarea",
            @"XCUIElementTypeLayoutItem": @"layoutitem",
            @"XCUIElementTypeHandle": @"handle",
            @"XCUIElementTypeStepper": @"stepper",
            @"XCUIElementTypeTab": @"tab",
            @"XCUIElementTypeTouchBar": @"touchbar",
            @"XCUIElementTypeGroup": @"group",
            @"XCUIElementTypeOther": @"other"
        };
    });
    
    NSString *mappedType = typeMapping[elementType];
    return mappedType ?: @"other";
}

+ (NSString *)fb_attributesStringFromSnapshot:(id<FBXCElementSnapshot>)snapshot atIndex:(NSInteger)index {
    NSMutableString *attributes = [NSMutableString string];
    
    // Basic attributes
    if (snapshot.identifier && snapshot.identifier.length > 0) {
        [attributes appendFormat:@" resource-id=\"%@\"", [self fb_escapeXMLString:snapshot.identifier]];
    }
    
    if (snapshot.label && snapshot.label.length > 0) {
        [attributes appendFormat:@" content-desc=\"%@\"", [self fb_escapeXMLString:snapshot.label]];
    }
    
    if (snapshot.title && snapshot.title.length > 0) {
        [attributes appendFormat:@" name=\"%@\"", [self fb_escapeXMLString:snapshot.title]];
    }
    
    if (snapshot.value) {
        NSString *valueString = [self fb_stringFromValue:snapshot.value];
        if (valueString.length > 0) {
            [attributes appendFormat:@" value=\"%@\"", [self fb_escapeXMLString:valueString]];
        }
    }
    
    // Frame attributes
    CGRect frame = snapshot.frame;
    [attributes appendFormat:@" x=\"%.0f\"", frame.origin.x];
    [attributes appendFormat:@" y=\"%.0f\"", frame.origin.y];
    [attributes appendFormat:@" width=\"%.0f\"", frame.size.width];
    [attributes appendFormat:@" height=\"%.0f\"", frame.size.height];
    
    // Bounds (for compatibility)
    [attributes appendFormat:@" bounds=\"[%.0f,%.0f][%.0f,%.0f]\"",
     frame.origin.x, frame.origin.y,
     frame.origin.x + frame.size.width, frame.origin.y + frame.size.height];
    
    // Boolean attributes
    [attributes appendFormat:@" enabled=\"%@\"", snapshot.enabled ? @"true" : @"false"];
    [attributes appendFormat:@" visible=\"%@\"", !CGRectIsEmpty(snapshot.visibleFrame) ? @"true" : @"false"];
    
    // Additional attributes if available
    if ([snapshot respondsToSelector:@selector(selected)]) {
        [attributes appendFormat:@" selected=\"%@\"", snapshot.selected ? @"true" : @"false"];
    }
    
    if ([snapshot respondsToSelector:@selector(hasFocus)]) {
        [attributes appendFormat:@" focused=\"%@\"", snapshot.hasFocus ? @"true" : @"false"];
    }
    
    if ([snapshot respondsToSelector:@selector(placeholderValue)] && snapshot.placeholderValue) {
        [attributes appendFormat:@" hint=\"%@\"", [self fb_escapeXMLString:snapshot.placeholderValue]];
    }
    
    // Index attribute
    [attributes appendFormat:@" index=\"%ld\"", (long)index];
    
    // Package (application bundle identifier)
    [attributes appendString:@" package=\"com.apple.test.WebDriverAgentRunner-Runner\""];
    
    // Class name (element type)
    NSString *className = [FBElementTypeTransformer stringWithElementType:snapshot.elementType];
    [attributes appendFormat:@" class=\"%@\"", className ?: @"XCUIElementTypeOther"];
    
    // Checkable and checked attributes (for compatibility)
    BOOL isCheckable = (snapshot.elementType == XCUIElementTypeCheckBox ||
                       snapshot.elementType == XCUIElementTypeSwitch ||
                       snapshot.elementType == XCUIElementTypeToggle);
    [attributes appendFormat:@" checkable=\"%@\"", isCheckable ? @"true" : @"false"];
    
    if (isCheckable && [snapshot respondsToSelector:@selector(selected)]) {
        [attributes appendFormat:@" checked=\"%@\"", snapshot.selected ? @"true" : @"false"];
    } else {
        [attributes appendString:@" checked=\"false\""];
    }
    
    // Clickable attribute
    BOOL isClickable = (snapshot.elementType == XCUIElementTypeButton ||
                       snapshot.elementType == XCUIElementTypeLink ||
                       snapshot.elementType == XCUIElementTypeCell ||
                       snapshot.elementType == XCUIElementTypeMenuItem ||
                       snapshot.elementType == XCUIElementTypeTab);
    [attributes appendFormat:@" clickable=\"%@\"", isClickable ? @"true" : @"false"];
    
    // Focusable attribute
    BOOL isFocusable = (snapshot.elementType == XCUIElementTypeTextField ||
                       snapshot.elementType == XCUIElementTypeSecureTextField ||
                       snapshot.elementType == XCUIElementTypeTextView ||
                       snapshot.elementType == XCUIElementTypeSearchField);
    [attributes appendFormat:@" focusable=\"%@\"", isFocusable ? @"true" : @"false"];
    
    // Long-clickable (always false for iOS)
    [attributes appendString:@" long-clickable=\"false\""];
    
    // Password attribute
    BOOL isPassword = (snapshot.elementType == XCUIElementTypeSecureTextField);
    [attributes appendFormat:@" password=\"%@\"", isPassword ? @"true" : @"false"];
    
    // Scrollable attribute
    BOOL isScrollable = (snapshot.elementType == XCUIElementTypeScrollView ||
                        snapshot.elementType == XCUIElementTypeTable ||
                        snapshot.elementType == XCUIElementTypeCollectionView);
    [attributes appendFormat:@" scrollable=\"%@\"", isScrollable ? @"true" : @"false"];
    
    return attributes;
}

+ (NSString *)fb_stringFromValue:(id)value {
    if (!value) {
        return @"";
    }
    
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    } else if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    } else if ([value respondsToSelector:@selector(description)]) {
        return [value description];
    }
    
    return @"";
}

+ (NSString *)fb_escapeXMLString:(NSString *)string {
    if (!string) {
        return @"";
    }
    
    NSMutableString *escaped = [string mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"'" withString:@"&apos;" options:0 range:NSMakeRange(0, escaped.length)];
    
    return escaped;
}

+ (NSString *)fb_indentationForDepth:(NSInteger)depth {
    NSMutableString *indentation = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) {
        [indentation appendString:@"  "];
    }
    return indentation;
}

@end

//
// Integration with Page Source Command
// Add this to your page source command implementation:
//

/*
// In your page source command method, replace the existing logic with:

- (id<FBResponsePayload>)handleGetPageSource:(FBRouteRequest *)request {
    FBApplication *application = request.session.activeApplication;
    if (!application) {
        return FBResponseWithStatus([FBCommandStatus invalidSessionErrorWithMessage:@"No active application"]);
    }
    
    NSString *formatType = request.parameters[@"format"] ?: @"json";
    
    // Grid sampling parameters (can be customized via request parameters)
    NSDictionary *samplingParams = @{
        @"samplesX": request.parameters[@"samplesX"] ?: @(kFBInitialSamplesX),
        @"samplesY": request.parameters[@"samplesY"] ?: @(kFBInitialSamplesY),
        @"maxRecursionDepth": request.parameters[@"maxRecursionDepth"] ?: @(kFBMaxRecursionDepth)
    };
    
    // Perform grid sampling to get snapshot tree
    id<FBXCElementSnapshot> gridSampledTree = [application fb_gridSampledSnapshotTreeWithParameters:samplingParams];
    
    if (!gridSampledTree) {
        return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Failed to generate grid sampled tree"]);
    }
    
    [FBLogger logFmt:@"Grid sampled tree generated successfully"];
    
    if ([formatType isEqualToString:@"xml"]) {
        NSString *xmlSource = [FBGridSampledXMLConverter xmlStringFromGridSampledSnapshot:gridSampledTree];
        return FBResponseWithObject(xmlSource);
    } else {
        // For JSON format, convert snapshot tree to dictionary representation
        NSDictionary *jsonTree = [self fb_dictionaryFromSnapshot:gridSampledTree];
        return FBResponseWithObject(jsonTree);
    }
}

// Helper method to convert snapshot to dictionary for JSON format
- (NSDictionary *)fb_dictionaryFromSnapshot:(id<FBXCElementSnapshot>)snapshot {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    
    dict[@"type"] = [FBElementTypeTransformer stringWithElementType:snapshot.elementType] ?: @"Unknown";
    dict[@"label"] = snapshot.label ?: @"";
    dict[@"name"] = snapshot.title ?: @"";
    dict[@"value"] = [self fb_stringFromValue:snapshot.value];
    dict[@"rect"] = @{
        @"x": @(snapshot.frame.origin.x),
        @"y": @(snapshot.frame.origin.y),
        @"width": @(snapshot.frame.size.width),
        @"height": @(snapshot.frame.size.height)
    };
    dict[@"isEnabled"] = @(snapshot.enabled);
    dict[@"isVisible"] = @(!CGRectIsEmpty(snapshot.visibleFrame));
    
    if (snapshot.identifier && snapshot.identifier.length > 0) {
        dict[@"testID"] = snapshot.identifier;
    }
    
    // Add children if they exist
    if (snapshot.children && [snapshot.children isKindOfClass:[NSArray class]] && snapshot.children.count > 0) {
        NSMutableArray *childrenArray = [NSMutableArray array];
        for (id<FBXCElementSnapshot> childSnapshot in snapshot.children) {
            [childrenArray addObject:[self fb_dictionaryFromSnapshot:childSnapshot]];
        }
        dict[@"children"] = childrenArray;
    }
    
    return dict;
}

- (NSString *)fb_stringFromValue:(id)value {
    if (!value) return @"";
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    if ([value respondsToSelector:@selector(description)]) return [value description];
    return @"";
}
*/
