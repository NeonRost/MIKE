// MIKE – Mike's Toolbox
// Copyright (C) 2026 NeonRost
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import AppKit
import SwiftUI

// Its own view because openWindow is only reachable through the view
// environment, not directly inside a Commands builder.
private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About MIKE") {
            openWindow(id: "about")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// An external tool MIKE started has no reason to outlive it — without
    /// this, quitting mid-download leaves an orphaned yt-dlp running.
    func applicationWillTerminate(_ notification: Notification) {
        ProcessRunner.terminateAll()
        // A path typed but never committed would otherwise be lost.
        registry?.commitCustomPaths()
    }

    /// Set by RootView so termination can flush pending edits.
    weak var registry: ToolRegistry?
}

@main
struct MIKEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("MIKE", id: "main") {
            RootView()
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 880, height: 600)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
        }

        Window("About MIKE", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("Licenses", id: "license") {
            LicenseView()
        }
    }
}
