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


import Foundation

struct ProcessResult {
    let status: Int32
    let output: String
    /// The watchdog had to stop it. Distinct from a launch failure (`nil`):
    /// a binary that runs but is slow under load is not a missing binary.
    var timedOut = false
    /// Stopped through `ProcessRunner.cancel(_:)` or at app termination.
    var cancelled = false
}

/// What a streamed run came to.
struct ProcessOutcome {
    let status: Int32
    /// The last lines the tool printed, newest last — enough to show the user
    /// what actually went wrong, not just a one-line guess at it.
    let log: [String]
    /// MIKE asked the process to stop. This is recorded when the request is
    /// made rather than read back from the exit status afterwards: ffmpeg
    /// catches SIGTERM, finishes its file and exits 255 like any other
    /// failure, so "died by signal" never becomes true for it.
    let cancelled: Bool
    /// The binary could not be started at all.
    let launchFailed: Bool

    var succeeded: Bool { status == 0 && !cancelled && !launchFailed }

    /// The one line most worth showing: the tool's own error line if it
    /// printed one, otherwise its last line, otherwise the exit code.
    func failureSummary(tool: String, limit: Int = 300) -> String {
        if launchFailed {
            return String(
                localized: "\(tool) could not be started.",
                comment: "Placeholder is a tool name such as ffmpeg"
            )
        }
        if let explicit = log.last(where: {
            let lowered = $0.lowercased()
            return lowered.hasPrefix("error") || $0.contains("ERROR:") || lowered.hasPrefix("warning")
        }) {
            return String(explicit.prefix(limit))
        }
        if let last = log.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(last.prefix(limit))
        }
        return String(
            localized: "\(tool) exited with code \(Int(status)).",
            comment: "First placeholder is a tool name such as ffmpeg"
        )
    }

    /// Everything kept from the run, for the Details popover.
    var logText: String { log.joined(separator: "\n") }
}

/// An error that can hand over the tool's own output alongside its summary.
protocol ToolLogCarrying {
    var toolLog: String? { get }
}

/// Thin wrapper around `Process`. Every call blocks, so callers must be on a
/// background queue.
enum ProcessRunner {

    /// Runs a short-lived command and collects its whole output.
    ///
    /// Returns `nil` when the binary cannot be launched. A run the watchdog had
    /// to stop comes back with `timedOut` set — that is how a quarantined or
    /// hanging executable shows up, and it must not hang the tool check.
    static func capture(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 5
    ) -> ProcessResult? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        // Registered like a streamed run, so quitting MIKE mid-probe does not
        // leave it behind either.
        running.add(process)

        let timedOut = Atomic(false)
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut.value = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        running.remove(process)

        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            timedOut: timedOut.value,
            cancelled: cancelRequests.consume(process)
        )
    }

    /// Runs a long command and reports its output line by line while it runs.
    ///
    /// Lines are split on both `\n` and `\r`: yt-dlp redraws its progress with
    /// carriage returns, so splitting on newlines alone would deliver the whole
    /// download as a single line at the very end.
    /// - Parameters:
    ///   - logLimit: how many trailing lines are kept for `ProcessOutcome.log`.
    ///   - onStart: handed the live `Process` so the caller can pass it to
    ///     `cancel(_:)`. Runs on the calling thread, before any output arrives.
    ///   - onLine: every line as it arrives, for callers that parse progress.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        logLimit: Int = 60,
        onStart: ((Process) -> Void)? = nil,
        onLine: ((String) -> Void)? = nil
    ) -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = Locked<[UInt8]>([])
        var log: [String] = []

        // Called with the buffer lock held, so `log` needs no lock of its own.
        let deliver: ([UInt8]) -> Void = { bytes in
            guard !bytes.isEmpty else { return }
            let line = String(decoding: bytes, as: UTF8.self)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            log.append(line)
            if log.count > logLimit { log.removeFirst(log.count - logLimit) }
            onLine?(line)
        }

        let emitLines: (Data, Bool) -> Void = { chunk, flush in
            buffer.withValue { bytes in
                bytes.append(contentsOf: chunk)
                while let index = bytes.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineBytes = Array(bytes[bytes.startIndex..<index])
                    bytes.removeSubrange(bytes.startIndex...index)
                    deliver(lineBytes)
                }
                if flush, !bytes.isEmpty {
                    deliver(Array(bytes))
                    bytes.removeAll()
                }
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            emitLines(chunk, false)
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return ProcessOutcome(status: -1, log: [], cancelled: false, launchFailed: true)
        }

        // Registered so quitting MIKE does not leave a yt-dlp behind.
        running.add(process)
        onStart?(process)

        process.waitUntilExit()
        running.remove(process)
        pipe.fileHandleForReading.readabilityHandler = nil

        // Whatever the handler did not pick up before the process ended.
        let remainder = pipe.fileHandleForReading.readDataToEndOfFile()
        emitLines(remainder, true)

        var collected: [String] = []
        buffer.withValue { _ in collected = log }
        return ProcessOutcome(
            status: process.terminationStatus,
            log: collected,
            cancelled: cancelRequests.consume(process),
            launchFailed: false
        )
    }

    // MARK: - Cancelling

    /// Asks a running process to stop and remembers that MIKE did the asking.
    /// Every Cancel button goes through here rather than calling
    /// `terminate()` itself — see `ProcessOutcome.cancelled` for why the
    /// request has to be recorded.
    static func cancel(_ process: Process) {
        guard process.isRunning else { return }
        cancelRequests.mark(process)
        process.terminate()
    }

    private static let cancelRequests = CancelRequests()

    /// Keyed by object identity and always consumed by the run it belongs to,
    /// so a later `Process` reusing the same address never inherits the flag.
    private final class CancelRequests {
        private var requested = Set<ObjectIdentifier>()
        private let lock = NSLock()

        func mark(_ process: Process) {
            lock.lock(); requested.insert(ObjectIdentifier(process)); lock.unlock()
        }

        func consume(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return requested.remove(ObjectIdentifier(process)) != nil
        }
    }

    // MARK: - Shutdown

    private static let running = RunningProcesses()

    /// Ends every process MIKE still has open. Called when the app quits: an
    /// external tool started by MIKE has no reason to outlive it.
    static func terminateAll() {
        running.terminateAll()
    }

    /// The set of live processes. A plain lock rather than an actor, because
    /// `terminateAll` has to finish synchronously during app termination.
    private final class RunningProcesses {
        private var processes: [Process] = []
        private let lock = NSLock()

        func add(_ process: Process) {
            lock.lock(); processes.append(process); lock.unlock()
        }

        func remove(_ process: Process) {
            lock.lock()
            processes.removeAll { $0 === process }
            lock.unlock()
        }

        func terminateAll() {
            lock.lock()
            let snapshot = processes
            processes.removeAll()
            lock.unlock()
            for process in snapshot where process.isRunning {
                ProcessRunner.cancel(process)
            }
        }
    }
}

/// Minimal mutable box guarded by a lock — the readability handler and the
/// waiting thread touch the same buffer.
private final class Locked<Value> {
    private var storage: Value
    private let lock = NSLock()

    init(_ value: Value) { storage = value }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}

private final class Atomic<Value> {
    private var storage: Value
    private let lock = NSLock()

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
