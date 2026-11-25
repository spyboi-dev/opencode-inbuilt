// OCServerClient - talks to the real OpenCode server over HTTP + SSE.
#import "OCServerClient.h"
#import "OCUtil.h"

@interface OCServerClient ()
@property (nonatomic, copy) NSString *serverURL;
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic, strong, nullable) NSURLSession *eventSession;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *eventTask;
@property (nonatomic, strong) NSMutableData *eventBuffer;
@property (nonatomic, assign) BOOL eventStreamWanted;
@end

@implementation OCServerClient

- (instancetype)initWithServerURL:(NSString *)serverURL password:(nullable NSString *)password {
    if ((self = [super init])) {
        _serverURL = [serverURL copy];
        _password = [password copy];
        _eventBuffer = [NSMutableData data];
    }
    return self;
}

#pragma mark - HTTP plumbing

- (NSString *)authHeader {
    if (!self.password.length) return @"";
    NSString *raw = [@"opencode:" stringByAppendingString:self.password];
    NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    return [@"Basic " stringByAppendingString:[data base64EncodedStringWithOptions:0]];
}

- (NSMutableURLRequest *)requestForPath:(NSString *)path method:(NSString *)method body:(nullable NSDictionary *)body {
    NSURL *url = [NSURL URLWithString:[self.serverURL stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    req.timeoutInterval = 30;
    NSString *auth = [self authHeader];
    if (auth.length) [req setValue:auth forHTTPHeaderField:@"Authorization"];
    if (body) {
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    return req;
}

- (void)runRequest:(NSMutableURLRequest *)req completion:(void (^)(id _Nullable json, NSError * _Nullable error))completion {
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); }); return; }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSString *msg = [NSString stringWithFormat:@"Server returned HTTP %ld", (long)http.statusCode];
            NSError *e = [NSError errorWithDomain:@"OCServerClient" code:http.statusCode
                                         userInfo:@{NSLocalizedDescriptionKey: msg}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, e); });
            return;
        }
        id json = nil;
        if (data.length) json = [OCUtil jsonObjectFromData:data];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(json, nil); });
    }];
    [task resume];
}

- (void)get:(NSString *)path completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    [self runRequest:[self requestForPath:path method:@"GET" body:nil] completion:completion];
}

- (void)post:(NSString *)path body:(nullable NSDictionary *)body completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    [self runRequest:[self requestForPath:path method:@"POST" body:body ?: @{}] completion:completion];
}

- (void)delete:(NSString *)path completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    [self runRequest:[self requestForPath:path method:@"DELETE" body:nil] completion:completion];
}

+ (NSArray *)dataArrayFromResponse:(nullable id)json {
    if ([json isKindOfClass:[NSDictionary class]]) {
        id data = json[@"data"];
        if ([data isKindOfClass:[NSArray class]]) return data;
    }
    return @[];
}

#pragma mark - Health, sessions, messages

- (void)healthCheckWithCompletion:(void (^)(BOOL, NSDictionary * _Nullable, NSError * _Nullable))completion {
    [self get:@"/api/info" completion:^(id json, NSError *error) {
        if (error) { completion(NO, nil, error); return; }
        completion(YES, [json isKindOfClass:[NSDictionary class]] ? json : @{}, nil);
    }];
}

- (void)listSessionsWithCompletion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    [self get:@"/api/session" completion:^(id json, NSError *error) {
        completion(error ? nil : [OCServerClient dataArrayFromResponse:json], error);
    }];
}

- (void)createSessionWithTitle:(nullable NSString *)title agent:(nullable NSString *)agent
                    completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    if (title.length) body[@"title"] = title;
    if (agent.length) body[@"agent"] = agent;
    [self post:@"/api/session" body:body completion:^(id json, NSError *error) {
        NSDictionary *session = nil;
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"data"] isKindOfClass:[NSDictionary class]]) session = json[@"data"];
        completion(session, error);
    }];
}

- (void)fetchSession:(NSString *)sessionID completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@", sessionID];
    [self get:path completion:^(id json, NSError *error) {
        NSDictionary *session = nil;
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"data"] isKindOfClass:[NSDictionary class]]) session = json[@"data"];
        completion(session, error);
    }];
}

- (void)deleteSession:(NSString *)sessionID completion:(void (^)(NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@", sessionID];
    [self delete:path completion:^(id json, NSError *error) { (void)json; completion(error); }];
}

- (void)forkSession:(NSString *)sessionID completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@/fork", sessionID];
    [self post:path body:@{} completion:^(id json, NSError *error) {
        NSDictionary *session = nil;
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"data"] isKindOfClass:[NSDictionary class]]) session = json[@"data"];
        completion(session, error);
    }];
}

- (void)fetchMessagesForSession:(NSString *)sessionID completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@/message", sessionID];
    [self get:path completion:^(id json, NSError *error) {
        completion(error ? nil : [OCServerClient dataArrayFromResponse:json], error);
    }];
}

- (void)sendPrompt:(NSString *)text toSession:(NSString *)sessionID
        completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@/prompt", sessionID];
    [self post:path body:@{@"text": text ?: @""} completion:^(id json, NSError *error) {
        NSDictionary *message = nil;
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"data"] isKindOfClass:[NSDictionary class]]) message = json[@"data"];
        completion(message, error);
    }];
}

- (void)interruptSession:(NSString *)sessionID completion:(void (^)(NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@/interrupt", sessionID];
    [self post:path body:@{} completion:^(id json, NSError *error) { (void)json; completion(error); }];
}

#pragma mark - Models, providers, context, diff

- (void)listModelsWithCompletion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    [self get:@"/api/model" completion:^(id json, NSError *error) {
        completion(error ? nil : [OCServerClient dataArrayFromResponse:json], error);
    }];
}

- (void)listProvidersWithCompletion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    [self get:@"/api/provider" completion:^(id json, NSError *error) {
        completion(error ? nil : [OCServerClient dataArrayFromResponse:json], error);
    }];
}

- (void)setModel:(NSString *)modelID providerID:(NSString *)providerID forSession:(NSString *)sessionID
      completion:(void (^)(NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@/model", sessionID];
    NSDictionary *body = @{@"model": @{@"id": modelID, @"providerID": providerID}};
    [self post:path body:body completion:^(id json, NSError *error) { (void)json; completion(error); }];
}

- (void)fetchContextForSession:(NSString *)sessionID completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@/context", sessionID];
    [self get:path completion:^(id json, NSError *error) {
        NSDictionary *ctx = nil;
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"data"] isKindOfClass:[NSDictionary class]]) ctx = json[@"data"];
        completion(ctx, error);
    }];
}

- (void)fetchDiffForSession:(NSString *)sessionID completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@/diff", sessionID];
    [self get:path completion:^(id json, NSError *error) {
        completion(error ? nil : [OCServerClient dataArrayFromResponse:json], error);
    }];
}

- (void)revertSession:(NSString *)sessionID completion:(void (^)(NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@/revert", sessionID];
    [self post:path body:@{} completion:^(id json, NSError *error) { (void)json; completion(error); }];
}

- (void)fetchPermissionsForSession:(NSString *)sessionID completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@/permission", sessionID];
    [self get:path completion:^(id json, NSError *error) {
        completion(error ? nil : [OCServerClient dataArrayFromResponse:json], error);
    }];
}

- (void)replyPermission:(NSString *)requestID sessionID:(NSString *)sessionID decision:(NSString *)decision
             completion:(void (^)(NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@/permission/%@/reply", sessionID, requestID];
    [self post:path body:@{@"decision": decision} completion:^(id json, NSError *error) { (void)json; completion(error); }];
}

#pragma mark - Files, shell

- (void)listFilesAtPath:(NSString *)path completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    [self get:[NSString stringWithFormat:@"/api/fs/list?path=%@", encoded ?: @"/"] completion:^(id json, NSError *error) {
        completion(error ? nil : [OCServerClient dataArrayFromResponse:json], error);
    }];
}

- (void)readFileAtPath:(NSString *)path completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlPath = [NSString stringWithFormat:@"/api/fs/read/%@", encoded ?: @""];
    NSURL *url = [NSURL URLWithString:[self.serverURL stringByAppendingString:urlPath]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 30;
    NSString *auth = [self authHeader];
    if (auth.length) [req setValue:auth forHTTPHeaderField:@"Authorization"];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        (void)response;
        NSString *text = nil;
        if (!error && data.length) text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text && data.length) {
            id json = [OCUtil jsonObjectFromData:data];
            if ([json isKindOfClass:[NSDictionary class]] && [json[@"data"] isKindOfClass:[NSString class]]) text = json[@"data"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(text, error); });
    }];
    [task resume];
}

- (void)writeFileAtPath:(NSString *)path content:(NSData *)content completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    // POST /api/experimental/fs/write — the server writes the raw
    // request body to the path (absolute, or relative to the
    // location; unlike read it is not confined to it) and returns
    // the resolved absolute path in data.path. The desktop app
    // uploads attachments through this endpoint, and the 2.3.0
    // server in the guest has it (verified in the pinned source
    // and the shipped binary). The engine uses it to deliver the
    // desktop bootstrap script as a file instead of typing it
    // into the console (see OCEngine deliverDesktopBootstrap).
    NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlPath = [NSString stringWithFormat:@"/api/experimental/fs/write?path=%@", encoded ?: @""];
    NSURL *url = [NSURL URLWithString:[self.serverURL stringByAppendingString:urlPath]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30;
    NSString *auth = [self authHeader];
    if (auth.length) [req setValue:auth forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = content;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSString *resolved = nil;
        NSError *resultError = error;
        if (!resultError) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (http.statusCode < 200 || http.statusCode >= 300) {
                NSString *msg = [NSString stringWithFormat:@"Server returned HTTP %ld", (long)http.statusCode];
                resultError = [NSError errorWithDomain:@"OCServerClient" code:http.statusCode
                                              userInfo:@{NSLocalizedDescriptionKey: msg}];
            } else {
                if (data.length) {
                    id json = [OCUtil jsonObjectFromData:data];
                    if ([json isKindOfClass:[NSDictionary class]] && [json[@"data"] isKindOfClass:[NSDictionary class]]) {
                        id p = json[@"data"][@"path"];
                        if ([p isKindOfClass:[NSString class]]) resolved = p;
                    }
                }
                if (!resolved.length) resolved = path;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(resolved, resultError); });
    }];
    [task resume];
}

- (void)runShellCommand:(NSString *)command inSession:(NSString *)sessionID
             completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/session/%@/shell", sessionID];
    [self post:path body:@{@"command": command} completion:^(id json, NSError *error) {
        NSDictionary *shell = nil;
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"data"] isKindOfClass:[NSDictionary class]]) shell = json[@"data"];
        completion(shell, error);
    }];
}

- (void)shellOutput:(NSString *)shellID completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    NSString *path = [NSString stringWithFormat:@"/api/shell/%@/output", shellID];
    [self get:path completion:^(id json, NSError *error) {
        NSDictionary *out = nil;
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"data"] isKindOfClass:[NSDictionary class]]) out = json[@"data"];
        completion(out, error);
    }];
}

#pragma mark - SSE event stream

- (BOOL)eventStreamRunning { return self.eventTask != nil; }

- (void)startEventStream {
    if (self.eventTask) return;
    self.eventStreamWanted = YES;
    NSURL *url = [NSURL URLWithString:[self.serverURL stringByAppendingString:@"/api/event"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 0; // long-lived stream
    NSString *auth = [self authHeader];
    if (auth.length) [req setValue:auth forHTTPHeaderField:@"Authorization"];
    [req setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 0;
    config.timeoutIntervalForResource = 0;
    self.eventSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    self.eventTask = [self.eventSession dataTaskWithRequest:req];
    [self.eventBuffer setLength:0];
    [self.eventTask resume];
}

- (void)stopEventStream {
    self.eventStreamWanted = NO;
    [self.eventTask cancel];
    self.eventTask = nil;
    [self.eventSession invalidateAndCancel];
    self.eventSession = nil;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.eventBuffer appendData:data];
    // Parse complete `data: {...}\n\n` frames.
    while (YES) {
        NSData *sep = [@"\n\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange range = [self.eventBuffer rangeOfData:sep options:0 range:NSMakeRange(0, self.eventBuffer.length)];
        if (range.location == NSNotFound) break;
        NSData *frame = [self.eventBuffer subdataWithRange:NSMakeRange(0, range.location)];
        [self.eventBuffer replaceBytesInRange:NSMakeRange(0, range.location + range.length) withBytes:NULL length:0];
        NSString *text = [[NSString alloc] initWithData:frame encoding:NSUTF8StringEncoding];
        if (!text.length) continue;
        NSMutableString *payload = [NSMutableString string];
        for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"data:"]) [payload appendString:[line substringFromIndex:5]];
            else if ([line hasPrefix:@":"]) { /* comment / heartbeat, ignore */ }
        }
        NSString *trimmed = [payload stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!trimmed.length) continue;
        id json = [OCUtil jsonObjectFromString:trimmed];
        if ([json isKindOfClass:[NSDictionary class]]) {
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.eventDelegate serverClientDidReceiveEvent:json];
            });
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(nullable NSError *)error {
    BOOL wasTask = (task == self.eventTask);
    self.eventTask = nil;
    if (!wasTask) return;
    if (!self.eventStreamWanted) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSError *e = error ?: [NSError errorWithDomain:@"OCServerClient" code:-1
                                              userInfo:@{NSLocalizedDescriptionKey: @"Event stream closed"}];
        [strongSelf.eventDelegate serverClientEventStreamDidFail:e];
        // Auto-reconnect after a short pause while the user still wants the stream.
        if (strongSelf.eventStreamWanted) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (strongSelf.eventStreamWanted && !strongSelf.eventTask) [strongSelf startEventStream];
            });
        }
    });
}

@end
