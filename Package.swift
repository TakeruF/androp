// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 anDrop contributors

import PackageDescription

let package = Package(
    name: "anDropIdentity",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "anDropIdentity", path: "Sources", exclude: ["AppUpdates.swift", "BrandLogos.swift", "HuaweiLANDiscovery.swift", "main.swift", "Localization.swift", "ShareViewController.swift", "engine.py", "huawei_runtime.py", "file_types.py", "peer_metadata.py", "discovery.py", "network_routes.py", "__pycache__"], sources: ["Peer.swift", "ReceiveAccessPolicy.swift", "TransferProgress.swift", "Diagnostics.swift"]),
        .testTarget(name: "anDropIdentityTests", dependencies: ["anDropIdentity"], path: "tests/swift")
    ]
)
