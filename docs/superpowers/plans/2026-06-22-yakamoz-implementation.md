# Yakamoz Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a usable native macOS LLM chat client that showcases PositronicKit and persists a faithful, per-turn view of the exact prompt, payload, journal, tools, workspace, and response.

**Architecture:** First add an opt-in `TurnInspecting` boundary to PositronicKit at the point where the runtime owns the real rendered prompt and journal update. Then build Yakamoz as an XcodeGen app with a SwiftUI application target and a `YakamozCore` framework containing SwiftData actors, provider configuration, runtime composition, workspaces, inspection projection, and observable view models.

**Tech Stack:** Swift 6.0, macOS 15.0, SwiftUI, Observation, SwiftData, Security/Keychain, Swift Testing, XcodeGen, PositronicKit/PKPrompt/PKShared/PKOpenAIProvider/PKTestSupport.

## Global Constraints

- Yakamoz and PositronicKit are sibling repositories; Yakamoz must use `.package(path: "../PositronicKit")`.
- Target macOS 15.0 because `PositronicKit/Package.swift` currently declares `.macOS(.v15)`; macOS 14.0 from the design sketch cannot resolve this dependency.
- Use Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`.
- Keep inspection in process and opt in; do not add inspection payloads to `ChatEvent` or any serialized transport contract.
- `TurnInspection`, `TurnJournalSnapshot`, and `RenderedPrompt.Section` remain `Sendable`, not `Codable`; Yakamoz owns explicit Codable projections.
- Store API keys only in Keychain. Store provider, base URL, model, generation parameters, and retry settings in `UserDefaults`.
- v1 is non-sandboxed and stores direct folder paths; reserve bookmark data in the workspace model without enabling App Sandbox.
- Tests use PKTestSupport doubles or local deterministic fakes and never call a live model endpoint.
- Embeddings, memories, context ranking, semantic search, and pipeline customization are excluded from this plan.

---

## File Structure

### PositronicKit repository

- `Sources/PositronicKit/Protocols/TurnInspecting.swift`: public inspection protocol and immutable snapshots.
- `Sources/PositronicKit/Services/Chat/ChatEngine.swift`: carries the optional inspector dependency and emits an inspection for every actual LLM turn.
- `Sources/PositronicKit/Services/Chat/ChatEngine+ContextBuilding.swift`: returns the initial rendered artifact and journal update in the turn context.
- `Sources/PositronicKit/Services/Chat/ChatTurnContext.swift`: retains the current rendered prompt/journal snapshot and updates them when tool/plugin messages cause another turn.
- `Sources/PositronicKit/PositronicKit.swift`: threads `turnInspector` through public facade initializers and copy builders.
- `Tests/PositronicKitTests/TurnInspectingTests.swift`: validates exact sent messages, section traits, journal projection, and multi-turn firing.
- `Sources/PositronicKitExamples/PositronicKitUsageExamples.swift`: public usage example.

### Yakamoz repository

- `project.yml`, `Makefile`: XcodeGen graph and repeatable build/test commands.
- `Sources/Yakamoz/YakamozApp.swift`, `Sources/Yakamoz/ContentView.swift`: app lifecycle, model container, Settings scene, root split view.
- `Sources/YakamozCore/Models/PersistenceModels.swift`: SwiftData entities only.
- `Sources/YakamozCore/Inspection/InspectionDTOs.swift`: Codable projections for prompt, messages, journal, tools, workspace, schema, and response.
- `Sources/YakamozCore/Inspection/SwiftDataTurnInspector.swift`: `TurnInspecting` implementation and response-enrichment writes.
- `Sources/YakamozCore/Persistence/*Store.swift`: one `@ModelActor` per PositronicKit persistence responsibility.
- `Sources/YakamozCore/Configuration/{ProviderSettings,KeychainStore}.swift`: non-secret settings and secrets.
- `Sources/YakamozCore/Runtime/YakamozRuntime.swift`: the only production composition root.
- `Sources/YakamozCore/Chat/{ChatEventReducer,ChatViewModel}.swift`: deterministic stream reduction and main-actor orchestration.
- `Sources/YakamozCore/Workspaces/{FileSystemWorkspace,FileSystemWorkspaceFactory}.swift`: folder-confined workspace implementation.
- `Sources/YakamozCore/Tools/DemoTools.swift`: calculator and current-date tools.
- `Sources/YakamozCore/Agents/{PersonaCatalog,TypedReply,AutonomousFollowUpPlugin}.swift`: persona, schema, decoder, and post-turn examples.
- `Sources/YakamozCore/Prompting/CurrentTimeSectionProvider.swift`: app-provided prompt section.
- `Sources/Yakamoz/Views/*`: shell, transcript/composer, settings, personas, and six focused inspector tabs.
- `Tests/YakamozTests/*Tests.swift`: projections, stores, configuration, workspace, reducer, runtime, and view-model behavior.

---

### Task 1: Publish the PositronicKit Turn Inspection Boundary

**Files:**
- Create: `../PositronicKit/Sources/PositronicKit/Protocols/TurnInspecting.swift`
- Create: `../PositronicKit/Tests/PositronicKitTests/TurnInspectingTests.swift`
- Modify: `../PositronicKit/Sources/PositronicKit/Services/Chat/ChatEngine.swift`
- Modify: `../PositronicKit/Sources/PositronicKit/Services/Chat/ChatEngine+ContextBuilding.swift`
- Modify: `../PositronicKit/Sources/PositronicKit/Services/Chat/ChatTurnContext.swift`
- Modify: `../PositronicKit/Sources/PositronicKit/PositronicKit.swift`
- Modify: `../PositronicKit/Sources/PositronicKitExamples/PositronicKitUsageExamples.swift`

**Interfaces:**
- Consumes: `RenderedPrompt`, `RenderedPrompt.buildMessages()`, `PromptJournalDiff`, internal `PromptHistoryUpdate`, `ChatTurnContext.turnCount`.
- Produces: `TurnInspecting.didComposeTurn(_:)`, `TurnInspection`, `TurnJournalSnapshot`, and `PositronicKit.init(..., turnInspector:)`.

- [ ] **Step 1: Write the failing public seam tests**

Create a lock-protected recorder and two Swift Testing cases. The first runs one response and asserts `timelineId`, model, section content, `sentMessages == rendered.buildMessages()`, token count, and initial journal additions. The second scripts a tool call plus final response and asserts inspections have turn indices `[0, 1]` and the second snapshot has a nonzero stable prefix.

```swift
import Foundation
import PKShared
import Testing
@testable import PositronicKit

private actor InspectionRecorder: TurnInspecting {
    private(set) var values: [TurnInspection] = []
    func didComposeTurn(_ inspection: TurnInspection) { values.append(inspection) }
}

@Suite("Turn inspecting")
struct TurnInspectingTests {
    @Test("Publishes the exact rendered artifact before generation")
    func publishesExactArtifact() async throws {
        let recorder = InspectionRecorder()
        let harness = try await ChatEngineTestHarness(inspector: recorder)
        harness.llm.mockClient.nextResponse = "Moonlight"
        _ = try await harness.collect(message: "What is yakamoz?")

        let value = try #require(await recorder.values.first)
        #expect(value.timelineId == harness.timelineId)
        #expect(value.turnIndex == 0)
        #expect(value.model == await harness.llm.configuration.modelName)
        #expect(value.sentMessages == value.rendered.buildMessages())
        #expect(value.estimatedTokens == value.rendered.estimatedTokens)
        #expect(!value.rendered.sections.isEmpty)
        #expect(!value.journal.overlay.addedSemiStableIDs.isEmpty)
        #expect(value.journal.stablePrefixCount == 0)
        #expect(value.journal.didCompact == false)
    }

    @Test("Publishes each model turn in a tool loop")
    func publishesToolLoopTurns() async throws {
        let recorder = InspectionRecorder()
        let harness = try await ChatEngineTestHarness(inspector: recorder)
        harness.llm.mockClient.nextToolCalls = [[MockToolCall(id: "call-1", name: "mock_tool")]]
        harness.llm.mockClient.nextResponses = ["", "Done"]
        _ = try await harness.collect(message: "Use the tool", tools: [MockTool().toAnyTool()])

        let values = await recorder.values
        #expect(values.map(\.turnIndex) == [0, 1])
        #expect(values[1].journal.stablePrefixCount > 0)
    }
}
```

Extract `ChatEngineTestHarness` and `MockTool` from the existing helpers in `ChatEngineTests.swift` into the new test file without changing their behavior; add `turnInspector` to the dependency initializer.

- [ ] **Step 2: Run the focused tests to prove the API is absent**

Run: `cd ../PositronicKit && swift test --filter TurnInspectingTests`

Expected: FAIL at compile time because `TurnInspecting`, `TurnInspection`, and the inspector dependency do not exist.

- [ ] **Step 3: Add the public snapshot types**

```swift
import Foundation
import PKPrompt
import PKShared

public protocol TurnInspecting: Sendable {
    func didComposeTurn(_ inspection: TurnInspection) async
}

public struct TurnInspection: Sendable {
    public let timelineId: UUID
    public let agentInstanceId: UUID?
    public let turnIndex: Int
    public let model: String
    public let rendered: RenderedPrompt
    public let sentMessages: [LLMMessage]
    public let journal: TurnJournalSnapshot
    public let estimatedTokens: Int

    public init(timelineId: UUID, agentInstanceId: UUID?, turnIndex: Int, model: String,
                rendered: RenderedPrompt, sentMessages: [LLMMessage],
                journal: TurnJournalSnapshot, estimatedTokens: Int) {
        self.timelineId = timelineId
        self.agentInstanceId = agentInstanceId
        self.turnIndex = turnIndex
        self.model = model
        self.rendered = rendered
        self.sentMessages = sentMessages
        self.journal = journal
        self.estimatedTokens = estimatedTokens
    }
}

public struct TurnJournalSnapshot: Sendable {
    public let overlay: PromptJournalDiff
    public let stablePrefixCount: Int
    public let didCompact: Bool

    public init(overlay: PromptJournalDiff, stablePrefixCount: Int, didCompact: Bool) {
        self.overlay = overlay
        self.stablePrefixCount = stablePrefixCount
        self.didCompact = didCompact
    }
}
```

- [ ] **Step 4: Thread and emit the dependency at actual generation time**

Add `let turnInspector: (any TurnInspecting)?` to `ChatEngine.Dependencies`. Keep the rendered prompt and journal update in `ChatTurnContext`; before each `processTurn`, publish this exact snapshot using the current `turnCount`. When tool or plugin messages continue the loop, rebuild through the existing prompt-history path before publishing the next snapshot rather than copying the previous messages.

```swift
if let inspector = dependencies.turnInspector,
   let rendered = turnContext.renderedPrompt,
   let update = turnContext.promptHistoryUpdate,
   let diff = update.diff {
    await inspector.didComposeTurn(TurnInspection(
        timelineId: turnContext.timelineId,
        agentInstanceId: turnContext.agentInstanceId,
        turnIndex: turnContext.turnCount - 1,
        model: turnContext.modelName,
        rendered: rendered,
        sentMessages: turnContext.currentMessages,
        journal: TurnJournalSnapshot(
            overlay: diff.journalDiff,
            stablePrefixCount: diff.stablePrefixCount,
            didCompact: update.didCompact
        ),
        estimatedTokens: rendered.estimatedTokens
    ))
}
```

If internal `PromptDiff` has no `journalDiff` projection, add a fileprivate computed property in `TimelinePromptHistory.swift` that constructs the public `PromptJournalDiff` from its changed/added/removed semi-stable entry IDs. Do not make internal diff types public.

- [ ] **Step 5: Thread the facade without changing default callers**

Add `turnInspector: (any TurnInspecting)? = nil` to both public initializer families and `RuntimeConfiguration`, retain it in `PositronicKit`, and pass it into every `ChatEngine.Dependencies` construction including `addPlugin(_:)`. The simplified initializer continues to pass `nil`.

- [ ] **Step 6: Add an executable usage example**

```swift
public actor ExampleTurnInspector: TurnInspecting {
    public private(set) var latestTokenEstimate = 0
    public init() {}
    public func didComposeTurn(_ inspection: TurnInspection) {
        latestTokenEstimate = inspection.estimatedTokens
    }
}

public static func makeInspectableRuntime(inspector: any TurnInspecting) -> PositronicKit {
    PositronicKit(llmService: UnconfiguredLLMService(), turnInspector: inspector)
}
```

- [ ] **Step 7: Verify and commit the upstream deliverable**

Run: `cd ../PositronicKit && swift test --filter TurnInspectingTests && make verify`

Expected: focused tests PASS; `make verify` exits 0; existing callers compile unchanged.

```bash
cd ../PositronicKit
git add Sources/PositronicKit Tests/PositronicKitTests/TurnInspectingTests.swift Sources/PositronicKitExamples/PositronicKitUsageExamples.swift
git commit -m "feat: expose composed turn inspections"
```

### Task 2: Create the XcodeGen Project and App Shell

**Files:**
- Create: `project.yml`
- Create: `Makefile`
- Create: `.gitignore`
- Create: `Sources/Yakamoz/YakamozApp.swift`
- Create: `Sources/Yakamoz/ContentView.swift`
- Create: `Sources/YakamozCore/YakamozCore.swift`
- Create: `Tests/YakamozTests/SmokeTests.swift`

**Interfaces:**
- Consumes: sibling PositronicKit products.
- Produces: buildable `Yakamoz`, `YakamozCore`, and `YakamozTests` targets with one shared scheme.

- [ ] **Step 1: Write the smoke test**

```swift
import Testing
@testable import YakamozCore

@Test("Core exposes its runtime version")
func coreLoads() {
    #expect(YakamozCore.version == 1)
}
```

- [ ] **Step 2: Add the XcodeGen graph**

```yaml
name: Yakamoz
options:
  deploymentTarget: { macOS: "15.0" }
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
packages:
  PositronicKit: { path: ../PositronicKit }
targets:
  Yakamoz:
    type: application
    platform: macOS
    sources: [Sources/Yakamoz]
    settings: { base: { PRODUCT_BUNDLE_IDENTIFIER: com.atakandulker.Yakamoz, GENERATE_INFOPLIST_FILE: YES } }
    dependencies: [{ target: YakamozCore }]
  YakamozCore:
    type: framework
    platform: macOS
    sources: [Sources/YakamozCore]
    dependencies:
      - { package: PositronicKit, product: PositronicKit }
      - { package: PositronicKit, product: PKShared }
      - { package: PositronicKit, product: PKPrompt }
      - { package: PositronicKit, product: PKOpenAIProvider }
  YakamozTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/YakamozTests]
    dependencies:
      - { target: YakamozCore }
      - { package: PositronicKit, product: PKTestSupport }
schemes:
  Yakamoz:
    build: { targets: { Yakamoz: all, YakamozCore: all } }
    test: { targets: [YakamozTests] }
```

- [ ] **Step 3: Add the minimal app and core implementation**

```swift
public enum YakamozCore { public static let version = 1 }
```

```swift
import SwiftUI

@main
struct YakamozApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
        Settings { Text("Provider settings") }.commandsRemoved()
    }
}
```

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            Text("Conversations")
        } detail: {
            ContentUnavailableView("New Conversation", systemImage: "moon.stars")
        }
    }
}
```

- [ ] **Step 4: Add repeatable commands and generated-file ignores**

```make
.PHONY: generate build test verify
generate:
	xcodegen generate
build: generate
	xcodebuild -project Yakamoz.xcodeproj -scheme Yakamoz -destination 'platform=macOS' build
test: generate
	xcodebuild -project Yakamoz.xcodeproj -scheme Yakamoz -destination 'platform=macOS' test
verify: build test
```

Ignore `Yakamoz.xcodeproj/`, `DerivedData/`, `.build/`, and `*.xcuserstate`.

- [ ] **Step 5: Generate, test, and commit**

Run: `xcodegen generate && make test`

Expected: XcodeGen creates one project; `SmokeTests.coreLoads` PASS.

```bash
git add project.yml Makefile .gitignore Sources Tests
git commit -m "build: scaffold Yakamoz macOS app"
```

### Task 3: Persist Inspection Projections with SwiftData

**Files:**
- Create: `Sources/YakamozCore/Models/PersistenceModels.swift`
- Create: `Sources/YakamozCore/Inspection/InspectionDTOs.swift`
- Create: `Sources/YakamozCore/Inspection/SwiftDataTurnInspector.swift`
- Create: `Tests/YakamozTests/TurnInspectionProjectionTests.swift`

**Interfaces:**
- Consumes: `TurnInspection` from Task 1.
- Produces: `InspectionSectionDTO`, `InspectionMessageDTO`, `JournalDTO`, `ResponseDTO`, `TurnInspectionModel`, and `SwiftDataTurnInspector`.

- [ ] **Step 1: Write projection and persistence tests**

Build a `TurnInspection` fixture from a rendered `AnyPrompt` containing stable system, semi-stable profile, and volatile user sections. Assert every trait and rendered content survives projection; persist it to an in-memory `ModelContainer`, fetch by `(conversationId, turnIndex)`, and compare model, messages, journal, and token estimate.

```swift
let schema = Schema([ConversationModel.self, MessageModel.self, TurnInspectionModel.self,
                     PersonaModel.self, WorkspaceModel.self])
let container = try ModelContainer(for: schema, configurations: .init(isStoredInMemoryOnly: true))
let inspector = SwiftDataTurnInspector(modelContainer: container)
await inspector.didComposeTurn(fixture)
let saved = try await inspector.inspection(conversationId: fixture.timelineId, turnIndex: 0)
#expect(saved?.sections.first?.content == "You are helpful")
#expect(saved?.sentMessages.map(\.role) == ["system", "user"])
#expect(saved?.estimatedTokens == fixture.estimatedTokens)
```

- [ ] **Step 2: Run the test to prove projection types are absent**

Run: `make test TEST_FILTER=TurnInspectionProjectionTests` after extending the Makefile test recipe to append `$(if $(TEST_FILTER),-only-testing:YakamozTests/$(TEST_FILTER),)`.

Expected: FAIL at compile time for missing models and inspector.

- [ ] **Step 3: Define focused SwiftData entities**

Use `@Model final class` entities with scalar relationship keys rather than cross-actor object references. Encode arrays into `Data` through computed properties so schema evolution is explicit.

```swift
@Model public final class TurnInspectionModel {
    @Attribute(.unique) public var id: String
    public var conversationId: UUID
    public var turnIndex: Int
    public var model: String
    public var createdAt: Date
    public var sectionsData: Data
    public var sentMessagesData: Data
    public var journalData: Data
    public var estimatedTokens: Int
    public var responseData: Data?

    public init(conversationId: UUID, turnIndex: Int, model: String, createdAt: Date = .now,
                sectionsData: Data, sentMessagesData: Data, journalData: Data,
                estimatedTokens: Int, responseData: Data? = nil) {
        id = "\(conversationId.uuidString):\(turnIndex)"
        self.conversationId = conversationId; self.turnIndex = turnIndex; self.model = model
        self.createdAt = createdAt; self.sectionsData = sectionsData
        self.sentMessagesData = sentMessagesData; self.journalData = journalData
        self.estimatedTokens = estimatedTokens; self.responseData = responseData
    }
}
```

Define the other four entities with the exact fields from spec section 8, including `WorkspaceModel.bookmarkData: Data?`.

- [ ] **Step 4: Define Codable DTO projections**

```swift
public struct InspectionSectionDTO: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let parentID: String?
    public let path: [String]
    public let role: String
    public let priority: Int
    public let compression: String
    public let cachePolicy: String
    public let estimatedTokens: Int
    public let compressionOutcome: String?
    public let content: String
}

public struct InspectionMessageDTO: Codable, Sendable, Equatable {
    public let role: String
    public let content: String
    public let toolCallID: String?
}

public struct JournalDTO: Codable, Sendable, Equatable {
    public let changedSemiStableIDs: [String]
    public let addedSemiStableIDs: [String]
    public let removedSemiStableIDs: [String]
    public let stablePrefixCount: Int
    public let didCompact: Bool
}

public struct ResponseDTO: Codable, Sendable, Equatable {
    public var reconstructedText: String
    public var thinking: String
    public var model: String?
    public var finishReason: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
}
```

Add `init(_ inspection: TurnInspection)` conversion that uses `rendered.sectionsByID[section.id]` for content and `String(describing:)` only for enum-like traits whose public types are not Codable.

- [ ] **Step 5: Implement the model actor inspector**

```swift
@ModelActor
public actor SwiftDataTurnInspector: TurnInspecting {
    public func didComposeTurn(_ inspection: TurnInspection) async {
        do {
            let dto = try InspectionProjection(inspection)
            modelContext.insert(dto.model)
            try modelContext.save()
        } catch {
            assertionFailure("Failed to persist turn inspection: \(error)")
        }
    }

    public func inspection(conversationId: UUID, turnIndex: Int) throws -> TurnInspectionModel? {
        let key = "\(conversationId.uuidString):\(turnIndex)"
        var descriptor = FetchDescriptor<TurnInspectionModel>(predicate: #Predicate { $0.id == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
```

- [ ] **Step 6: Verify and commit**

Run: `make test TEST_FILTER=TurnInspectionProjectionTests`

Expected: projection and in-memory persistence tests PASS.

```bash
git add Sources/YakamozCore/Models Sources/YakamozCore/Inspection Tests/YakamozTests/TurnInspectionProjectionTests.swift Makefile
git commit -m "feat: persist turn inspection projections"
```

### Task 4: Implement PositronicKit SwiftData Store Adapters

**Files:**
- Create: `Sources/YakamozCore/Persistence/MessageStore.swift`
- Create: `Sources/YakamozCore/Persistence/TimelineStore.swift`
- Create: `Sources/YakamozCore/Persistence/WorkspaceStore.swift`
- Create: `Sources/YakamozCore/Persistence/AgentStores.swift`
- Create: `Sources/YakamozCore/Persistence/ToolAndOriginStores.swift`
- Create: `Tests/YakamozTests/PersistenceAdapterTests.swift`

**Interfaces:**
- Consumes: SwiftData models from Task 3 and current protocol signatures in `../PositronicKit/Sources/PositronicKit/Protocols/PersistenceProtocols.swift` plus workspace persistence files.
- Produces: one `@ModelActor` implementation for each protocol named in spec section 8.2 and a `YakamozStores` bundle.

- [ ] **Step 1: Write round-trip contract tests**

For every adapter, save a concrete PositronicKit value, fetch it through the protocol existential, update it where supported, delete it, and assert the final fetch is empty. Include message order by `createdAt`, timeline workspace attachment IDs, agent instance/template values, known/custom tool references, and request origins.

```swift
let stores = YakamozStores(modelContainer: inMemoryContainer())
let messageStore: any MessageStoreProtocol = stores.messages
let message = ConversationMessage(timelineId: timelineID, role: .user, content: "Hello")
try await messageStore.saveMessage(message)
#expect(try await messageStore.fetchMessages(for: timelineID).map(\.content) == ["Hello"])
try await messageStore.deleteMessages(for: timelineID)
#expect(try await messageStore.fetchMessages(for: timelineID).isEmpty)
```

- [ ] **Step 2: Run tests and capture the exact required methods**

Run: `make test TEST_FILTER=PersistenceAdapterTests`

Expected: compile errors list every unimplemented protocol requirement; use that compiler list as the method checklist and do not invent overloads.

- [ ] **Step 3: Implement each adapter with value conversion at its boundary**

Each method performs its `FetchDescriptor`, mapping, and save inside its model actor. No method returns `PersistentModel`, `ModelContext`, or closures capturing either.

```swift
@ModelActor
public actor SwiftDataMessageStore: MessageStoreProtocol {
    public func saveMessage(_ message: ConversationMessage) async throws {
        modelContext.insert(MessageModel(message))
        try modelContext.save()
    }

    public func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage] {
        let descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.conversationId == timelineId },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(descriptor).map(ConversationMessage.init)
    }

    public func deleteMessages(for timelineId: UUID) async throws {
        try modelContext.delete(model: MessageModel.self, where: #Predicate { $0.conversationId == timelineId })
        try modelContext.save()
    }
}
```

Where a PositronicKit model contains Codable nested data, store JSON `Data` and fail with a typed `PersistenceError.encoding`/`.decoding` rather than silently dropping values.

- [ ] **Step 4: Bundle actors without sharing ModelContext instances**

```swift
public struct YakamozStores: Sendable {
    public let messages: SwiftDataMessageStore
    public let timelines: SwiftDataTimelineStore
    public let workspaces: SwiftDataWorkspaceStore
    public let tools: SwiftDataToolStore
    public let agents: SwiftDataAgentInstanceStore
    public let templates: SwiftDataAgentTemplateStore
    public let origins: SwiftDataRequestOriginStore

    public init(modelContainer: ModelContainer) {
        messages = .init(modelContainer: modelContainer)
        timelines = .init(modelContainer: modelContainer)
        workspaces = .init(modelContainer: modelContainer)
        tools = .init(modelContainer: modelContainer)
        agents = .init(modelContainer: modelContainer)
        templates = .init(modelContainer: modelContainer)
        origins = .init(modelContainer: modelContainer)
    }
}
```

- [ ] **Step 5: Verify and commit**

Run: `make test TEST_FILTER=PersistenceAdapterTests && make build`

Expected: all adapter contracts PASS and strict-concurrency build emits no actor-isolation errors.

```bash
git add Sources/YakamozCore/Persistence Sources/YakamozCore/Models Tests/YakamozTests/PersistenceAdapterTests.swift
git commit -m "feat: bridge PositronicKit stores to SwiftData"
```

### Task 5: Add Provider Settings, Keychain, and Runtime Composition

**Files:**
- Create: `Sources/YakamozCore/Configuration/ProviderSettings.swift`
- Create: `Sources/YakamozCore/Configuration/KeychainStore.swift`
- Create: `Sources/YakamozCore/Runtime/YakamozRuntime.swift`
- Create: `Tests/YakamozTests/ProviderConfigurationTests.swift`
- Create: `Tests/YakamozTests/RuntimeCompositionTests.swift`

**Interfaces:**
- Consumes: Task 1 inspector, Task 4 stores, `PKOpenAIProvider`, `LLMConfiguration`, `GenerationParameters`, `RetryPolicy`, `HealthCheckable`.
- Produces: `ProviderPreset`, observable `ProviderSettings`, `SecretStoring`, and `YakamozRuntime`.

- [ ] **Step 1: Write settings and secret-store tests**

Use a dedicated `UserDefaults(suiteName:)` and an in-memory `SecretStoring` fake. Assert each preset URL, blank Ollama key acceptance, custom URL validation, persistence reload, generation/retry mapping, and that no API key appears in defaults.

```swift
#expect(ProviderPreset.openAI.baseURL.absoluteString == "https://api.openai.com/v1")
#expect(ProviderPreset.openRouter.baseURL.absoluteString == "https://openrouter.ai/api/v1")
#expect(ProviderPreset.ollama.baseURL.absoluteString == "http://localhost:11434/v1")
#expect(defaults.dictionaryRepresentation().values.allSatisfy { !String(describing: $0).contains("sk-secret") })
```

- [ ] **Step 2: Implement settings and Keychain wrappers**

```swift
public enum ProviderPreset: String, CaseIterable, Codable, Sendable {
    case openAI, openRouter, ollama, custom
    public var baseURL: URL {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")!
        case .ollama: URL(string: "http://localhost:11434/v1")!
        case .custom: URL(string: "http://localhost:8080/v1")!
        }
    }
}

public protocol SecretStoring: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}
```

Implement `KeychainStore` with `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, and `SecItemDelete`, service `com.atakandulker.Yakamoz`. Convert non-success OSStatus values into a `KeychainError(status:)`.

- [ ] **Step 3: Write the composition test before the runtime**

Inject a `RuntimeDependencies` containing an in-memory model container, fake secrets, fixed clock, and mock LLM factory. Assert `makeClient()` passes the chosen base URL/model/key, the runtime uses the SwiftData inspector and stores, all tools are registered, and `healthCheck()` delegates once.

- [ ] **Step 4: Implement the single composition root**

```swift
public actor YakamozRuntime {
    public let kit: PositronicKit
    public let stores: YakamozStores
    public let inspector: SwiftDataTurnInspector
    private let llmService: any LLMServiceProtocol

    public init(modelContainer: ModelContainer, settings: ProviderSettings,
                secrets: any SecretStoring, clock: any Clock<Duration> = ContinuousClock()) throws {
        stores = YakamozStores(modelContainer: modelContainer)
        inspector = SwiftDataTurnInspector(modelContainer: modelContainer)
        PKOpenAIProvider.register()
        let key = try secrets.read(account: "provider-api-key") ?? ""
        llmService = LLMService(configuration: settings.configuration(apiKey: key))
        kit = PositronicKit(
            llmService: llmService,
            messageStore: stores.messages,
            timelinePersistence: stores.timelines,
            workspacePersistence: stores.workspaces,
            agentInstanceStore: stores.agents,
            requestOriginStore: stores.origins,
            toolPersistence: stores.tools,
            turnInspector: inspector,
            generationParameters: settings.generationParameters
        )
    }

    public func healthCheck() async -> HealthStatus { await llmService.healthCheck() }
}
```

Match the current `LLMConfiguration` initializer exactly when implementing `settings.configuration(apiKey:)`; do not add a second provider abstraction.

- [ ] **Step 5: Verify and commit**

Run: `make test TEST_FILTER=ProviderConfigurationTests && make test TEST_FILTER=RuntimeCompositionTests`

Expected: preset, secret, composition, and health checks PASS without network.

```bash
git add Sources/YakamozCore/Configuration Sources/YakamozCore/Runtime Tests/YakamozTests
git commit -m "feat: compose configurable OpenAI-compatible runtime"
```

### Task 6: Reduce Chat Events and Stream Real Turns

**Files:**
- Create: `Sources/YakamozCore/Chat/ChatEventReducer.swift`
- Create: `Sources/YakamozCore/Chat/ChatViewModel.swift`
- Create: `Tests/YakamozTests/ChatEventReducerTests.swift`
- Create: `Tests/YakamozTests/ChatViewModelTests.swift`

**Interfaces:**
- Consumes: `PositronicKit.run(...)`, `ChatEvent`, inspection store, SwiftData timeline/messages.
- Produces: `TranscriptItem`, `ToolTrace`, `ChatTurnState`, and `@MainActor @Observable ChatViewModel`.

- [ ] **Step 1: Write reducer tests for every event family**

Feed generation/thinking deltas, tool-call deltas, attempting/success/failure statuses, generation context, cancellation, completion, and response metadata one at a time. Assert reconstructed text order, tool timing/state, touched files, final metadata, and that a new turn never mutates a completed turn.

```swift
var state = ChatTurnState(turnIndex: 0)
ChatEventReducer.reduce(.generation("Moon"), into: &state, now: instant0)
ChatEventReducer.reduce(.generation("light"), into: &state, now: instant1)
#expect(state.response.reconstructedText == "Moonlight")
```

Use the real `ChatEvent` static constructors/current enum cases from PKShared rather than adding test-only event types.

- [ ] **Step 2: Implement the pure reducer**

```swift
public enum ChatEventReducer {
    public static func reduce(_ event: ChatEvent, into state: inout ChatTurnState, now: ContinuousClock.Instant) {
        if let text = event.textContent { state.response.reconstructedText += text }
        if let thought = event.thinkingContent { state.response.thinking += thought }
        switch event {
        case let .delta(event: .toolExecution(id, status)),
             let .completion(event: .toolExecution(id, status)):
            state.applyToolStatus(id: id, status: status, now: now)
        case let .meta(event: .generationContext(metadata)):
            state.workspaceFiles = metadata.files
        case let .completion(event: .generationCompleted(metadata)):
            state.apply(metadata)
        default:
            break
        }
    }
}
```

Adjust associated-value patterns to the current PKShared declarations; retain the exhaustive behavior above.

- [ ] **Step 3: Write view-model tests with a runtime protocol fake**

Define `ChatRunning.run(...)` with the same inputs Yakamoz uses and adapt `PositronicKit` to it. Script an `AsyncThrowingStream`, call `send`, and assert user insertion, `isSending`, live delta updates, response persistence enrichment, selection, cancellation, and surfaced error text.

- [ ] **Step 4: Implement the main-actor view model**

```swift
@MainActor @Observable
public final class ChatViewModel {
    public private(set) var transcript: [TranscriptItem] = []
    public private(set) var isSending = false
    public var selectedTurnIndex: Int?
    public var errorMessage: String?
    private var sendTask: Task<Void, Never>?

    public func send(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSending else { return }
        sendTask = Task { await consume(text) }
    }

    public func cancel() { sendTask?.cancel() }
}
```

In `consume`, append the user item, create the assistant turn state, iterate `for try await event`, reduce each event, and call `SwiftDataTurnInspector.updateResponse(...)` on completion. Keep all published mutation on `MainActor`.

- [ ] **Step 5: Verify and commit**

Run: `make test TEST_FILTER=ChatEventReducerTests && make test TEST_FILTER=ChatViewModelTests`

Expected: deterministic reducer and stream tests PASS.

```bash
git add Sources/YakamozCore/Chat Tests/YakamozTests/ChatEventReducerTests.swift Tests/YakamozTests/ChatViewModelTests.swift
git commit -m "feat: stream and reduce inspectable chat turns"
```

### Task 7: Build the Conversation Shell and Settings Scene

**Files:**
- Modify: `Sources/Yakamoz/YakamozApp.swift`
- Modify: `Sources/Yakamoz/ContentView.swift`
- Create: `Sources/Yakamoz/Views/ConversationListView.swift`
- Create: `Sources/Yakamoz/Views/ChatView.swift`
- Create: `Sources/Yakamoz/Views/MessageBubble.swift`
- Create: `Sources/Yakamoz/Views/ComposerView.swift`
- Create: `Sources/Yakamoz/Views/SettingsView.swift`

**Interfaces:**
- Consumes: Task 5 settings/runtime and Task 6 view model.
- Produces: usable new/select/send/cancel chat workflow and Command-comma settings.

- [ ] **Step 1: Add the production model container and environment runtime**

Create one `ModelContainer` for all five models in `YakamozApp.init`, construct settings, Keychain, runtime, and a selected-conversation coordinator, then inject them with typed environment keys. On construction failure, show a `ContentUnavailableView` carrying the error rather than force-unwrapping.

- [ ] **Step 2: Implement the navigation split view**

```swift
NavigationSplitView {
    ConversationListView(selection: $selection)
        .navigationSplitViewColumnWidth(min: 220, ideal: 280)
} detail: {
    if let conversation = selection {
        ChatView(conversation: conversation)
    } else {
        ContentUnavailableView("Select a Conversation", systemImage: "bubble.left.and.bubble.right")
    }
}
```

Use `@Query(sort: \.createdAt, order: .reverse)` for rows, insert `ConversationModel(title: "New Chat")` from the plus button, and display persona/workspace icons only when their IDs are present.

- [ ] **Step 3: Implement transcript selection and composer behavior**

`MessageBubble` renders user, assistant, and tool roles distinctly. Assistant bubbles are buttons with `.buttonStyle(.plain)` that set `selectedTurnIndex`. `ComposerView` uses a multiline `TextField`, Return to send, Shift-Return for newline, a send/stop button, disabled empty sends, and an accessibility label for every icon-only control.

- [ ] **Step 4: Implement Settings**

Create sections for preset/custom URL, API key, model, temperature, maximum output tokens, retry attempts/delay, and Test Connection. Save secrets on explicit Apply; update settings immediately for non-secrets; display the `HealthStatus` result inline.

- [ ] **Step 5: Build and manually verify the shell**

Run: `make build`

Expected: build succeeds. Launch from Xcode; create two conversations, switch between them, open Settings with Command-comma, and verify an invalid endpoint produces visible health status without terminating the app.

```bash
git add Sources/Yakamoz
git commit -m "feat: add conversation shell and provider settings"
```

### Task 8: Implement Prompt, Sent, Journal, and Response Inspector Tabs

**Files:**
- Create: `Sources/Yakamoz/Views/Inspector/InspectorDrawer.swift`
- Create: `Sources/Yakamoz/Views/Inspector/PromptInspectorView.swift`
- Create: `Sources/Yakamoz/Views/Inspector/SentInspectorView.swift`
- Create: `Sources/Yakamoz/Views/Inspector/JournalInspectorView.swift`
- Create: `Sources/Yakamoz/Views/Inspector/ResponseInspectorView.swift`
- Create: `Sources/YakamozCore/Inspection/InspectionViewModel.swift`
- Create: `Tests/YakamozTests/InspectionViewModelTests.swift`

**Interfaces:**
- Consumes: persisted `TurnInspectionModel` selected by conversation/turn.
- Produces: resizable bottom drawer and four faithful inspection tabs.

- [ ] **Step 1: Write inspection-view-model tests**

Persist two turns and assert selection fetches only the matching key, decodes all DTOs, builds a parent/child section tree by `parentID`, formats JSON from `sentMessages` with sorted keys, computes compression totals from DTO outcomes, and returns an explicit empty state for a user/tool message.

- [ ] **Step 2: Implement inspection loading and derived presentation data**

```swift
@MainActor @Observable
public final class InspectionViewModel {
    public private(set) var inspection: InspectionPresentation?
    public private(set) var loadError: String?

    public func select(conversationId: UUID, turnIndex: Int?) async {
        guard let turnIndex else { inspection = nil; return }
        do { inspection = try await repository.presentation(conversationId: conversationId, turnIndex: turnIndex) }
        catch { loadError = error.localizedDescription; inspection = nil }
    }
}
```

- [ ] **Step 3: Build the resizable Xcode-style drawer**

Place a divider and drag handle above a `TabView` with `.tabViewStyle(.automatic)`. Clamp height to 180...70% of detail height; persist open state, selected tab, and height with `@SceneStorage`. Toolbar toggle uses `sidebar.bottom` and never discards the selected turn.

- [ ] **Step 4: Implement the four tabs**

Prompt: outline section tree with role, concrete type/path, priority, compression, cache policy, token estimate, content disclosure, total tokens, and compression summary.

Sent: segmented rendered/raw JSON toggle; rendered list shows exact role/content/tool call ID and raw view displays only the persisted `sentMessages` DTO array.

Journal: columns for stable prefix, changed/added/removed semi-stable IDs, volatile sections, and a visible compact marker when `didCompact` is true; include earlier/later turn navigation.

Response: reconstructed generation/thinking, final model, finish reason, token usage, and structured-output schema/result when present.

- [ ] **Step 5: Verify and commit**

Run: `make test TEST_FILTER=InspectionViewModelTests && make build`

Expected: presentation tests PASS and all four tabs compile.

```bash
git add Sources/Yakamoz/Views/Inspector Sources/YakamozCore/Inspection Tests/YakamozTests/InspectionViewModelTests.swift
git commit -m "feat: inspect prompt payload journal and response"
```

### Task 9: Add Safe Demo Tools and Folder Workspaces

**Files:**
- Create: `Sources/YakamozCore/Tools/DemoTools.swift`
- Create: `Sources/YakamozCore/Workspaces/FileSystemWorkspace.swift`
- Create: `Sources/YakamozCore/Workspaces/FileSystemWorkspaceFactory.swift`
- Create: `Sources/Yakamoz/Views/WorkspacePicker.swift`
- Create: `Sources/Yakamoz/Views/Inspector/ToolsInspectorView.swift`
- Create: `Sources/Yakamoz/Views/Inspector/WorkspaceInspectorView.swift`
- Create: `Tests/YakamozTests/DemoToolsTests.swift`
- Create: `Tests/YakamozTests/FileSystemWorkspaceTests.swift`

**Interfaces:**
- Consumes: `Tool`, `AnyTool`, `ToolRouter`, PKShared file tools, `WorkspaceProtocol`, `WorkspaceCreating`, `PathSanitizer`, `HealthCheckable`.
- Produces: calculator/date tools, confined filesystem workspace/factory, folder attachment UI, Tools tab, Workspace tab.

- [ ] **Step 1: Write security and tool tests**

Create a temporary root and assert read/write/list/delete, nested directories, missing files, health check, and tool listing. Assert `../outside`, absolute paths outside root, and symlink escapes fail without reading/writing. Test calculator precedence, division by zero, invalid expressions, and fixed-clock date output.

```swift
await #expect(throws: WorkspaceError.self) { try await workspace.readFile(path: "../secret") }
await #expect(throws: WorkspaceError.self) { try await workspace.writeFile(path: symlinkEscape, content: "x") }
#expect(try await calculator.evaluate("2 + 3 * 4") == 14)
```

- [ ] **Step 2: Implement deterministic demo tools**

Use a small recursive-descent parser supporting decimal numbers, parentheses, unary minus, `+ - * /`; do not evaluate expressions with JavaScript or shell commands. Inject `now: @Sendable () -> Date` into `CurrentDateTimeTool` and format ISO-8601.

- [ ] **Step 3: Implement the confined workspace and factory**

Resolve every operation by standardizing and resolving symlinks for both root and candidate, then require `candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")`. Map file operations onto `FileManager`; expose PKShared file tools from `listTools` and route their IDs in `executeTool`.

```swift
private func confinedURL(for path: String) throws -> URL {
    let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let candidate = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
    guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
        throw WorkspaceError.invalidPath(path)
    }
    return candidate
}
```

- [ ] **Step 4: Attach workspaces and tool toggles to conversations**

Use `NSOpenPanel` configured for one directory. Persist `WorkspaceModel`, create its `WorkspaceReference`, attach it as primary through the timeline/workspace manager, and update per-conversation `enabledToolIds`. Runtime `send` resolves only enabled demo, file, and workspace tools.

- [ ] **Step 5: Implement Tools and Workspace tabs**

Tools shows call name, routing source, arguments JSON, attempting/success/failure, output/error, and elapsed duration. Workspace shows folder, health, recursive file tree with refresh, available workspace tools, and touched files from response metadata.

- [ ] **Step 6: Verify and commit**

Run: `make test TEST_FILTER=DemoToolsTests && make test TEST_FILTER=FileSystemWorkspaceTests && make build`

Expected: all tool/workspace tests PASS, including traversal and symlink escape cases.

```bash
git add Sources/YakamozCore/Tools Sources/YakamozCore/Workspaces Sources/Yakamoz/Views Tests/YakamozTests
git commit -m "feat: add safe tools and folder workspaces"
```

### Task 10: Add Personas, Prompt Extension, Structured Replies, and Follow-up Plugin

**Files:**
- Create: `Sources/YakamozCore/Agents/PersonaCatalog.swift`
- Create: `Sources/YakamozCore/Agents/TypedReply.swift`
- Create: `Sources/YakamozCore/Agents/AutonomousFollowUpPlugin.swift`
- Create: `Sources/YakamozCore/Prompting/CurrentTimeSectionProvider.swift`
- Create: `Sources/Yakamoz/Views/PersonaEditorView.swift`
- Create: `Sources/Yakamoz/Views/TypedReplyControls.swift`
- Create: `Tests/YakamozTests/AgentExtensionTests.swift`

**Interfaces:**
- Consumes: `AgentTemplate`, `AgentInstance`, `AgentInstanceManager`, `StructuredOutputSchema`, `StructuredOutputDecoder`, `PromptSectionProviding`, `ChatTurnPlugin`.
- Produces: four built-ins, custom persona CRUD, typed-reply mode, visible current-time prompt section, bounded follow-up toggle.

- [ ] **Step 1: Write extension seam tests**

Assert the four built-in IDs/instructions, persona-to-agent conversion, custom edit persistence, deterministic current-time section traits/content, JSON-only schema validation success/failure, and plugin continuation policy. The plugin must return at most one follow-up per user send and never follow up after cancellation/error.

- [ ] **Step 2: Implement catalog and prompt section**

```swift
public enum PersonaCatalog {
    public static let builtIns = [
        PersonaDefinition(id: "helpful", name: "Helpful Assistant", instructions: "Be accurate, direct, and helpful."),
        PersonaDefinition(id: "reviewer", name: "Terse Code Reviewer", instructions: "Lead with concrete defects. Be concise."),
        PersonaDefinition(id: "socratic", name: "Socratic Tutor", instructions: "Teach by asking one focused question at a time."),
        PersonaDefinition(id: "json", name: "JSON-only", instructions: "Return only JSON matching the supplied schema.")
    ]
}
```

`CurrentTimeSectionProvider` injects a stable ID `yakamoz.current-time`, volatile cache policy, low priority, `.keep` compression, ISO-8601 content, and a fixed clock in tests.

- [ ] **Step 3: Implement typed replies**

Define one concrete `TypedReplyPayload: Codable, Sendable, Equatable` containing `summary: String` and `actionItems: [String]`. Generate its `StructuredOutputSchema`, pass the corresponding `LLMResponseFormat` for enabled conversations, decode the final response with `StructuredOutputDecoder`, and persist schema JSON, parsed JSON, or validation error in `ResponseDTO`.

- [ ] **Step 4: Implement bounded autonomous follow-up**

```swift
public actor AutonomousFollowUpPlugin: ChatTurnPlugin {
    private var followedTimelines: Set<UUID> = []
    public func messages(after turn: CompletedTurn) async throws -> [LLMMessage] {
        guard !followedTimelines.contains(turn.timelineId) else { return [] }
        followedTimelines.insert(turn.timelineId)
        return [LLMMessage(role: .user, content: "Check your answer once for omissions, then provide the final answer.")]
    }
}
```

Match the current `ChatTurnPlugin` method name/signature. Surface the continuation as a labeled transcript divider and clear the per-send guard before the next user send.

- [ ] **Step 5: Add persona and typed-reply UI**

Add persona picker/edit sheet to conversation toolbar, show built-in/custom distinction, and pass the selected instance ID/system instructions to `run`. Add typed-reply and autonomous-follow-up toggles to conversation options; show schema/validation in Response tab.

- [ ] **Step 6: Verify and commit**

Run: `make test TEST_FILTER=AgentExtensionTests && make build`

Expected: all seam tests PASS and strict-concurrency build succeeds.

```bash
git add Sources/YakamozCore/Agents Sources/YakamozCore/Prompting Sources/Yakamoz/Views Tests/YakamozTests/AgentExtensionTests.swift
git commit -m "feat: showcase agent and extension seams"
```

### Task 11: End-to-End Verification and Polish

**Files:**
- Create: `Tests/YakamozTests/InspectableChatIntegrationTests.swift`
- Create: `README.md`
- Modify: `Sources/Yakamoz/Views/ChatView.swift`
- Modify: `Sources/Yakamoz/Views/Inspector/InspectorDrawer.swift`
- Modify: `Makefile`

**Interfaces:**
- Consumes: all previous tasks.
- Produces: deterministic end-to-end evidence, documented setup, keyboard/accessibility polish, and a green repository gate.

- [ ] **Step 1: Write the end-to-end integration test**

Use PKTestSupport to script user message -> tool call -> tool result -> assistant response. Run through `YakamozRuntime` with an in-memory model container. Assert two model turns, exact sent payloads, journal evolution, tool trace, persisted transcript, response metadata, selected inspection, and reopening from a fresh repository actor.

```swift
#expect(savedInspections.map(\.turnIndex) == [0, 1])
#expect(savedInspections[0].sentMessages.last?.content == "Inspect this")
#expect(savedInspections[1].journal.stablePrefixCount > 0)
#expect(reopened.response.reconstructedText == "Inspection complete")
#expect(reopened.tools.first?.status == .success)
```

- [ ] **Step 2: Run the integration test and fix only exposed defects**

Run: `make test TEST_FILTER=InspectableChatIntegrationTests`

Expected: PASS with no network and no timing sleeps; streams finish through continuations controlled by the test.

- [ ] **Step 3: Complete macOS interaction polish**

Add Command-N for new chat, Command-I for inspector, Command-1...6 for tabs, focus return to composer after send, selection highlights, VoiceOver labels/values for inspector rows, selectable monospaced raw text, minimum window size 900x620, and empty/loading/error states in every tab.

- [ ] **Step 4: Document setup and transparency guarantees**

README sections must cover prerequisites (Xcode, XcodeGen, macOS 15), `make generate/build/test/verify`, provider presets and Keychain behavior, folder access/non-sandbox choice, the six tabs, exact-vs-projected data boundary, no live calls in tests, and the deferred embeddings/pipeline cluster.

- [ ] **Step 5: Run both repository gates**

Run: `cd ../PositronicKit && make verify`

Expected: exit 0.

Run: `cd ../Yakamoz && make verify`

Expected: Xcode build and all Yakamoz tests PASS with zero Swift concurrency errors.

- [ ] **Step 6: Inspect repository state and commit**

Run: `git status --short && git diff --check`

Expected: only intended Yakamoz files are modified; `git diff --check` emits no output.

```bash
git add README.md Makefile Sources/Yakamoz Tests/YakamozTests/InspectableChatIntegrationTests.swift
git commit -m "test: verify inspectable chat end to end"
```

---

## Self-Review Results

- **Spec coverage:** Tasks 1-11 cover the upstream transparency seam, XcodeGen shell, SwiftData projections/adapters, provider/Keychain settings, real streaming chat, all six inspector tabs, tools/workspaces, agents/personas, structured output, prompt sections, turn plugins, and final polish. The embeddings and pipeline cluster remains excluded exactly as specified.
- **Constraint correction:** The plan uses macOS 15.0 because the local PositronicKit package enforces that floor. Lowering Yakamoz alone to 14.0 would make dependency resolution fail.
- **Boundary check:** Inspection is never placed in `ChatEvent`; only app DTOs are Codable and persisted.
- **Type consistency:** `TurnInspection.turnIndex` is zero-based; storage keys use `conversationId:turnIndex`; the same key drives bubble selection and drawer loading. `ResponseDTO` is enriched after stream completion without replacing the composition snapshot.
- **Placeholder scan:** Every task names its files, concrete API boundary, focused tests, commands, expected result, and commit. Compiler-driven signature matching is limited to existing PositronicKit protocols whose declarations are authoritative and may evolve while this plan is executed.
