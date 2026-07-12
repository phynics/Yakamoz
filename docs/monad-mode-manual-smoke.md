# Monad mode: operation guide and manual smoke

This guide verifies Yakamoz against a real, **user-managed** `monad server`. It is deliberately manual: Yakamoz unit tests use in-memory transport fakes and never make live network calls.

## Modes and profile behavior

Yakamoz has two separate operation modes:

- **Local** is the default. Conversations, operators, workspaces, and the full inspector use Yakamoz's local SwiftData and embedded PositronicKit runtime.
- **Monad** reads agents, timelines, workspaces, and chat events from the selected Monad server. The server is authoritative: Yakamoz does not cache Monad conversations or merge them with Local conversations.

The segmented **Local / Monad** control is a per-window choice that Yakamoz remembers as the default for new windows. A `MonadProfile` contains a stable id, display name, server URL, and default marker. Version 1 presents one active profile but keeps the value type ready for a later profile-list UI. Its optional API key is stored separately under the profile id, never serialized in the profile itself. As with Yakamoz's local provider credentials, this app's current secret store is `UserDefaults` in plaintext; use only a development credential appropriate for this local showcase app.

## Prerequisites

- Build Yakamoz and open the generated `Yakamoz.xcodeproj` in Xcode.
- Have a Monad server you control, with a configured LLM provider and its required API key. Do not paste a production credential into a shared screen recording or this repository.
- Have at least one server agent and an agent-owned timeline. Create these with an authorized Monad CLI/API workflow if the server is empty. Yakamoz v1 lists server agents and their timelines; it does not yet create a server agent or timeline from the Monad-mode UI.
- Choose a small disposable folder containing `smoke.txt` for the workspace steps. Its contents should be safe for the configured model/provider to receive.

## Smoke procedure

1. In a separate terminal, start the server; Yakamoz must not start or manage it:

   ```bash
   cd /path/to/monad-project/Monad
   swift run monad server
   ```

   Wait for `Server started and listening on 127.0.0.1:8080`. For a local server, a quick unauthenticated readiness check is:

   ```bash
   curl --fail http://127.0.0.1:8080/status
   ```

2. In Yakamoz, open **Settings → Monad Server**. Save a profile such as `Local Monad` with `http://127.0.0.1:8080`, then apply the server's API key when that server protects its API. Use **Check Connection** and require a green **Healthy** state. A reachable server whose provider is not configured is reported separately; configure that on the server, not in Yakamoz.

3. In the app window, switch the segmented mode control from **Local** to **Monad**. Confirm that the sidebar contains only server **Agents** and **Templates**, not local operators or local conversations. Press refresh after changing the profile.

4. Select a server agent, then select one of its server timelines. Confirm the timeline title and id load. To cover server timeline creation, create a dedicated disposable timeline through an authorized Monad CLI/API client and verify it from that client. Monad mode currently exposes agent-associated timelines only, so a general newly created timeline cannot yet be browsed/selected there; this is tracked by `YAK-MON-11`. Do not expect any remote timeline to be copied into Local mode.

5. In the selected Monad chat, use **Attach Folder…** and choose the disposable folder. Confirm the folder appears as an attached workspace chip; detach it and verify the chip disappears, then attach it again. This registers Yakamoz as the attached-workspace provider, registers the folder and its tools with Monad, and attaches the returned server workspace id to the timeline.

6. Send a direct prompt first, such as `Reply with the word READY.` Verify incremental output, completion, and any model/finish/token metadata available in the **Response** inspector tab. Then ask the server to use the folder, for example: `Read smoke.txt from the attached workspace and quote its first line.` Confirm the tool row and answer show the tool round trip. If a write test is appropriate for the folder, ask it to create `written-by-smoke.txt`, verify the file stays under the selected folder, then remove it manually.

7. Open the Monad inspector. **Response** and **Tools** are live, limited views. **Prompt**, **Sent**, and **Journal** must explicitly say unavailable for Monad-backed turns; this is the tracked server API follow-up `MON-API-3`, not stale local inspector data.

8. Switch back to **Local**. Confirm the Local sidebar and local conversation data are unchanged; no remote timeline or transcript should have been migrated or cached locally.

## v1 boundaries

- Yakamoz never starts, stops, or configures a Monad server.
- It does not migrate Local conversations to Monad, or Monad conversations to Local.
- It does not cache Monad conversations, transcripts, agents, or workspace membership in local SwiftData.
- Monad mode supports Yakamoz-provided **folder** workspaces only. Terminal workspaces are explicitly unavailable in v1.
- Yakamoz may save a Monad connection profile/API key and read `/status`, but never writes the Monad server's LLM-provider configuration.
- Remote inspector parity is intentionally limited; see `MON-API-3` for prompt, sent-payload, and journal data.

## Recorded smoke attempt — 2026-07-12

Command run:

```bash
cd /Volumes/Development/monad-project/Monad
swift run monad server
curl --fail http://127.0.0.1:8080/status
swift run monad status
curl http://127.0.0.1:8080/api/sessions
```

Result: the server built and started at `127.0.0.1:8080`; `/status` returned HTTP 200 with `status: "ok"`, a healthy database, and an OpenRouter provider. The authenticated server API returned HTTP 401 for `/api/sessions`, and the local `monad status` invocation reported that no API key was configured. Therefore this attempt could not create/list a protected timeline, select an agent, register an attached folder, or exercise streaming. This is an environment credential blocker, not a full smoke pass. Re-run the complete procedure above with an authorized user-managed server before claiming end-to-end coverage.
