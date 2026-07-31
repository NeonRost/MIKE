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
import Combine
import SwiftUI

/// Keeps track of where `yt-dlp` and `ffmpeg` live and whether they run.
///
/// The check repeats whenever the app comes back to the front: people install
/// the tools in Terminal while MIKE is already open, and a launch-only check
/// would keep insisting they are missing.
@MainActor
final class ToolRegistry: ObservableObject {

    @Published private(set) var statuses: [Tool: ToolStatus] = [:]
    /// Not a requirement — only whether the `brew install` line Setup offers
    /// would work as it stands.
    @Published private(set) var homebrew: ToolStatus = .missing
    @Published private(set) var isChecking = false

    /// Edited freely while typing; written to disk only once the entry is
    /// finished, not on every keystroke. See `commitCustomPaths()`.
    @Published var customPaths: [Tool: String] = [:]

    private var lastCheck: Date?
    private var activationObserver: NSObjectProtocol?
    private var checkWatchdog: Task<Void, Never>?

    init() {
        var restored: [Tool: String] = [:]
        for tool in Tool.allCases {
            restored[tool] = UserDefaults.standard.string(forKey: tool.customPathDefaultsKey) ?? ""
        }
        customPaths = restored

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }

        refresh(force: true)
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    func status(for tool: Tool) -> ToolStatus {
        statuses[tool] ?? .missing
    }

    func isAvailable(_ tool: Tool) -> Bool {
        status(for: tool).isAvailable
    }

    /// True when every tool in `tools` is present — the check the sections use
    /// to decide whether to disable themselves.
    func hasAll(_ tools: [Tool]) -> Bool {
        tools.allSatisfy { isAvailable($0) }
    }

    func missing(from tools: [Tool]) -> [Tool] {
        tools.filter { !isAvailable($0) }
    }

    /// Which encoder, if any, can write WebP right now. cwebp is the reference
    /// implementation and is preferred; an ffmpeg built with libwebp also
    /// works, but the stock Homebrew build is not.
    var webpEncoder: WebPEncoder? {
        if let cwebp = status(for: .cwebp).url {
            return .cwebp(cwebp)
        }
        let ffmpeg = status(for: .ffmpeg)
        if let url = ffmpeg.url, ffmpeg.supportsWebP {
            return .ffmpeg(url)
        }
        return nil
    }

    /// Spelled out for the UI, because "install ffmpeg" is the wrong advice
    /// when ffmpeg is already there but was built without libwebp.
    var webpUnavailableReason: String? {
        if webpEncoder != nil { return nil }
        if status(for: .ffmpeg).isAvailable {
            return String(
                localized: "WEBP export needs cwebp — your ffmpeg was built without WebP support.",
                comment: "ffmpeg is present but cannot encode WebP"
            )
        }
        return String(
            localized: "WEBP export needs cwebp.",
            comment: "No WebP encoder available at all"
        )
    }

    func binding(for tool: Tool) -> Binding<String> {
        Binding(
            get: { self.customPaths[tool] ?? "" },
            set: { self.customPaths[tool] = $0 }
        )
    }

    /// - Parameter force: bypasses the debounce, for the "Check again" button
    ///   and the initial run.
    func refresh(force: Bool = false) {
        guard !isChecking else { return }
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 1.0 { return }

        isChecking = true
        let paths = customPaths

        // Without this, a probe that never returns would leave the section
        // stuck and "Check again" silently doing nothing.
        checkWatchdog?.cancel()
        checkWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.isChecking = false
        }

        Task.detached(priority: .userInitiated) {
            var found: [Tool: ToolStatus] = [:]
            for tool in Tool.allCases {
                found[tool] = ToolLocator.locate(tool, customPath: paths[tool])
            }
            let result = found
            let brew = ToolLocator.locateHomebrew()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.statuses = result
                self.homebrew = brew
                self.lastCheck = Date()
                self.checkWatchdog?.cancel()
                self.checkWatchdog = nil
                self.isChecking = false
            }
        }
    }

    /// Writes the entered paths out. Called when a field is committed or
    /// loses focus, and once more when the app quits.
    func commitCustomPaths() {
        for (tool, path) in customPaths {
            UserDefaults.standard.set(path, forKey: tool.customPathDefaultsKey)
        }
    }
}
