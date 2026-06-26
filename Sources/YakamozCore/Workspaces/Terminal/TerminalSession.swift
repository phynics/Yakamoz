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

        let line = "\(command); printf '\\n\(mark):%s\\n' \"$?\"\n"
        let bytes = Array(line.utf8)
        process.send(data: bytes[...])

        return await collectUntilMark(mark: mark, graceMs: graceMs)
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
    /// command is left pending for a future read/wait (Task 10-11).
    private func collectUntilMark(mark: String, graceMs: Int) async -> RunResult {
        let deadline = Date().addingTimeInterval(Double(graceMs) / 1000.0)

        while true {
            if let result = extractFinished(mark: mark) {
                pendingMark = nil
                return result
            }

            if hasExited || Date() >= deadline {
                let partial = decodeAndClean(buffer[pendingStart...], stripFirstEchoedLine: true)
                return .running(partial)
            }

            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms poll interval
        }
    }

    /// Attempts to locate `mark`'s completion line within the pending region of `buffer`.
    /// Returns `nil` if the marker hasn't appeared yet.
    private func extractFinished(mark: String) -> RunResult? {
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

        // Output is everything before the marker line begins.
        let outputText = nsText.substring(to: match.range.location)

        let cleaned = cleanOutput(outputText, stripFirstEchoedLine: true)

        // Advance past this command's region so the next `run` starts fresh.
        pendingStart = buffer.count

        return .finished(cleaned, exitCode)
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
