# app-ios — native iOS client

The native replacement for the Flutter client in [`../app`](../app). Same
protocol, same relay, same Pi extension — a phone talking to a coding agent on
the user's Mac.

`../app`, `../relay` and `../pi-extension` are **ground truth**. This subproject
must be byte-compatible with them; when a doc here and the running code
disagree, the code wins. Start from [`../PROTOCOL.md`](../PROTOCOL.md) and
[`../plan/61-stable-session-identity.md`](../plan/61-stable-session-identity.md),
which are current as of 2026-08-24.

## Layout

```text
app-ios/
  Package.swift          RemotePiKit — six library targets, six test targets
  project.yml            xcodegen spec for the app target (the .xcodeproj is generated)
  Sources/
    RemotePiProtocol/    wire vocabulary + the cross-module seams   ← read this first
    RemotePiCrypto/      Ed25519 (CryptoKit) + Keychain key storage
    RemotePiTransport/   relay WebSocket, hello/challenge/auth
    RemotePiSession/     room state, chat, machine control plane
    RemotePiPairing/     QR + pair_request + mesh_versions
    RemotePiStore/       persistence keyed by session_id
  Tests/                 one test target per library target
  App/Sources/           the SwiftUI app target (views and lifecycle only)
```

Dependency edges, enforced by `Package.swift`:

```text
RemotePiProtocol
   ├── RemotePiCrypto ── RemotePiTransport ── RemotePiSession
   │                  └── RemotePiPairing (also → Protocol, Transport)
   └── RemotePiStore
```

**No third-party dependencies.** CryptoKit gives Ed25519
(`Curve25519.Signing`), `URLSessionWebSocketTask` gives the socket, Security
gives the Keychain. A dependency would have to be vendored into the app target
too, and the point of this rewrite is a build that is `swift build` and nothing
else.

## Build and test

Everything testable lives in the package, so the fast loop needs no simulator
and no Xcode:

```sh
cd app-ios
swift build
swift test
```

The package declares `macOS 14` alongside `iOS 18` purely so those two commands
work on the command line. Nothing in the targets may take a macOS-only code
path that the iOS build does not also take.

## Generate and build the app

The `.xcodeproj` is **generated and not checked in** — `project.yml` is the
source of truth, so a merge conflict is a three-line diff instead of an
unreadable pbxproj.

```sh
cd app-ios
xcodegen generate --spec project.yml        # ~/opt/brew/bin/xcodegen

xcodebuild -project RemotePi.xcodeproj \
           -scheme RemotePi \
           -sdk iphonesimulator \
           -destination 'generic/platform=iOS Simulator' \
           build
```

Bundle id `work.jacobmoura.remotepi.native`, deployment target iOS 18.0 (the
same as the Flutter app's `IPHONEOS_DEPLOYMENT_TARGET`, so a device that runs
one runs the other). The simulator build is unsigned; set your own team locally
rather than committing one.

Purpose strings live in `project.yml` under `info.properties` and are generated
into `App/Info.plist`: camera (QR pairing), microphone + speech recognition
(dictation), photo library read and add (image attachments). iOS terminates the
app on first use of a capability whose key is missing, so keep the wording
accurate rather than generic.

## What is fixed and what is not

`Sources/RemotePiProtocol` is **fixed**: the types there are the contract the
other five targets are being written against in parallel. Changing a signature
there breaks work in flight — raise it rather than editing.

Everywhere else, a scaffolded body throws `ScaffoldError.notImplemented(_:)`.
That is the work list:

```sh
grep -rn notImplemented Sources
```

## Protocol notes worth reading before writing any code

These are the things that have actually broken, repeatedly.

**Base64 has two spellings and they are not interchangeable.** The relay
registry, `hello.pubkey`, `Envelope.peer` and every control frame use
**standard** Base64 with padding. The QR payload and on-device storage keys use
**URL-safe** Base64 without padding. `PeerID` stores the raw 32 bytes and
serializes explicitly at each boundary, so no caller ever compares the two
spellings as strings. See the header of
[`../app/lib/data/transport/epk_encoding.dart`](../app/lib/data/transport/epk_encoding.dart)
for the history.

**`room_id == session_id` (plan 61).** The room id is not derived from anything
the user can edit. The client never computes one: after `create_session` it
waits for `action_ok` and then for the `room_announced` carrying that
`session_id`.

**A rename is a metadata patch.** It never re-keys a room, never restarts a
connection, never opens a second tile. `name_rev` is monotonic and the gate is
**strictly greater** — and a rejected patch still triggers a broadcast of the
current name, so an inbound `name` is not by itself evidence of a rename.

**Patch semantics.** Absent key = preserve. Explicit `null` = clear. `working`
is a plain bool with no null state. `PatchField` exists because
`encodeIfPresent` cannot express that difference.

**Key persistent state by `SessionKey`, never by room id alone.** A room id is
unique only within one machine.

**`ctrl` is not a chat.** `role: "control"` marks the machine gateway's room.
It must never render as a tile, and its inbound envelopes must be exempt from
the "drop frames from a room other than the active one" demux — its replies
arrive while some unrelated chat is open.

**Mutating control actions require a stable `idempotency_key`.** Mint it once
per user intent and reuse it for every retry; the machine replays the original
outcome, including the original error, so a retry loop cannot become a spawn
loop. A fresh key per attempt deduplicates nothing.

**`started_at` changes on every reconnect.** Never a key, never a sort order.

**`ct` is not ciphertext.** It is Base64 of plaintext JSON. There is no
end-to-end encryption in this product and no copy may claim otherwise.
