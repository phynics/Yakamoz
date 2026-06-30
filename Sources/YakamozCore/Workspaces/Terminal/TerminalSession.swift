import Foundation
import SwiftTerm

/// Result of running a command through `TerminalSession.run`.
///
/// `.finished` carries the cleaned output text, the command's exit code, and the command's
/// unique id (for fetching full output via `readStoredOutput`). `.running` is returned when
/// the grace period elapses before the command's completion marker appears; the command is
/// left in-flight (`TerminalSession` keeps tracking it) and the caller can poll again later
/// via `read()`/`wait(timeoutMs:)`.
public enum RunResult: Sendable, Equatable {
    case finished(String, Int32, UUID)
    case running(String, UUID)
}

/// Status of a session's in-flight (or most recently completed) command, as observed by
/// `read()`/`wait(timeoutMs:)`.
public enum TerminalStatus: Sendable, Equatable {
    case running
    case finished(Int32)
}

/// Result of `TerminalSession.read()`/`wait(timeoutMs:)`: output accumulated since the last
/// `read`/`wait`/`run` call, the current status of the (possibly still in-flight) command,
/// and the command's unique id (for fetching full output via `readStoredOutput`).
public struct ReadResult: Sendable, Equatable {
    public let output: String
    public let status: TerminalStatus
    public let commandId: UUID

    public init(output: String, status: TerminalStatus, commandId: UUID) {
        self.output = output
        self.status = status
        self.commandId = commandId
    }
}

/// Stored output of a completed command, available for paging via `readStoredOutput`.
public struct StoredOutput: Sendable, Equatable {
    public let fullOutput: String
    /// The lines of full output, split on newlines (empty if fullOutput is empty).
    public let lines: [String]

    public init(fullOutput: String) {
        self.fullOutput = fullOutput
        lines = fullOutput.isEmpty ? [] : fullOutput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    public var byteCount: Int {
        fullOutput.utf8.count
    }

    public var lineCount: Int {
        lines.count
    }
}

/// Runs an interactive shell on a pseudo-terminal (via `SwiftTerm.LocalProcess`) and lets
/// callers execute commands and observe their output and exit code.
///
/// **Output capture.** Each `run` brackets the command between two per-command markers:
/// `printf '\nBEGIN-<id>\n'; <command>; printf '\nEND-<id>:%s\n' "$?"`. Output is captured
/// strictly between `BEGIN-<id>` and `END-<id>:<code>`, so prompt/echo/line-editor noise can
/// never leak in. To make this robust, the session disables tty echo, the zsh line editor
/// (`zle`), and the prompt at startup (`prepareShell`) — otherwise the PTY would echo each
/// command (duplicating the markers) and zsh's line editor would wrap/redraw long command
/// lines with cursor-movement escapes. `<id>` is a fresh random UUID per command, so a command
/// that prints a marker-shaped line with a *different* id cannot terminate the command early
/// (a command printing this command's exact random id is indistinguishable, but unguessable).
///
/// `TerminalSession` is an `actor`: all mutable PTY-output state (`buffer`, `pendingStart`,
/// `readCursor`, `pendingMark`) is owned by the actor, and the only way data flows in from the
/// (non-actor, delegate-driven) PTY read loop is through `appendOutput`/`handleTerminated`,
/// both of which are actor methods invoked from `Task { await ... }` hops inside the
/// delegate adapter below.
public actor TerminalSession {
    /// Bridges `SwiftTerm.LocalProcessDelegate` (a class-bound protocol, called back on a
    /// `DispatchQueue`) into the actor. `LocalProcess` holds its delegate weakly, so
    /// `TerminalSession` keeps a strong reference to this adapter for the process's lifetime.
    private final class DelegateAdapter: LocalProcessDelegate {
        weak var session: TerminalSession?
        private let sequenceLock = NSLock()
        private var nextSequence = 0

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
            let sequence = reserveSequence()
            Task { await session.appendOutput(bytes, sequence: sequence) }
        }

        func getWindowSize() -> winsize {
            winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }

        private func reserveSequence() -> Int {
            sequenceLock.lock()
            defer { sequenceLock.unlock() }

            let sequence = nextSequence
            nextSequence += 1
            return sequence
        }
    }

    /// Matches ANSI escape sequences (CSI-style) for stripping from captured output.
    private static let ansiEscapePattern = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
    )

    private let delegateAdapter: DelegateAdapter
    private let process: LocalProcess

    /// All bytes received from the PTY since the session started.
    private var buffer: [UInt8] = []
    /// Byte offset into `buffer` marking the start of the currently-pending command's region
    /// (set when `run` writes the command; consumed once that command's END marker is found).
    private var pendingStart: Int = 0
    /// The per-command random id for the in-flight command, or `nil` if no command is
    /// outstanding. Both the start marker (`BEGIN-<id>`) and end marker (`END-<id>:<code>`)
    /// embed this same id.
    private var pendingMark: String?
    /// The UUID of the currently in-flight command, or `nil` if no command is running.
    /// This is separate from `pendingMark` which is a random string used for PTY delimiting.
    private var pendingCommandId: UUID?
    /// Set once the underlying shell process has exited.
    private var hasExited = false
    /// Byte offset into `buffer` marking what `read()`/`wait(timeoutMs:)` have already
    /// surfaced to callers. Distinct from `pendingStart`: `pendingStart` tracks the start of
    /// the *current command's* region, while `readCursor` tracks how much of that region
    /// `read`/`wait` have already returned, so each call only reports output new since the last.
    private var readCursor: Int = 0
    /// Exit code of the most recently completed command, surfaced by `read()`/`wait` when no
    /// command is currently pending.
    private var lastExitCode: Int32?
    /// Delegate callbacks are synchronous, but each callback enters this actor via its own
    /// task. Sequence numbers preserve PTY byte ordering if those tasks are scheduled out of
    /// order.
    private var nextOutputSequence = 0
    private var pendingOutputChunks: [Int: [UInt8]] = [:]

    // MARK: - Full output store (YAK-T6)

    // This store is SEPARATE from the YAK-TF4 PTY buffer compaction mechanism.
    // - PTY buffer (`buffer`, `pendingStart`, etc.) is compacted after each command finishes,
    //   retaining only the current command's region (or nothing if idle).
    // - Full output store (`commandOutputs`) is an LRU-capped map preserving complete output
    //   for the last N commands, persisting through PTY compaction so agents can fetch full
    //   output later via `readStoredOutput`. The two mechanisms are orthogonal: PTY stays
    //   bounded; full-output store is a distinct, explicitly-capped resource.

    /// Stored full output keyed by command UUID, with LRU eviction when cap is exceeded.
    /// Proposed cap: last 20 commands OR 8 MB total, whichever first.
    private var commandOutputs: [UUID: StoredOutput] = [:]
    /// Ordered list of command UUIDs, oldest first, for LRU eviction.
    private var commandOutputOrder: [UUID] = []
    /// Running byte sum of all stored outputs (used to enforce byte cap).
    private var totalStoredBytes: Int = 0
    /// FIFO record of command ids evicted from `commandOutputs` by the LRU cap, so
    /// `readStoredOutput` can distinguish an evicted id (`commandOutputExpired`) from a
    /// never-issued one (`unknownCommandOutput`). Bounded to the last N evicted ids; once an id
    /// ages out of this list it legitimately falls back to `unknownCommandOutput`.
    private var evictedCommandIds: [UUID] = []
    private var evictedCommandIdSet: Set<UUID> = []

    private static let commandOutputCapCount = 20
    private static let commandOutputCapBytes = 8 * 1024 * 1024 // 8 MB
    private static let evictedCommandIdCapCount = 200

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

        try await prepareShell()
    }

    /// Quiesces the shell so command output can be captured cleanly: disables tty echo, the
    /// zsh line editor, and the prompt, then drains everything up to a one-shot READY marker
    /// and clears the buffer so the first `run` starts from a blank slate.
    private func prepareShell() async throws {
        let initId = UUID().uuidString
        // `stty -echo` stops the tty echoing sent commands; `unsetopt zle` stops zsh's line
        // editor from redrawing/wrapping input; clearing PROMPT/RPROMPT removes prompt noise.
        //
        // The READY marker is printed via `printf '...%s...' '<id>'` rather than interpolating
        // the id into the format string: this setup line is sent while tty echo is still on
        // (echo is only disabled once `stty -echo` runs), so the line is echoed back. With the
        // id passed as a `%s` argument, the echoed *source* contains `READY-%s` (no contiguous
        // `READY-<id>`), while only the *executed* output produces the contiguous token we scan
        // for — so the drain can't match the echo and clear the buffer prematurely.
        let setup = "stty -echo; unsetopt zle 2>/dev/null; PROMPT=''; RPROMPT=''; printf '\\nREADY-%s\\n' '\(initId)'\n"
        process.send(data: Array(setup.utf8)[...])

        let needle = Array("READY-\(initId)".utf8)
        let deadline = Date().addingTimeInterval(5.0)
        while true {
            if buffer[...].firstRange(of: needle) != nil {
                buffer.removeAll(keepingCapacity: true)
                pendingStart = 0
                readCursor = 0
                return
            }
            if hasExited || Date() >= deadline {
                throw TerminalWorkspaceError.sessionSpawnFailed
            }
            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms poll interval
        }
    }

    /// Runs `command` in the session's shell and waits (up to `graceMs`) for it to complete.
    ///
    /// - Parameters:
    ///   - command: The shell command to run.
    ///   - graceMs: Grace period in milliseconds to wait for the command to complete.
    ///   - grepPattern: Optional regex pattern to filter output to matching lines. Pattern is
    ///     safely passed to the shell via quoted argument, not interpolated into the command line.
    /// - Throws: `TerminalWorkspaceError.commandAlreadyRunning` if a previous command is
    ///   still outstanding, or `TerminalWorkspaceError.shellExited` if the shell has exited.
    public func run(
        _ command: String,
        graceMs: Int,
        grepPattern: String? = nil
    ) async throws -> RunResult {
        guard pendingMark == nil else {
            throw TerminalWorkspaceError.commandAlreadyRunning
        }
        guard !hasExited else {
            throw TerminalWorkspaceError.shellExited
        }

        let id = UUID().uuidString
        let commandUUID = UUID()
        pendingMark = id
        pendingCommandId = commandUUID
        pendingStart = buffer.count
        readCursor = buffer.count

        // BEGIN is printed *before* the command so the command's real stdout lands strictly
        // between BEGIN-<id> and END-<id>:<exit code>; everything else is excluded by the
        // marker-bracketed extraction (no echo-stripping heuristic). The id is passed as a
        // `%s` argument (not interpolated into the format) so that even if tty echo were on,
        // the echoed source wouldn't contain the contiguous marker token we scan for.
        //
        // If grepPattern is provided, pipe the command output through grep with the pattern
        // passed safely as a quoted argument (not interpolated into the shell line).
        let commandLine: String
        if let pattern = grepPattern {
            // Use grep with the pattern safely quoted; -- stops option processing so
            // patterns starting with '-' are not interpreted as flags.
            commandLine = "(\(command)) | grep -- '\(pattern.replacingOccurrences(of: "'", with: "'\\''"))'"
        } else {
            commandLine = command
        }

        let line = "printf '\\nBEGIN-%s\\n' '\(id)'; \(commandLine); printf '\\nEND-%s:%s\\n' '\(id)' \"$?\"\n"
        process.send(data: Array(line.utf8)[...])

        return await collectUntilMark(mark: id, commandId: commandUUID, graceMs: graceMs)
    }

    /// Returns output accumulated since the last `read`/`wait`/`run` call, along with the
    /// current status of the command (if any) issued by the most recent `run`, and the command id.
    ///
    /// If a command is pending, this makes one attempt to find its completion marker (in case
    /// it arrived between polls) before falling back to reporting partial output as
    /// `.running`. If no command is pending, returns any unread trailing output (there
    /// shouldn't normally be any) with `.finished` carrying the last known exit code.
    public func read() async -> ReadResult {
        let commandId = pendingCommandId ?? UUID()
        if let mark = pendingMark {
            if let finished = extractFinished(mark: mark) {
                pendingMark = nil
                let commandIdToReturn = pendingCommandId ?? UUID()
                lastExitCode = finished.exitCode
                let newOutput = sinceReadCursor(upTo: finished.markerLocation)
                readCursor = buffer.count
                storeCommandOutput(id: commandIdToReturn, output: finished.output)
                compactBufferIfFullyConsumed()
                return ReadResult(output: newOutput, status: .finished(finished.exitCode), commandId: commandIdToReturn)
            }

            let newOutput = sinceReadCursor(upTo: buffer.count)
            readCursor = buffer.count
            return ReadResult(output: newOutput, status: .running, commandId: commandId)
        }

        let newOutput = sinceReadCursor(upTo: buffer.count)
        readCursor = buffer.count
        compactBufferIfFullyConsumed()
        return ReadResult(output: newOutput, status: .finished(lastExitCode ?? 0), commandId: commandId)
    }

    /// Polls until the pending command's completion marker appears, the shell exits, or
    /// `timeoutMs` elapses, then returns the accumulated output since the last `read`/`wait`/
    /// `run` call along with the resulting status and command id.
    ///
    /// If no command is pending when called, returns immediately (equivalent to `read()`).
    /// Never throws: a timeout is reported as `.running`, not an error.
    public func wait(timeoutMs: Int) async -> ReadResult {
        guard pendingMark != nil else {
            return await read()
        }

        let commandId = pendingCommandId ?? UUID()
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var accumulated = ""

        while true {
            let result = await read()
            accumulated += result.output

            if case let .finished(code) = result.status {
                return ReadResult(output: accumulated, status: .finished(code), commandId: result.commandId)
            }
            if hasExited || Date() >= deadline {
                return ReadResult(output: accumulated, status: .running, commandId: commandId)
            }
            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms poll interval
        }
    }

    /// Terminates the session's shell process and waits briefly for the delegate-reported exit.
    ///
    /// Safe to call more than once. Waiting for `hasExited` keeps test and registry cleanup from
    /// racing ahead while the PTY child is still alive.
    public func terminate() async {
        guard !hasExited else { return }
        process.terminate()

        let deadline = Date().addingTimeInterval(2.0)
        while !hasExited, Date() < deadline {
            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms poll interval
        }
    }

    /// Exposes retained PTY buffer size to tests that verify session compaction behavior.
    func bufferByteCountForTesting() -> Int {
        buffer.count
    }

    /// Feeds `text` to the running command's stdin, raw (no marker/cursor bookkeeping). The
    /// caller is responsible for including any trailing newline `text` needs.
    ///
    /// This does not consult an approver — steering an already-approved, already-running
    /// command is considered part of that command's existing approval (approval/tooling
    /// concerns live above `TerminalSession`).
    ///
    /// Requires an in-flight command: writing to stdin when nothing is running would let a
    /// caller feed an arbitrary line straight to the idle login shell, bypassing the
    /// per-command approval gate (`terminal_run`). Rejects that case with `.notRunning`.
    ///
    /// - Throws: `TerminalWorkspaceError.shellExited` if the shell has already exited, or
    ///   `TerminalWorkspaceError.notRunning` if no command is currently in-flight.
    public func sendInput(_ text: String) async throws {
        guard !hasExited else { throw TerminalWorkspaceError.shellExited }
        guard pendingMark != nil else { throw TerminalWorkspaceError.notRunning }
        process.send(data: Array(text.utf8)[...])
    }

    /// Sends Ctrl-C (SIGINT, byte `0x03`) to the running command.
    ///
    /// `run` issues each command as a `;`-separated zsh list ending in the END-marker `printf`.
    /// Observed behavior (verified by the `interruptStopsRunningCommand` test): SIGINT-ing the
    /// foreground job aborts the *entire* list in this shell setup — the trailing `printf` END
    /// marker never runs, so it would never arrive on its own and `pendingMark` would leak
    /// (a subsequent `run` would throw `.commandAlreadyRunning`).
    ///
    /// To keep the session usable, after sending Ctrl-C this method injects a synthetic
    /// `END-<id>:130` line for the *same* pending id directly into the buffer (130 = the
    /// conventional `128 + SIGINT` interrupted exit code). The BEGIN marker for this command
    /// already arrived (the start `printf` runs before the command), so the dual-marker
    /// extractor resolves this synthetic line identically to a real one, and the session is
    /// immediately reusable.
    public func interrupt() async {
        guard !hasExited else { return }
        guard let mark = pendingMark else { return }

        process.send(data: [0x03][...])

        // Give the shell a brief moment to actually abort/echo before injecting the synthetic
        // marker, so any output it does produce is captured ahead of the marker line.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // If the real marker arrived in that window (e.g. a shell where the list continues),
        // don't inject a duplicate.
        guard pendingMark == mark, extractFinished(mark: mark) == nil else { return }

        buffer.append(contentsOf: Array("\nEND-\(mark):130\n".utf8))
    }

    /// Invoked (via the delegate adapter) whenever new bytes arrive from the PTY.
    func appendOutput(_ bytes: [UInt8], sequence: Int) {
        pendingOutputChunks[sequence] = bytes

        while let chunk = pendingOutputChunks.removeValue(forKey: nextOutputSequence) {
            buffer.append(contentsOf: chunk)
            nextOutputSequence += 1
        }
    }

    /// Invoked (via the delegate adapter) when the shell process exits.
    func handleTerminated(exitCode _: Int32?) {
        hasExited = true
    }

    /// Polls `buffer` for `mark`'s completion line, up to a total budget of `graceMs`
    /// milliseconds. Returns `.finished` with the cleaned output and parsed exit code if the
    /// marker is found in time, or `.running` with the (cleaned) partial output so far if the
    /// budget is exhausted — in which case the command is left pending for a future `read`/`wait`.
    private func collectUntilMark(mark: String, commandId: UUID, graceMs: Int) async -> RunResult {
        let deadline = Date().addingTimeInterval(Double(graceMs) / 1000.0)

        while true {
            if let found = extractFinished(mark: mark) {
                pendingMark = nil
                let idToReturn = pendingCommandId ?? UUID()
                lastExitCode = found.exitCode
                pendingStart = buffer.count
                readCursor = buffer.count
                storeCommandOutput(id: idToReturn, output: found.output)
                compactBufferIfFullyConsumed()
                return .finished(found.output, found.exitCode, idToReturn)
            }

            if hasExited || Date() >= deadline {
                let partial = partialOutputSinceBegin(mark: mark)
                readCursor = buffer.count
                return .running(partial, commandId)
            }

            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms poll interval
        }
    }

    /// Drops fully-consumed output once no command is pending so a long-lived session only
    /// retains the active command's transcript rather than every prior command forever.
    /// Note: This is the YAK-TF4 buffer compaction mechanism; the separate commandOutputs
    /// store (YAK-T6) survives this compaction and is not affected by it.
    private func compactBufferIfFullyConsumed() {
        guard pendingMark == nil, readCursor == buffer.count else { return }
        buffer.removeAll(keepingCapacity: true)
        pendingStart = 0
        readCursor = 0
    }

    /// Stores the full output of a completed command in the LRU-capped commandOutputs map.
    /// Evicts oldest commands if the store exceeds the cap (count or bytes).
    private func storeCommandOutput(id: UUID, output: String) {
        let stored = StoredOutput(fullOutput: output)
        let byteCount = stored.byteCount

        commandOutputs[id] = stored
        commandOutputOrder.append(id)
        totalStoredBytes += byteCount

        // Evict oldest commands if over either cap, recording each eviction so a later
        // `readStoredOutput` can report `commandOutputExpired` (vs. `unknownCommandOutput`).
        while commandOutputOrder.count > Self.commandOutputCapCount || totalStoredBytes > Self.commandOutputCapBytes {
            guard let oldest = commandOutputOrder.first else { break }
            commandOutputOrder.removeFirst()
            if let removed = commandOutputs.removeValue(forKey: oldest) {
                totalStoredBytes -= removed.byteCount
            }
            recordEvictedCommandId(oldest)
        }
    }

    /// Records an evicted command id in a bounded FIFO so `readStoredOutput` can distinguish
    /// an evicted id from a never-issued one. When the FIFO overflows its cap, the oldest
    /// evicted id is dropped — at which point that very old id falls back to `unknownCommandOutput`.
    private func recordEvictedCommandId(_ id: UUID) {
        evictedCommandIds.append(id)
        evictedCommandIdSet.insert(id)
        while evictedCommandIds.count > Self.evictedCommandIdCapCount {
            let dropped = evictedCommandIds.removeFirst()
            evictedCommandIdSet.remove(dropped)
        }
    }

    /// Fetches a page of stored output for the given command id (actor-isolated read).
    ///
    /// - Parameters:
    ///   - commandId: The UUID of the command.
    ///   - offset: Starting line index (0-indexed). Defaults to 0.
    ///   - limit: Maximum lines to return. Defaults to nil (all remaining lines).
    /// - Returns: A tuple of (lines, totalLineCount, totalByteCount).
    /// - Throws: `commandOutputExpired` if the id was stored then evicted by the LRU cap (and is
    ///   still tracked in the bounded evicted-id FIFO); `unknownCommandOutput` if the id was never
    ///   issued (or aged out of the evicted-id FIFO).
    public func readStoredOutput(commandId: UUID, offset: Int = 0, limit: Int? = nil) throws -> (lines: [String], totalLines: Int, totalBytes: Int) {
        guard let stored = commandOutputs[commandId] else {
            // Distinguish an evicted (was-stored, then dropped by the cap) id from a never-issued one.
            if evictedCommandIdSet.contains(commandId) {
                throw TerminalWorkspaceError.commandOutputExpired
            }
            throw TerminalWorkspaceError.unknownCommandOutput
        }

        let totalLines = stored.lineCount
        let totalBytes = stored.byteCount
        let startIdx = max(0, offset)
        let endIdx = limit.map { startIdx + $0 } ?? totalLines
        let clampedEnd = min(endIdx, totalLines)
        let range = startIdx ..< clampedEnd
        let lines = range.isEmpty ? [] : Array(stored.lines[range])

        return (lines, totalLines, totalBytes)
    }

    /// A located, parsed completion marker: the cleaned output of the command, its exit code,
    /// and the byte offset in `buffer` where the END marker line begins (the boundary up to
    /// which `read`/`wait` should report this command's output).
    private struct FoundMarker {
        let output: String
        let exitCode: Int32
        let markerLocation: Int
    }

    /// Finds the absolute `buffer` offset just past the `BEGIN-<id>` line within
    /// `buffer[pendingStart...]`, i.e. the start of the command's real-output region. Returns
    /// `nil` if the begin marker (or its terminating newline) hasn't arrived yet. Tolerant of
    /// the PTY's `\r\n` line endings — it scans to the next `\n` after `BEGIN-<id>`.
    private func beginMarkerEnd(mark: String) -> Int? {
        let needle = Array("BEGIN-\(mark)".utf8)
        guard let range = buffer[pendingStart...].firstRange(of: needle) else { return nil }
        var idx = range.upperBound
        while idx < buffer.count, buffer[idx] != 0x0A {
            idx += 1
        }
        guard idx < buffer.count else { return nil } // line's newline not yet arrived
        return idx + 1
    }

    /// Attempts to locate `mark`'s `END-<id>:<code>` line after its BEGIN marker. Returns `nil`
    /// until both markers (and a complete exit-code integer) for *this exact* id have arrived.
    /// Matches the literal per-command id, so a command printing a fake `END-<otherid>:0`
    /// cannot hijack capture. Does NOT mutate cursors — callers advance those per their contract.
    private func extractFinished(mark: String) -> FoundMarker? {
        guard let beginEnd = beginMarkerEnd(mark: mark) else { return nil }

        let endNeedle = Array("END-\(mark):".utf8)
        guard let endRange = buffer[beginEnd...].firstRange(of: endNeedle) else { return nil }

        // Parse the exit-code integer immediately following the colon. Require a non-digit
        // terminator to be present so we don't parse a half-arrived number.
        var i = endRange.upperBound
        var digits: [UInt8] = []
        if i < buffer.count, buffer[i] == 0x2D { digits.append(buffer[i]); i += 1 } // leading '-'
        while i < buffer.count, buffer[i] >= 0x30, buffer[i] <= 0x39 {
            digits.append(buffer[i]); i += 1
        }
        guard !digits.isEmpty, i < buffer.count,
              let exitCode = Int32(String(decoding: digits, as: UTF8.self))
        else { return nil }

        let cleaned = cleanOutput(String(decoding: buffer[beginEnd ..< endRange.lowerBound], as: UTF8.self))
        return FoundMarker(output: cleaned, exitCode: exitCode, markerLocation: endRange.lowerBound)
    }

    /// Returns the cleaned partial output of the in-flight command: bytes after the
    /// `BEGIN-<id>` line up to the end of `buffer`, or `""` if BEGIN hasn't arrived yet.
    private func partialOutputSinceBegin(mark: String) -> String {
        guard let beginEnd = beginMarkerEnd(mark: mark) else { return "" }
        return decodeAndClean(buffer[beginEnd...])
    }

    /// Returns the cleaned text of `buffer[readCursor..<upperBound]`, clamped to start no
    /// earlier than the current command's `BEGIN-<id>` marker (if one is pending), so output
    /// before the marker is never surfaced by `read`/`wait`.
    private func sinceReadCursor(upTo upperBound: Int) -> String {
        var lowerBound = readCursor
        if let mark = pendingMark, let beginEnd = beginMarkerEnd(mark: mark), beginEnd > lowerBound {
            lowerBound = beginEnd
        }
        guard lowerBound < upperBound else { return "" }
        return decodeAndClean(buffer[lowerBound ..< upperBound])
    }

    /// Decodes a raw byte slice as UTF-8 and applies the same cleanup as `cleanOutput`.
    private func decodeAndClean(_ bytes: ArraySlice<UInt8>) -> String {
        cleanOutput(String(decoding: bytes, as: UTF8.self))
    }

    /// Strips ANSI escape sequences and bare carriage returns from `text`, then trims
    /// surrounding whitespace/newlines. Callers slice `text` to the region strictly between
    /// the BEGIN and END markers, so no echo-stripping heuristic is needed here.
    private func cleanOutput(_ text: String) -> String {
        let nsText = text as NSString
        let ansiStripped = Self.ansiEscapePattern.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: ""
        )
        return ansiStripped.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
