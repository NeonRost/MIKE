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

struct AboutView: View {
    @Environment(\.openWindow) private var openWindow

    /// Comes from MARKETING_VERSION in the project settings, never a literal.
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("MIKE – Mike's Toolbox")
                .font(.title3.bold())
            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("MIKE comes with absolutely no warranty. Redistribution and modification are permitted under the terms of the GNU GPL v3.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Button("Show License") {
                openWindow(id: "license")
            }
            .buttonStyle(.link)
            .font(.caption)
            Text(copyright)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 320)
    }
}

struct LicenseView: View {

    /// MIKE's own licence, plus the one third-party component it bundles.
    private enum Document: String, CaseIterable, Identifiable {
        case mike
        case readability

        var id: String { rawValue }

        /// Product and licence names, so this is deliberately not translated.
        var label: String {
            switch self {
            case .mike: return "MIKE (GPL v3)"
            case .readability: return "Readability.js (Apache 2.0)"
            }
        }

        var resourceName: String {
            switch self {
            case .mike: return "LICENSE"
            case .readability: return "LICENSE-Readability"
            }
        }
    }

    @State private var document = Document.mike

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: document.resourceName, withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            switch document {
            case .mike:
                return String(
                    localized: "The LICENSE file was not found in the app bundle. The license text is available at https://www.gnu.org/licenses/gpl-3.0.txt",
                    comment: "Fallback when the bundled licence file is missing"
                )
            case .readability:
                return String(
                    localized: "The Readability license file was not found in the app bundle. The license text is available at https://www.apache.org/licenses/LICENSE-2.0",
                    comment: "Fallback when the bundled Apache licence file is missing"
                )
            }
        }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("License", selection: $document) {
                ForEach(Document.allCases) { Text(verbatim: $0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView {
                Text(licenseText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(minWidth: 560, idealWidth: 560, minHeight: 440, idealHeight: 480)
    }
}
