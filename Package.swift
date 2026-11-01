// swift-tools-version:6.0
//
// iRessources — a native macOS port of Resources (https://github.com/nokyan/resources)
// Copyright (C) 2026 Bertrand LE GAL
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "iRessources",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CSystem",
            path: "Sources/CSystem",
            linkerSettings: [
                .linkedLibrary("IOReport"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "iRessources",
            dependencies: ["CSystem"],
            path: "Sources/iRessources",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreWLAN"),
            ]
        ),
    ]
)
