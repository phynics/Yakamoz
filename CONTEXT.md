# Yakamoz

Yakamoz is a local, single-user macOS showcase app driving the PositronicKit agent runtime.
For every assistant turn it exposes what was assembled, sent, journaled, and returned.

## Language

### Operators & personas

**Operator**:
A persistent, configured assistant role the user chats with: name, instructions, a private
vault, and default model and tool choices.
_Avoid_: Agent, assistant (use "agent" only where a PositronicKit type leaves no choice)

**Persona**:
A named, reusable bundle of system instructions that can seed a new operator.
Built-ins have stable slugs; custom personas persist.
_Avoid_: preset, profile

**Vault**:
An operator's private on-disk folder for notes and memory, separate from attached
workspaces.
_Avoid_: workspace, memory store

### Conversations & workspaces

**Conversation**:
Yakamoz's user-facing chat shell: title, operator and tool selection, attached workspaces,
and timeline state. Its runtime counterpart is PositronicKit's Timeline.
_Avoid_: chat, thread, timeline

**Workspace**:
A folder attached to a conversation that roots the agent's file tools. Kinds: folder
workspace (read-only tools) and terminal workspace (persistent shell).
_Avoid_: folder, project, directory

### Inspection & providers

**Inspector**:
The right-hand column that shows one assistant turn — the selected one, else the latest —
as prompt, sent, journal, response, and tools tabs. It holds no settings (ADR 0003).
_Avoid_: panel, debugger

**Provider preset**:
A named provider configuration (OpenAI, OpenRouter, Ollama, Custom) mapped to a
PositronicKit provider adapter.
_Avoid_: provider config, profile

### Network client (Gnostic)

Gnostic owns this vocabulary; these entries record only how the terms surface in Yakamoz
and which local terms they must not be confused with.

**Gnostic client**:
Yakamoz's role on a Gnostic network: it discovers and interacts with Nodes, Ascendants, and
workspaces without hosting anything. Advertising presence is a possible future capability,
not current behavior.
_Avoid_: node, host

**Node**:
A Gnostic host that advertises the Ascendants, Timelines, and Workspaces it owns.
_Avoid_: server, broker (the broker is transport, not a Node)

**Ascendant**:
A remote agent identity hosted by a Node. Yakamoz lists discovered Ascendants in the
sidebar's Network group and runs Network turns against them.
_Avoid_: operator, agent

**Gnostic Timeline**:
A remote, Node-owned conversation identity addressed by Gnostic operations. Yakamoz does
not own it, and it is not a local Conversation.
_Avoid_: conversation, thread

**Network workspace**:
A discovered capability resource that a Gnostic Timeline can attach. Distinct from
Yakamoz's Workspace (a folder attached to a local conversation).
_Avoid_: workspace (unqualified), folder

**Network turn**:
A Gnostic Timeline-addressed operation executed by a remote Ascendant whose updates the
client streams. Not a local assistant turn and not inspected by the turn inspector.
_Avoid_: turn (unqualified in network contexts)
