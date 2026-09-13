# Tailview Design

Working name: **Tailview**. Native macOS remote-desktop *viewer* for machines already on the user’s Tailscale tailnet.

This is not a new remote-access network. Tailscale is the overlay. Tailview discovers peers and opens an in-app desktop session to software already running on those peers (Apple Screen Sharing, VNC, or RDP).

## Problem

Screen Sharing.app can already reach a Mac over Tailscale if you remember the MagicDNS name or `100.x` address. Jump Desktop does the same for VNC/RDP with a better machine list and an in-app session. Tailview is an OSS Jump Desktop-shaped viewer whose primary job is: **show online tailnet peers and one-click into a usable desktop session.**

## Goals (v1)

- Native macOS viewer (SwiftUI). No custom host/agent to install on remotes.
- Auto-list Tailscale peers (name, OS, online/offline). One-click connect.
- In-app session: framebuffer + mouse + keyboard + **text clipboard**.
- Protocols: Apple Screen Sharing (Mac), VNC (Linux), RDP (Windows / xrdp).
- Protocol choice: OS heuristic, saved override, explicit fail-over on connect failure.
- Credentials in Keychain. No cloud, no our servers, no extra tunnel.

## Non-goals (v1)

- Custom capture/encode agent on the remote
- File transfer, audio, multi-monitor
- Automatic port scanning
- App Store sandbox distribution
- iOS/Android as remotes
- Relays, unattended access outside Tailscale, or replacing Tailscale ACLs

## Success

v1 is done when:

1. The list matches Tailscale (online/offline, this Mac hidden).
2. One click opens a controllable session on a Mac (Screen Sharing), a Linux VNC server, and an RDP endpoint.
3. Text clipboard syncs both ways.
4. A wrong-protocol failure can be overridden and the override is remembered.
5. Tailscale-quit and mid-session disconnects fail in the ways described under Errors, not with a crash.

## Architecture

Single macOS app. Tailscale must already be installed and logged in.

```
SwiftUI shell
  ├─ Machine list (LocalAPI peers + saved profile)
  ├─ Session window (framebuffer, mouse/keyboard, clipboard)
  └─ SessionController  →  VNC/ARD (Swift)  or  IronRDP (Rust FFI)
Keychain holds passwords. Overrides live in a local profile store.
```

Packets: Tailview → Tailscale → peer `:5900` or `:3389`. We do not proxy.

Phased implementation inside this one app (not separate products):

1. List + connect shell (no real protocol yet)
2. VNC + Apple Screen Sharing sessions
3. Text clipboard on VNC
4. RDP sessions + clipboard

## Components

| Unit | Responsibility | Depends on |
|---|---|---|
| **TailscaleClient** | Read LocalAPI status: peer id, hostname, tailnet IPs, online, OS. | Tailscale running locally |
| **ProfileStore** | Per-peer protocol/port override and last-used timestamp. JSON under Application Support. | — |
| **CredentialStore** | Username/password in Keychain, keyed by peer stable id + protocol. | — |
| **PeerDirectory** | Merge live peers + profiles. Apply heuristic unless overridden. | TailscaleClient, ProfileStore |
| **RemoteSession** | Protocol-agnostic interface: connect, frames, mouse/keys, clipboard, disconnect. | — |
| **VNCSession** | RFB client + Apple Remote Desktop (ARD) auth. Mac Screen Sharing and Linux VNC. | RemoteSession |
| **RDPSession** | Swift wrapper around IronRDP (`cdylib`). Same `RemoteSession` surface. | RemoteSession, Rust lib |
| **SessionController** | Owns one backend, window lifetime, fail-over prompt, reconnect. | backends, CredentialStore |
| **Session UI** | Scale-to-fit framebuffer, pointer/keyboard mapping. Single display. | SessionController |

`RemoteSession` is the isolation boundary. VNC and RDP must be swappable without the list or window knowing which protocol is live.

### Protocol heuristic

Taken from Tailscale `Hostinfo.OS` (or equivalent LocalAPI field):

| OS | Default protocol | Default port |
|---|---|---|
| macOS | Screen Sharing (RFB + ARD auth) | 5900 |
| linux | VNC | 5900 |
| windows | RDP | 3389 |
| iOS, Android, others | Not connectable | — |

User override (protocol + port) always wins. Linux VNC vs xrdp is the expected override case.

On macOS remotes, authenticate with ARD (type 30) first; if the server asks for a VNC password, use that instead. That is auth negotiation, not protocol fail-over.

### Libraries (locked)

- **UI / discovery / Keychain:** Swift, SwiftUI. App is **not** sandboxed (unix socket + `100.x` connections).
- **VNC:** RoyalVNC (MIT). If it cannot do ARD auth type 30, add a small ARD-auth module and keep RoyalVNC for RFB. Do **not** link libvncclient (GPL-2 would infect the app).
- **RDP:** IronRDP (Apache-2.0 / MIT) behind UniFFI. FFI is RDP-only; VNC stays Swift.
- **License for Tailview:** MIT.

## Data flow

1. **List.** On launch, `TailscaleClient` polls LocalAPI about every 2 seconds. `PeerDirectory` publishes rows: display name, OS, online, suggested protocol, saved override.
2. **Connect.** Click peer → endpoint is the peer’s tailnet IP + profile port → Keychain creds or one prompt (then save) → `SessionController` starts the suggested backend → session window.
3. **Session.** Backend authenticates → framebuffer frames → view draws → mouse/keyboard become RFB pointer/key or RDP input. Clipboard: local `NSPasteboard` string changes are sent; remote cut-text is written back to the pasteboard. Text only.
4. **Fail-over.** Connect *failure* (refused, timeout, no RFB/RDP handshake) → prompt to try the paired protocol (VNC/Screen Sharing ↔ RDP, default ports 5900 ↔ 3389). Success writes `ProfileStore`. Auth failure does **not** fail over.
5. **Disconnect.** Closing the window tears down the backend. Nothing is installed or left running on the remote.

Connect uses the peer’s Tailscale IPv4 (`100.x`) if present, otherwise IPv6. LocalAPI: HTTP over the platform Tailscale unix socket, same source as `tailscale status --json`. If the socket is missing or returns not-logged-in, treat Tailscale as unavailable. Do not shell out to the `tailscale` CLI for the steady state.

Profiles path: `~/Library/Application Support/Tailview/profiles.json`, keyed by Tailscale stable node id.

## Errors

| Case | Behavior |
|---|---|
| Tailscale not running or not logged in | Empty list, explanation, button/link to open the Tailscale app. No crash. |
| Peer offline | Row shown, Connect disabled. |
| This Mac (`Self`) | Hidden. |
| Connect refused or timeout | Explain nothing is listening on that port. Offer the other protocol. |
| Bad password | Re-prompt. Do not fail over. |
| Mid-session drop | Banner + Reconnect with the same protocol, port, and creds. |
| IronRDP dylib missing or failed to load | VNC still works. RDP Connect explains RDP is unavailable. |
| Not-connectable OS | Row shown, Connect disabled, reason visible. |

No background port probes. Fail-over happens only after a user-initiated connect fails.

## UI (v1)

Standard document-style app, not menu-bar-only:

- Main window: peer list (name, OS, online, protocol). Connect on the row.
- Session: separate window per connection. Scale-to-fit, no multi-monitor picker.
- First connect: credential sheet; “Save in Keychain” default on. RDP and Mac ARD require username + password. VNC password-only servers leave username empty.

Input: send Mac keys as-is (no Cmd-as-Ctrl remap in v1). Pointer coordinates map through the scale-to-fit transform.

## Testing

CI tests *our* code with fakes. Live VNC/RDP servers are not a v1 CI gate.

- **Heuristic + PeerDirectory:** OS → protocol, override wins, hide Self, offline/not-connectable disable Connect.
- **TailscaleClient:** fixture JSON shaped like LocalAPI `/localapi/v0/status`. No tailscaled in unit tests.
- **SessionController:** fake `RemoteSession`. Assert fail-over prompt vs auth retry, reconnect, teardown.
- **Clipboard:** local pasteboard string ↔ protocol cut-text via a fake backend.
- **Manual v1:** Mac Screen Sharing peer, Linux VNC peer, RDP peer; quit Tailscale; unplug mid-session.

IronRDP and RoyalVNC keep their upstream tests. An optional TigerVNC/xrdp smoke job can be added later; it does not block v1.

## Project layout (when implementation starts)

```
apps/macos/          SwiftUI app, TailscaleClient, UI, SessionController
core/vnc/            VNCSession + ARD auth
core/rdp/            IronRDP crate + Swift/UniFFI wrapper
docs/superpowers/    specs and plans
```

## Implementation notes

- Clipboard v1 is **plain text**. RFB: extended clipboard UTF-8 when the server supports it, otherwise Latin-1 `ClientCutText` / `ServerCutText`. RDP: CLIPRDR Unicode text.
- Single remote display. If the server has multiple monitors, show whatever the protocol gives as the default desktop bitmap; no monitor picker.
- Reconnect is explicit (button), not an infinite silent retry loop.
- Do not use private `ScreenSharing.framework` APIs.
