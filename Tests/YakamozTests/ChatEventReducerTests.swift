import Foundation
import PKShared
import PositronicKit
import Testing
@testable import YakamozCore

@Suite("ChatEventReducer")
struct ChatEventReducerTests {
    private let clock = ContinuousClock()

    @Test("Generation deltas accumulate reconstructed text in order")
    func generationDeltasAccumulateText() {
        var state = ChatTurnState(turnIndex: 0)
        let instant0 = clock.now
        let instant1 = clock.now

        ChatEventReducer.reduce(.generation("Moon"), into: &state, now: instant0)
        ChatEventReducer.reduce(.generation("light"), into: &state, now: instant1)

        #expect(state.response.reconstructedText == "Moonlight")
    }

    @Test("Thinking deltas accumulate separately from generation text")
    func thinkingDeltasAccumulateSeparately() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.reasoning("Let me consider "), into: &state, now: now)
        ChatEventReducer.reduce(.reasoning("the options."), into: &state, now: now)
        ChatEventReducer.reduce(.generation("Here is the answer."), into: &state, now: now)

        #expect(state.response.thinking == "Let me consider the options.")
        #expect(state.response.reconstructedText == "Here is the answer.")
    }

    @Test("Tool call deltas capture arguments before execution")
    func toolCallDeltaCapturesArguments() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-1", name: "search", arguments: "{\"query\":\"moon\"}")),
            into: &state,
            now: now
        )

        let trace = state.tools["call-1"]
        #expect(trace?.name == "search")
        #expect(trace?.arguments == "{\"query\":\"moon\"}")
        #expect(trace?.state == .attempting)
        #expect(trace?.startedAt == nil)
        #expect(state.orderedTools.map(\.id) == ["call-1"])
        #expect(state.response.reconstructedText.isEmpty)
    }

    @Test("UIX-5: id-less continuation chunks accumulate onto the same index's tool call")
    func toolCallDeltaIdLessContinuationsAccumulateByIndex() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        // First chunk carries the id (and possibly empty/partial args); OpenAI-style
        // continuations only carry an index + argument fragment, with a nil id.
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-1", name: "cat", arguments: "{\"path")),
            into: &state, now: now
        )
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: nil, name: nil, arguments: "\":\"/tmp/")),
            into: &state, now: now
        )
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: nil, name: nil, arguments: "a.txt\"}")),
            into: &state, now: now
        )

        let trace = state.tools["call-1"]
        #expect(trace?.arguments == "{\"path\":\"/tmp/a.txt\"}")
        #expect(state.orderedTools.map(\.id) == ["call-1"])
    }

    @Test("UIX-5: interleaved parallel tool calls route id-less continuations by index, not just most-recent id")
    func toolCallDeltaInterleavedParallelCallsRouteByIndex() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        // Two parallel tool calls interleaved: each gets its id on the first chunk,
        // then continuations arrive interleaved by index with nil ids.
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-1", name: "cat", arguments: "{\"path\":")),
            into: &state, now: now
        )
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 1, id: "call-2", name: "ls", arguments: "{\"dir\":")),
            into: &state, now: now
        )
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: nil, name: nil, arguments: "\"/a.txt\"}")),
            into: &state, now: now
        )
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 1, id: nil, name: nil, arguments: "\"/tmp\"}")),
            into: &state, now: now
        )

        #expect(state.tools["call-1"]?.arguments == "{\"path\":\"/a.txt\"}")
        #expect(state.tools["call-2"]?.arguments == "{\"dir\":\"/tmp\"}")
        #expect(state.orderedTools.map(\.id) == ["call-1", "call-2"])
    }
    @Test("UIX-5: an id-less delta for an index never seen before is dropped (no id to key on yet)")
    func toolCallDeltaIdLessWithUnknownIndexIsDropped() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: nil, name: nil, arguments: "{\"path\":\"/a.txt\"}")),
            into: &state,
            now: now
        )

        #expect(state.tools.isEmpty)
        #expect(state.orderedTools.isEmpty)
    }

    @Test("UIX-12: post-fix delta shape — non-nil ids on all chunks route directly by id")
    func toolCallDeltaPostFixNonNilIdsRouteById() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        // Post-PKSTREAM-001 shape: every delta carries a non-nil id (the upstream
        // backfill from the index-keyed accumulator), with the same id repeated
        // across continuation chunks for the same index. The nil-id branch is
        // vestigial in practice once Yakamoz is pinned to a release containing it.
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-1", name: "cat", arguments: "{\"path")),
            into: &state, now: now
        )
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-1", name: nil, arguments: "\":\"/tmp/")),
            into: &state, now: now
        )
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-1", name: nil, arguments: "a.txt\"}")),
            into: &state, now: now
        )

        let trace = state.tools["call-1"]
        #expect(trace?.arguments == "{\"path\":\"/tmp/a.txt\"}")
        #expect(state.orderedTools.map(\.id) == ["call-1"])
        #expect(state.toolCallIdByIndex[0] == "call-1")
    }

    @Test("UIX-12: interleaved parallel calls with post-fix non-nil ids route by id, not just most-recent")
    func toolCallDeltaPostFixInterleavedParallelCallsRouteById() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        // Two parallel tool calls interleaved, post-fix shape: every chunk carries
        // its own non-nil id matching the first chunk's id for that index.
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-1", name: "cat", arguments: "{\"path\":")),
            into: &state, now: now
        )
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 1, id: "call-2", name: "ls", arguments: "{\"dir\":")),
            into: &state, now: now
        )
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-1", name: nil, arguments: "\"/a.txt\"}")),
            into: &state, now: now
        )
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 1, id: "call-2", name: nil, arguments: "\"/tmp\"}")),
            into: &state, now: now
        )

        #expect(state.tools["call-1"]?.arguments == "{\"path\":\"/a.txt\"}")
        #expect(state.tools["call-2"]?.arguments == "{\"dir\":\"/tmp\"}")
        #expect(state.orderedTools.map(\.id) == ["call-1", "call-2"])
    }

    @Test("UIX-12: a non-nil delta id takes precedence over the index→id map (id wins)")
    func toolCallDeltaNonNilIdPrecedenceOverMap() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        // Degenerate stream: index 0 first carries id "call-A", then a later
        // chunk for the same index carries a different non-nil id "call-B". The
        // id-bearing path must win over the map (the map is only consulted for
        // nil-id deltas), so "call-B" starts a new trace and the map is updated.
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-A", name: "cat", arguments: "{\"a\":")),
            into: &state, now: now
        )
        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-B", name: nil, arguments: "{\"b\":")),
            into: &state, now: now
        )

        #expect(state.tools["call-A"]?.arguments == "{\"a\":")
        #expect(state.tools["call-B"]?.arguments == "{\"b\":")
        #expect(state.orderedTools.map(\.id) == ["call-A", "call-B"])
        #expect(state.toolCallIdByIndex[0] == "call-B")
    }

    @Test("TEX-2: explanation in the streamed tool-call delta surfaces live, before any result")
    func toolCallDeltaExplanationSurfacesLiveWhileAttempting() throws {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(
                index: 0, id: "call-1", name: "search",
                arguments: #"{"query":"moon","explanation":"Looking up moon facts."}"#
            )),
            into: &state,
            now: now
        )

        let trace = state.tools["call-1"]
        #expect(trace?.state == .attempting)
        #expect(trace?.output == nil)
        let presentation = try ToolTranscriptPresentation(trace: #require(trace))
        #expect(presentation.status == .attempting)
        #expect(presentation.explanationText == "Looking up moon facts.")
    }

    @Test("Attempting status creates a tool trace and records a start time")
    func attemptingCreatesTrace() {
        var state = ChatTurnState(turnIndex: 0)
        let startedAt = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: startedAt
        )

        let trace = state.tools["call-1"]
        #expect(trace?.name == "search")
        #expect(trace?.state == .attempting)
        #expect(trace?.startedAt == startedAt)
        #expect(trace?.finishedAt == nil)
        #expect(state.orderedTools.map(\.id) == ["call-1"])
    }

    @Test("Success status transitions an attempting trace and records output")
    func successTransitionsTrace() {
        var state = ChatTurnState(turnIndex: 0)
        let startedAt = clock.now
        let finishedAt = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: startedAt
        )
        ChatEventReducer.reduce(
            .toolCompleted(toolCallId: "call-1", status: .success(.success("3 results"))),
            into: &state,
            now: finishedAt
        )

        let trace = state.tools["call-1"]
        #expect(trace?.state == .succeeded)
        #expect(trace?.output == "3 results")
        #expect(trace?.error == nil)
        #expect(trace?.startedAt == startedAt)
        #expect(trace?.finishedAt == finishedAt)
    }

    @Test("Tool trace DTO preserves arguments and output")
    func toolTraceDTOPreservesArgumentsAndOutput() throws {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolCall(ToolCallDelta(index: 0, id: "call-1", name: "calculator", arguments: "{\"expression\":\"2 + 2\"}")),
            into: &state,
            now: now
        )
        ChatEventReducer.reduce(
            .toolCompleted(toolCallId: "call-1", status: .success(.success("4"))),
            into: &state,
            now: now
        )

        let dto = try #require(state.toolTraceDTOs.first)
        #expect(dto.arguments == "{\"expression\":\"2 + 2\"}")
        #expect(dto.output == "4")
    }

    @Test("Failed status transitions a trace, captures error, and uses the reference display name")
    func failedTransitionsTrace() {
        var state = ChatTurnState(turnIndex: 0)
        let startedAt = clock.now
        let finishedAt = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: startedAt
        )
        ChatEventReducer.reduce(
            .toolCompleted(toolCallId: "call-1", status: .failed(reference: .known(id: "search"), error: "timeout")),
            into: &state,
            now: finishedAt
        )

        let trace = state.tools["call-1"]
        #expect(trace?.state == .failed)
        #expect(trace?.error == "timeout")
        #expect(trace?.finishedAt == finishedAt)
    }

    @Test("Failure(message) status (tool-not-found style) also transitions the trace")
    func failureMessageTransitionsTrace() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: now
        )
        ChatEventReducer.reduce(
            .toolCompleted(toolCallId: "call-1", status: .executionError("not found")),
            into: &state,
            now: now
        )

        #expect(state.tools["call-1"]?.state == .failed)
        #expect(state.tools["call-1"]?.error == "not found")
    }

    @Test("toolCallError event creates/marks a trace as failed, even without a prior attempting status")
    func toolCallErrorEventMarksFailed() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolCallError(toolCallId: "call-2", name: "search", error: "invalid arguments"),
            into: &state,
            now: now
        )

        let trace = state.tools["call-2"]
        #expect(trace?.name == "search")
        #expect(trace?.state == .failed)
        #expect(trace?.error == "invalid arguments")
        #expect(state.orderedTools.map(\.id) == ["call-2"])
    }

    @Test("Multiple tools preserve first-seen order in orderedTools")
    func multipleToolsPreserveOrder() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-b", status: .attempting(name: "second", reference: .known(id: "second"))),
            into: &state,
            now: now
        )
        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-a", status: .attempting(name: "first", reference: .known(id: "first"))),
            into: &state,
            now: now
        )

        #expect(state.orderedTools.map(\.id) == ["call-b", "call-a"])
    }

    @Test("generationContext meta event records touched workspace files")
    func generationContextRecordsFiles() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .generationContext(ChatMetadata(memories: [], files: ["notes/today.md", "todo.txt"])),
            into: &state,
            now: now
        )

        #expect(state.workspaceFiles == ["notes/today.md", "todo.txt"])
    }

    @Test("generationCancelled marks the turn cancelled without completing it")
    func generationCancelledMarksCancelled() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.generationCancelled(), into: &state, now: now)

        #expect(state.isCancelled)
        #expect(!state.isComplete)
        #expect(state.timelineState == .cancelled)
    }

    @Test("error(message:) records errorMessage on the turn state")
    func errorMessageIsRecorded() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.error("network blip"), into: &state, now: now)

        #expect(state.errorMessage == "network blip")
        #expect(state.timelineState == .failed)
    }

    @Test("approval-style errors map to blocked timeline state by error identity (STAB-6)")
    func approvalErrorMapsToBlockedState() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.error(ToolError.permissionDenied("rm")), into: &state, now: now)

        #expect(state.errorIdentity == ChatEvent.ErrorIdentity(domain: PKErrorDomain.tool, code: 210))
        #expect(state.timelineState == .blocked)
    }

    @Test("A non-blocked PKError identity maps to failed (not blocked)")
    func nonBlockedIdentityMapsToFailed() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        // executionFailed carries tool domain code 203 — not in the blocked set.
        ChatEventReducer.reduce(.error(ToolError.executionFailed("timeout")), into: &state, now: now)

        #expect(state.errorIdentity == ChatEvent.ErrorIdentity(domain: PKErrorDomain.tool, code: 203))
        #expect(state.errorMessage?.contains("Failed to execute") == true)
        #expect(state.timelineState == .failed)
    }

    @Test("An error message containing 'denied' but with a nil identity maps to failed (STAB-6 regression)")
    func deniedInMessageButNilIdentityMapsToFailed() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        // The exact regression the ticket describes: a provider error body that
        // happens to contain the word "denied" must NOT be classified as blocked.
        // A bare-string `.error` carries identity == nil, which falls back to .failed.
        ChatEventReducer.reduce(
            .error("The provider denied the request: HTTP 429 rate limited."),
            into: &state,
            now: now
        )

        #expect(state.errorIdentity == nil)
        #expect(state.errorMessage?.contains("denied") == true)
        #expect(state.timelineState == .failed)
    }

    @Test("A disallowed-tools identity also classifies as blocked")
    func disallowedToolsIdentityMapsToBlocked() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .error(ToolError.attachedToolsDisallowedOnPrivateTimeline),
            into: &state,
            now: now
        )

        #expect(state.errorIdentity == ChatEvent.ErrorIdentity(domain: PKErrorDomain.tool, code: 207))
        #expect(state.timelineState == .blocked)
    }

    @Test("streamCompleted marks the turn complete (terminal)")
    func streamCompletedMarksComplete() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.streamCompleted(), into: &state, now: now)

        #expect(state.isComplete)
        #expect(state.timelineState == .completed)
    }

    @Test("attempting tool execution maps the timeline to tooling")
    func attemptingToolExecutionMapsToToolingState() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: now
        )

        #expect(state.timelineState == .tooling)
    }

    @Test("completion(generationCompleted) records final response metadata")
    func completionRecordsResponseMetadata() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now
        let message = Message(content: "Final answer", role: .assistant)
        let metadata = APIResponseMetadata(
            model: "gpt-test",
            promptTokens: 12,
            completionTokens: 34,
            totalTokens: 46,
            finishReason: "stop"
        )

        ChatEventReducer.reduce(.generationCompleted(message: message, metadata: metadata), into: &state, now: now)

        #expect(state.response.model == "gpt-test")
        #expect(state.response.finishReason == "stop")
        #expect(state.response.inputTokens == 12)
        #expect(state.response.outputTokens == 34)
    }

    @Test("A completed turn never mutates: events after streamCompleted are ignored")
    func completedTurnNeverMutates() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.generation("first"), into: &state, now: now)
        ChatEventReducer.reduce(.streamCompleted(), into: &state, now: now)
        #expect(state.isComplete)

        // Late/stray events after completion must not mutate the finalized state.
        ChatEventReducer.reduce(.generation("late text"), into: &state, now: now)
        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-late", status: .attempting(name: "late", reference: .known(id: "late"))),
            into: &state,
            now: now
        )
        let metadata = APIResponseMetadata(model: "should-not-apply")
        ChatEventReducer.reduce(.generationCompleted(message: Message(content: "x", role: .assistant), metadata: metadata), into: &state, now: now)

        #expect(state.response.reconstructedText == "first")
        #expect(state.orderedTools.isEmpty)
        #expect(state.response.model == nil)
    }

    @Test("ToolTrace.elapsed derives duration from startedAt/finishedAt instants")
    func toolTraceElapsedDerivesDuration() {
        var state = ChatTurnState(turnIndex: 0)
        let startedAt = clock.now
        Thread.sleep(forTimeInterval: 0.001)
        let finishedAt = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: startedAt
        )
        ChatEventReducer.reduce(
            .toolCompleted(toolCallId: "call-1", status: .success(.success("ok"))),
            into: &state,
            now: finishedAt
        )

        let elapsed = state.tools["call-1"]?.elapsed
        #expect(elapsed != nil)
        #expect((elapsed ?? .zero) > .zero)
    }

    @Test("UIX-4: text-before-tool produces a text segment followed by a tool segment")
    func textBeforeToolProducesOrderedSegments() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.generation("Let me check that."), into: &state, now: now)
        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: now
        )

        #expect(state.turnSegments == [.text("Let me check that."), .tool(id: "call-1")])
    }

    @Test("UIX-4: tool-before-text produces a tool segment followed by a text segment")
    func toolBeforeTextProducesOrderedSegments() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: now
        )
        ChatEventReducer.reduce(.generation("Here's what I found."), into: &state, now: now)

        #expect(state.turnSegments == [.tool(id: "call-1"), .text("Here's what I found.")])
    }

    @Test("UIX-4: multiple tools interspersed with text preserve chronological order (text -> tool -> text -> tool)")
    func interleavedTextAndToolsPreserveOrder() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.generation("First I'll search."), into: &state, now: now)
        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: now
        )
        ChatEventReducer.reduce(.generation("Now let me calculate."), into: &state, now: now)
        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-2", status: .attempting(name: "calculator", reference: .known(id: "calculator"))),
            into: &state,
            now: now
        )

        #expect(state.turnSegments == [
            .text("First I'll search."),
            .tool(id: "call-1"),
            .text("Now let me calculate."),
            .tool(id: "call-2"),
        ])
    }

    @Test("UIX-4: consecutive text deltas coalesce into a single text segment")
    func consecutiveTextDeltasCoalesce() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.generation("Moon"), into: &state, now: now)
        ChatEventReducer.reduce(.generation("light"), into: &state, now: now)
        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: now
        )
        ChatEventReducer.reduce(.generation("Sonata"), into: &state, now: now)
        ChatEventReducer.reduce(.generation(" No. 14"), into: &state, now: now)

        #expect(state.turnSegments == [
            .text("Moonlight"),
            .tool(id: "call-1"),
            .text("Sonata No. 14"),
        ])
    }

    @Test("UIX-4: tool status updates after the first sighting do not create duplicate segments")
    func toolStatusUpdatesDoNotDuplicateSegments() {
        var state = ChatTurnState(turnIndex: 0)
        let startedAt = clock.now
        let finishedAt = clock.now

        ChatEventReducer.reduce(.generation("Checking..."), into: &state, now: startedAt)
        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: startedAt
        )
        ChatEventReducer.reduce(
            .toolCompleted(toolCallId: "call-1", status: .success(.success("done"))),
            into: &state,
            now: finishedAt
        )
        ChatEventReducer.reduce(.generation("Found it."), into: &state, now: finishedAt)

        #expect(state.turnSegments == [
            .text("Checking..."),
            .tool(id: "call-1"),
            .text("Found it."),
        ])
    }

    @Test("UIX-4: a toolCallError before any status update registers a tool segment (mirrors toolOrder)")
    func toolCallErrorRegistersSegment() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.generation("Trying a tool call."), into: &state, now: now)
        ChatEventReducer.reduce(
            .toolCallError(toolCallId: "call-2", name: "search", error: "invalid arguments"),
            into: &state,
            now: now
        )

        #expect(state.turnSegments == [.text("Trying a tool call."), .tool(id: "call-2")])
    }

    @Test("UIX-7: thinking -> text -> tool -> thinking -> text yields segments in true arrival order")
    func thinkingTextToolThinkingTextYieldsOrderedSegments() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.reasoning("Let me check that."), into: &state, now: now)
        ChatEventReducer.reduce(.generation("Checking now."), into: &state, now: now)
        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: now
        )
        ChatEventReducer.reduce(.reasoning("Now let me consider the result."), into: &state, now: now)
        ChatEventReducer.reduce(.generation("Here's the answer."), into: &state, now: now)

        #expect(state.turnSegments == [
            .thinking("Let me check that."),
            .text("Checking now."),
            .tool(id: "call-1"),
            .thinking("Now let me consider the result."),
            .text("Here's the answer."),
        ])
    }

    @Test("UIX-7: consecutive thinking deltas coalesce into a single thinking segment")
    func consecutiveThinkingDeltasCoalesce() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.reasoning("Let me "), into: &state, now: now)
        ChatEventReducer.reduce(.reasoning("think "), into: &state, now: now)
        ChatEventReducer.reduce(.reasoning("about this."), into: &state, now: now)
        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: now
        )

        #expect(state.turnSegments == [
            .thinking("Let me think about this."),
            .tool(id: "call-1"),
        ])
    }

    @Test("UIX-7: response.thinking still accumulates the full flat string unchanged, independent of segments")
    func responseThinkingAccumulatesFlatStringAlongsideSegments() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.reasoning("First thought. "), into: &state, now: now)
        ChatEventReducer.reduce(.generation("Some text."), into: &state, now: now)
        ChatEventReducer.reduce(
            .toolProgress(toolCallId: "call-1", status: .attempting(name: "search", reference: .known(id: "search"))),
            into: &state,
            now: now
        )
        ChatEventReducer.reduce(.reasoning("Second thought."), into: &state, now: now)

        #expect(state.response.thinking == "First thought. Second thought.")
        #expect(state.turnSegments == [
            .thinking("First thought. "),
            .text("Some text."),
            .tool(id: "call-1"),
            .thinking("Second thought."),
        ])
    }

    @Test("responseDTO reflects accumulated text, thinking, and metadata")
    func responseDTOReflectsAccumulatedState() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now

        ChatEventReducer.reduce(.reasoning("pondering"), into: &state, now: now)
        ChatEventReducer.reduce(.generation("answer"), into: &state, now: now)
        let metadata = APIResponseMetadata(model: "gpt-test", promptTokens: 1, completionTokens: 2, finishReason: "stop")
        ChatEventReducer.reduce(.generationCompleted(message: Message(content: "answer", role: .assistant), metadata: metadata), into: &state, now: now)

        let dto = state.responseDTO
        #expect(dto.reconstructedText == "answer")
        #expect(dto.thinking == "pondering")
        #expect(dto.model == "gpt-test")
        #expect(dto.finishReason == "stop")
        #expect(dto.inputTokens == 1)
        #expect(dto.outputTokens == 2)
    }

    @Test("sidecarsCompleted accumulates results onto ChatTurnState")
    func sidecarsCompletedAccumulatesResults() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now
        let results: [SidecarResult] = [
            SidecarResult(name: "title", outcome: .value(AnyCodable("Fixing the auth bug"))),
            SidecarResult(name: "section_title", outcome: .declined)
        ]
        ChatEventReducer.reduce(.sidecarsCompleted(results), into: &state, now: now)
        #expect(state.sidecarResults == results)
        #expect(!state.isComplete)
    }

    @Test("sidecar delta events are observed but do not mutate reconstructedText")
    func sidecarDeltaDoesNotMutateResponseText() {
        var state = ChatTurnState(turnIndex: 0)
        let now = clock.now
        let delta = SidecarDelta(name: "title", partialText: "Fixing the", isFinal: false)
        ChatEventReducer.reduce(.sidecar(delta), into: &state, now: now)
        #expect(state.response.reconstructedText.isEmpty)
    }

    @Test("ResponseDTO sidecarResults round-trip through Codable")
    func responseDTOSidecarResultsRoundTrip() throws {
        let results: [SidecarResult] = [
            SidecarResult(name: "title", outcome: .value(AnyCodable("Fixing the auth bug"))),
            SidecarResult(name: "section_title", outcome: .declined)
        ]
        let dto = ResponseDTO(
            reconstructedText: "answer",
            thinking: "",
            sidecarResults: results
        )
        let data = try JSONEncoder().encode(dto)
        let decoded = try JSONDecoder().decode(ResponseDTO.self, from: data)
        #expect(decoded.sidecarResults == results)
    }

    @Test("ResponseDTO decodes a legacy blob missing sidecarResults as an empty array")
    func responseDTOLegacyBlobMissingSidecarResultsDefaultsToEmpty() throws {
        // A blob encoded before SID-1 only carried the original required keys + tools.
        let legacyJSON = """
        {
          "reconstructedText": "answer",
          "thinking": "",
          "tools": []
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ResponseDTO.self, from: legacyJSON)
        #expect(decoded.sidecarResults.isEmpty)
    }
}
