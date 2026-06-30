# Yakamoz

A native macOS chat client that puts the **prompt pipeline under glass**. Yakamoz drives
the shared [`PositronicKit`](https://github.com/phynics/PositronicKit) agent runtime and, for every assistant turn,
exposes exactly what was assembled, sent, journaled, and returned — through a six-tab
inspector drawer. It is a showcase/dev app, not a shipping product.

## Prerequisites

- **macOS 15** (Sequoia) or later — the deployment target is `macOS 15.0`.
- **Xcode 16+** with the Swift 6 toolchain (the project builds with
  `SWIFT_VERSION = 6.0` and `SWIFT_STRICT_CONCURRENCY = complete`).
- **[XcodeGen](https://github.com/yonsei/XcodeGen)** (`brew install xcodegen`) — the
  `.xcodeproj` is generated from [`project.yml`](project.yml) and is not the source of truth.
- This repository is a **source release**, not a signed or notarized binary distribution.
  It does not include Apple signing certificates, provisioning profiles, notarization
  credentials, or export archives. Build and run it locally from source.

## Build, test, run

Clone and enter the repository:

```bash
git clone git@github.com:phynics/Yakamoz.git
cd Yakamoz
```

`make generate` resolves [`PositronicKit`](https://github.com/phynics/PositronicKit)
through SwiftPM from its public GitHub repository.

All commands run from this directory and go through the [`Makefile`](Makefile), which wraps
`xcodegen` + `xcodebuild` with a project-local `DerivedData`/`SourcePackages` path.

```bash
make generate   # regenerate Yakamoz.xcodeproj from project.yml
make build      # generate + build the app
make test       # generate + run the full test suite (macOS destination)
make verify     # generate + headless xcodebuild test, failing if zero tests execute

# Run a single Swift Testing suite or XCTest class:
make test TEST_FILTER=InspectableChatIntegrationTests
```

`make verify` is the CI gate. It runs `xcodegen generate`, then
`xcodebuild test -scheme Yakamoz -destination 'platform=macOS' -skipMacroValidation`,
and parses the `xcodebuild` output to fail the command if the executed test count is zero.

To run the app, open the generated `Yakamoz.xcodeproj` in Xcode and run the **Yakamoz**
scheme (the app target links only `YakamozCore`; see the boundary note below).

## Providers, presets, and secret storage

Provider configuration lives in **Settings** (⌘,) and is backed by `ProviderSettings`.
Three presets ship, each mapped to a `PositronicKit` provider adapter:

| Preset       | Adapter                | Notes                                        |
| ------------ | ---------------------- | -------------------------------------------- |
| **OpenAI**   | `PKOpenAIProvider`     | Default. `https://api.openai.com/v1`.        |
| **OpenRouter** | `PKOpenRouterProvider` | `https://openrouter.ai/api/v1`.              |
| **Ollama**   | `PKOllamaProvider`     | Local; typically no API key required.        |

- **API keys are stored in `UserDefaults`, in plaintext.** Keys are stored in a dedicated
  preferences suite under provider-specific accounts, so switching presets does not clobber
  another provider's key. Keys are written **only** on an explicit **Apply** in Settings.
- **⚠️ Security tradeoff, accepted deliberately.** Unlike the Keychain, `UserDefaults` is not
  encrypted: values land in a `.plist` file under `~/Library/Preferences/`, readable by any
  process running as the user (no Keychain prompt, no ACL) and included in unencrypted backups
  of that directory. This is acceptable for Yakamoz as a local, single-user showcase app — do
  not adopt this pattern for anything that needs real secrecy guarantees.
- A health badge in Settings runs a one-shot `healthCheck()` against the selected provider.

## Folder access and the non-sandbox choice

Yakamoz can attach a **folder workspace** to a conversation, which jails a set of read-only
filesystem tools (`cat`/`ls`/`find`/`search_files`/`grep`/`change_directory`) to that folder.
To keep folder access friction-free for a local dev tool, **the app is not sandboxed**. A
security-scoped bookmark is still captured when a folder is attached so the path survives
relaunches. If you harden this into a sandboxed build, you must resolve and `startAccessing`
those bookmarks before tool use.

## Terminal workspaces and the unjailed-shell tradeoff

A folder workspace can also spin up a **terminal workspace** ("Create Terminal" on the folder
chip): a persistent, PTY-backed shell the agent drives through five tools (`terminal_run` plus
`terminal_read`/`terminal_send_input`/`terminal_interrupt`/`terminal_wait`). The shell is a real
login shell rooted at the folder, and is **not confined** to that folder — it can `cd` anywhere
the user can. This is inherent to offering a usable shell and is **accepted deliberately**,
consistent with Yakamoz being a non-sandboxed, single-user local dev/showcase app.

It is mitigated by a **per-command user permission prompt**: every `terminal_run` is gated by a
default-deny approval (`TerminalCommandApproving` / `MainActorApprover`) surfaced as an in-chat
banner — Approve, Deny, or "Allow for this terminal" (per-terminal opt-out of further prompts).
If no approver is wired, every command is denied, so the backend is never an un-gated
arbitrary-exec primitive. Sessions are kept alive across timeline switches and are torn down when
the terminal is detached, when its conversation is deleted, and on app quit; **live shell state
does not survive relaunch** (only the attachment does).
Do not copy this unconfined-shell pattern into anything that requires real isolation.

## Where data is stored

On a normal (non-sandboxed) run the SwiftData database lives under the user's
`~/Library/Application Support/` directory. The app creates its storage directory if needed
and reports the resolved path if the persistent container fails to open. Tests use in-memory
or temporary `ModelContainer`s and do not touch this location.

## The inspector — six tabs

Open with the toolbar info button or **⌘I**. Each tab inspects the currently selected
assistant turn:

1. **Prompt** — the assembled section tree (role, priority, compression, cache policy,
   estimated tokens, and per-section compression outcome).
2. **Sent** — the exact `LLMMessage` array sent to the provider, plus a pretty-printed,
   selectable JSON view.
3. **Journal** — the turn's `PromptJournal` evolution: changed/added/removed semi-stable
   sections, stable-prefix count, and whether compaction ran.
4. **Response** — reconstructed text/thinking, model, finish reason, token usage, and (for
   typed-reply conversations) the requested schema / parsed JSON / validation error.
5. **Tools** — every tool call in the turn, with status, output/error, and elapsed time.
6. **Workspace** — the attached folder's contents and the files touched during the turn.

Keyboard: **⌘1…⌘6** jump directly to a tab (opening the drawer if closed).

## Exact-vs-projected data boundary

The inspector distinguishes **what actually happened** from **a derived view of it**:

- **Exact / captured:** the Sent tab's `LLMMessage` payloads, the Journal diff, and the
  persisted `ResponseDTO` (reconstructed text, model, finish reason, token usage, and the
  turn's **tool traces**) are recorded by `SwiftDataTurnInspector` and survive relaunch.
- **Projected:** the Prompt tab's section tree and compression summary are *projections* of
  the rendered prompt (`InspectionSectionDTO`, built with `String(describing:)` for the
  non-`Codable` trait enums) — faithful, but a presentation shape, not the live IR.
- **Typed replies are best-effort, not provider-enforced.** When a conversation enables
  structured/typed replies, the schema is shown to the model and the final text is decoded
  against `TypedReplyPayload` **after** the turn (`TypedReply.decode`). It is a post-hoc
  decode that may fail and surface a validation error in the Response tab — the provider is
  not constrained to honor the schema.

### Tool-trace persistence

Tool traces are persisted on the turn's `ResponseDTO.tools` (as `ToolTraceDTO`s). A reloaded
conversation reads historical tool calls from disk; the **in-flight** turn falls back to the
live, in-memory `ChatTurnState` until its response is persisted. Because a single user send
can drive several engine LLM round-trips (one per tool loop), the final response and traces
are attached to the engine's **last** inspection turn for the conversation.

## No live calls in tests

The test suite never touches the network. `YakamozRuntime` exposes an `llmServiceFactory`
seam; tests inject `PKTestSupport.MockLLMService` and drive completion through scripted
stream continuations (no `Task.sleep`-based timing). The end-to-end
`InspectableChatIntegrationTests` runs a full user → tool call → tool result → assistant
response turn through a real `PositronicKit` stack on an in-memory `ModelContainer`, then
reopens the conversation from a fresh `SwiftDataTurnInspector` to prove everything round-trips
from disk.

## Keyboard shortcuts

| Shortcut | Action                         |
| -------- | ------------------------------ |
| ⌘N       | New chat                       |
| ⌘I       | Toggle the inspector drawer    |
| ⌘1 … ⌘6  | Select an inspector tab        |
| ↩        | Send (⇧↩ inserts a newline)    |

The composer regains focus after each send.

## Out of scope

The following PositronicKit capabilities are intentionally **out of scope** for Yakamoz's
showcase build and are not wired up: the embeddings / vector-recall pipeline (semantic
memory, embedding-backed context gathering) and the broader multi-stage retrieval cluster.
The runtime composes without them so the inspector story stays focused on prompt assembly,
sending, journaling, response, tools, and workspaces.

## Architecture boundary

The **app target** (`Sources/Yakamoz`) imports only `SwiftUI`, `SwiftData`, and
`YakamozCore`. It never names a `PositronicKit`/`PKShared` type directly — boundary mirror
types (e.g. `AppHealthStatus`, `UICoordinator`) live in the app/core so the optimized test
build's linker never needs the unembedded framework metadata. All shared runtime logic lives
in `YakamozCore` (which links PositronicKit) or upstream in `PositronicKit` itself.

## License

Yakamoz is released under the Apache License, Version 2.0. See [`LICENSE`](LICENSE).
