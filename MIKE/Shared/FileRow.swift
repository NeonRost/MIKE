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

/// A single-file chooser row: a caption, the chosen path (or a placeholder),
/// and Choose/Clear buttons. Shared by Convert Format and Metadata, which both
/// operate on one picked file.
struct FileRow: View {
    let label: LocalizedStringKey
    let file: URL?
    var isEnabled: Bool = true
    let onChoose: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let file {
                    Text(verbatim: (file.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text("No file selected")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if file != nil {
                Button("Clear", action: onClear)
                    .disabled(!isEnabled)
            }
            Button("Choose…", action: onChoose)
                .disabled(!isEnabled)
        }
    }
}
