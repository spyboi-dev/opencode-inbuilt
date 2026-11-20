// OCVsockBridge - see OCVsockBridge.h.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "OCVsockBridge.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>

static const uint32_t kVsockConnectTimeoutMs = 5000;
static const NSUInteger kMaxTrackedFds = 64;

@interface OCVsockBridge () {
    OCVsockConnectBlock _connectVsock;
    int _listenerFd;
    BOOL _running;
    uint16_t _localPort;
    uint32_t _vsockPort;
    NSMutableSet<NSNumber *> *_liveFds;
    NSLock *_fdsLock;
}
@end

@implementation OCVsockBridge

- (instancetype)initWithConnectVsock:(OCVsockConnectBlock)connectVsock {
    if ((self = [super init])) {
        _connectVsock = [connectVsock copy];
        _listenerFd = -1;
        _liveFds = [NSMutableSet set];
        _fdsLock = [[NSLock alloc] init];
    }
    return self;
}

- (BOOL)running { return _running; }
- (uint16_t)localPort { return _localPort; }
- (uint32_t)vsockPort { return _vsockPort; }

- (void)trackFd:(int)fd {
    [_fdsLock lock];
    if (_liveFds.count < kMaxTrackedFds) [_liveFds addObject:@(fd)];
    [_fdsLock unlock];
}

- (void)untrackFd:(int)fd {
    [_fdsLock lock];
    [_liveFds removeObject:@(fd)];
    [_fdsLock unlock];
}

- (BOOL)startOnLocalPort:(uint16_t)localPort vsockPort:(uint32_t)vsockPort error:(NSError **)error {
    if (_running) return YES;
    if (!_connectVsock) {
        if (error) *error = [NSError errorWithDomain:@"OCVsockBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No vsock connect function (runtime not loaded)"}];
        return NO;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:@"OCVsockBridge" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Could not open the loopback socket"}];
        return NO;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(localPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 32) != 0) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:@"OCVsockBridge" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not listen on 127.0.0.1:%u", localPort]}];
        return NO;
    }
    _listenerFd = fd;
    _localPort = localPort;
    _vsockPort = vsockPort;
    _running = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [weakSelf acceptLoop];
    });
    return YES;
}

- (void)stop {
    _running = NO;
    if (_listenerFd >= 0) {
        // Closing the listener unblocks accept(); shutdown first so a
        // thread stuck in accept() wakes even on platforms where
        // close() alone does not.
        shutdown(_listenerFd, SHUT_RDWR);
        close(_listenerFd);
        _listenerFd = -1;
    }
    [_fdsLock lock];
    NSArray<NSNumber *> *fds = [_liveFds allObjects];
    [_fdsLock unlock];
    for (NSNumber *n in fds) {
        shutdown(n.intValue, SHUT_RDWR);
        close(n.intValue);
    }
}

- (void)acceptLoop {
    while (_running) {
        int client = accept(_listenerFd, NULL, NULL);
        if (client < 0) {
            if (!_running) return;
            continue;
        }
        [self trackFd:client];
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [weakSelf handleClient:client];
        });
    }
}

// One accepted connection: open the vsock stream, then pump both
// directions until either side closes. A half-close (the guest's
// shutdown(SHUT_WR), which a blocking read can miss) is honoured by
// polling: when one direction hits EOF we shut down the write side of
// the other, so the peer sees a clean EOF instead of a hang.
- (void)handleClient:(int)client {
    int vsock = _connectVsock(_vsockPort, kVsockConnectTimeoutMs);
    if (vsock < 0) {
        // Nothing listens in the guest yet (server not up, or the
        // guest-side socat proxy is not running). Fail fast with a
        // refused connection so health checks retry instead of hanging.
        [self untrackFd:client];
        close(client);
        return;
    }
    [self trackFd:vsock];
    __weak typeof(self) weakSelf = self;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [weakSelf pumpFrom:client to:vsock];
        dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [weakSelf pumpFrom:vsock to:client];
        dispatch_group_leave(group);
    });
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    shutdown(client, SHUT_RDWR);
    shutdown(vsock, SHUT_RDWR);
    close(client);
    close(vsock);
    [self untrackFd:client];
    [self untrackFd:vsock];
}

- (void)pumpFrom:(int)src to:(int)dst {
    uint8_t buffer[16384];
    while (YES) {
        struct pollfd pfd;
        pfd.fd = src;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int ready = poll(&pfd, 1, 5000);
        if (ready <= 0) {
            // Timeout: keep waiting while the bridge runs; an error
            // or hangup ends this direction.
            if (ready < 0) return;
            if (!_running) return;
            continue;
        }
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) return;
        if (!(pfd.revents & POLLIN)) continue;
        ssize_t n = read(src, buffer, sizeof(buffer));
        if (n <= 0) {
            // EOF or error: tell the peer no more bytes are coming
            // this way, so it sees a clean EOF instead of a hang.
            // The opposite direction keeps pumping.
            shutdown(dst, SHUT_WR);
            return;
        }
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(dst, buffer + off, (size_t)(n - off));
            if (w <= 0) return;
            off += w;
        }
    }
}

@end
