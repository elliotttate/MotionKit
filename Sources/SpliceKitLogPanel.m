//
//  SpliceKitLogPanel.m
//  Floating in-app log viewer with source controls and interaction tracing.
//

#import "SpliceKitLogPanel.h"
#import "SpliceKit.h"
#import <objc/runtime.h>

static NSString * const kSKLogPanelIncludeSpliceKitKey = @"SpliceKitLogPanelIncludeSpliceKit";
static NSString * const kSKLogPanelIncludeUnifiedKey = @"SpliceKitLogPanelIncludeUnified";
static NSString * const kSKLogPanelIncludeInteractionKey = @"SpliceKitLogPanelIncludeInteraction";
static NSString * const kSKLogPanelUnifiedModeKey = @"SpliceKitLogPanelUnifiedMode";
static NSString * const kSKLogPanelFilterTextKey = @"SpliceKitLogPanelFilterText";
static NSString * const kSKLogPanelFilterScopeKey = @"SpliceKitLogPanelFilterScope";
static NSString * const kSKLogPanelRepeatLimitKey = @"SpliceKitLogPanelRepeatLimit";

typedef NS_ENUM(NSInteger, SKLogPanelUnifiedMode) {
    SKLogPanelUnifiedModeImportant = 0,
    SKLogPanelUnifiedModeBalanced = 1,
    SKLogPanelUnifiedModeVerbose = 2,
    SKLogPanelUnifiedModeErrors = 3,
};

typedef NS_ENUM(NSInteger, SKLogPanelFilterScope) {
    SKLogPanelFilterScopeAll = 0,
    SKLogPanelFilterScopeProblems = 1,
    SKLogPanelFilterScopeSpliceKit = 2,
    SKLogPanelFilterScopeUnified = 3,
    SKLogPanelFilterScopeInteractions = 4,
};

typedef NS_ENUM(NSInteger, SKLogLineSource) {
    SKLogLineSourceSpliceKit = 0,
    SKLogLineSourceUnified = 1,
    SKLogLineSourceInteraction = 2,
};

static NSUInteger const kSKLogPanelMaxFileBytes = 250 * 1024;
static NSUInteger const kSKLogPanelMaxChars = 200000;
static NSUInteger const kSKLogPanelMaxInteractionLines = 1000;
static NSUInteger const kSKLogPanelMaxUnifiedLines = 2000;
static NSUInteger const kSKLogPanelMaxPendingChars = 64000;
static NSUInteger const kSKLogPanelRepeatLimitCount = 2;

static BOOL (*sSKLogPanelOriginalSendAction)(id, SEL, SEL, id, id) = NULL;

static NSString *SpliceKitLogPanel_logPath(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/MotionKit"];
    return [dir stringByAppendingPathComponent:@"motionkit.log"];
}

static NSDictionary<NSAttributedStringKey, id> *SpliceKitLogPanel_textAttributes(void) {
    NSFont *font = nil;
    if (@available(macOS 15.0, *)) {
        font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    } else {
        font = [NSFont userFixedPitchFontOfSize:11];
    }
    return @{
        NSFontAttributeName: font ?: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor textColor],
    };
}

typedef NS_ENUM(NSInteger, SKLogLineKind) {
    SKLogLineKindPlaceholder = 0,
    SKLogLineKindSpliceKit,
    SKLogLineKindTrace,
    SKLogLineKindUnifiedDebug,
    SKLogLineKindUnifiedInfo,
    SKLogLineKindUnifiedWarning,
    SKLogLineKindUnifiedError,
    SKLogLineKindUnifiedOther,
};

typedef NS_ENUM(NSInteger, SKLogFragmentRole) {
    SKLogFragmentRoleBase = 0,
    SKLogFragmentRoleTimestamp,
    SKLogFragmentRoleTag,
    SKLogFragmentRoleLevel,
    SKLogFragmentRoleProcess,
    SKLogFragmentRolePID,
    SKLogFragmentRoleMetadata,
    SKLogFragmentRoleQuote,
    SKLogFragmentRolePrivate,
};

static NSString *SpliceKitLogPanel_timestampString(void) {
    return [NSDateFormatter localizedStringFromDate:[NSDate date]
                                          dateStyle:NSDateFormatterNoStyle
                                          timeStyle:NSDateFormatterMediumStyle];
}

static NSUInteger SpliceKitLogPanel_lineCount(NSString *text) {
    if (text.length == 0) return 0;
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        if ([text characterAtIndex:i] == '\n') count += 1;
    }
    return MAX(count, 1);
}

static SKLogLineKind SpliceKitLogPanel_lineKind(NSString *line) {
    if (line.length == 0 ||
        [line hasPrefix:@"Waiting for"] ||
        [line hasPrefix:@"Enable at least one log source"] ||
        [line hasPrefix:@"No log sources enabled"]) {
        return SKLogLineKindPlaceholder;
    }
    if ([line containsString:@"[Trace]"]) return SKLogLineKindTrace;
    if ([line containsString:@"[SpliceKit]"]) return SKLogLineKindSpliceKit;
    if ([line hasPrefix:@"20"]) {
        if ([line containsString:@" Fault "] || [line containsString:@" Error "]) {
            return SKLogLineKindUnifiedError;
        }
        if ([line containsString:@" Warning "] || [line containsString:@" Warn "]) {
            return SKLogLineKindUnifiedWarning;
        }
        if ([line containsString:@" Info "] ||
            [line containsString:@" Notice "] ||
            [line containsString:@" Default "]) {
            return SKLogLineKindUnifiedInfo;
        }
        if ([line containsString:@" Db "] || [line containsString:@" Debug "]) {
            return SKLogLineKindUnifiedDebug;
        }
        return SKLogLineKindUnifiedOther;
    }
    return SKLogLineKindUnifiedOther;
}

static NSDictionary<NSAttributedStringKey, id> *SpliceKitLogPanel_attributesForFragment(SKLogLineKind kind,
                                                                                        SKLogFragmentRole role) {
    static NSDictionary<NSAttributedStringKey, id> *attributeMap[SKLogLineKindUnifiedOther + 1][SKLogFragmentRolePrivate + 1];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFont *regularFont = nil;
        NSFont *mediumFont = nil;
        NSFont *semiboldFont = nil;
        if (@available(macOS 15.0, *)) {
            regularFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
            mediumFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
            semiboldFont = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightSemibold];
        } else {
            regularFont = [NSFont userFixedPitchFontOfSize:11] ?: [NSFont systemFontOfSize:11];
            mediumFont = regularFont;
            semiboldFont = regularFont;
        }

        NSColor *baseColors[] = {
            [NSColor colorWithCalibratedWhite:0.62 alpha:1.0],
            [NSColor colorWithCalibratedRed:0.92 green:0.94 blue:1.0 alpha:1.0],
            [NSColor colorWithCalibratedRed:0.49 green:0.90 blue:0.78 alpha:1.0],
            [NSColor colorWithCalibratedRed:0.66 green:0.69 blue:0.76 alpha:1.0],
            [NSColor colorWithCalibratedRed:0.72 green:0.83 blue:1.0 alpha:1.0],
            [NSColor colorWithCalibratedRed:1.0 green:0.78 blue:0.43 alpha:1.0],
            [NSColor colorWithCalibratedRed:1.0 green:0.46 blue:0.46 alpha:1.0],
            [NSColor colorWithCalibratedRed:0.86 green:0.87 blue:0.90 alpha:1.0],
        };

        for (NSInteger rawKind = SKLogLineKindPlaceholder; rawKind <= SKLogLineKindUnifiedOther; rawKind++) {
            NSColor *levelColor = baseColors[rawKind];
            NSColor *tagColor = rawKind == SKLogLineKindTrace
                ? [NSColor colorWithCalibratedRed:0.49 green:0.90 blue:0.78 alpha:1.0]
                : (rawKind == SKLogLineKindSpliceKit
                    ? [NSColor colorWithCalibratedRed:0.72 green:0.83 blue:1.0 alpha:1.0]
                    : levelColor);
            NSColor *timestampColor = [NSColor colorWithCalibratedRed:0.56 green:0.82 blue:1.00 alpha:1.0];
            NSColor *processColor = [NSColor colorWithCalibratedRed:0.95 green:0.95 blue:0.99 alpha:1.0];
            NSColor *pidColor = [NSColor colorWithCalibratedRed:0.78 green:0.72 blue:1.00 alpha:1.0];
            NSColor *metadataColor = [NSColor colorWithCalibratedRed:1.00 green:0.82 blue:0.56 alpha:1.0];
            NSColor *quoteColor = [NSColor colorWithCalibratedRed:0.69 green:0.93 blue:0.73 alpha:1.0];
            NSColor *privateColor = [NSColor colorWithCalibratedWhite:0.72 alpha:1.0];

            attributeMap[rawKind][SKLogFragmentRoleBase] = @{
                NSFontAttributeName: regularFont,
                NSForegroundColorAttributeName: baseColors[rawKind],
            };
            attributeMap[rawKind][SKLogFragmentRoleTimestamp] = @{
                NSFontAttributeName: semiboldFont,
                NSForegroundColorAttributeName: timestampColor,
            };
            attributeMap[rawKind][SKLogFragmentRoleTag] = @{
                NSFontAttributeName: semiboldFont,
                NSForegroundColorAttributeName: tagColor,
            };
            attributeMap[rawKind][SKLogFragmentRoleLevel] = @{
                NSFontAttributeName: semiboldFont,
                NSForegroundColorAttributeName: levelColor,
            };
            attributeMap[rawKind][SKLogFragmentRoleProcess] = @{
                NSFontAttributeName: mediumFont,
                NSForegroundColorAttributeName: processColor,
            };
            attributeMap[rawKind][SKLogFragmentRolePID] = @{
                NSFontAttributeName: mediumFont,
                NSForegroundColorAttributeName: pidColor,
            };
            attributeMap[rawKind][SKLogFragmentRoleMetadata] = @{
                NSFontAttributeName: mediumFont,
                NSForegroundColorAttributeName: metadataColor,
            };
            attributeMap[rawKind][SKLogFragmentRoleQuote] = @{
                NSFontAttributeName: mediumFont,
                NSForegroundColorAttributeName: quoteColor,
            };
            attributeMap[rawKind][SKLogFragmentRolePrivate] = @{
                NSFontAttributeName: regularFont,
                NSForegroundColorAttributeName: privateColor,
            };
        }
    });

    return attributeMap[kind][role];
}

static NSDictionary<NSAttributedStringKey, id> *SpliceKitLogPanel_attributesForLine(NSString *line) {
    return SpliceKitLogPanel_attributesForFragment(SpliceKitLogPanel_lineKind(line),
                                                   SKLogFragmentRoleBase);
}

static void SpliceKitLogPanel_appendString(NSMutableAttributedString *output,
                                           NSString *text,
                                           NSDictionary<NSAttributedStringKey, id> *attributes) {
    if (text.length == 0) return;
    [output appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
}

static void SpliceKitLogPanel_appendRange(NSMutableAttributedString *output,
                                          NSString *source,
                                          NSRange range,
                                          NSDictionary<NSAttributedStringKey, id> *attributes) {
    if (range.location == NSNotFound || range.length == 0) return;
    SpliceKitLogPanel_appendString(output, [source substringWithRange:range], attributes);
}

static NSUInteger SpliceKitLogPanel_skipSpaces(NSString *text, NSUInteger index) {
    while (index < text.length && [text characterAtIndex:index] == ' ') index += 1;
    return index;
}

static NSUInteger SpliceKitLogPanel_unifiedTimestampLength(NSString *line) {
    if (line.length < 23) return 0;
    if ([line characterAtIndex:4] != '-' ||
        [line characterAtIndex:7] != '-' ||
        [line characterAtIndex:10] != ' ' ||
        [line characterAtIndex:13] != ':' ||
        [line characterAtIndex:16] != ':' ||
        [line characterAtIndex:19] != '.') {
        return 0;
    }
    return 23;
}

static void SpliceKitLogPanel_appendHighlightedBody(NSMutableAttributedString *output,
                                                    NSString *body,
                                                    SKLogLineKind kind) {
    NSDictionary<NSAttributedStringKey, id> *baseAttrs =
        SpliceKitLogPanel_attributesForFragment(kind, SKLogFragmentRoleBase);
    NSDictionary<NSAttributedStringKey, id> *quoteAttrs =
        SpliceKitLogPanel_attributesForFragment(kind, SKLogFragmentRoleQuote);
    NSDictionary<NSAttributedStringKey, id> *privateAttrs =
        SpliceKitLogPanel_attributesForFragment(kind, SKLogFragmentRolePrivate);

    NSUInteger cursor = 0;
    while (cursor < body.length) {
        NSRange privateRange = [body rangeOfString:@"<private>"
                                           options:0
                                             range:NSMakeRange(cursor, body.length - cursor)];
        NSRange quoteStart = [body rangeOfString:@"\""
                                         options:0
                                           range:NSMakeRange(cursor, body.length - cursor)];

        NSUInteger nextLocation = NSNotFound;
        BOOL isPrivate = NO;
        if (privateRange.location != NSNotFound) {
            nextLocation = privateRange.location;
            isPrivate = YES;
        }
        if (quoteStart.location != NSNotFound &&
            (nextLocation == NSNotFound || quoteStart.location < nextLocation)) {
            nextLocation = quoteStart.location;
            isPrivate = NO;
        }

        if (nextLocation == NSNotFound) {
            SpliceKitLogPanel_appendRange(output, body, NSMakeRange(cursor, body.length - cursor), baseAttrs);
            break;
        }

        if (nextLocation > cursor) {
            SpliceKitLogPanel_appendRange(output, body, NSMakeRange(cursor, nextLocation - cursor), baseAttrs);
        }

        if (isPrivate) {
            SpliceKitLogPanel_appendRange(output, body, privateRange, privateAttrs);
            cursor = NSMaxRange(privateRange);
            continue;
        }

        NSRange quoteEnd = [body rangeOfString:@"\""
                                       options:0
                                         range:NSMakeRange(quoteStart.location + 1,
                                                            body.length - quoteStart.location - 1)];
        NSUInteger end = quoteEnd.location == NSNotFound ? body.length : NSMaxRange(quoteEnd);
        SpliceKitLogPanel_appendRange(output, body, NSMakeRange(quoteStart.location, end - quoteStart.location), quoteAttrs);
        cursor = end;
    }
}

static NSMutableAttributedString *SpliceKitLogPanel_attributedStringForLine(NSString *line) {
    SKLogLineKind kind = SpliceKitLogPanel_lineKind(line);
    NSDictionary<NSAttributedStringKey, id> *baseAttrs =
        SpliceKitLogPanel_attributesForFragment(kind, SKLogFragmentRoleBase);
    NSMutableAttributedString *output = [[NSMutableAttributedString alloc] init];

    NSUInteger contentLength = line.length;
    while (contentLength > 0) {
        unichar tail = [line characterAtIndex:contentLength - 1];
        if (tail != '\n' && tail != '\r') break;
        contentLength -= 1;
    }

    NSString *content = [line substringToIndex:contentLength];
    NSString *suffix = [line substringFromIndex:contentLength];
    if (content.length == 0) {
        SpliceKitLogPanel_appendString(output, line, baseAttrs);
        return output;
    }

    if ([content hasPrefix:@"["]) {
        NSRange closing = [content rangeOfString:@"]"];
        if (closing.location != NSNotFound) {
            SpliceKitLogPanel_appendRange(output, content, NSMakeRange(0, NSMaxRange(closing)),
                                          SpliceKitLogPanel_attributesForFragment(kind, SKLogFragmentRoleTimestamp));
            NSUInteger cursor = NSMaxRange(closing);
            NSUInteger spaced = SpliceKitLogPanel_skipSpaces(content, cursor);
            if (spaced > cursor) {
                SpliceKitLogPanel_appendRange(output, content, NSMakeRange(cursor, spaced - cursor), baseAttrs);
                cursor = spaced;
            }
            if (cursor < content.length && [content characterAtIndex:cursor] == '[') {
                NSRange tagClose = [content rangeOfString:@"]"
                                                  options:0
                                                    range:NSMakeRange(cursor, content.length - cursor)];
                if (tagClose.location != NSNotFound) {
                    SpliceKitLogPanel_appendRange(output, content,
                                                  NSMakeRange(cursor, NSMaxRange(tagClose) - cursor),
                                                  SpliceKitLogPanel_attributesForFragment(kind, SKLogFragmentRoleTag));
                    cursor = NSMaxRange(tagClose);
                    if (cursor < content.length) {
                        SpliceKitLogPanel_appendHighlightedBody(output, [content substringFromIndex:cursor], kind);
                    }
                    if (suffix.length > 0) SpliceKitLogPanel_appendString(output, suffix, baseAttrs);
                    return output;
                }
            }
        }
    }

    NSUInteger timestampLength = SpliceKitLogPanel_unifiedTimestampLength(content);
    if (timestampLength > 0) {
        NSUInteger cursor = 0;
        SpliceKitLogPanel_appendRange(output, content, NSMakeRange(0, timestampLength),
                                      SpliceKitLogPanel_attributesForFragment(kind, SKLogFragmentRoleTimestamp));
        cursor = timestampLength;

        NSUInteger spaced = SpliceKitLogPanel_skipSpaces(content, cursor);
        if (spaced > cursor) {
            SpliceKitLogPanel_appendRange(output, content, NSMakeRange(cursor, spaced - cursor), baseAttrs);
            cursor = spaced;
        }

        NSUInteger levelEnd = cursor;
        while (levelEnd < content.length && [content characterAtIndex:levelEnd] != ' ') levelEnd += 1;
        if (levelEnd > cursor) {
            SpliceKitLogPanel_appendRange(output, content, NSMakeRange(cursor, levelEnd - cursor),
                                          SpliceKitLogPanel_attributesForFragment(kind, SKLogFragmentRoleLevel));
            cursor = levelEnd;
        }

        spaced = SpliceKitLogPanel_skipSpaces(content, cursor);
        if (spaced > cursor) {
            SpliceKitLogPanel_appendRange(output, content, NSMakeRange(cursor, spaced - cursor), baseAttrs);
            cursor = spaced;
        }

        NSRange pidOpen = [content rangeOfString:@"[" options:0 range:NSMakeRange(cursor, content.length - cursor)];
        if (pidOpen.location != NSNotFound && pidOpen.location > cursor) {
            SpliceKitLogPanel_appendRange(output, content, NSMakeRange(cursor, pidOpen.location - cursor),
                                          SpliceKitLogPanel_attributesForFragment(kind, SKLogFragmentRoleProcess));
            NSRange pidClose = [content rangeOfString:@"]"
                                              options:0
                                                range:NSMakeRange(pidOpen.location, content.length - pidOpen.location)];
            if (pidClose.location != NSNotFound) {
                SpliceKitLogPanel_appendRange(output, content,
                                              NSMakeRange(pidOpen.location, NSMaxRange(pidClose) - pidOpen.location),
                                              SpliceKitLogPanel_attributesForFragment(kind, SKLogFragmentRolePID));
                cursor = NSMaxRange(pidClose);
            } else {
                cursor = pidOpen.location;
            }
        }

        while (cursor < content.length) {
            spaced = SpliceKitLogPanel_skipSpaces(content, cursor);
            if (spaced > cursor) {
                SpliceKitLogPanel_appendRange(output, content, NSMakeRange(cursor, spaced - cursor), baseAttrs);
                cursor = spaced;
            }
            if (cursor >= content.length) break;

            unichar opener = [content characterAtIndex:cursor];
            unichar closer = 0;
            if (opener == '[') closer = ']';
            else if (opener == '(') closer = ')';
            else break;

            NSRange closeRange = [content rangeOfString:[NSString stringWithCharacters:&closer length:1]
                                                options:0
                                                  range:NSMakeRange(cursor, content.length - cursor)];
            if (closeRange.location == NSNotFound) break;

            SpliceKitLogPanel_appendRange(output, content,
                                          NSMakeRange(cursor, NSMaxRange(closeRange) - cursor),
                                          SpliceKitLogPanel_attributesForFragment(kind, SKLogFragmentRoleMetadata));
            cursor = NSMaxRange(closeRange);
        }

        if (cursor < content.length) {
            SpliceKitLogPanel_appendHighlightedBody(output, [content substringFromIndex:cursor], kind);
        }
        if (suffix.length > 0) SpliceKitLogPanel_appendString(output, suffix, baseAttrs);
        return output;
    }

    SpliceKitLogPanel_appendHighlightedBody(output, content, kind);
    if (suffix.length > 0) SpliceKitLogPanel_appendString(output, suffix, baseAttrs);
    return output;
}

static NSString *SpliceKitLogPanel_trimTrailingNewlines(NSString *line) {
    NSUInteger end = line.length;
    while (end > 0) {
        unichar c = [line characterAtIndex:end - 1];
        if (c != '\n' && c != '\r') break;
        end -= 1;
    }
    return [line substringToIndex:end];
}

static NSString *SpliceKitLogPanel_normalizedRepeatKey(NSString *line) {
    NSString *content = SpliceKitLogPanel_trimTrailingNewlines(line);
    if (content.length == 0) return @"";

    if ([content hasPrefix:@"["]) {
        NSRange firstClose = [content rangeOfString:@"]"];
        if (firstClose.location != NSNotFound) {
            NSUInteger cursor = SpliceKitLogPanel_skipSpaces(content, NSMaxRange(firstClose));
            return cursor < content.length ? [content substringFromIndex:cursor] : @"";
        }
    }

    NSUInteger timestampLength = SpliceKitLogPanel_unifiedTimestampLength(content);
    if (timestampLength > 0) {
        NSUInteger cursor = SpliceKitLogPanel_skipSpaces(content, timestampLength);
        NSString *withoutTimestamp = cursor < content.length ? [content substringFromIndex:cursor] : @"";

        NSRange pidOpen = [withoutTimestamp rangeOfString:@"["];
        if (pidOpen.location != NSNotFound) {
            NSRange pidClose = [withoutTimestamp rangeOfString:@"]"
                                                     options:0
                                                       range:NSMakeRange(pidOpen.location,
                                                                          withoutTimestamp.length - pidOpen.location)];
            if (pidClose.location != NSNotFound) {
                NSString *before = [withoutTimestamp substringToIndex:pidOpen.location];
                NSString *after = NSMaxRange(pidClose) < withoutTimestamp.length
                    ? [withoutTimestamp substringFromIndex:NSMaxRange(pidClose)]
                    : @"";
                return [before stringByAppendingString:after];
            }
        }
        return withoutTimestamp;
    }

    return content;
}

static NSButton *SpliceKitLogPanel_makeCheckbox(NSString *title, id target, SEL action) {
    NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
    button.buttonType = NSButtonTypeSwitch;
    button.bezelStyle = NSBezelStyleRegularSquare;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    return button;
}

static NSString *SpliceKitLogPanel_titleOrPlaceholder(NSString *value, NSString *placeholder) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : placeholder;
}

static NSString *SpliceKitLogPanel_menuPath(NSMenu *menu) {
    if (!menu) return @"";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMenu *current = menu;
    while (current) {
        NSString *title = SpliceKitLogPanel_titleOrPlaceholder(current.title, @"");
        if (title.length > 0) [parts insertObject:title atIndex:0];
        current = current.supermenu;
    }
    return [parts componentsJoinedByString:@" > "];
}

static NSString *SpliceKitLogPanel_menuItemPath(NSMenuItem *item) {
    if (!item) return @"";
    NSString *menuPath = SpliceKitLogPanel_menuPath(item.menu);
    NSString *itemTitle = SpliceKitLogPanel_titleOrPlaceholder(item.title, @"<untitled item>");
    return menuPath.length > 0
        ? [NSString stringWithFormat:@"%@ > %@", menuPath, itemTitle]
        : itemTitle;
}

static NSString *SpliceKitLogPanel_windowDescription(NSWindow *window) {
    if (!window) return @"<window>";
    NSString *title = SpliceKitLogPanel_titleOrPlaceholder(window.title, NSStringFromClass(window.class));
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:title];
    if (window.isSheet) [parts addObject:@"sheet"];
    if ([window isKindOfClass:[NSPanel class]]) [parts addObject:@"panel"];
    return [parts componentsJoinedByString:@" / "];
}

static NSString *SpliceKitLogPanel_stateDescriptionForObject(id obj) {
    if ([obj isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *item = obj;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (item.state != NSControlStateValueOff) {
            [parts addObject:[NSString stringWithFormat:@"state=%@",
                              item.state == NSControlStateValueOn ? @"on" : @"mixed"]];
        }
        if ([item respondsToSelector:@selector(keyEquivalent)] && item.keyEquivalent.length > 0) {
            [parts addObject:[NSString stringWithFormat:@"key=%@", item.keyEquivalent]];
        }
        return parts.count > 0 ? [parts componentsJoinedByString:@" "] : nil;
    }
    if ([obj isKindOfClass:[NSButton class]]) {
        NSButton *button = obj;
        if (button.state != NSControlStateValueOff) {
            return [NSString stringWithFormat:@"state=%@",
                    button.state == NSControlStateValueOn ? @"on" :
                    button.state == NSControlStateValueMixed ? @"mixed" : @"off"];
        }
        return nil;
    }
    if ([obj isKindOfClass:[NSPopUpButton class]]) {
        NSString *title = SpliceKitLogPanel_titleOrPlaceholder([(NSPopUpButton *)obj titleOfSelectedItem],
                                                               @"<none>");
        return [NSString stringWithFormat:@"selected=%@", title];
    }
    if ([obj isKindOfClass:[NSSegmentedControl class]]) {
        NSSegmentedControl *control = obj;
        NSInteger segment = control.selectedSegment;
        if (segment < 0) return @"selected=<none>";
        NSString *label = [control labelForSegment:segment] ?: [NSString stringWithFormat:@"%ld", (long)segment];
        return [NSString stringWithFormat:@"selected=%@", label];
    }
    if ([obj isKindOfClass:[NSSlider class]]) {
        return [NSString stringWithFormat:@"value=%.3f", [(NSSlider *)obj doubleValue]];
    }
    if ([obj isKindOfClass:[NSTextField class]]) {
        NSString *value = SpliceKitLogPanel_titleOrPlaceholder([(NSTextField *)obj stringValue], @"");
        if (value.length == 0) return nil;
        if (value.length > 48) value = [[value substringToIndex:48] stringByAppendingString:@"..."];
        return [NSString stringWithFormat:@"value=\"%@\"", value];
    }
    return nil;
}

static NSString *SpliceKitLogPanel_viewPath(NSView *view) {
    if (!view) return @"";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSView *current = view;
    NSUInteger depth = 0;
    while (current && depth < 7) {
        NSMutableString *piece = [NSMutableString stringWithString:NSStringFromClass(current.class)];
        if (current.identifier.length > 0) {
            [piece appendFormat:@"#%@", current.identifier];
        }
        if ([current isKindOfClass:[NSButton class]]) {
            NSString *title = SpliceKitLogPanel_titleOrPlaceholder([(NSButton *)current title], @"");
            if (title.length > 0) [piece appendFormat:@"(\"%@\")", title];
        } else if ([current isKindOfClass:[NSTextField class]]) {
            NSString *value = SpliceKitLogPanel_titleOrPlaceholder([(NSTextField *)current stringValue], @"");
            if (value.length > 0 && value.length < 24) [piece appendFormat:@"(\"%@\")", value];
        }
        [parts insertObject:piece atIndex:0];
        current = current.superview;
        depth += 1;
    }
    return [parts componentsJoinedByString:@" > "];
}

static NSString *SpliceKitLogPanel_objectContextDescription(id obj) {
    if (!obj) return @"";

    if ([obj isKindOfClass:[NSMenuItem class]]) {
        NSString *path = SpliceKitLogPanel_menuItemPath(obj);
        NSString *state = SpliceKitLogPanel_stateDescriptionForObject(obj);
        return state.length > 0 ? [NSString stringWithFormat:@"%@ %@", path, state] : path;
    }
    if ([obj isKindOfClass:[NSToolbarItem class]]) {
        NSToolbarItem *item = obj;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        NSString *label = SpliceKitLogPanel_titleOrPlaceholder(item.label, item.itemIdentifier ?: @"<toolbar item>");
        [parts addObject:[NSString stringWithFormat:@"toolbar \"%@\"", label]];
        if (item.itemIdentifier.length > 0) [parts addObject:[NSString stringWithFormat:@"id=%@", item.itemIdentifier]];
        return [parts componentsJoinedByString:@" "];
    }
    if ([obj isKindOfClass:[NSWindow class]]) {
        return SpliceKitLogPanel_windowDescription(obj);
    }
    if ([obj isKindOfClass:[NSView class]]) {
        NSView *view = obj;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        NSString *className = NSStringFromClass(view.class);
        [parts addObject:className];
        NSString *state = SpliceKitLogPanel_stateDescriptionForObject(view);
        if (state.length > 0) [parts addObject:state];
        NSString *window = SpliceKitLogPanel_windowDescription(view.window);
        if (window.length > 0) [parts addObject:[NSString stringWithFormat:@"window=%@", window]];
        NSString *path = SpliceKitLogPanel_viewPath(view);
        if (path.length > 0) [parts addObject:[NSString stringWithFormat:@"path=%@", path]];
        return [parts componentsJoinedByString:@" "];
    }
    return NSStringFromClass([obj class]) ?: @"<object>";
}

static NSString *SpliceKitLogPanel_eventTypeName(NSEventType type) {
    switch (type) {
        case NSEventTypeLeftMouseDown: return @"leftMouseDown";
        case NSEventTypeLeftMouseUp: return @"leftMouseUp";
        case NSEventTypeRightMouseDown: return @"rightMouseDown";
        case NSEventTypeRightMouseUp: return @"rightMouseUp";
        case NSEventTypeMouseMoved: return @"mouseMoved";
        case NSEventTypeLeftMouseDragged: return @"leftMouseDragged";
        case NSEventTypeRightMouseDragged: return @"rightMouseDragged";
        case NSEventTypeMouseEntered: return @"mouseEntered";
        case NSEventTypeMouseExited: return @"mouseExited";
        case NSEventTypeKeyDown: return @"keyDown";
        case NSEventTypeKeyUp: return @"keyUp";
        case NSEventTypeFlagsChanged: return @"flagsChanged";
        case NSEventTypeScrollWheel: return @"scrollWheel";
        case NSEventTypeTabletPoint: return @"tabletPoint";
        case NSEventTypeApplicationDefined: return @"applicationDefined";
        case NSEventTypePeriodic: return @"periodic";
        default: return [NSString stringWithFormat:@"event(%ld)", (long)type];
    }
}

static NSString *SpliceKitLogPanel_eventDescription(NSEvent *event) {
    if (!event) return @"";

    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:SpliceKitLogPanel_eventTypeName(event.type)];
    if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
        NSString *chars = event.charactersIgnoringModifiers ?: @"";
        if (chars.length > 0) [parts addObject:[NSString stringWithFormat:@"chars=%@", chars]];
    } else if (event.type == NSEventTypeLeftMouseDown ||
               event.type == NSEventTypeLeftMouseUp ||
               event.type == NSEventTypeRightMouseDown ||
               event.type == NSEventTypeRightMouseUp) {
        NSPoint point = event.locationInWindow;
        [parts addObject:[NSString stringWithFormat:@"@%.0f,%.0f", point.x, point.y]];
    }
    if (event.modifierFlags & NSEventModifierFlagCommand) [parts addObject:@"cmd"];
    if (event.modifierFlags & NSEventModifierFlagOption) [parts addObject:@"opt"];
    if (event.modifierFlags & NSEventModifierFlagControl) [parts addObject:@"ctrl"];
    if (event.modifierFlags & NSEventModifierFlagShift) [parts addObject:@"shift"];
    return [parts componentsJoinedByString:@" "];
}

@interface SpliceKitLogPanel () <NSWindowDelegate, NSTextFieldDelegate, NSSearchFieldDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSTextView *textView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSTask *unifiedLogTask;
@property (nonatomic, strong) NSPipe *unifiedLogPipe;
@property (nonatomic, strong) NSMutableData *unifiedLogBuffer;
@property (nonatomic, strong) NSMutableArray<NSString *> *unifiedLines;
@property (nonatomic, strong) NSMutableArray<NSString *> *interactionLines;
@property (nonatomic, strong) NSMutableArray *interactionObserverTokens;
@property (nonatomic, strong) NSButton *spliceKitCheckbox;
@property (nonatomic, strong) NSButton *unifiedCheckbox;
@property (nonatomic, strong) NSButton *interactionCheckbox;
@property (nonatomic, strong) NSButton *repeatLimitCheckbox;
@property (nonatomic, strong) NSPopUpButton *unifiedModePopup;
@property (nonatomic, strong) NSSearchField *filterField;
@property (nonatomic, strong) NSPopUpButton *filterScopePopup;
@property (nonatomic, strong) NSMutableString *pendingDisplayText;
@property (nonatomic, strong) NSTimer *flushTimer;
@property (nonatomic) BOOL pendingScrollToBottom;
@property (nonatomic) NSUInteger pendingDroppedLineCount;
@property (nonatomic, copy) NSString *lastRepeatKey;
@property (nonatomic) NSUInteger lastRepeatVisibleCount;
@property (nonatomic) unsigned long long readOffset;
@end

@implementation SpliceKitLogPanel

+ (instancetype)sharedPanel {
    static SpliceKitLogPanel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    self.unifiedLines = [NSMutableArray array];
    self.interactionLines = [NSMutableArray array];
    [self installActionTracingIfNeeded];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationWillTerminateNotification
        object:nil
        queue:nil
        usingBlock:^(__unused NSNotification *note) {
            [self.pollTimer invalidate];
            self.pollTimer = nil;
            [self stopUnifiedLogStream];
            [self stopInteractionTrace];
            [self.panel orderOut:nil];
        }];
    return self;
}

- (BOOL)isVisible {
    return self.panel && self.panel.isVisible;
}

- (void)togglePanel {
    if (self.isVisible) [self hidePanel];
    else [self showPanel];
}

- (void)showPanel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self showPanel]; });
        return;
    }

    [self setupPanelIfNeeded];
    [self loadControlStateFromDefaults];
    [self startPolling];
    [self rebuildDisplayedContent];
    [self startUnifiedLogStream];
    [self startInteractionTrace];
    [self.panel makeKeyAndOrderFront:nil];
}

- (void)hidePanel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self hidePanel]; });
        return;
    }

    [self stopPolling];
    [self stopUnifiedLogStream];
    [self stopInteractionTrace];
    [self.panel orderOut:nil];
}

- (BOOL)includeSpliceKitLogs {
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:kSKLogPanelIncludeSpliceKitKey];
    return raw == nil ? YES : [raw boolValue];
}

- (BOOL)includeUnifiedLogs {
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:kSKLogPanelIncludeUnifiedKey];
    return raw == nil ? YES : [raw boolValue];
}

- (BOOL)includeInteractionLogs {
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:kSKLogPanelIncludeInteractionKey];
    return raw == nil ? YES : [raw boolValue];
}

- (SKLogPanelUnifiedMode)unifiedMode {
    id rawValue = [[NSUserDefaults standardUserDefaults] objectForKey:kSKLogPanelUnifiedModeKey];
    if (!rawValue) return SKLogPanelUnifiedModeBalanced;
    NSInteger raw = [rawValue integerValue];
    if (raw < SKLogPanelUnifiedModeImportant || raw > SKLogPanelUnifiedModeErrors) {
        return SKLogPanelUnifiedModeBalanced;
    }
    return (SKLogPanelUnifiedMode)raw;
}

- (SKLogPanelFilterScope)filterScope {
    id rawValue = [[NSUserDefaults standardUserDefaults] objectForKey:kSKLogPanelFilterScopeKey];
    if (!rawValue) return SKLogPanelFilterScopeAll;
    NSInteger raw = [rawValue integerValue];
    if (raw < SKLogPanelFilterScopeAll || raw > SKLogPanelFilterScopeInteractions) {
        return SKLogPanelFilterScopeAll;
    }
    return (SKLogPanelFilterScope)raw;
}

- (NSString *)filterText {
    NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:kSKLogPanelFilterTextKey] ?: @"";
    return [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (BOOL)repeatLimitEnabled {
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:kSKLogPanelRepeatLimitKey];
    return raw == nil ? YES : [raw boolValue];
}

- (NSString *)filterScopeTitle {
    switch (self.filterScope) {
        case SKLogPanelFilterScopeAll: return @"All";
        case SKLogPanelFilterScopeProblems: return @"Problems";
        case SKLogPanelFilterScopeSpliceKit: return @"SpliceKit";
        case SKLogPanelFilterScopeUnified: return @"Unified";
        case SKLogPanelFilterScopeInteractions: return @"Interactions";
    }
}

- (NSString *)unifiedModeTitle {
    switch (self.unifiedMode) {
        case SKLogPanelUnifiedModeImportant: return @"Important";
        case SKLogPanelUnifiedModeBalanced: return @"Balanced";
        case SKLogPanelUnifiedModeVerbose: return @"Verbose";
        case SKLogPanelUnifiedModeErrors: return @"Errors";
    }
}

- (NSString *)unifiedLogLevelString {
    switch (self.unifiedMode) {
        case SKLogPanelUnifiedModeErrors: return @"error";
        case SKLogPanelUnifiedModeImportant: return @"info";
        case SKLogPanelUnifiedModeBalanced:
        case SKLogPanelUnifiedModeVerbose:
            return @"debug";
    }
}

- (BOOL)lineMatchesUnifiedMode:(NSString *)line {
    if (!line.length) return NO;

    if (self.unifiedMode != SKLogPanelUnifiedModeErrors) {
        return YES;
    }

    SKLogLineKind kind = SpliceKitLogPanel_lineKind(line);
    if (kind == SKLogLineKindUnifiedError) return YES;

    return [line rangeOfString:@" error " options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [line rangeOfString:@" fault " options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [line rangeOfString:@" failed" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [line rangeOfString:@" exception" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [line rangeOfString:@" crash" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (NSString *)unifiedLogPredicate {
    NSMutableString *predicate = [NSMutableString stringWithString:
        @"process == \"Final Cut Pro\" AND NOT(eventMessage CONTAINS[c] \"[SpliceKit]\")"];

    if (self.unifiedMode == SKLogPanelUnifiedModeBalanced ||
        self.unifiedMode == SKLogPanelUnifiedModeImportant) {
        [predicate appendString:@" AND subsystem != \"com.apple.defaults\""];
        [predicate appendString:@" AND subsystem != \"com.apple.xpc\""];
        [predicate appendString:@" AND NOT(eventMessage CONTAINS[c] \"found no value for key\")"];
        [predicate appendString:@" AND NOT(eventMessage CONTAINS[c] \"Latching animation\")"];
        [predicate appendString:@" AND NOT(subsystem == \"com.apple.AppKit\" AND "
         @"(category == \"Animation\" OR category == \"AutomaticTermination\"))"];
    }

    return predicate;
}

- (BOOL)isInteractionTracingEnabled {
    return self.isVisible && self.includeInteractionLogs;
}

- (BOOL)lineMatchesFilter:(NSString *)line source:(SKLogLineSource)source {
    if (![self lineMatchesUnifiedMode:line]) {
        return NO;
    }

    SKLogPanelFilterScope scope = self.filterScope;
    SKLogLineKind kind = SpliceKitLogPanel_lineKind(line);

    switch (scope) {
        case SKLogPanelFilterScopeProblems:
            if (kind != SKLogLineKindUnifiedWarning &&
                kind != SKLogLineKindUnifiedError &&
                [line rangeOfString:@"error" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [line rangeOfString:@"fault" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [line rangeOfString:@"warn" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [line rangeOfString:@"failed" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [line rangeOfString:@"exception" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [line rangeOfString:@"crash" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [line rangeOfString:@"blocked" options:NSCaseInsensitiveSearch].location == NSNotFound) {
                return NO;
            }
            break;
        case SKLogPanelFilterScopeSpliceKit:
            if (source != SKLogLineSourceSpliceKit) return NO;
            break;
        case SKLogPanelFilterScopeUnified:
            if (source != SKLogLineSourceUnified) return NO;
            break;
        case SKLogPanelFilterScopeInteractions:
            if (source != SKLogLineSourceInteraction) return NO;
            break;
        case SKLogPanelFilterScopeAll:
            break;
    }

    NSString *filterText = self.filterText;
    if (filterText.length > 0 &&
        [line rangeOfString:filterText options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return NO;
    }
    return YES;
}

- (NSString *)filteredTextFromString:(NSString *)text source:(SKLogLineSource)source {
    if (text.length == 0) return @"";

    NSMutableString *filtered = [NSMutableString string];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(__unused NSString *substring, __unused NSRange substringRange,
                                       NSRange enclosingRange, __unused BOOL *stop) {
        NSString *line = [text substringWithRange:enclosingRange];
        if ([self lineMatchesFilter:line source:source]) {
            [filtered appendString:line];
        }
    }];
    return filtered;
}

- (NSString *)unifiedHistoryText {
    if (!self.includeUnifiedLogs || self.unifiedLines.count == 0) return @"";
    NSMutableString *text = [NSMutableString string];
    for (NSString *line in self.unifiedLines) {
        if ([self lineMatchesUnifiedMode:line] &&
            [self lineMatchesFilter:line source:SKLogLineSourceUnified]) {
            [text appendString:line];
        }
    }
    return text;
}

- (void)resetRepeatLimitState {
    self.lastRepeatKey = nil;
    self.lastRepeatVisibleCount = 0;
}

- (NSString *)repeatLimitedTextFromString:(NSString *)text resetState:(BOOL)resetState {
    if (!text.length) {
        if (resetState) [self resetRepeatLimitState];
        return @"";
    }

    if (!self.repeatLimitEnabled) {
        if (resetState) [self resetRepeatLimitState];
        return text;
    }

    if (resetState) [self resetRepeatLimitState];

    NSMutableString *limited = [NSMutableString string];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(__unused NSString *substring, __unused NSRange substringRange,
                                       NSRange enclosingRange, __unused BOOL *stop) {
        NSString *line = [text substringWithRange:enclosingRange];
        NSString *key = SpliceKitLogPanel_normalizedRepeatKey(line);
        if (key.length == 0) {
            [limited appendString:line];
            self.lastRepeatKey = nil;
            self.lastRepeatVisibleCount = 0;
            return;
        }

        if ([self.lastRepeatKey isEqualToString:key]) {
            self.lastRepeatVisibleCount += 1;
            if (self.lastRepeatVisibleCount <= kSKLogPanelRepeatLimitCount) {
                [limited appendString:line];
            }
            return;
        }

        self.lastRepeatKey = key;
        self.lastRepeatVisibleCount = 1;
        [limited appendString:line];
    }];
    return limited;
}

- (void)replaceDisplayedText:(NSString *)text {
    NSString *displayText = text.length ? text : @"";
    NSMutableAttributedString *output = [[NSMutableAttributedString alloc] init];
    [displayText enumerateSubstringsInRange:NSMakeRange(0, displayText.length)
                                    options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired
                                 usingBlock:^(__unused NSString *substring, __unused NSRange substringRange,
                                              NSRange enclosingRange, __unused BOOL *stop) {
        NSString *line = [displayText substringWithRange:enclosingRange];
        [output appendAttributedString:SpliceKitLogPanel_attributedStringForLine(line)];
    }];
    if (output.length == 0 && displayText.length > 0) {
        [output appendAttributedString:SpliceKitLogPanel_attributedStringForLine(displayText)];
    }
    [self.textView.textStorage setAttributedString:output];
}

- (void)appendDisplayedText:(NSString *)text {
    if (!text.length) return;
    NSMutableAttributedString *output = [[NSMutableAttributedString alloc] init];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(__unused NSString *substring, __unused NSRange substringRange,
                                       NSRange enclosingRange, __unused BOOL *stop) {
        NSString *line = [text substringWithRange:enclosingRange];
        [output appendAttributedString:SpliceKitLogPanel_attributedStringForLine(line)];
    }];
    if (output.length == 0) {
        [output appendAttributedString:SpliceKitLogPanel_attributedStringForLine(text)];
    }
    [self.textView.textStorage appendAttributedString:output];
}

- (BOOL)isNearBottom {
    NSScrollView *scrollView = self.textView.enclosingScrollView;
    if (!scrollView) return YES;

    NSRect visibleRect = scrollView.contentView.documentVisibleRect;
    CGFloat distance = NSMaxY(self.textView.bounds) - NSMaxY(visibleRect);
    return distance <= 48.0;
}

- (void)clearPendingDisplayedText {
    @synchronized (self) {
        if (self.pendingDisplayText.length > 0) {
            [self.pendingDisplayText setString:@""];
        }
        self.pendingScrollToBottom = NO;
        self.pendingDroppedLineCount = 0;
    }

    [self.flushTimer invalidate];
    self.flushTimer = nil;
    [self resetRepeatLimitState];
}

- (void)enqueueDisplayedText:(NSString *)text wantsScroll:(BOOL)wantsScroll {
    if (!text.length) return;

    BOOL shouldSchedule = NO;
    @synchronized (self) {
        if (!self.pendingDisplayText) {
            self.pendingDisplayText = [NSMutableString string];
        }
        if ((self.pendingDisplayText.length + text.length) > kSKLogPanelMaxPendingChars) {
            self.pendingDroppedLineCount += SpliceKitLogPanel_lineCount(text);
        } else {
            [self.pendingDisplayText appendString:text];
        }
        self.pendingScrollToBottom = self.pendingScrollToBottom || wantsScroll;
        shouldSchedule = (self.flushTimer == nil);
    }

    if (!shouldSchedule) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (self.flushTimer) return;
            self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:0.20
                                                               target:self
                                                             selector:@selector(flushPendingDisplayedText:)
                                                             userInfo:nil
                                                              repeats:NO];
        }
    });
}

- (void)flushPendingDisplayedText:(__unused NSTimer *)timer {
    self.flushTimer = nil;

    NSString *text = nil;
    BOOL wantsScroll = NO;
    NSUInteger droppedLineCount = 0;
    @synchronized (self) {
        if (self.pendingDisplayText.length == 0 && self.pendingDroppedLineCount == 0) return;
        text = self.pendingDisplayText.length > 0 ? [self.pendingDisplayText copy] : @"";
        [self.pendingDisplayText setString:@""];
        wantsScroll = self.pendingScrollToBottom;
        self.pendingScrollToBottom = NO;
        droppedLineCount = self.pendingDroppedLineCount;
        self.pendingDroppedLineCount = 0;
    }

    if (droppedLineCount > 0) {
        NSString *dropNotice = [NSString stringWithFormat:
            @"[%@] [Trace] Dropped %lu queued log lines while panel caught up\n",
            SpliceKitLogPanel_timestampString(), (unsigned long)droppedLineCount];
        text = [text stringByAppendingString:dropNotice];
    }

    text = [self repeatLimitedTextFromString:text resetState:NO];
    if (text.length == 0) return;

    BOOL shouldAutoScroll = wantsScroll &&
        ([self.textView.string hasPrefix:@"Waiting for"] || [self isNearBottom]);
    if ([self.textView.string hasPrefix:@"Waiting for"]) {
        [self replaceDisplayedText:@""];
    }
    [self appendDisplayedText:text];
    [self trimTextStorageIfNeeded];
    if (shouldAutoScroll) [self scrollToBottom];
}

- (void)trimTextStorageIfNeeded {
    NSTextStorage *storage = self.textView.textStorage;
    if (storage.length <= kSKLogPanelMaxChars) return;

    NSUInteger trim = storage.length - kSKLogPanelMaxChars;
    NSString *current = storage.string;
    NSRange firstNewline = [current rangeOfString:@"\n"
                                          options:0
                                            range:NSMakeRange(trim, current.length - trim)];
    NSUInteger cutoff = firstNewline.location == NSNotFound ? trim : NSMaxRange(firstNewline);
    [storage deleteCharactersInRange:NSMakeRange(0, cutoff)];
}

- (void)updateStatusLabel {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (self.includeSpliceKitLogs) [parts addObject:@"SpliceKit file"];
    if (self.includeUnifiedLogs) {
        [parts addObject:[NSString stringWithFormat:@"FCP unified (%@)", self.unifiedModeTitle]];
    }
    if (self.includeInteractionLogs) [parts addObject:@"Interaction trace"];

    NSMutableString *status = [NSMutableString string];
    if (parts.count > 0) {
        [status appendFormat:@"Showing %@", [parts componentsJoinedByString:@", "]];
    } else {
        [status appendString:@"No log sources enabled"];
    }

    NSMutableArray<NSString *> *filters = [NSMutableArray array];
    if (self.filterScope != SKLogPanelFilterScopeAll) {
        [filters addObject:self.filterScopeTitle];
    }
    if (self.filterText.length > 0) {
        [filters addObject:[NSString stringWithFormat:@"text=\"%@\"", self.filterText]];
    }
    if (filters.count > 0) {
        [status appendFormat:@" | Filter: %@", [filters componentsJoinedByString:@", "]];
    }
    if (self.repeatLimitEnabled) {
        [status appendFormat:@" | Repeat cap: %lu", (unsigned long)kSKLogPanelRepeatLimitCount];
    }

    self.statusLabel.stringValue = status;
    self.unifiedModePopup.enabled = self.includeUnifiedLogs;
}

- (NSString *)recentSpliceKitLogText {
    NSString *path = SpliceKitLogPanel_logPath();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    self.readOffset = attrs ? [attrs fileSize] : 0;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return @"";

    NSData *slice = data;
    if (data.length > kSKLogPanelMaxFileBytes) {
        slice = [data subdataWithRange:NSMakeRange(data.length - kSKLogPanelMaxFileBytes,
                                                   kSKLogPanelMaxFileBytes)];
    }

    NSString *text = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
    if (!text) text = [[NSString alloc] initWithData:slice encoding:NSISOLatin1StringEncoding];
    if (!text) return @"";

    if (data.length > kSKLogPanelMaxFileBytes) {
        NSRange firstNewline = [text rangeOfString:@"\n"];
        if (firstNewline.location != NSNotFound && NSMaxRange(firstNewline) < text.length) {
            text = [text substringFromIndex:NSMaxRange(firstNewline)];
        }
    }
    return text;
}

- (NSString *)interactionHistoryText {
    if (!self.includeInteractionLogs || self.interactionLines.count == 0) return @"";
    NSMutableString *text = [NSMutableString stringWithString:@"[Trace] Interaction history\n"];
    for (NSString *line in self.interactionLines) {
        if ([self lineMatchesFilter:line source:SKLogLineSourceInteraction]) {
            [text appendString:line];
        }
    }
    if ([text isEqualToString:@"[Trace] Interaction history\n"]) return @"";
    return text;
}

- (void)rebuildDisplayedContent {
    [self clearPendingDisplayedText];

    NSMutableString *display = [NSMutableString string];
    BOOL hasAnyRawContent = NO;

    if (self.includeSpliceKitLogs) {
        NSString *splicekitText = [self recentSpliceKitLogText];
        if (splicekitText.length > 0) {
            hasAnyRawContent = YES;
            NSString *filtered = [self filteredTextFromString:splicekitText source:SKLogLineSourceSpliceKit];
            if (filtered.length > 0) [display appendString:filtered];
        }
    } else {
        NSString *path = SpliceKitLogPanel_logPath();
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        self.readOffset = attrs ? [attrs fileSize] : 0;
    }

    NSString *unifiedText = [self unifiedHistoryText];
    if (self.includeUnifiedLogs && self.unifiedLines.count > 0) {
        hasAnyRawContent = YES;
        if (unifiedText.length > 0) {
            if (display.length > 0 && ![display hasSuffix:@"\n"]) [display appendString:@"\n"];
            if (display.length > 0) [display appendString:@"\n"];
            [display appendString:unifiedText];
        }
    }

    NSString *interactionText = [self interactionHistoryText];
    if (self.includeInteractionLogs && self.interactionLines.count > 0) {
        hasAnyRawContent = YES;
    }
    if (interactionText.length > 0) {
        if (display.length > 0 && ![display hasSuffix:@"\n"]) [display appendString:@"\n"];
        if (display.length > 0) [display appendString:@"\n"];
        [display appendString:interactionText];
    }

    if (display.length == 0) {
        if (hasAnyRawContent) {
            [display appendString:@"No log lines match current filters.\n"];
        } else if (self.includeUnifiedLogs || self.includeInteractionLogs) {
            [display appendString:@"Waiting for live log events...\n"];
        } else if (self.includeSpliceKitLogs) {
            [display appendString:@"Waiting for SpliceKit log output...\n"];
        } else {
            [display appendString:@"Enable at least one log source above.\n"];
        }
    }

    [self replaceDisplayedText:[self repeatLimitedTextFromString:display resetState:YES]];
    [self trimTextStorageIfNeeded];
    [self updateStatusLabel];
    [self scrollToBottom];
}

- (void)loadControlStateFromDefaults {
    self.spliceKitCheckbox.state = self.includeSpliceKitLogs ? NSControlStateValueOn : NSControlStateValueOff;
    self.unifiedCheckbox.state = self.includeUnifiedLogs ? NSControlStateValueOn : NSControlStateValueOff;
    self.interactionCheckbox.state = self.includeInteractionLogs ? NSControlStateValueOn : NSControlStateValueOff;
    self.repeatLimitCheckbox.state = self.repeatLimitEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self.unifiedModePopup selectItemAtIndex:self.unifiedMode];
    self.filterField.stringValue = self.filterText ?: @"";
    [self.filterScopePopup selectItemAtIndex:self.filterScope];
    [self updateStatusLabel];
}

- (void)persistControlState {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:(self.spliceKitCheckbox.state == NSControlStateValueOn)
               forKey:kSKLogPanelIncludeSpliceKitKey];
    [defaults setBool:(self.unifiedCheckbox.state == NSControlStateValueOn)
               forKey:kSKLogPanelIncludeUnifiedKey];
    [defaults setBool:(self.interactionCheckbox.state == NSControlStateValueOn)
               forKey:kSKLogPanelIncludeInteractionKey];
    [defaults setBool:(self.repeatLimitCheckbox.state == NSControlStateValueOn)
               forKey:kSKLogPanelRepeatLimitKey];
    [defaults setInteger:self.unifiedModePopup.indexOfSelectedItem
                  forKey:kSKLogPanelUnifiedModeKey];
    [defaults setObject:self.filterField.stringValue ?: @"" forKey:kSKLogPanelFilterTextKey];
    [defaults setInteger:self.filterScopePopup.indexOfSelectedItem
                  forKey:kSKLogPanelFilterScopeKey];
    [defaults synchronize];
}

- (void)logOptionsChanged:(__unused id)sender {
    [self persistControlState];
    [self stopUnifiedLogStream];
    [self stopInteractionTrace];
    [self rebuildDisplayedContent];
    [self startUnifiedLogStream];
    [self startInteractionTrace];
}

- (void)filterControlsChanged:(__unused id)sender {
    [self persistControlState];
    [self rebuildDisplayedContent];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object != self.filterField) return;
    [self filterControlsChanged:self.filterField];
}

- (BOOL)isInternalLogPanelObject:(id)obj {
    if (!obj) return NO;
    if (obj == self || obj == self.panel) return YES;
    if ([obj isKindOfClass:[NSWindow class]]) return obj == self.panel;
    if ([obj isKindOfClass:[NSView class]]) return ((NSView *)obj).window == self.panel;
    return NO;
}

- (void)recordInteractionMessage:(NSString *)message {
    if (!message.length) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *line = [NSString stringWithFormat:@"[%@] [Trace] %@\n",
                          SpliceKitLogPanel_timestampString(), message];
        [self.interactionLines addObject:line];
        while (self.interactionLines.count > kSKLogPanelMaxInteractionLines) {
            [self.interactionLines removeObjectAtIndex:0];
        }

        if (!self.isInteractionTracingEnabled) return;
        if ([self lineMatchesFilter:line source:SKLogLineSourceInteraction]) {
            [self enqueueDisplayedText:line wantsScroll:YES];
        }
    });
}

- (void)recordApplicationAction:(SEL)action target:(id)target sender:(id)sender handled:(BOOL)handled {
    if (!self.isInteractionTracingEnabled) return;
    if ([self isInternalLogPanelObject:sender] || [self isInternalLogPanelObject:target]) return;

    NSString *actionName = NSStringFromSelector(action) ?: @"<unknown>";
    NSString *senderDescription = SpliceKitLogPanel_objectContextDescription(sender);
    NSString *targetDescription = SpliceKitLogPanel_objectContextDescription(target);
    NSString *eventDescription = SpliceKitLogPanel_eventDescription(NSApp.currentEvent);

    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"Action %@", actionName]];
    if (senderDescription.length > 0) [parts addObject:[NSString stringWithFormat:@"from %@", senderDescription]];
    if (targetDescription.length > 0) [parts addObject:[NSString stringWithFormat:@"target=%@", targetDescription]];
    if (eventDescription.length > 0) [parts addObject:[NSString stringWithFormat:@"event=%@", eventDescription]];
    [parts addObject:[NSString stringWithFormat:@"handled=%@", handled ? @"YES" : @"NO"]];
    [self recordInteractionMessage:[parts componentsJoinedByString:@" | "]];
}

- (void)handleMenuTrackingBegan:(NSNotification *)note {
    if (!self.isInteractionTracingEnabled) return;
    NSMenu *menu = note.object;
    NSString *path = SpliceKitLogPanel_menuPath(menu);
    if (path.length == 0) return;
    NSString *window = SpliceKitLogPanel_windowDescription(NSApp.keyWindow);
    [self recordInteractionMessage:[NSString stringWithFormat:
        @"Menu opened: %@ | items=%lu | window=%@",
        path, (unsigned long)menu.itemArray.count, window]];
}

- (void)handlePopoverDidShow:(NSNotification *)note {
    if (!self.isInteractionTracingEnabled) return;
    NSPopover *popover = note.object;
    NSString *behavior = @"application";
    switch (popover.behavior) {
        case NSPopoverBehaviorTransient: behavior = @"transient"; break;
        case NSPopoverBehaviorSemitransient: behavior = @"semitransient"; break;
        case NSPopoverBehaviorApplicationDefined: behavior = @"application"; break;
    }
    NSString *controller = popover.contentViewController
        ? NSStringFromClass([popover.contentViewController class]) : @"<none>";
    [self recordInteractionMessage:[NSString stringWithFormat:
        @"Popover shown: controller=%@ behavior=%@",
        controller, behavior]];
}

- (void)handleWindowWillClose:(NSNotification *)note {
    if (!self.isInteractionTracingEnabled) return;
    NSWindow *window = note.object;
    if ([self isInternalLogPanelObject:window]) return;
    [self recordInteractionMessage:[NSString stringWithFormat:@"Window closing: %@",
                                    SpliceKitLogPanel_windowDescription(window)]];
}

- (void)handleWindowBecameKey:(NSNotification *)note {
    if (!self.isInteractionTracingEnabled) return;
    NSWindow *window = note.object;
    if ([self isInternalLogPanelObject:window]) return;
    NSString *className = NSStringFromClass(window.class) ?: @"NSWindow";
    NSString *firstResponder = window.firstResponder ? NSStringFromClass([window.firstResponder class]) : @"<none>";
    [self recordInteractionMessage:[NSString stringWithFormat:
        @"Focused window: %@ | class=%@ | responder=%@",
        SpliceKitLogPanel_windowDescription(window), className, firstResponder]];
}

- (void)installActionTracingIfNeeded {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method method = class_getInstanceMethod([NSApplication class], @selector(sendAction:to:from:));
        if (!method) return;
        sSKLogPanelOriginalSendAction = (BOOL (*)(id, SEL, SEL, id, id))method_getImplementation(method);
        method_setImplementation(method, (IMP)SKLogPanel_sendAction);
    });
}

- (void)startInteractionTrace {
    if (!self.isInteractionTracingEnabled) return;
    if (self.interactionObserverTokens.count > 0) return;

    self.interactionObserverTokens = [NSMutableArray array];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    __weak typeof(self) weakSelf = self;

    id menuOpenToken = [center addObserverForName:NSMenuDidBeginTrackingNotification
                                           object:nil
                                            queue:[NSOperationQueue mainQueue]
                                       usingBlock:^(NSNotification *note) {
        [weakSelf handleMenuTrackingBegan:note];
    }];
    if (menuOpenToken) [self.interactionObserverTokens addObject:menuOpenToken];

    id keyWindowToken = [center addObserverForName:NSWindowDidBecomeKeyNotification
                                            object:nil
                                             queue:[NSOperationQueue mainQueue]
                                        usingBlock:^(NSNotification *note) {
        [weakSelf handleWindowBecameKey:note];
    }];
    if (keyWindowToken) [self.interactionObserverTokens addObject:keyWindowToken];

    id popoverToken = [center addObserverForName:NSPopoverDidShowNotification
                                          object:nil
                                           queue:[NSOperationQueue mainQueue]
                                      usingBlock:^(NSNotification *note) {
        [weakSelf handlePopoverDidShow:note];
    }];
    if (popoverToken) [self.interactionObserverTokens addObject:popoverToken];

    id windowCloseToken = [center addObserverForName:NSWindowWillCloseNotification
                                              object:nil
                                               queue:[NSOperationQueue mainQueue]
                                          usingBlock:^(NSNotification *note) {
        [weakSelf handleWindowWillClose:note];
    }];
    if (windowCloseToken) [self.interactionObserverTokens addObject:windowCloseToken];

    [self recordInteractionMessage:@"Interaction tracing enabled"];
}

- (void)stopInteractionTrace {
    if (self.interactionObserverTokens.count == 0) return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (id token in self.interactionObserverTokens) {
        [center removeObserver:token];
    }
    self.interactionObserverTokens = nil;
}

- (void)setupPanelIfNeeded {
    if (self.panel) return;

    NSRect screenFrame = [[NSScreen mainScreen] visibleFrame];
    CGFloat width = 920.0;
    CGFloat height = 520.0;
    CGFloat x = NSMaxX(screenFrame) - width - 40.0;
    CGFloat y = NSMidY(screenFrame) - height / 2.0;
    NSRect frame = NSMakeRect(MAX(x, 60.0), MAX(y, 80.0), width, height);

    self.panel = [[NSPanel alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskResizable |
                                                       NSWindowStyleMaskUtilityWindow)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"SpliceKit Log";
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = NO;
    self.panel.hidesOnDeactivate = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.minSize = NSMakeSize(640.0, 320.0);
    self.panel.releasedWhenClosed = NO;
    self.panel.delegate = self;
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorCanJoinAllSpaces;

    NSView *content = self.panel.contentView;

    NSView *header = [[NSView alloc] initWithFrame:NSZeroRect];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:header];

    NSView *statusRow = [[NSView alloc] initWithFrame:NSZeroRect];
    statusRow.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:statusRow];

    NSView *controlRow = [[NSView alloc] initWithFrame:NSZeroRect];
    controlRow.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:controlRow];

    NSView *filterRow = [[NSView alloc] initWithFrame:NSZeroRect];
    filterRow.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:filterRow];

    self.statusLabel = [NSTextField labelWithString:@"Waiting for log output..."];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    if ([self.statusLabel.cell isKindOfClass:[NSTextFieldCell class]]) {
        ((NSTextFieldCell *)self.statusLabel.cell).lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    [statusRow addSubview:self.statusLabel];

    NSButton *clearButton = [NSButton buttonWithTitle:@"Clear"
                                               target:self
                                               action:@selector(clearClicked:)];
    clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    clearButton.bezelStyle = NSBezelStyleRounded;
    [statusRow addSubview:clearButton];

    NSButton *revealButton = [NSButton buttonWithTitle:@"Reveal Log"
                                                target:self
                                                action:@selector(revealClicked:)];
    revealButton.translatesAutoresizingMaskIntoConstraints = NO;
    revealButton.bezelStyle = NSBezelStyleRounded;
    [statusRow addSubview:revealButton];

    NSTextField *sourcesLabel = [NSTextField labelWithString:@"Sources:"];
    sourcesLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [controlRow addSubview:sourcesLabel];

    self.spliceKitCheckbox = SpliceKitLogPanel_makeCheckbox(@"SpliceKit", self, @selector(logOptionsChanged:));
    [controlRow addSubview:self.spliceKitCheckbox];

    self.unifiedCheckbox = SpliceKitLogPanel_makeCheckbox(@"FCP Unified", self, @selector(logOptionsChanged:));
    [controlRow addSubview:self.unifiedCheckbox];

    self.interactionCheckbox = SpliceKitLogPanel_makeCheckbox(@"Interactions", self, @selector(logOptionsChanged:));
    [controlRow addSubview:self.interactionCheckbox];

    self.repeatLimitCheckbox = SpliceKitLogPanel_makeCheckbox(@"Repeat cap", self, @selector(logOptionsChanged:));
    [controlRow addSubview:self.repeatLimitCheckbox];

    NSTextField *verbosityLabel = [NSTextField labelWithString:@"Verbosity:"];
    verbosityLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [controlRow addSubview:verbosityLabel];

    self.unifiedModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.unifiedModePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.unifiedModePopup addItemsWithTitles:@[@"Important", @"Balanced", @"Verbose", @"Errors"]];
    self.unifiedModePopup.target = self;
    self.unifiedModePopup.action = @selector(logOptionsChanged:);
    [controlRow addSubview:self.unifiedModePopup];

    NSTextField *filterLabel = [NSTextField labelWithString:@"Filter:"];
    filterLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [filterRow addSubview:filterLabel];

    self.filterField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.filterField.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterField.placeholderString = @"Search log text";
    self.filterField.delegate = self;
    self.filterField.target = self;
    self.filterField.action = @selector(filterControlsChanged:);
    [filterRow addSubview:self.filterField];

    NSTextField *scopeLabel = [NSTextField labelWithString:@"Scope:"];
    scopeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [filterRow addSubview:scopeLabel];

    self.filterScopePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.filterScopePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.filterScopePopup addItemsWithTitles:@[@"All", @"Problems", @"SpliceKit", @"Unified", @"Interactions"]];
    self.filterScopePopup.target = self;
    self.filterScopePopup.action = @selector(filterControlsChanged:);
    [filterRow addSubview:self.filterScopePopup];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = YES;
    scrollView.backgroundColor = [NSColor textBackgroundColor];
    [content addSubview:scrollView];

    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    textView.editable = NO;
    textView.richText = NO;
    textView.selectable = YES;
    textView.automaticQuoteSubstitutionEnabled = NO;
    textView.automaticDashSubstitutionEnabled = NO;
    textView.automaticTextReplacementEnabled = NO;
    textView.allowsUndo = NO;
    textView.importsGraphics = NO;
    textView.drawsBackground = YES;
    textView.backgroundColor = [NSColor textBackgroundColor];
    textView.textColor = [NSColor textColor];
    textView.insertionPointColor = [NSColor textColor];
    textView.font = SpliceKitLogPanel_textAttributes()[NSFontAttributeName];
    textView.textContainerInset = NSMakeSize(10.0, 10.0);
    textView.typingAttributes = SpliceKitLogPanel_textAttributes();
    [textView.textStorage setAttributedString:[[NSAttributedString alloc]
        initWithString:@"Waiting for log output...\n"
            attributes:SpliceKitLogPanel_textAttributes()]];
    scrollView.documentView = textView;
    self.textView = textView;

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:content.topAnchor constant:10.0],
        [header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12.0],
        [header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12.0],
        [header.heightAnchor constraintEqualToConstant:88.0],

        [statusRow.topAnchor constraintEqualToAnchor:header.topAnchor],
        [statusRow.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [statusRow.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [statusRow.heightAnchor constraintEqualToConstant:28.0],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:statusRow.leadingAnchor],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:statusRow.centerYAnchor],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:revealButton.leadingAnchor constant:-12.0],

        [clearButton.trailingAnchor constraintEqualToAnchor:statusRow.trailingAnchor],
        [clearButton.centerYAnchor constraintEqualToAnchor:statusRow.centerYAnchor],

        [revealButton.trailingAnchor constraintEqualToAnchor:clearButton.leadingAnchor constant:-8.0],
        [revealButton.centerYAnchor constraintEqualToAnchor:statusRow.centerYAnchor],

        [controlRow.topAnchor constraintEqualToAnchor:statusRow.bottomAnchor constant:4.0],
        [controlRow.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [controlRow.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [controlRow.heightAnchor constraintEqualToConstant:22.0],

        [sourcesLabel.leadingAnchor constraintEqualToAnchor:controlRow.leadingAnchor],
        [sourcesLabel.centerYAnchor constraintEqualToAnchor:controlRow.centerYAnchor],

        [self.spliceKitCheckbox.leadingAnchor constraintEqualToAnchor:sourcesLabel.trailingAnchor constant:8.0],
        [self.spliceKitCheckbox.centerYAnchor constraintEqualToAnchor:controlRow.centerYAnchor],

        [self.unifiedCheckbox.leadingAnchor constraintEqualToAnchor:self.spliceKitCheckbox.trailingAnchor constant:10.0],
        [self.unifiedCheckbox.centerYAnchor constraintEqualToAnchor:controlRow.centerYAnchor],

        [self.interactionCheckbox.leadingAnchor constraintEqualToAnchor:self.unifiedCheckbox.trailingAnchor constant:10.0],
        [self.interactionCheckbox.centerYAnchor constraintEqualToAnchor:controlRow.centerYAnchor],

        [self.repeatLimitCheckbox.leadingAnchor constraintEqualToAnchor:self.interactionCheckbox.trailingAnchor constant:10.0],
        [self.repeatLimitCheckbox.centerYAnchor constraintEqualToAnchor:controlRow.centerYAnchor],

        [verbosityLabel.leadingAnchor constraintEqualToAnchor:self.repeatLimitCheckbox.trailingAnchor constant:18.0],
        [verbosityLabel.centerYAnchor constraintEqualToAnchor:controlRow.centerYAnchor],

        [self.unifiedModePopup.leadingAnchor constraintEqualToAnchor:verbosityLabel.trailingAnchor constant:8.0],
        [self.unifiedModePopup.centerYAnchor constraintEqualToAnchor:controlRow.centerYAnchor],

        [filterRow.topAnchor constraintEqualToAnchor:controlRow.bottomAnchor constant:4.0],
        [filterRow.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [filterRow.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [filterRow.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
        [filterRow.heightAnchor constraintEqualToConstant:24.0],

        [filterLabel.leadingAnchor constraintEqualToAnchor:filterRow.leadingAnchor],
        [filterLabel.centerYAnchor constraintEqualToAnchor:filterRow.centerYAnchor],

        [self.filterField.leadingAnchor constraintEqualToAnchor:filterLabel.trailingAnchor constant:8.0],
        [self.filterField.centerYAnchor constraintEqualToAnchor:filterRow.centerYAnchor],
        [self.filterField.widthAnchor constraintGreaterThanOrEqualToConstant:240.0],

        [scopeLabel.leadingAnchor constraintEqualToAnchor:self.filterField.trailingAnchor constant:12.0],
        [scopeLabel.centerYAnchor constraintEqualToAnchor:filterRow.centerYAnchor],

        [self.filterScopePopup.leadingAnchor constraintEqualToAnchor:scopeLabel.trailingAnchor constant:8.0],
        [self.filterScopePopup.centerYAnchor constraintEqualToAnchor:filterRow.centerYAnchor],
        [self.filterScopePopup.trailingAnchor constraintLessThanOrEqualToAnchor:filterRow.trailingAnchor],

        [scrollView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8.0],
        [scrollView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];

    [self loadControlStateFromDefaults];
}

- (void)startPolling {
    if (self.pollTimer) return;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                      target:self
                                                    selector:@selector(pollLogFile:)
                                                    userInfo:nil
                                                     repeats:YES];
    [self.pollTimer fire];
}

- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)startUnifiedLogStream {
    if (!self.isVisible || !self.includeUnifiedLogs) return;
    if (self.unifiedLogTask) return;

    self.unifiedLogBuffer = [NSMutableData data];
    self.unifiedLogTask = [[NSTask alloc] init];
    self.unifiedLogTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
    self.unifiedLogTask.arguments = @[
        @"stream",
        @"--style", @"compact",
        @"--level", [self unifiedLogLevelString],
        @"--predicate", [self unifiedLogPredicate],
    ];

    self.unifiedLogPipe = [NSPipe pipe];
    self.unifiedLogTask.standardOutput = self.unifiedLogPipe;
    self.unifiedLogTask.standardError = self.unifiedLogPipe;

    __weak typeof(self) weakSelf = self;
    NSFileHandle *readHandle = self.unifiedLogPipe.fileHandleForReading;
    readHandle.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if (data.length == 0) {
            handle.readabilityHandler = nil;
            return;
        }
        [weakSelf handleUnifiedLogChunk:data];
    };

    self.unifiedLogTask.terminationHandler = ^(__unused NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.unifiedLogPipe.fileHandleForReading == readHandle) {
                readHandle.readabilityHandler = nil;
            }
            weakSelf.unifiedLogTask = nil;
            weakSelf.unifiedLogPipe = nil;
            weakSelf.unifiedLogBuffer = nil;
        });
    };

    NSError *error = nil;
    if (![self.unifiedLogTask launchAndReturnError:&error]) {
        self.unifiedLogTask = nil;
        self.unifiedLogPipe = nil;
        self.unifiedLogBuffer = nil;
        [self enqueueDisplayedText:[NSString stringWithFormat:
            @"[%@] [Trace] Failed to start FCP unified log stream: %@\n",
            SpliceKitLogPanel_timestampString(),
            error.localizedDescription ?: @"unknown error"]
                      wantsScroll:YES];
        return;
    }

    [self enqueueDisplayedText:[NSString stringWithFormat:
        @"[%@] [Trace] Streaming live FCP unified logs (%@)\n",
        SpliceKitLogPanel_timestampString(), self.unifiedModeTitle]
                  wantsScroll:YES];
}

- (void)stopUnifiedLogStream {
    self.unifiedLogPipe.fileHandleForReading.readabilityHandler = nil;
    if (self.unifiedLogTask) {
        if (self.unifiedLogTask.running) [self.unifiedLogTask terminate];
        self.unifiedLogTask.terminationHandler = nil;
    }
    self.unifiedLogTask = nil;
    self.unifiedLogPipe = nil;
    self.unifiedLogBuffer = nil;
}

- (void)handleUnifiedLogChunk:(NSData *)data {
    if (data.length == 0 || !self.includeUnifiedLogs) return;

    @synchronized (self) {
        [self.unifiedLogBuffer appendData:data];
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        const char *bytes = self.unifiedLogBuffer.bytes;
        NSUInteger length = self.unifiedLogBuffer.length;
        NSUInteger start = 0;

        for (NSUInteger i = 0; i < length; i++) {
            if (bytes[i] != '\n') continue;
            NSData *lineData = [self.unifiedLogBuffer subdataWithRange:NSMakeRange(start, i - start)];
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            if (!line) line = [[NSString alloc] initWithData:lineData encoding:NSISOLatin1StringEncoding];
            if (line.length > 0 &&
                ![line hasPrefix:@"Filtering the log data using"] &&
                ![line hasPrefix:@"Timestamp"]) {
                [lines addObject:line];
            }
            start = i + 1;
        }

        if (start > 0) {
            NSData *remaining = start < length
                ? [self.unifiedLogBuffer subdataWithRange:NSMakeRange(start, length - start)]
                : [NSData data];
            self.unifiedLogBuffer = [remaining mutableCopy];
        }

        if (lines.count == 0) return;
        NSMutableString *joined = [NSMutableString string];
        for (NSString *line in lines) {
            NSString *storedLine = [line stringByAppendingString:@"\n"];
            [self.unifiedLines addObject:storedLine];
            if (self.unifiedLines.count > kSKLogPanelMaxUnifiedLines) {
                [self.unifiedLines removeObjectAtIndex:0];
            }
            if ([self lineMatchesUnifiedMode:storedLine] &&
                [self lineMatchesFilter:storedLine source:SKLogLineSourceUnified]) {
                [joined appendString:storedLine];
            }
        }
        if (joined.length > 0) {
            [self enqueueDisplayedText:joined wantsScroll:YES];
        }
    }
}

- (void)pollLogFile:(__unused NSTimer *)timer {
    NSString *path = SpliceKitLogPanel_logPath();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attrs) {
        self.readOffset = 0;
        if (self.includeSpliceKitLogs) [self rebuildDisplayedContent];
        return;
    }

    unsigned long long fileSize = [attrs fileSize];
    if (!self.includeSpliceKitLogs) {
        self.readOffset = fileSize;
        return;
    }
    if (fileSize < self.readOffset) {
        [self rebuildDisplayedContent];
        return;
    }
    if (fileSize == self.readOffset) return;

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        [self rebuildDisplayedContent];
        return;
    }

    [handle seekToFileOffset:self.readOffset];
    NSData *delta = [handle readDataToEndOfFile];
    [handle closeFile];
    self.readOffset = fileSize;

    NSString *text = [[NSString alloc] initWithData:delta encoding:NSUTF8StringEncoding];
    if (!text) text = [[NSString alloc] initWithData:delta encoding:NSISOLatin1StringEncoding];
    if (!text.length) return;

    NSString *filtered = [self filteredTextFromString:text source:SKLogLineSourceSpliceKit];
    if (filtered.length > 0) {
        [self enqueueDisplayedText:filtered wantsScroll:YES];
    }
}

- (void)scrollToBottom {
    [self.textView scrollRangeToVisible:NSMakeRange(self.textView.string.length, 0)];
}

- (void)clearClicked:(__unused id)sender {
    NSString *path = SpliceKitLogPanel_logPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [[NSData data] writeToFile:path atomically:YES];
    self.readOffset = 0;
    [self.unifiedLines removeAllObjects];
    [self.interactionLines removeAllObjects];
    [self clearPendingDisplayedText];
    [self rebuildDisplayedContent];
}

- (void)revealClicked:(__unused id)sender {
    NSString *path = SpliceKitLogPanel_logPath();
    NSURL *url = [NSURL fileURLWithPath:path];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        [[NSFileManager defaultManager] createFileAtPath:path contents:[NSData data] attributes:nil];
    }
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
}

- (void)windowWillClose:(__unused NSNotification *)notification {
    [self clearPendingDisplayedText];
    [self stopPolling];
    [self stopUnifiedLogStream];
    [self stopInteractionTrace];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"LogUI"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static BOOL SKLogPanel_sendAction(id selfObj, SEL _cmd, SEL action, id target, id sender) {
    BOOL handled = sSKLogPanelOriginalSendAction
        ? sSKLogPanelOriginalSendAction(selfObj, _cmd, action, target, sender)
        : NO;
    [[SpliceKitLogPanel sharedPanel] recordApplicationAction:action
                                                      target:target
                                                      sender:sender
                                                     handled:handled];
    return handled;
}

@end
