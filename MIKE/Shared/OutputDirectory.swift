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

/// A remembered output folder. Defaults to the Desktop and survives restarts;
/// if the stored folder has since disappeared it quietly falls back again.
@MainActor
final class OutputDirectory: ObservableObject {

    @Published private(set) var url: URL

    private let defaultsKey: String

    static let desktop: URL = FileManager.default
        .urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")

    init(defaultsKey: String) {
        self.defaultsKey = defaultsKey
        if let stored = UserDefaults.standard.string(forKey: defaultsKey) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: stored, isDirectory: &isDirectory),
               isDirectory.boolValue {
                url = URL(fileURLWithPath: stored)
                return
            }
        }
        url = Self.desktop
    }

    func set(_ newURL: URL) {
        url = newURL
        UserDefaults.standard.set(newURL.path, forKey: defaultsKey)
    }

    /// Shown in the UI: `~/…` rather than the full home path.
    var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// The save-location row: the path is the prominent part, the button is not.
struct OutputDirectoryRow: View {
    @ObservedObject var directory: OutputDirectory
    var isEnabled: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Save to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: directory.displayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button("Choose…") { choose() }
                .disabled(!isEnabled)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory.url
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the folder picker")
        if panel.runModal() == .OK, let chosen = panel.url {
            directory.set(chosen)
        }
    }
}
