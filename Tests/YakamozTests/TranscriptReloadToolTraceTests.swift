import Foundation
import PKShared
import PositronicKit
import Testing
@testable import YakamozCore

/// Exercises `YakamozRuntime.transcriptItems(from:)`'s reconstruction of tool-call /
/// tool-result traces from persisted `ConversationMessage` rows (STAB-3). A reloaded
/// conversation must surface the same tool badges/traces that were visible live, so the
/// "prompt pipeline under glass" story does not silently lose tool visibility across
/// restarts.
@Suite("TranscriptReload tool-trace reconstruction")
struct TranscriptReloadToolTraceTests {
    /// A user → assistant (with one tool call) → tool result → assistant (final text)
    /// sequence rebuilds a single assistant turn carrying one populated `ToolTrace`.
    @Test("assistant turn with one tool call reconstructs a single tool trace")
    func singleToolCallReconstructsTrace() throws {
        let timelineId = UUID()
        let userMsg = ConversationMessage(
            timelineId: timelineId, role: .user, content: "what is 2+2?"
        )
        let assistantCallId = "call_abc"
        let toolCallsJSON = try Self.encodeJSON([
            ToolCall(id: assistantCallId, name: "calculator", arguments: ["expression": AnyCodable("2+2")]),
        ])
        let assistantToolMsg = ConversationMessage(
            timelineId: timelineId, role: .assistant, content: "", toolCalls: toolCallsJSON
        )
        let toolMsg = ConversationMessage(
            timelineId: timelineId, role: .tool, content: "4", toolCallId: assistantCallId
        )
        let assistantFinalMsg = ConversationMessage(
            timelineId: timelineId, role: .assistant, content: "The answer is 4."
        )

        let transcript = YakamozRuntime.transcriptItems(from: [
            userMsg, assistantToolMsg, toolMsg, assistantFinalMsg,
        ])

        // One user item + one consolidated assistant item.
        #expect(transcript.count == 2)
        guard case let .assistant(id, turn) = transcript[1] else {
            Issue.record("expected an assistant item as second transcript entry")
            return
        }
        #expect(id == assistantFinalMsg.id)
        #expect(turn.toolOrder == [assistantCallId])
        #expect(turn.tools.count == 1)
        let trace = try #require(turn.tools[assistantCallId])
        #expect(trace.name == "calculator")
        #expect(trace.state == .succeeded)
        #expect(trace.output == "4")
        // Arguments round-trip as a JSON object string keyed by the persisted args.
        #expect(trace.arguments?.contains("\"expression\"") == true)
        #expect(trace.arguments?.contains("2+2") == true)
        // Final assistant message supplies text/thinking on reload.
        #expect(turn.response.reconstructedText == "The answer is 4.")
        #expect(turn.response.thinking == "")
        #expect(turn.isComplete == true)
        // One logical assistant turn → persisted inspection counter advanced by the two
        // assistant messages, so the bubble's `inspectionTurnIndex` is the latest (1).
        #expect(turn.inspectionTurnIndex == 1)
    }

    /// A tool whose result message carries the `"Error: …"` prefix reconstructs as a
    /// `.failed` trace with its `error` set (mirrors `ToolTurnProjector.projectError`).
    @Test("failed tool result reconstructs as a failed trace")
    func failedToolResultReconstructsAsFailed() throws {
        let timelineId = UUID()
        let assistantCallId = "call_fail"
        let toolCallsJSON = try Self.encodeJSON([
            ToolCall(id: assistantCallId, name: "read_file", arguments: ["path": AnyCodable("/secret")]),
        ])
        let assistantToolMsg = ConversationMessage(
            timelineId: timelineId, role: .assistant, content: "", toolCalls: toolCallsJSON
        )
        let toolMsg = ConversationMessage(
            timelineId: timelineId, role: .tool, content: "Error: permission denied", toolCallId: assistantCallId
        )
        let assistantFinalMsg = ConversationMessage(
            timelineId: timelineId, role: .assistant, content: "I couldn't read the file."
        )

        let transcript = YakamozRuntime.transcriptItems(from: [assistantToolMsg, toolMsg, assistantFinalMsg])

        guard case let .assistant(_, turn) = transcript.first(where: { Self.isAssistant($0) }) else {
            Issue.record("expected an assistant item")
            return
        }
        #expect(turn.tools.count == 1)
        let trace = try #require(turn.tools[assistantCallId])
        #expect(trace.state == .failed)
        #expect(trace.error == "permission denied")
        #expect(trace.output == nil)
    }

    /// Two round-trips within one user send (each with its own tool call) collapse into a
    /// single assistant turn whose `toolOrder` preserves first-seen order across both
    /// assistant messages.
    @Test("multiple tool round-trips within one send preserve first-seen order")
    func multipleRoundTripsPreserveOrder() throws {
        let timelineId = UUID()
        let firstCallId = "call_1"
        let secondCallId = "call_2"
        let firstToolCalls = try Self.encodeJSON([
            ToolCall(id: firstCallId, name: "ls", arguments: ["path": AnyCodable("/")]),
        ])
        let secondToolCalls = try Self.encodeJSON([
            ToolCall(id: secondCallId, name: "read_file", arguments: ["path": AnyCodable("/tmp/a")]),
        ])

        let messages: [ConversationMessage] = [
            ConversationMessage(timelineId: timelineId, role: .user, content: "show me the files"),
            ConversationMessage(timelineId: timelineId, role: .assistant, content: "", toolCalls: firstToolCalls),
            ConversationMessage(timelineId: timelineId, role: .tool, content: "a\nb", toolCallId: firstCallId),
            ConversationMessage(timelineId: timelineId, role: .assistant, content: "", toolCalls: secondToolCalls),
            ConversationMessage(timelineId: timelineId, role: .tool, content: "contents", toolCallId: secondCallId),
            ConversationMessage(timelineId: timelineId, role: .assistant, content: "Here are your files and a.txt."),
        ]

        let transcript = YakamozRuntime.transcriptItems(from: messages)

        #expect(transcript.count == 2) // user + one consolidated assistant
        guard case let .assistant(id, turn) = transcript[1] else {
            Issue.record("expected an assistant item as second transcript entry")
            return
        }
        // Final assistant message supplies the bubble id and reconstructed text.
        let lastAssistant = messages.last { $0.messageRole == .assistant }
        #expect(id == lastAssistant?.id)
        #expect(turn.response.reconstructedText == "Here are your files and a.txt.")
        #expect(turn.toolOrder == [firstCallId, secondCallId])
        #expect(turn.tools.count == 2)
        #expect(turn.tools[firstCallId]?.name == "ls")
        #expect(turn.tools[firstCallId]?.state == .succeeded)
        #expect(turn.tools[firstCallId]?.output == "a\nb")
        #expect(turn.tools[secondCallId]?.name == "read_file")
        #expect(turn.tools[secondCallId]?.output == "contents")
        // Three assistant messages advanced the inspection counter three times.
        #expect(turn.inspectionTurnIndex == 2)
    }

    /// A conversation with two separate user sends rebuilds two assistant turns, each
    /// with its own tool traces (no leakage across turns).
    @Test("two sends rebuild two independent tool-traced turns")
    func twoSendsTwoTurns() throws {
        let timelineId = UUID()
        let callA = "call_a"
        let callB = "call_b"

        let messages: [ConversationMessage] = try [
            ConversationMessage(timelineId: timelineId, role: .user, content: "turn 1"),
            ConversationMessage(
                timelineId: timelineId, role: .assistant, content: "",
                toolCalls: Self.encodeJSON([ToolCall(id: callA, name: "calcul", arguments: ["e": AnyCodable("1+1")])])
            ),
            ConversationMessage(timelineId: timelineId, role: .tool, content: "2", toolCallId: callA),
            ConversationMessage(timelineId: timelineId, role: .assistant, content: "It's 2."),
            // Second send.
            ConversationMessage(timelineId: timelineId, role: .user, content: "turn 2"),
            ConversationMessage(
                timelineId: timelineId, role: .assistant, content: "",
                toolCalls: Self.encodeJSON([ToolCall(id: callB, name: "calcul", arguments: ["e": AnyCodable("3+3")])])
            ),
            ConversationMessage(timelineId: timelineId, role: .tool, content: "6", toolCallId: callB),
            ConversationMessage(timelineId: timelineId, role: .assistant, content: "It's 6."),
        ]

        let transcript = YakamozRuntime.transcriptItems(from: messages)
        // user, assistant, user, assistant
        #expect(transcript.count == 4)
        let assistantTurns = transcript.compactMap { item -> ChatTurnState? in
            if case let .assistant(_, turn) = item { return turn } else { return nil }
        }
        #expect(assistantTurns.count == 2)

        #expect(assistantTurns[0].toolOrder == [callA])
        #expect(assistantTurns[0].tools[callA]?.output == "2")
        #expect(assistantTurns[0].response.reconstructedText == "It's 2.")

        #expect(assistantTurns[1].toolOrder == [callB])
        #expect(assistantTurns[1].tools[callB]?.output == "6")
        #expect(assistantTurns[1].response.reconstructedText == "It's 6.")
    }

    /// A plain text-only assistant turn (no tool calls) rebuilds with an empty tool
    /// map/order — regression guard ensuring the new path did not change plain turns.
    @Test("plain assistant turn keeps an empty tool map")
    func plainAssistantTurnHasNoTools() {
        let timelineId = UUID()
        let messages: [ConversationMessage] = [
            ConversationMessage(timelineId: timelineId, role: .user, content: "hi"),
            ConversationMessage(timelineId: timelineId, role: .assistant, content: "hello!", think: "greeting"),
        ]

        let transcript = YakamozRuntime.transcriptItems(from: messages)
        #expect(transcript.count == 2)
        guard case let .assistant(_, turn) = transcript[1] else {
            Issue.record("expected an assistant item")
            return
        }
        #expect(turn.toolOrder.isEmpty)
        #expect(turn.tools.isEmpty)
        #expect(turn.response.reconstructedText == "hello!")
        #expect(turn.response.thinking == "greeting")
    }

    /// Orphaned `.tool`-role results (no matching persisted call — malformed persisted
    /// state) must sort deterministically by timestamp ascending, not by dictionary
    /// iteration order, when populating `toolOrder`/`tools` (STAB-14).
    @Test("orphaned tool results sort by timestamp, not dictionary iteration order")
    func orphanedToolResultsSortByTimestamp() {
        let timelineId = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Deliberately construct orphan ids/timestamps so that neither insertion order
        // nor natural string/dictionary order of the call ids matches the expected
        // (timestamp-ascending) order — this would fail under nondeterministic dictionary
        // iteration if the fix regresses.
        let orphanZ = ConversationMessage(
            timelineId: timelineId, role: .tool, content: "third",
            toolCallId: "call_zzz_last"
        )
        let orphanA = ConversationMessage(
            timelineId: timelineId, role: .tool, content: "first",
            toolCallId: "call_aaa_first"
        )
        let orphanM = ConversationMessage(
            timelineId: timelineId, role: .tool, content: "second",
            toolCallId: "call_mmm_middle"
        )

        // Assign timestamps out of both insertion and alphabetical order: A is latest,
        // Z is earliest, M is in between — so expected order (Z, M, A) matches neither.
        var earliest = orphanZ
        earliest.timestamp = base
        var middle = orphanM
        middle.timestamp = base.addingTimeInterval(1)
        var latest = orphanA
        latest.timestamp = base.addingTimeInterval(2)

        let assistantFinalMsg = ConversationMessage(
            timelineId: timelineId, role: .assistant, content: "done"
        )

        // Insertion order into the reconstruction is A, M, Z (reverse of expected
        // timestamp order) so a naive dictionary-iteration-order bug would very likely
        // diverge from the timestamp-sorted expectation.
        let transcript = YakamozRuntime.transcriptItems(from: [
            latest, middle, earliest, assistantFinalMsg,
        ])

        guard case let .assistant(_, turn) = transcript.first(where: { Self.isAssistant($0) }) else {
            Issue.record("expected an assistant item")
            return
        }

        #expect(turn.toolOrder == ["call_zzz_last", "call_mmm_middle", "call_aaa_first"])
        #expect(turn.tools.count == 3)
        #expect(turn.tools["call_zzz_last"]?.output == "third")
        #expect(turn.tools["call_mmm_middle"]?.output == "second")
        #expect(turn.tools["call_aaa_first"]?.output == "first")
    }

    /// Orphaned results with identical timestamps break the tie by `id` (UUID string
    /// ordering) so the order is still deterministic across runs (STAB-14).
    @Test("orphaned tool results with equal timestamps tie-break by id")
    func orphanedToolResultsTieBreakById() throws {
        let timelineId = UUID()
        let sameTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let idLow = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let idHigh = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))

        let orphanHigh = ConversationMessage(
            id: idHigh, timelineId: timelineId, role: .tool, content: "high",
            timestamp: sameTimestamp, toolCallId: "call_high"
        )
        let orphanLow = ConversationMessage(
            id: idLow, timelineId: timelineId, role: .tool, content: "low",
            timestamp: sameTimestamp, toolCallId: "call_low"
        )
        let assistantFinalMsg = ConversationMessage(
            timelineId: timelineId, role: .assistant, content: "done"
        )

        // Insert the higher-id orphan first so a bug that preserves insertion order
        // instead of tie-breaking by id would produce the opposite order.
        let transcript = YakamozRuntime.transcriptItems(from: [
            orphanHigh, orphanLow, assistantFinalMsg,
        ])

        guard case let .assistant(_, turn) = transcript.first(where: { Self.isAssistant($0) }) else {
            Issue.record("expected an assistant item")
            return
        }

        #expect(turn.toolOrder == ["call_low", "call_high"])
    }

    // MARK: - Helpers

    private static func encodeJSON(_ calls: [ToolCall]) throws -> String {
        let data = try JSONEncoder().encode(calls)
        return try #require(String(data: data, encoding: .utf8))
    }

    private static func isAssistant(_ item: TranscriptItem) -> Bool {
        if case .assistant = item { return true }
        return false
    }
}
