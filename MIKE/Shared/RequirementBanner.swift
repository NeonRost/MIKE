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

import SwiftUI

/// Shown at the top of a section whose tools are missing, so the gap is visible
/// before the user starts anything rather than as a failure afterwards.
struct RequirementBanner: View {
    let missing: [Tool]
    let onOpenTools: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Setup", action: onOpenTools)
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Two separate sentences rather than one with a switchable verb: languages
    /// do not agree on how singular and plural change the rest of the sentence.
    private var message: String {
        let names = missing.map(\.executableName)
        guard names.count != 1 else {
            return String(
                localized: "This section needs \(names[0]), which is not installed.",
                comment: "Banner in a disabled section. Placeholder is a tool name such as ffmpeg."
            )
        }
        let list = ListFormatter.localizedString(byJoining: names)
        return String(
            localized: "This section needs \(list), which are not installed.",
            comment: "Banner in a disabled section. Placeholder is a list of tool names."
        )
    }
}

/// Header used by every section, so they all read the same way.
struct SectionHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Status line shared by the sections: colours success and failure alike.
///
/// Takes a plain `String` on purpose — the callers assemble their messages with
/// `String(localized:)` because the text is built at runtime.
struct StatusLine: View {
    enum Kind {
        case idle
        case working
        case success
        case failure
    }

    let text: String
    let kind: Kind

    var body: some View {
        if !text.isEmpty {
            HStack(spacing: 6) {
                if kind == .working {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(text)
                    .font(.callout)
                    .foregroundStyle(colour)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var colour: Color {
        switch kind {
        case .idle, .working: return .primary
        case .success: return .green
        case .failure: return .red
        }
    }
}
