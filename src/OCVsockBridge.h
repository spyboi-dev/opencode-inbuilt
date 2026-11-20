// OCVsockBridge: the host half of the host<->guest bridge (see
// KERNARIUM-ENGINE.md section 4).
//
// The Kernarium guest does NOT share the host's loopback, so
// OCServerClient cannot reach the guest server at 127.0.0.1:4096
// directly. This bridge listens on 127.0.0.1:<localPort> and, for each
// accepted connection, opens a vsock stream to the guest
// (connect_vsock) and pumps bytes both ways until either side closes.
// From OCServerClient's side nothing changes: it still talks
// NSURLSession to http://127.0.0.1:4096, including the long-lived SSE
// stream (each reconnect is a new loopback connection, hence a new
// vsock stream).
//
// The guest half is socat, baked into the image and started by the
// console bootstrap (or its systemd unit):
//   socat VSOCK-LISTEN:4096,fork TCP:127.0.0.1:4096
// A second bridge on 8000 serves the user's app.py the same way.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

// Returns a connected SOCK_STREAM fd owned by the caller, or a
// negative errno (as kernarium_runtime_connect_vsock does).
typedef int (^OCVsockConnectBlock)(uint32_t port, uint32_t timeoutMs);

@interface OCVsockBridge : NSObject

- (instancetype)initWithConnectVsock:(OCVsockConnectBlock)connectVsock;

// Start listening on 127.0.0.1:localPort, forwarding each connection
// to vsockPort in the guest. NO if the port cannot be claimed.
- (BOOL)startOnLocalPort:(uint16_t)localPort
              vsockPort:(uint32_t)vsockPort
                  error:(NSError **)error;

- (void)stop;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) uint16_t localPort;
@property (nonatomic, readonly) uint32_t vsockPort;

@end
