// iRessources — a native macOS port of Resources (https://github.com/nokyan/resources)
// Copyright (C) 2026 Bertrand LE GAL
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file for details.

import AppKit
import SwiftUI

@main
struct IRessourcesApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var monitor = SystemMonitor()

    init() {
        if CommandLine.arguments.contains("--dump") {
            Diagnostics.dump()
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--write-iconset"),
           let path = CommandLine.arguments[safe: index + 1] {
            MainActor.assumeIsolated {
                do {
                    try AppIconStyle.writeIconset(to: URL(fileURLWithPath: path))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                    exit(1)
                }
            }
        }
    }

    var body: some Scene {
        Window("iRessources", id: "main") {
            ContentView()
                .environment(monitor)
                .themedRoot()
                .frame(minWidth: 860, minHeight: 540)
                .background(WindowVisibilityObserver { monitor.isVisible = $0 })
        }
        .commands {
            SidebarCommands(monitor: monitor)
            CommandGroup(after: .toolbar) {
                Button("Refresh Now") { monitor.refreshNow() }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environment(monitor)
                .themedRoot()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched from `swift run` rather than from a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let icon = UserDefaults.standard.string(forKey: Preferences.appIcon).flatMap(AppIconStyle.init) ?? .pulse
        if icon != .pulse { icon.apply() }
    }
}

/// Reports whether the hosting window is actually visible on screen (not
/// minimised, hidden or fully covered), so sampling can be throttled.
struct WindowVisibilityObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObservingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.onChange?(window.occlusionState.contains(.visible))
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
