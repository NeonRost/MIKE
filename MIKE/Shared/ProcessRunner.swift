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
}

/// Thin wrapper around `Process`. Every call blocks, so callers must be on a
/// background queue.
enum ProcessRunner {

    /// Runs a short-lived command and collects its whole output.
    ///
    /// Returns `nil` when the binary cannot be launched or does not finish
    /// within `timeout` — that is how a quarantined or architecture-mismatched
    /// executable shows up, and it must not hang the tool check.
    static func capture(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 5
    ) -> ProcessResult? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

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

        if timedOut.value { return nil }
        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    /// Runs a long command and reports its output line by line while it runs.
    ///
    /// Lines are split on both `\n` and `\r`: yt-dlp redraws its progress with
    /// carriage returns, so splitting on newlines alone would deliver the whole
    /// download as a single line at the very end.
    /// - Parameter onStart: handed the live `Process` so the caller can call
    ///   `terminate()` on it. Runs on the calling thread, before any output
    ///   arrives.
    @discardableResult
    static func stream(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onStart: ((Process) -> Void)? = nil,
        onLine: @escaping (String) -> Void
    ) -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = Locked<[UInt8]>([])

        let emitLines: (Data, Bool) -> Void = { chunk, flush in
            buffer.withValue { bytes in
                bytes.append(contentsOf: chunk)
                while let index = bytes.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineBytes = Array(bytes[bytes.startIndex..<index])
                    bytes.removeSubrange(bytes.startIndex...index)
                    deliver(lineBytes, to: onLine)
                }
                if flush, !bytes.isEmpty {
                    deliver(Array(bytes), to: onLine)
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
            return -1
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

        return process.terminationStatus
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
                process.terminate()
            }
        }
    }

    private static func deliver(_ bytes: [UInt8], to onLine: (String) -> Void) {
        guard !bytes.isEmpty else { return }
        let line = String(decoding: bytes, as: UTF8.self)
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onLine(line)
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
