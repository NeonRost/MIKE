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

struct DirectLinkView: View {
    @State private var urlText = ""
    @State private var resultLink = ""
    @State private var isRunning = false
    @State private var status = ""
    @State private var statusKind = StatusLine.Kind.idle

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Direct Link",
                    subtitle: "Turns a TikTok page URL into a direct link to the video file. Needs no external tools."
                )

                TextField("https://www.tiktok.com/@…/video/…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .onSubmit { resolve() }

                HStack(spacing: 12) {
                    Button("Get Link") { resolve() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    StatusLine(text: status, kind: statusKind)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Direct link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField(text: .constant(resultLink)) { EmptyView() }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .disabled(true)
                            .textSelection(.enabled)
                        Button("Copy") { WebURL.copyToClipboard(resultLink) }
                            .disabled(resultLink.isEmpty)
                    }
                }
                .padding(.top, 4)

            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resolve() {
        guard !isRunning else { return }
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard WebURL.isValid(trimmed) else {
            status = String(localized: "That is not a valid URL.")
            statusKind = .failure
            return
        }
        guard trimmed.lowercased().contains("tiktok.com") else {
            status = String(localized: "TikTok links only.")
            statusKind = .failure
            return
        }

        isRunning = true
        resultLink = ""
        statusKind = .working
        status = String(localized: "Resolving…")

        Task {
            do {
                let link = try await TikTokResolver.resolve(trimmed)
                resultLink = link
                WebURL.copyToClipboard(link)
                status = String(localized: "Done — link copied.")
                statusKind = .success
            } catch {
                status = error.localizedDescription
                statusKind = .failure
            }
            isRunning = false
        }
    }
}
