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
The right-pane drawer with two modes: compose (provider, workspace, and tool settings) and
inspect, which shows the selected assistant turn as prompt, sent, journal, response, and
tools tabs.
_Avoid_: panel, debugger

**Provider preset**:
A named provider configuration (OpenAI, OpenRouter, Ollama, Custom) mapped to a
PositronicKit provider adapter.
_Avoid_: provider config, profile
