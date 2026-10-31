# Yakamoz is a Gnostic client

Yakamoz is a Gnostic client first. The app opens on the network, Network turns are its main
activity, and a network-only user needs no LLM provider. This supersedes the "client mode"
framing in [ADR 0002](0002-embed-gnosticcore-consumer-client.md). The rest of ADR 0002
stands: Yakamoz embeds the public Gnostic client libraries and acts strictly as a consumer.

The client targets Gnostic's 0.5 contract (protocol major 3), which replaces the Ascendant
with Timelines, Runtime instances, Sessions, and Projects. Gnostic 0.5.0 is not released, so
Yakamoz pins Gnostic commit `6132067c24c2e1033ee118023685741a62fe4bc4` by revision. That
commit requires PositronicKit `7.0.0-rc.2` exactly, so both pins move together. When 0.5.0
ships, Yakamoz returns to an exact-version pin (#42).

## Considered options

- **Stay on Gnostic 0.4.2**: rejected — a 0.4.2 client cannot talk to a protocol major 3
  Node, so every feature built on it would need rework.
- **Wait for `0.5.0-rc.1`**: rejected — nothing announces when it will land, and the client
  work should not wait for it.
- **Keep the client as one mode beside local chat**: rejected — it keeps the app organized
  around local chat, and a network-only user still meets provider setup.

## Consequences

Local chat stays for now and moves to PositronicKit 7 with the bump, even though it may be
removed later. A setting can hide it. Removing it would also delete the five-tab inspector
of [ADR 0003](0003-inspector-is-glass.md), so that decision stays with the owner until the
client is proven against a real Node.

Commits after the pinned revision can change the API without notice. Moving the pin is
deliberate work with its own issue, and it follows the same steps as the original bump.
