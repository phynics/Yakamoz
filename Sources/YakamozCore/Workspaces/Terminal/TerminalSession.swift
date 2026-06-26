import Foundation
import SwiftTerm

/// Result of running a command through `TerminalSession.run`.
///
/// `.finished` carries the cleaned output text and the command's exit code. `.running` is
/// returned when the grace period elapses before the command's completion marker appears;
/// the command is left in-flight (`TerminalSession` keeps tracking it) and the caller can
/// poll again later (Task 11).
public enum RunResult: Sendable, Equatable {
    case finished(String, Int32)
    case running(String)
}

/// Status of a session's in-flight (or most recently completed) command, as observed by
/// `read()`/`wait(timeoutMs:)`.
public enum TerminalStatus: Sendable, Equatable {
    case running
    case finished(Int32)
}

/// Result of `TerminalSession.read()`/`wait(timeoutMs:)`: output accumulated since the last
/// `read`/`wait`/`run` call, plus the current status of the (possibly still in-flight) command.
public struct ReadResult: Sendable, Equatable {
    public let output: String
    public let status: TerminalStatus

    public init(output: String, status: TerminalStatus) {
        self.output = output
        self.status = status
    }
}

/// Runs an interactive shell on a pseudo-terminal (via `SwiftTerm.LocalProcess`) and lets
/// callers execute commands and observe their output and exit code.
///
/// `TerminalSession` is an `actor`: all mutable PTY-output state (`buffer`, `cursor`,
/// `pendingMark`) is owned by the actor, and the only way data flows in from the
/// (non-actor, delegate-driven) PTY read loop is through `appendOutput`/`handleTerminated`,
/// both of which are actor methods invoked from `Task { await ... }` hops inside the
/// delegate adapter below.
public actor TerminalSession {
    /// Bridges `SwiftTerm.LocalProcessDelegate` (a class-bound protocol, called back on a
    /// `DispatchQueue`) into the actor. `LocalProcess` holds its delegate weakly, so
    /// `TerminalSession` keeps a strong reference to this adapter for the process's lifetime.
    private final class DelegateAdapter: LocalProcessDelegate {
        weak var session: TerminalSession?

        init(session: TerminalSession? = nil) {
            self.session = session
        }

        func processTerminated(_: LocalProcess, exitCode: Int32?) {
            guard let session else { return }
            Task { await session.handleTerminated(exitCode: exitCode) }
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            guard let session else { return }
            let bytes = Array(slice)
            Task { await session.appendOutput(bytes[...]) }
        }

        func getWindowSize() -> winsize {
            winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }
    }

    /// Marker line format used to delimit a command's output: `MARK-<uuid>:<exit code>`.
    private static let markerLinePattern = try! NSRegularExpression(pattern: #"MARK-[0-9A-Fa-f-]+:(-?\d+)"#)

    /// Matches ANSI escape sequences (CSI-style) for stripping from captured output.
    private static let ansiEscapePattern = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
    )

    private let delegateAdapter: DelegateAdapter
    private let process: LocalProcess

    /// All bytes received from the PTY since the session started.
    private var buffer: [UInt8] = []
    /// Byte offset into `buffer` marking the start of the currently-pending command's output
    /// (set when `run` writes the command; consumed once that command's marker is found).
    private var pendingStart: Int = 0
    /// The marker string for the in-flight command, or `nil` if no command is outstanding.
    private var pendingMark: String?
    /// Set once the underlying shell process has exited.
    private var hasExited = false
    /// Byte offset into `buffer` marking what `read()`/`wait(timeoutMs:)` have already
    /// surfaced to callers. Distinct from `pendingStart`: `pendingStart` tracks the start of
    /// the *current command's* region (consumed/reset by `run`'s own marker search via
    /// `extractFinished`), while `readCursor` tracks how much of that region `read`/`wait`
    /// have already returned, so each call only reports output that's new since the last one.
    private var readCursor: Int = 0
    /// Exit code of the most recently completed command, surfaced by `read()`/`wait` when no
    /// command is currently pending.
    private var lastExitCode: Int32?

    public init(rootURL: URL) async throws {
        let adapter = DelegateAdapter()
        delegateAdapter = adapter
        process = LocalProcess(delegate: adapter)

        var environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        environment.append("TERM=dumb")

        process.startProcess(
            executable: "/bin/zsh",
            args: ["-f"],
            environment: environment,
            currentDirectory: rootURL.path
        )

        guard process.shellPid != 0, process.childfd >= 0 else {
            throw TerminalWorkspaceError.sessionSpawnFailed
        }

        // Wire the adapter back to this actor now that `self` fully exists.
        adapter.session = self
    }

    /// Runs `command` in the session's shell and waits (up to `graceMs`) for it to complete.
    ///
    /// - Throws: `TerminalWorkspaceError.commandAlreadyRunning` if a previous command is
    ///   still outstanding, or `TerminalWorkspaceError.shellExited` if the shell has exited.
    public func run(_ command: String, graceMs: Int) async throws -> RunResult {
        guard pendingMark == nil else {
            throw TerminalWorkspaceError.commandAlreadyRunning
        }
        guard !hasExited else {
            throw TerminalWorkspaceError.shellExited
        }

        let mark = "MARK-\(UUID().uuidString)"
        pendingMark = mark
        pendingStart = buffer.count
        readCursor = buffer.count

        let line = "\(command); printf '\\n\(mark):%s\\n' \"$?\"\n"
        let bytes = Array(line.utf8)
        process.send(data: bytes[...])

        return await collectUntilMark(mark: mark, graceMs: graceMs)
    }

    /// Returns output accumulated since the last `read`/`wait`/`run` call, along with the
    /// current status of the command (if any) issued by the most recent `run`.
    ///
    /// If a command is pending, this makes one attempt to find its completion marker (in case
    /// it arrived between polls) before falling back to reporting partial output as
    /// `.running`. If no command is pending, returns any unread trailing output (there
    /// shouldn't normally be any) with `.finished` carrying the last known exit code.
    public func read() async -> ReadResult {
        if let mark = pendingMark {
            if let finished = extractFinished(mark: mark) {
                pendingMark = nil
                lastExitCode = finished.exitCode
                let newOutput = sinceReadCursor(upTo: finished.markerLocation)
                readCursor = buffer.count
                return ReadResult(output: newOutput, status: .finished(finished.exitCode))
            }

            let newOutput = sinceReadCursor(upTo: buffer.count)
            readCursor = buffer.count
            return ReadResult(output: newOutput, status: .running)
        }

        let newOutput = sinceReadCursor(upTo: buffer.count)
        readCursor = buffer.count
        return ReadResult(output: newOutput, status: .finished(lastExitCode ?? 0))
    }

    /// Polls (like `run`'s grace period) until the pending command's completion marker
    /// appears, the shell exits, or `timeoutMs` elapses, then returns the accumulated output
    /// since the last `read`/`wait`/`run` call along with the resulting status.
    ///
    /// If no command is pending when called, returns immediately (equivalent to `read()`).
    /// Never throws: a timeout is reported as `.running`, not an error.
    public func wait(timeoutMs: Int) async -> ReadResult {
        guard pendingMark != nil else {
            return await read()
        }

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var accumulated = ""

        while true {
            let result = await read()
            accumulated += result.output

            if case let .finished(code) = result.status {
                return ReadResult(output: accumulated, status: .finished(code))
            }
            if hasExited || Date() >= deadline {
                return ReadResult(output: accumulated, status: .running)
            }
            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms poll interval
        }
    }

    /// Terminates the session's shell process. Safe to call more than once.
    public func terminate() {
        guard !hasExited else { return }
        process.terminate()
    }

    /// Invoked (via the delegate adapter) whenever new bytes arrive from the PTY.
    func appendOutput(_ bytes: ArraySlice<UInt8>) {
        buffer.append(contentsOf: bytes)
    }

    /// Invoked (via the delegate adapter) when the shell process exits.
    func handleTerminated(exitCode _: Int32?) {
        hasExited = true
    }

    /// Polls `buffer` (starting at `pendingStart`) for `mark`'s completion line, up to a
    /// total budget of `graceMs` milliseconds. Returns `.finished` with the cleaned output
    /// and parsed exit code if the marker is found in time, or `.running` with the
    /// (cleaned) partial output so far if the budget is exhausted — in which case the
    /// command is left pending for a future `read`/`wait`.
    private func collectUntilMark(mark: String, graceMs: Int) async -> RunResult {
        let deadline = Date().addingTimeInterval(Double(graceMs) / 1000.0)

        while true {
            if let found = extractFinished(mark: mark) {
                pendingMark = nil
                lastExitCode = found.exitCode
                pendingStart = buffer.count
                readCursor = buffer.count
                return .finished(found.output, found.exitCode)
            }

            if hasExited || Date() >= deadline {
                let partial = decodeAndClean(buffer[pendingStart...], stripFirstEchoedLine: true)
                return .running(partial)
            }

            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms poll interval
        }
    }

    /// A located, parsed completion marker: the cleaned output of the command that preceded
    /// it, its exit code, and the byte offset in `buffer` where the marker line begins (the
    /// boundary up to which `read`/`wait` should report this command's output).
    private struct FoundMarker {
        let output: String
        let exitCode: Int32
        let markerLocation: Int
    }

    /// Attempts to locate `mark`'s completion line within the pending region of `buffer`
    /// (i.e. `buffer[pendingStart...]`). Returns `nil` if the marker hasn't appeared yet.
    /// Does NOT mutate `pendingStart`/`readCursor` — callers (`collectUntilMark`, `read`)
    /// decide how to advance those based on their own contract.
    private func extractFinished(mark: String) -> FoundMarker? {
        let region = buffer[pendingStart...]
        let text = String(decoding: region, as: UTF8.self)
        let nsText = text as NSString

        guard let match = Self.markerLinePattern.firstMatch(
            in: text, range: NSRange(location: 0, length: nsText.length)
        ) else {
            return nil
        }

        // Confirm this match is *our* mark (markers embed a UUID; pattern is generic, so
        // double-check the literal mark text precedes the matched range).
        let matchedMark = nsText.substring(with: match.range).split(separator: ":").first.map(String.init)
        guard matchedMark == mark else {
            return nil
        }

        let exitCodeRange = match.range(at: 1)
        let exitCodeString = nsText.substring(with: exitCodeRange)
        guard let exitCode = Int32(exitCodeString) else {
            return nil
        }

        // Output is everything before the marker line begins (relative to the start of the
        // pending region, then converted back into an absolute `buffer` offset below).
        let outputText = nsText.substring(to: match.range.location)
        let cleaned = cleanOutput(outputText, stripFirstEchoedLine: true)

        // `match.range.location` is a UTF-16 offset into `text`, which itself starts at
        // `pendingStart`. Recompute the absolute byte offset by re-encoding the prefix.
        let markerLocation = pendingStart + outputText.utf8.count

        return FoundMarker(output: cleaned, exitCode: exitCode, markerLocation: markerLocation)
    }

    /// Returns the cleaned text of `buffer[readCursor..<upperBound]`, stripping the echoed
    /// command line only on the very first read of a command's output (i.e. when
    /// `readCursor == pendingStart`, the offset `run` set when it issued the command).
    private func sinceReadCursor(upTo upperBound: Int) -> String {
        guard readCursor < upperBound else { return "" }
        let stripEcho = readCursor == pendingStart
        return decodeAndClean(buffer[readCursor ..< upperBound], stripFirstEchoedLine: stripEcho)
    }

    /// Decodes a raw byte slice as UTF-8 and applies the same cleanup as `cleanOutput`.
    private func decodeAndClean(_ bytes: ArraySlice<UInt8>, stripFirstEchoedLine: Bool) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        return cleanOutput(text, stripFirstEchoedLine: stripFirstEchoedLine)
    }

    /// Strips the PTY-echoed command line (the first line, when present) and ANSI escape
    /// sequences/bare carriage returns from `text`.
    private func cleanOutput(_ text: String, stripFirstEchoedLine: Bool) -> String {
        let nsText = text as NSString
        let ansiStripped = Self.ansiEscapePattern.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: ""
        )

        var working = ansiStripped.replacingOccurrences(of: "\r", with: "")

        if stripFirstEchoedLine {
            if let newlineIndex = working.firstIndex(of: "\n") {
                working = String(working[working.index(after: newlineIndex)...])
            } else {
                // No newline yet means the entire text so far is just the echo; nothing left.
                working = ""
            }
        }

        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
