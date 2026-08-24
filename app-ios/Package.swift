// swift-tools-version: 6.0
//
// RemotePiKit — the native iOS client for Remote Pi.
//
// Layering (enforced by the dependency edges below, not by convention):
//
//     RemotePiProtocol            wire vocabulary + the cross-module seams
//        ├── RemotePiCrypto       Ed25519 (CryptoKit) + Keychain key storage
//        │      └── RemotePiTransport   relay WebSocket, hello/challenge/auth
//        │             └── RemotePiSession   room state, chat, control plane
//        │      └── RemotePiPairing         QR + pair_request + mesh_versions
//        └── RemotePiStore        persistence keyed by session_id
//
// NO third-party dependencies, ever. CryptoKit gives Curve25519.Signing,
// URLSessionWebSocketTask gives the socket, Security gives the Keychain.
// A dependency here would have to be vendored into the App target too, and
// the whole point of this rewrite is a build that is `swift build` and
// nothing else.
//
// macOS 14 is listed only so `swift test` runs on the command line without a
// simulator. Nothing in these targets may use a macOS-only API path that the
// iOS build does not also take.

import PackageDescription

let package = Package(
    name: "RemotePiKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RemotePiProtocol", targets: ["RemotePiProtocol"]),
        .library(name: "RemotePiCrypto", targets: ["RemotePiCrypto"]),
        .library(name: "RemotePiTransport", targets: ["RemotePiTransport"]),
        .library(name: "RemotePiSession", targets: ["RemotePiSession"]),
        .library(name: "RemotePiPairing", targets: ["RemotePiPairing"]),
        .library(name: "RemotePiStore", targets: ["RemotePiStore"]),
        // Umbrella product the app target links against, so `project.yml`
        // names one thing instead of six.
        .library(
            name: "RemotePiKit",
            targets: [
                "RemotePiProtocol",
                "RemotePiCrypto",
                "RemotePiTransport",
                "RemotePiSession",
                "RemotePiPairing",
                "RemotePiStore",
            ]
        ),
    ],
    targets: [
        .target(name: "RemotePiProtocol"),
        .target(name: "RemotePiCrypto", dependencies: ["RemotePiProtocol"]),
        .target(name: "RemotePiTransport", dependencies: ["RemotePiProtocol", "RemotePiCrypto"]),
        .target(name: "RemotePiSession", dependencies: ["RemotePiProtocol", "RemotePiTransport"]),
        .target(
            name: "RemotePiPairing",
            dependencies: ["RemotePiProtocol", "RemotePiCrypto", "RemotePiTransport"]
        ),
        .target(name: "RemotePiStore", dependencies: ["RemotePiProtocol"]),

        .testTarget(name: "RemotePiProtocolTests", dependencies: ["RemotePiProtocol"]),
        .testTarget(name: "RemotePiCryptoTests", dependencies: ["RemotePiCrypto"]),
        .testTarget(name: "RemotePiTransportTests", dependencies: ["RemotePiTransport"]),
        .testTarget(name: "RemotePiSessionTests", dependencies: ["RemotePiSession"]),
        .testTarget(name: "RemotePiPairingTests", dependencies: ["RemotePiPairing"]),
        .testTarget(name: "RemotePiStoreTests", dependencies: ["RemotePiStore"]),
    ]
)
