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
                    [la appendAttributedString:[[NSAttributedString alloc] initWithString:chunk attributes:@{NSFontAttributeName: bold}]];
                    [sc scanString:@"**" intoString:nil];
                }
            } else if ([sc scanString:@"`" intoString:nil]) {
                if ([sc scanUpToString:@"`" intoString:&chunk]) {
                    [la appendAttributedString:[[NSAttributedString alloc] initWithString:chunk attributes:@{NSFontAttributeName: mono, NSBackgroundColorAttributeName: [UIColor colorWithWhite:0.92 alpha:1]}]];
                    [sc scanString:@"`" intoString:nil];
                }
            } else if ([sc scanUpToCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@"*`"] intoString:&chunk]) {
                [la appendAttributedString:[[NSAttributedString alloc] initWithString:chunk attributes:@{NSFontAttributeName: lineFont}]];
            } else {
                // lone * or ` character
                [la appendAttributedString:[[NSAttributedString alloc] initWithString:[t substringWithRange:NSMakeRange(sc.scanLocation, 1)] attributes:@{NSFontAttributeName: lineFont}]];
                sc.scanLocation += 1;
            }
        }
        if (!la.length) [la appendAttributedString:[[NSAttributedString alloc] initWithString:@"" attributes:@{NSFontAttributeName: lineFont}]];
        [out appendAttributedString:la];
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:@{NSFontAttributeName: font}]];
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
    for (NSDictionary *d in diff) {
        NSString *type = d[@"type"];
        UIColor *bg = [UIColor whiteColor];
        NSString *prefix = @"  ";
        if ([type isEqualToString:@"add"]) { bg = [UIColor colorWithRed:0.85 green:0.97 blue:0.86 alpha:1]; prefix = @"+ "; }
        else if ([type isEqualToString:@"del"]) { bg = [UIColor colorWithRed:0.99 green:0.88 blue:0.88 alpha:1]; prefix = @"- "; }
        NSString *line = [prefix stringByAppendingString:[d[@"text"] stringByAppendingString:@"\n"]];
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:@{NSFontAttributeName: mono, NSBackgroundColorAttributeName: bg}]];
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
