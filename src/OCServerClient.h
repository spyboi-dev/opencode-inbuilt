// OCServerClient - talks to the real OpenCode server over HTTP + SSE.
// Server: opencode serve on 127.0.0.1:4096 (the in-app engine).
// Auth: HTTP Basic, user "opencode", password from the Keychain, on every call.
// API verified live against opencode 2.2.6 (see BUILD-NOTE.md).
// SSE: GET /api/event, events arrive as `data: {json}\n\n`, envelope
// {id, type, data}. The client parses each event and forwards it to its
// delegate; it never assumes a fixed set of event types.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol OCServerEventDelegate <NSObject>
- (void)serverClientDidReceiveEvent:(NSDictionary *)event;
- (void)serverClientEventStreamDidFail:(NSError *)error;
@end

@interface OCServerClient : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, weak, nullable) id<OCServerEventDelegate> eventDelegate;
@property (nonatomic, readonly) BOOL eventStreamRunning;
- (instancetype)initWithServerURL:(NSString *)serverURL password:(nullable NSString *)password;

- (void)healthCheckWithCompletion:(void (^)(BOOL ok, NSDictionary * _Nullable info, NSError * _Nullable error))completion;
- (void)listSessionsWithCompletion:(void (^)(NSArray * _Nullable sessions, NSError * _Nullable error))completion;
- (void)createSessionWithTitle:(nullable NSString *)title agent:(nullable NSString *)agent
                    completion:(void (^)(NSDictionary * _Nullable session, NSError * _Nullable error))completion;
- (void)deleteSession:(NSString *)sessionID completion:(void (^)(NSError * _Nullable error))completion;
- (void)fetchSession:(NSString *)sessionID completion:(void (^)(NSDictionary * _Nullable session, NSError * _Nullable error))completion;
- (void)forkSession:(NSString *)sessionID completion:(void (^)(NSDictionary * _Nullable session, NSError * _Nullable error))completion;
- (void)fetchMessagesForSession:(NSString *)sessionID
                     completion:(void (^)(NSArray * _Nullable messages, NSError * _Nullable error))completion;
- (void)sendPrompt:(NSString *)text toSession:(NSString *)sessionID
        completion:(void (^)(NSDictionary * _Nullable message, NSError * _Nullable error))completion;
- (void)interruptSession:(NSString *)sessionID completion:(void (^)(NSError * _Nullable error))completion;
- (void)listModelsWithCompletion:(void (^)(NSArray * _Nullable models, NSError * _Nullable error))completion;
- (void)listProvidersWithCompletion:(void (^)(NSArray * _Nullable providers, NSError * _Nullable error))completion;
- (void)setModel:(NSString *)modelID providerID:(NSString *)providerID forSession:(NSString *)sessionID
      completion:(void (^)(NSError * _Nullable error))completion;
- (void)fetchContextForSession:(NSString *)sessionID
                    completion:(void (^)(NSDictionary * _Nullable context, NSError * _Nullable error))completion;
- (void)fetchDiffForSession:(NSString *)sessionID
                 completion:(void (^)(NSArray * _Nullable diff, NSError * _Nullable error))completion;
- (void)revertSession:(NSString *)sessionID completion:(void (^)(NSError * _Nullable error))completion;
- (void)fetchPermissionsForSession:(NSString *)sessionID
                        completion:(void (^)(NSArray * _Nullable requests, NSError * _Nullable error))completion;
- (void)replyPermission:(NSString *)requestID sessionID:(NSString *)sessionID
               decision:(NSString *)decision // "once", "always" or "reject"
             completion:(void (^)(NSError * _Nullable error))completion;
- (void)listFilesAtPath:(NSString *)path
             completion:(void (^)(NSArray * _Nullable entries, NSError * _Nullable error))completion;
- (void)readFileAtPath:(NSString *)path
            completion:(void (^)(NSString * _Nullable content, NSError * _Nullable error))completion;
- (void)writeFileAtPath:(NSString *)path content:(NSData *)content
             completion:(void (^)(NSString * _Nullable resolvedPath, NSError * _Nullable error))completion;
- (void)runShellCommand:(NSString *)command inSession:(NSString *)sessionID
             completion:(void (^)(NSDictionary * _Nullable shell, NSError * _Nullable error))completion;
- (void)shellOutput:(NSString *)shellID
         completion:(void (^)(NSDictionary * _Nullable output, NSError * _Nullable error))completion;

- (void)startEventStream;
- (void)stopEventStream;
@end

NS_ASSUME_NONNULL_END
