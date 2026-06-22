# Yakamoz — Design Spec

- **Date:** 2026-06-22
- **Status:** Draft (approved in brainstorming; pending spec review + implementation plan)
- **Owner:** atakandulker
- **Type:** New project — usable showcase app for PositronicKit primitives

---

## 1. Summary

**Yakamoz** is a native macOS app (Swift / SwiftUI, generated with XcodeGen) whose
purpose is to **showcase the primitives of `PositronicKit`** by being a genuinely
usable LLM chat client whose every turn is fully inspectable.

The north star: **total transparency of the round-trip** — exactly what was
delivered to the model, exactly what came back, and the full composition pipeline
that produced it. The chat is the primary surface; an Xcode-style **Inspector
drawer** reveals, per turn, the composed prompt tree, the literal messages sent,
the prompt-journal evolution, tool round-trips, the attached workspace, and the
raw response.

The project has **two deliverables**:

1. **Upstream:** a new public **transparency seam** in `PositronicKit`
   (`TurnInspecting`) that surfaces the real per-turn prompt artifacts which are
   currently computed internally but never cross the public boundary. This is
   reusable by `Monad` and aligns with the workspace rule "prefer fixing shared
   abstractions in `PositronicKit` rather than re-implementing them downstream."
2. **The Yakamoz macOS app** that consumes that seam plus the rest of PositronicKit.

> **Name:** *Yakamoz* — the reflection of moonlight on water. The app reflects back
> what the model actually sees.

---

## 2. Goals / Non-goals

### Goals
- Be a **usable** chat client (real conversations against real models).
- **Showcase PositronicKit primitives comprehensively** — the app's reason to exist.
- Make the prompt **composition pipeline** and the **exact sent payload** visible
  and trustworthy (not a reconstruction/approximation).
- Demonstrate PositronicKit's **pluggability** (persistence, workspaces, prompt
  sections, tools, turn plugins) by actually implementing those seams in the app.
- Idiomatic macOS: SwiftUI, SwiftData, Keychain, folder access, Settings scene.

### Non-goals (v1)
- The embeddings cluster (Context ranking, Memory, vector search, semantic search)
  — deferred to **Phase 2** as a coherent unit (shared embeddings dependency).
- Pipeline customization seam (`Pipeline`/`PipelineStage` context/assembly override)
  — **Phase 2** with embeddings.
- iOS/iPadOS, Mac App Store sandboxed distribution, multi-window document model.
- A built-in mock/scripted LLM provider (tests use `PKTestSupport` mocks instead).

---

## 3. Key decisions (locked in brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| App identity | Usable chat client + inspector drawers | Usable AND educational; transparency co-equal with chat |
| LLM connectivity | Single OpenAI-compatible client, user-configurable base URL | One config powers OpenAI / OpenRouter / Ollama; BYO key |
| Transparency data source | **New `TurnInspecting` seam in PositronicKit** | Faithful (real bytes), reusable upstream, opt-in |
| Persistence | **SwiftData** (`@ModelActor` adapters) | Native macOS middle ground; the adapters showcase PK persistence protocols |
| Layout | **B**: chat default + bottom Inspector drawer (Xcode-style) | Chat stays roomy; inspect on demand, per selected turn |
| Scope philosophy | **Comprehensive** primitive coverage | App's purpose is showcasing PositronicKit |
| Embeddings cluster | **Phase 2** | Shared embeddings dependency; build together |
| Pipelines seam | **Phase 2** | Most abstract primitive; bundle with embeddings |

---

## 4. Architecture overview

```
Yakamoz.app (SwiftUI, macOS 14+)
   ├── target: Yakamoz        (@main App, SwiftUI views, scenes)
   ├── target: YakamozCore    (framework: runtime composition, SwiftData adapters,
   │                           TurnInspecting projection, settings/Keychain, view models)
   └── target: YakamozTests   (Swift Testing, against YakamozCore)
        │
        │ local SwiftPM path dependency  ( .package(path: "../PositronicKit") )
        ▼
PositronicKit  ──► products: PositronicKit, PKShared, PKPrompt, PKOpenAIProvider
   ▲
   └── NEW: TurnInspecting seam (Sources/PositronicKit/Protocols/TurnInspecting.swift)
```

- **Sibling layout preserved.** `Yakamoz/` sits next to `Monad/`, `PositronicKit/`,
  `Shuttle/`. The `../PositronicKit` relative path keeps the workspace invariant.
- **Composition root:** `YakamozRuntime` (in `YakamozCore`) assembles the
  `PositronicKit` facade with SwiftData-backed stores, the `PKOpenAIProvider`
  (base URL/key from settings), the registered tools, the workspace creator, the
  prompt-section providers, the chat-turn plugins, and the app's `TurnInspecting`
  implementation. Mirrors `MonadServerFactory` as the single composition root with
  explicit constructor injection (no service locator).

---

## 5. The PositronicKit transparency seam (the crux)

### 5.1 Problem

Inside `ChatEngine.buildPrompt` (`Sources/PositronicKit/Services/Chat/ChatEngine+ContextBuilding.swift`)
the engine computes everything we want to show:

- `renderedPrompt: RenderedPrompt` — `.sections` (each with `role`, `priority`,
  `compression`, `cachePolicy`, `estimatedTokens`, `path`, `parentID`,
  `compressionOutcome`, `content`), `.compressionReport`.
- `renderedPrompt.buildMessages()` — **the exact messages sent to the model**.
- `promptHistory.update(prompt:)` → a diff (`PromptJournalDiff`-style: stable
  prefix count, overlays, `didCompact`) — the **PromptJournal** story.

None of it crosses the public boundary: `ChatTurnPlugin`/`CompletedTurn` only carry
`fullResponse` + `modelName`; the runtime `PromptAssembler` is `internal`
("intentionally not the public prompt authoring surface"); `RenderedPrompt.Section`
is `Sendable` but **not `Codable`**; and `ChatMetadata` on the event stream carries
only memory/file **IDs**, no scores or prompt content.

### 5.2 Chosen design — an opt-in injectable inspector

A dedicated, opt-in protocol mirroring the existing `ChatTurnPlugin` seam, handed
the **real in-process artifacts** (no Codable requirement, no transport bloat).

```swift
// Sources/PositronicKit/Protocols/TurnInspecting.swift  (next to ChatTurnPlugin.swift)
import Foundation
import PKPrompt
import PKShared

/// Observes the composed prompt for a single turn, before generation.
/// Opt-in: hosts that do not inject an inspector pay nothing.
public protocol TurnInspecting: Sendable {
    func didComposeTurn(_ inspection: TurnInspection) async
}

/// In-process snapshot of one turn's composition. Sendable (NOT Codable) — stays
/// in-process; consumers project to their own persistence format if needed.
public struct TurnInspection: Sendable {
    public let timelineId: UUID
    public let agentInstanceId: UUID?
    public let turnIndex: Int
    public let model: String
    public let rendered: RenderedPrompt        // real sections + traits + compressionReport
    public let sentMessages: [LLMMessage]       // exact buildMessages() output
    public let journal: PromptJournalDiff        // stable-prefix / overlays / didCompact
    public let estimatedTokens: Int
}
```

- **Call site:** in `ChatEngine.buildPrompt`, immediately after `renderedPrompt`
  and the prompt-history `update` are produced:
  `await inspector?.didComposeTurn(TurnInspection(...))`. Fires **once per turn**,
  which is exactly the granularity the Prompt and Journal tabs want (the journal
  evolves across the multi-turn tool loop).
- **Injection:** add `turnInspector: (any TurnInspecting)? = nil` to the
  `PositronicKit` facade initializers and thread it into `ChatEngine.Dependencies`,
  exactly as `chatTurnPlugins` is threaded today.

### 5.3 Why not `ChatEvent.meta`

Rejected. `ChatEvent` is a **shared, serialized transport contract** (in `PKShared`,
`Codable` so `Monad` streams it over SSE/WebSocket; the CLI consumes it). Putting a
heavy `TurnInspection` there would (a) serialize and push the full prompt to every
Monad client on every turn, (b) break exhaustive `switch`es over `MetaEvent` in
`Monad` (downstream churn for a showcase feature), and (c) force `Codable` onto
internal rendering types and bake them into a versioned wire format. Inspection is
an opt-in, occasional, heavy concern — the universal event stream is the wrong home.

### 5.4 Tradeoff accepted

The seam does **not** give free persist/replay (a `Codable ChatEvent` would have).
That is fine: persistence is Yakamoz's job. The app's `TurnInspecting`
implementation projects `TurnInspection` into a `Codable` SwiftData `@Model`
(`TurnInspectionModel`) keyed to the turn. The live drawer reads the fresh value;
reopening a past turn reads the stored projection. **All Codable/persistence
concerns live in the app, where showcase-specific churn belongs.**

### 5.5 Upstream hygiene

New public API ⇒ in the same change: add a usage example in
`PositronicKitExamples`, add tests in `PositronicKitTests` asserting the inspector
fires once per turn with the correct rendered sections / sent messages / journal
diff, and keep `make verify` green. `Monad` keeps compiling unchanged (the seam is
purely additive and opt-in; no `ChatEvent` change).

---

## 6. UI design

### 6.1 Shell (layout B)

`NavigationSplitView`: **sidebar** (conversations + persona/workspace affordances)
→ **detail** = `ChatView` with a collapsible bottom **Inspector drawer**.

- **`ConversationListView`** — timelines from SwiftData; "＋ New chat"; per-row
  persona + attached-workspace indicators.
- **`ChatView`** — message transcript (user / assistant / tool messages) + composer.
  A `@MainActor @Observable ChatViewModel` consumes `run()`'s `ChatEvent` stream,
  reducing deltas into the transcript live. **Selecting an assistant bubble** sets
  the *inspected turn*, which drives the drawer.
- **Inspector drawer** — Xcode debug-area style; toggle to show/hide; full-width
  tab bar; resizable height.

### 6.2 Inspector drawer — 6 tabs

| Tab | Shows | Primitives |
|---|---|---|
| **Prompt** | Composed section tree: role · type · priority · compression strategy · cachePolicy · estimatedTokens · expandable rendered content. Header: total tokens + compression summary. | Prompt DSL, traits, `RenderedPrompt`, `CompressionReport`, `TokenEstimator` |
| **Sent** | The exact `sentMessages` array (role+content), with a raw-JSON toggle. The literal request payload. | `RenderedPrompt.buildMessages()`, `LLMMessage` |
| **Journal** | Stable-prefix vs overlays vs volatile across the conversation's turns; `compact()` markers. | `PromptJournal`, `PromptJournalDiff` |
| **Tools** | Per turn: tool calls, routing decision, arguments, `ToolResult`, status/timing. | `Tool`, `ToolRouter`, `ToolResult`, `ToolExecutionStatus` |
| **Workspace** | Attached folder, live file tree, `healthCheck` status, workspace tool list. | `WorkspaceProtocol`, `WorkspaceCreating`, `HealthCheckable` |
| **Response** | Reconstructed deltas, final `Message`, `APIResponseMetadata` (token usage, finish reason, model). | `ChatEvent`, `APIResponseMetadata` |

### 6.3 Settings scene (⌘,)

Provider/base-URL presets, API key, model, generation params, retry config,
"Test connection". See §9.

---

## 7. Primitive coverage catalog

### v1 (comprehensive, non-embeddings)
- **Chat + Inspector:** Timelines · streaming `ChatEvent` · Prompt DSL
  (`SystemPrompt`/`TextPrompt`/`UserPrompt`/`HistoryPrompt`/`ForEach`) ·
  `priority`/`compression`/`cachePolicy` traits · `RenderedPrompt`→messages ·
  `PromptJournal` (diff/overlays/compact) · `TokenEstimator` · `CompressionReport`
  · `APIResponseMetadata`.
- **Tools + Workspaces:** `Tool`/`AnyTool`/`ToolRouter`/`ToolResult` · built-in
  PKShared file tools (`ReadFileTool`, `ListDirectoryTool`, `FindFileTool`,
  `SearchFilesTool`, `SearchFileContentTool`, `ChangeDirectoryTool`) ·
  `WorkspaceProtocol` + `WorkspaceCreating` (`FileSystemWorkspace`) · `PathSanitizer`
  · `HealthCheckable`.
- **Agents:** `AgentTemplate` → `AgentInstance` · `AgentInstanceManager`.
- **Structured output:** `StructuredOutputSchema` · `StructuredOutputDecoder` ·
  `LLMResponseFormat`/`LLMResponseSchema`.
- **Extension seams:** **NEW `TurnInspecting`** · `PromptSectionProviding` ·
  `ChatTurnPlugin` · persistence protocols (SwiftData adapters) · `WorkspaceCreating`.
- **Providers/config:** `PKOpenAIProvider` (custom base URL) · `LLMConfiguration` ·
  presets · `GenerationParameters` · `RetryPolicy` · `ConfigurationServiceProtocol`
  · `healthCheck`.

### Phase 2 (coherent follow-up)
- Embeddings cluster: `EmbeddingServiceProtocol` · `VectorStoreProtocol` ·
  `ContextManager`/`ContextRanker` (Context Inspector #4) · `Memory`/`MemoryStore`
  · semantic-search lab.
- Pipelines: `Pipeline`/`PipelineStage`/`PipelineBuilder` (contextPipeline +
  assemblyPipeline override seams) + a stage-event visualizer.

---

## 8. Data model & persistence (SwiftData)

### 8.1 `@Model` types
- `ConversationModel` — `id`, `title`, `createdAt`, `personaId?`,
  `enabledToolIds: [String]`, `workspaceRef?`.
- `MessageModel` — `id`, `conversationId`, `role`, `content`, `toolCalls`,
  `createdAt`, `remoteDepth`.
- `TurnInspectionModel` — projected `TurnInspection`: `conversationId`, `turnIndex`,
  `model`, `createdAt`, `sections` (Codable), `sentMessages` (Codable),
  `journal` (Codable), `estimatedTokens`, plus captured response metadata.
- `PersonaModel` — `id`, `name`, `systemInstructions`, `builtIn`.
- `WorkspaceModel` — `id`, `displayName`, `folderPath` (and security-scoped
  bookmark data, see §10).

### 8.2 Bridging SwiftData to PositronicKit protocols
PositronicKit persistence protocols (`MessageStoreProtocol`,
`TimelinePersistenceProtocol`, `WorkspacePersistenceProtocol`,
`AgentInstanceStoreProtocol`, `ToolPersistenceProtocol`, `MemoryStoreProtocol`,
`RequestOriginStoreProtocol`, `AgentTemplateStoreProtocol`) are `Sendable` `async`
protocols. `ModelContext` is **not** `Sendable`.

**Bridge:** each adapter is an **`@ModelActor`** that confines its `ModelContext`,
implementing the protocol's `async` methods. This is the clean, idiomatic Swift-6
bridge and is itself a showcase of PositronicKit's persistence pluggability.

The app's `TurnInspecting` implementation (`SwiftDataTurnInspector`) writes
`TurnInspectionModel` from each `TurnInspection`.

---

## 9. Provider configuration

- **Single OpenAI-compatible client** via `PKOpenAIProvider` with a custom host /
  base URL.
- **Presets:** OpenAI (`https://api.openai.com/v1`), OpenRouter
  (`https://openrouter.ai/api/v1`), Ollama (`http://localhost:11434/v1`), Custom.
- **API key** stored in **Keychain** (`KeychainStore` in `YakamozCore`); blank
  allowed for Ollama. Non-secret settings (base URL, model, params) in
  `UserDefaults`/`@AppStorage`.
- **`GenerationParameters`** (temperature, maxTokens, …) editable.
- **`RetryPolicy`** surfaced as a retry configuration.
- **"Test connection"** uses `LLMServiceProtocol`'s `HealthCheckable.healthCheck()`.

---

## 10. Tools & Workspaces

- **Built-in tools:** register PKShared's file tools and a couple of safe,
  deterministic demo tools (e.g. `calculator`, `currentDateTime`) to exercise
  `ToolRouter` + streaming tool-execution status. Per-conversation enable toggles.
- **`FileSystemWorkspace: WorkspaceProtocol`** + **`FileSystemWorkspaceFactory:
  WorkspaceCreating`** in `YakamozCore`, backed by a user-picked folder, sandboxed
  to that directory (path traversal guarded via `PathSanitizer`). Implements
  `readFile`/`writeFile`/`listFiles`/`deleteFile`/`listTools`/`executeTool`/`healthCheck`.
- **Attachment:** the workspace is attached to a timeline as the **primary
  workspace** via `TimelineManager`/`WorkspaceManager`; its tools merge into
  `run()`'s tool set; touched files appear in `ChatMetadata.files` and the
  Workspace tab.
- **macOS sandbox:** v1 runs **non-sandboxed** (store the folder path; direct
  access). Security-scoped bookmarks + the user-selected-file entitlement are noted
  as the hardening path if sandboxed distribution is later desired
  (`WorkspaceModel` already reserves a bookmark-data field).

---

## 11. Agents / personas & structured output

- **Personas:** built-in `AgentTemplate`s (Helpful Assistant, Terse Code Reviewer,
  Socratic Tutor, JSON-only) instantiated as `AgentInstance`s; selectable per
  conversation → drives `systemInstructions` / `agentInstanceId` in `run()`.
  Switching a persona visibly changes the system section in the **Prompt** tab.
  Simple create/edit of custom personas (`PersonaModel`).
- **Structured output:** a per-conversation "typed reply" mode using
  `StructuredOutputSchema` + `StructuredOutputDecoder`; the drawer shows the schema,
  the parsed object, and validation outcome.
- **`PromptSectionProviding`:** a small app-provided section (e.g. "current time"
  or a profile blurb) injected via the extension seam, made visible in the Prompt
  tab to reinforce the composition story.
- **`ChatTurnPlugin`:** an opt-in "autonomous follow-up" toggle demonstrating
  post-turn continuation, with a clear UI indicator when a turn self-continues.

---

## 12. Build & tooling (XcodeGen)

`Yakamoz/project.yml` (sketch):

```yaml
name: Yakamoz
options:
  deploymentTarget: { macOS: "14.0" }   # SwiftData + @Observable floor (15 optional)
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
    dependencies:
      - target: YakamozCore
  YakamozCore:
    type: framework
    platform: macOS
    sources: [Sources/YakamozCore]
    dependencies:
      - package: PositronicKit
        products: [PositronicKit, PKShared, PKPrompt, PKOpenAIProvider]
  YakamozTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/YakamozTests]
    dependencies:
      - target: YakamozCore
      - package: PositronicKit
        products: [PKTestSupport]
```

- **`Makefile`** wraps `xcodegen generate` and `xcodebuild` build/test.
- Generated `Info.plist`; one shared scheme.

---

## 13. Testing strategy

- **Upstream seam (TDD):** in `PositronicKitTests`, assert `TurnInspecting` fires
  once per turn with correct rendered sections / sent messages / journal diff;
  update `PositronicKitExamples`; keep `make verify` green.
- **App:** `YakamozTests` (Swift Testing, matching PositronicKit style) for:
  SwiftData adapter round-trips, the `TurnInspection` → `@Model` projection,
  Keychain/settings, `FileSystemWorkspace` (read/write/list + traversal guard), and
  `ChatViewModel` event reduction driven by **`PKTestSupport`'s mock
  `LLMServiceProtocol`** — deterministic turns, no network.

---

## 14. Phasing / milestones

- **Phase 0** — XcodeGen skeleton + PositronicKit wiring → empty shell builds/runs.
- **Phase 1** — PositronicKit `TurnInspecting` seam (TDD) + examples + `make verify`.
- **Phase 2** — Provider config (Settings + Keychain + health check) + spine chat
  (timelines, streaming) end-to-end against a real endpoint.
- **Phase 3** — SwiftData persistence adapters + `@Model` types.
- **Phase 4** — Inspector drawer (6 tabs) consuming `TurnInspection`.
- **Phase 5** — Tools (built-in + demo) + Workspaces (`FileSystemWorkspace`) +
  Agents/personas + structured output + `PromptSectionProviding` + `ChatTurnPlugin`.
- **Phase 6** — Polish.
- **Later (Phase 2 cluster)** — embeddings cluster (Context #4, Memory, vector
  search, semantic search) + Pipelines visualizer.

---

## 15. Risks & open questions

- **Additive enum risk:** none chosen — the seam deliberately avoids touching
  `ChatEvent`, so no downstream `switch` churn.
- **`PromptJournalDiff` shape:** confirm the exact public diff type emitted by
  `promptHistory.update(prompt:)` during implementation; if it isn't already public
  in a Codable-projectable form, the Journal projection adapts.
- **Endpoint embeddings (Phase 2):** not all OpenAI-compatible endpoints expose
  `/embeddings`; the embeddings cluster will need an endpoint-capability check.
- **macOS sandbox:** v1 non-sandboxed by choice; revisit bookmarks/entitlements if
  distribution requires the sandbox.
- **SwiftData + actor isolation:** verify `@ModelActor` adapters satisfy the
  `Sendable` `async` protocol requirements without `ModelContext` escaping.

---

## 16. Rejected alternatives (summary)

- **Transparency via `ChatEvent.meta`** — rejected (§5.3): transport-contract
  pollution, downstream churn, forced Codable.
- **Reconstruct the prompt in-app via PKPrompt** — rejected: a parallel
  reconstruction would diverge from what the engine actually sends, contradicting
  the "exact bytes" north star.
- **Drive the pipeline at a lower level in-app** — rejected: `PromptAssembler` is
  internal, and reimplementing the turn loop violates "don't re-implement shared
  abstractions downstream."
- **GRDB / JSON persistence** — rejected in favor of SwiftData (native, and the
  adapters double as a persistence-protocol showcase).
