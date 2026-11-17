// OCUtil - small shared helpers: JSON, dates, markdown, line diff.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCUtil : NSObject
+ (NSString *)uuidString;
+ (NSString *)nowISO;
+ (NSString *)jsonString:(id)obj;
+ (nullable id)jsonObjectFromData:(NSData *)data;
+ (nullable id)jsonObjectFromString:(NSString *)s;
+ (NSString *)truncate:(NSString *)s toLength:(NSUInteger)n;
// Very small markdown renderer: **bold**, `code`, # headers, - bullets.
+ (NSAttributedString *)attributedFromMarkdown:(NSString *)text baseFont:(UIFont *)font;
// Line diff: returns array of @{@"type":@"same"|@"add"|@"del", @"text":...}
+ (NSArray<NSDictionary *> *)lineDiffFromOld:(NSString *)oldText newText:(NSString *)newText;
+ (NSAttributedString *)attributedDiff:(NSArray<NSDictionary *> *)diff;
// Resolve a user path inside the workspace; returns nil if it escapes.
+ (nullable NSString *)workspacePathForRelative:(NSString *)rel;
+ (NSString *)workspaceRoot;
+ (NSString *)relativePath:(NSString *)abs;
+ (NSString *)displayPath:(NSString *)abs;
@end

NS_ASSUME_NONNULL_END
