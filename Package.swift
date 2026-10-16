// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import PackageDescription

let package = Package(
    name: "anDropIdentity",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "anDropIdentity", path: "Sources", exclude: ["ControlState.swift", "ControlIntents.swift", "ControlWidgets.swift", "BrandLogos.swift", "main.swift", "Localization.swift", "ShareViewController.swift", "engine.py", "peer_metadata.py", "discovery.py"], sources: ["Peer.swift", "ReceiveAccessPolicy.swift", "TransferProgress.swift"]),
        .testTarget(name: "anDropIdentityTests", dependencies: ["anDropIdentity"], path: "tests/swift")
    ]
)
