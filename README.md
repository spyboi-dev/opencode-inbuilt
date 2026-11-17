# OpenCode Inbuilt

One iOS app, real OpenCode engine inside it. No separate LinuxRunner
install, no second app, no outside server, JITless.

Native Objective-C UIKit, ChatGPT style: Sessions, Files, Engine,
Settings. The UI talks to the real OpenCode 2.3.0 server running in
the in-app Debian 13 guest (LinuxRunner ARM64 interpreter) at
`127.0.0.1:4096`, over HTTP + SSE, with Basic auth (user `opencode`,
password in the Keychain).

## Build

```sh
./build.sh
```

clang-18 + ld64.lld-18, iPhoneOS26.5.sdk, `-Wall -Wextra`, zero
warnings. Produces `build/OpenCode-Inbuilt.ipa`.

## Install

Re-sign with your Apple account in SideStore / AltStore and install.
Open the app → Engine tab → Run first-launch setup (37 MB Debian
packages, SHA-256 verified) → Start engine → sign in to a provider
in the guest → use the Sessions tab.

## Status

v1 IPA is built and host-verified (arm64, SDK 26.5, adhoc signed).
The client was tested live against a real opencode 2.2.6 server on
this VM (sessions, prompt, shell tool call, SSE events all work).

One open item, stated in BUILD-NOTE.md: the guest core library is
not linked in this build (no meson on this VM, Swift bridge
unbuildable here, guest untestable on x86_64 Linux). The Engine tab
says so honestly. The remaining step is a GitHub Actions macOS +
Xcode 26 build of the core; no UI or client change is needed for it.

See [BUILD-NOTE.md](BUILD-NOTE.md) for the full embedding decision,
the bug pass, and the install steps.
