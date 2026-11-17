#import "OCUtil.h"

@implementation OCUtil

+ (NSString *)uuidString { return [[NSUUID UUID] UUIDString]; }

+ (NSString *)nowISO {
    static NSDateFormatter *f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [[NSDateFormatter alloc] init]; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'"; f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0]; });
    return [f stringFromDate:[NSDate date]];
}

+ (NSString *)jsonString:(id)obj {
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&e];
    if (!d) return @"{}";
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

+ (nullable id)jsonObjectFromData:(NSData *)data {
    if (!data.length) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
}

+ (nullable id)jsonObjectFromString:(NSString *)s {
    if (!s.length) return nil;
    return [self jsonObjectFromData:[s dataUsingEncoding:NSUTF8StringEncoding]];
}

+ (NSString *)truncate:(NSString *)s toLength:(NSUInteger)n {
    if (s.length <= n) return s;
    return [[s substringToIndex:n] stringByAppendingString:@"..."];
}

+ (NSAttributedString *)attributedFromMarkdown:(NSString *)text baseFont:(UIFont *)font {
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    UIFont *bold = [UIFont boldSystemFontOfSize:font.pointSize];
    UIFont *mono = [UIFont monospacedSystemFontOfSize:font.pointSize - 1 weight:UIFontWeightRegular];
    UIFont *hFont = [UIFont boldSystemFontOfSize:font.pointSize + 3];
    // Every run carries an explicit foreground colour. Without it the
    // text falls back to the label's default textColor, which is black,
    // so in dark mode the body would be invisible; and the old inline
    // code background (0.92 white) made white code text unreadable,
    // the white boxes in the 2026-11-17 screenshots.
    UIColor *fg = [UIColor labelColor];
    UIColor *codeBG = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x2e/255.0 green:0x2e/255.0 blue:0x2e/255.0 alpha:1.0] : [UIColor colorWithWhite:0.92 alpha:1];
    }];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        NSString *t = line;
        UIFont *lineFont = font;
        if ([t hasPrefix:@"### "]) { t = [t substringFromIndex:4]; lineFont = hFont; }
        else if ([t hasPrefix:@"## "]) { t = [t substringFromIndex:3]; lineFont = hFont; }
        else if ([t hasPrefix:@"# "]) { t = [t substringFromIndex:2]; lineFont = hFont; }
        else if ([t hasPrefix:@"- "] || [t hasPrefix:@"* "]) { t = [@"\u2022 " stringByAppendingString:[t substringFromIndex:2]]; }
        // inline **bold** and `code`
        NSMutableAttributedString *la = [[NSMutableAttributedString alloc] init];
        NSScanner *sc = [NSScanner scannerWithString:t];
        sc.charactersToBeSkipped = nil;
        while (!sc.isAtEnd) {
            NSString *chunk = nil;
            if ([sc scanString:@"**" intoString:nil]) {
                if ([sc scanUpToString:@"**" intoString:&chunk]) {
                    [la appendAttributedString:[[NSAttributedString alloc] initWithString:chunk attributes:@{NSFontAttributeName: bold, NSForegroundColorAttributeName: fg}]];
                    [sc scanString:@"**" intoString:nil];
                }
            } else if ([sc scanString:@"`" intoString:nil]) {
                if ([sc scanUpToString:@"`" intoString:&chunk]) {
                    [la appendAttributedString:[[NSAttributedString alloc] initWithString:chunk attributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: fg, NSBackgroundColorAttributeName: codeBG}]];
                    [sc scanString:@"`" intoString:nil];
                }
            } else if ([sc scanUpToCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@"*`"] intoString:&chunk]) {
                [la appendAttributedString:[[NSAttributedString alloc] initWithString:chunk attributes:@{NSFontAttributeName: lineFont, NSForegroundColorAttributeName: fg}]];
            } else {
                // lone * or ` character
                [la appendAttributedString:[[NSAttributedString alloc] initWithString:[t substringWithRange:NSMakeRange(sc.scanLocation, 1)] attributes:@{NSFontAttributeName: lineFont, NSForegroundColorAttributeName: fg}]];
                sc.scanLocation += 1;
            }
        }
        if (!la.length) [la appendAttributedString:[[NSAttributedString alloc] initWithString:@"" attributes:@{NSFontAttributeName: lineFont, NSForegroundColorAttributeName: fg}]];
        [out appendAttributedString:la];
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: fg}]];
    }
    return out;
}

+ (NSArray<NSDictionary *> *)lineDiffFromOld:(NSString *)oldText newText:(NSString *)newText {
    NSArray<NSString *> *a = [oldText componentsSeparatedByString:@"\n"];
    NSArray<NSString *> *b = [newText componentsSeparatedByString:@"\n"];
    NSUInteger n = a.count, m = b.count;
    // LCS table (cap: files over 2000 lines fall back to whole-file replace view)
    if (n > 2000 || m > 2000) return @[@{@"type": @"del", @"text": oldText}, @{@"type": @"add", @"text": newText}];
    NSMutableArray<NSMutableArray<NSNumber *> *> *dp = [NSMutableArray array];
    for (NSUInteger i = 0; i <= n; i++) {
        NSMutableArray<NSNumber *> *row = [NSMutableArray array];
        for (NSUInteger j = 0; j <= m; j++) [row addObject:@0];
        [dp addObject:row];
    }
    for (NSInteger i = (NSInteger)n - 1; i >= 0; i--) {
        for (NSInteger j = (NSInteger)m - 1; j >= 0; j--) {
            if ([a[i] isEqualToString:b[j]]) dp[i][j] = @([dp[i+1][j+1] integerValue] + 1);
            else dp[i][j] = @(MAX([dp[i+1][j] integerValue], [dp[i][j+1] integerValue]));
        }
    }
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSUInteger i = 0, j = 0;
    while (i < n && j < m) {
        if ([a[i] isEqualToString:b[j]]) { [out addObject:@{@"type": @"same", @"text": a[i]}]; i++; j++; }
        else if ([dp[i+1][j] integerValue] >= [dp[i][j+1] integerValue]) { [out addObject:@{@"type": @"del", @"text": a[i]}]; i++; }
        else { [out addObject:@{@"type": @"add", @"text": b[j]}]; j++; }
    }
    while (i < n) { [out addObject:@{@"type": @"del", @"text": a[i]}]; i++; }
    while (j < m) { [out addObject:@{@"type": @"add", @"text": b[j]}]; j++; }
    return out;
}

+ (NSAttributedString *)attributedDiff:(NSArray<NSDictionary *> *)diff {
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    UIFont *mono = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    UIColor *fg = [UIColor labelColor];
    for (NSDictionary *d in diff) {
        NSString *type = d[@"type"];
        // Dark mode gets dark tints, light mode the old pastels, so
        // the text stays readable in both.
        UIColor *bg = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x1c/255.0 green:0x1c/255.0 blue:0x1c/255.0 alpha:1.0] : [UIColor whiteColor];
        }];
        NSString *prefix = @"  ";
        if ([type isEqualToString:@"add"]) {
            bg = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
                return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x14/255.0 green:0x33/255.0 blue:0x1e/255.0 alpha:1.0] : [UIColor colorWithRed:0.85 green:0.97 blue:0.86 alpha:1];
            }];
            prefix = @"+ ";
        } else if ([type isEqualToString:@"del"]) {
            bg = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
                return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0x3d/255.0 green:0x1a/255.0 blue:0x1a/255.0 alpha:1.0] : [UIColor colorWithRed:0.99 green:0.88 blue:0.88 alpha:1];
            }];
            prefix = @"- ";
        }
        NSString *line = [prefix stringByAppendingString:[d[@"text"] stringByAppendingString:@"\n"]];
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: fg, NSBackgroundColorAttributeName: bg}]];
    }
    return out;
}

+ (NSString *)workspaceRoot {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *root = [[paths firstObject] stringByAppendingPathComponent:@"Workspace"];
    [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

+ (nullable NSString *)workspacePathForRelative:(NSString *)rel {
    NSString *clean = [rel stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!clean.length) return nil;
    if ([clean hasPrefix:@"/"]) clean = [clean substringFromIndex:1];
    NSString *root = [self workspaceRoot];
    NSString *full = [[root stringByAppendingPathComponent:clean] stringByStandardizingPath];
    if (![full hasPrefix:root]) return nil; // escapes the sandbox workspace
    return full;
}

+ (NSString *)relativePath:(NSString *)abs {
    NSString *root = [self workspaceRoot];
    if ([abs hasPrefix:root]) return [abs substringFromIndex:root.length + 1];
    return abs;
}

+ (NSString *)displayPath:(NSString *)abs { return [self relativePath:abs]; }

@end
