# DeepSeek Harness concepts mapped to OTP

This project uses DeepSeek Harness as a comparison, not as an implementation
template. DeepSeek Harness builds an agent from Cordis plugins contributing
services, typed events, and reversible effects to a shared context. Its core
turn flow derives a model request from an append-only session log, calls an LLM,
dispatches tools, and appends model-visible results before the next step.

Primary references:

- [DeepSeek Harness architecture](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md)
- [Core subsystem and agent loop](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/core.md)
- [Session event model](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/session.md)
- [Subagent capability](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/subagent.md)

## Mapping

| DeepSeek Harness / Cordis concept | BeamAgent equivalent |
| --- | --- |
| Shared `Context` service graph | Explicit process names, arguments, and behaviour modules |
| Plugin fiber and reversible effect | Supervisor child ownership and process termination |
| Service registry | Elixir `Registry`, with registrations owned by a catalog process |
| Agent handle and live registry | A registered `GenServer` with a mailbox |
| Agent-loop plugin | A replaceable `BeamAgent.AgentStrategy` module run by the agent process |
| LLM adapter registry | Stateless `BeamAgent.LLMProvider` modules published in `Registry` |
| Tool runtime registry | Stateless `BeamAgent.Tool` modules published in `Registry` |
| Session event source of truth | Session-owned append-only JSONL `EventLog` process |
| In-process subagent provider | Dynamically supervised child session subtree |
| Scoped/stateful capability | A process under the session's `ResourceSupervisor` |
| Dependency disposal/reload | Links plus `:rest_for_one` restart ordering |

## Process tree

```text
BeamAgent.Supervisor
├── BeamAgent.Registry
├── BeamAgent.CapabilityCatalog
└── BeamAgent.SessionRootSupervisor (DynamicSupervisor)
    └── SessionSupervisor (one per root session, :rest_for_one)
        ├── EventLog (GenServer, append-only JSONL)
        ├── ResourceSupervisor (DynamicSupervisor)
        ├── Context (GenServer, project instructions and skill snapshot)
        ├── ToolPolicy (GenServer, approvals and pending callers)
        ├── SubagentSupervisor (DynamicSupervisor)
        │   └── SessionSupervisor (one per child, recursively)
        └── Agent (GenServer)
```

The event log comes first because every model-visible fact depends on it. If the
agent crashes, only the agent restarts and reconstructs messages by replaying the
log. If the event log process dies, `:rest_for_one` rebuilds all downstream
session processes after the log has reopened and validated its file.

`ToolPolicy` owns one session's allow/ask/deny decisions and outstanding
approval calls. It monitors both the CLI approval handler and every waiting turn
worker: losing the handler fails pending calls closed, while losing a caller
removes its approval instead of leaking it. Under `:rest_for_one`, policy loss
restarts the dependent subagent supervisor and agent but keeps the event log and
resource supervisor alive.

`Context` owns one immutable runtime snapshot of root project instructions and
skill metadata. Every load records content hashes and an aggregate fingerprint
in the event log. A context crash reloads current workspace files and, through
`:rest_for_one`, rebuilds policy, subagent ownership, and the agent against that
new snapshot. An explicit `reload_context` performs the same refresh without a
crash and is approval-gated when selected by the model.

The agent delegates a turn to a task owned by its session `ResourceSupervisor`,
then links to and monitors that task. This keeps the agent mailbox responsive to
status and cancellation requests. Cancellation terminates the worker, records a
durable cancellation event, and replies to the original caller; an agent crash
also takes its in-flight worker down rather than leaving orphan work behind.

## Workspace and tool execution

Every session receives one canonical, immutable workspace root. Model paths must
be relative; lexical traversal and symlink resolution are both checked before a
tool sees an absolute path. Child sessions inherit the root rather than resolving
their own ambient current directory. The root is bound into the durable event
log and validated on resume; older logs acquire a one-time `workspace_bound`
event so they cannot silently move on later resumes.

```text
assistant tool call
  → global capability lookup
  → access classification (:read/:write/:execute/:delegate)
  → session ToolPolicy (allow/ask/deny)
  → tool body in the supervised turn worker
  → normalized content plus typed error envelope
  → durable tool_result event
  → next model step
```

Before each provider step, the strategy reads the current supervised context
snapshot. OpenAI-compatible and Ollama adapters prepend it as a `system` message;
Anthropic sends it through the top-level `system` field. Instruction bodies are
eager because they define project authority. Skill bodies are lazy: only a
bounded name/description catalog enters the system prompt, while `read_skill`
returns the complete selected `SKILL.md` and records `skill_activated`.

The catalog still owns trusted, stateless tool modules. Runtime authority is
session-scoped: read tools are allowed by default, mutations and commands follow
the configured risky-tool policy, and approvals grant exactly one pending call.
The CLI does not execute approvals inside the model-call task; it owns the human
mailbox, answers `ToolPolicy`, and continues awaiting the supervised turn.

File edits use observed-state concurrency rather than blind overwrite:
`read_file` returns a SHA-256 version and `edit_file` must present it while also
matching exactly one old-text occurrence. Creates use exclusive file creation.
Commands use explicit cwd, timeout, output limits, and an enforcing platform
sandbox. A missing sandbox backend is an error, not an automatic unsandboxed
fallback.

## Deliberate non-port

There is no generic shared mutable plugin context, effect stack, event waterfall,
or hot-reloadable plugin tree. Replaceability is kept at narrow behaviour seams;
lifecycle is kept in processes and supervisors. Tool execution receives an
explicit immutable context. Stateful resources belong under a session supervisor
instead of hiding inside a module singleton.

The JSONL log is synchronous and calls `fsync` after every event. This is a small
correctness-first implementation, not a high-throughput persistence backend. A
production adapter could batch writes behind the same process/API while retaining
sequence validation and append-only semantics.

## CLI boundary

`BeamAgent.CLI` is an escript entry point over the public harness API. Its JSON
configuration contains deployment inputs—provider and model, API base URL,
credential environment-variable name, data directory, loop limit, and
timeout—but no secrets or runtime state. Starting or resuming a session still
goes through `BeamAgent`, capability resolution still goes through the Registry,
and conversation state still goes only to the session event log. A future web
view can therefore use the same public API and persisted events without the CLI
becoming a second orchestration core.

The terminal presentation is similarly isolated in `BeamAgent.CLI.UI`. It adds
ANSI-aware headers, conversational roles, compact tool activity, setup guidance,
and slash-command discovery without owning sessions or interpreting model
protocols. Running the executable with no arguments is the human path: it opens
chat and performs guided setup first when configuration is absent. Explicit
subcommands remain stable for scripts and diagnostics.

## Provider boundary

All providers implement the same stateless `BeamAgent.LLMProvider` behaviour:
the tool loop supplies normalized conversation history and tool schemas, and the
adapter returns normalized text plus zero or more tool calls. Transport lives
behind `BeamAgent.HTTPClient`, which keeps protocol tests independent of a live
service and leaves room for another HTTP implementation.

| CLI provider | API protocol | Authentication |
| --- | --- | --- |
| `ollama` | Native [`/api/chat`](https://docs.ollama.com/api/chat) tool calling | None by default |
| `openai` | [OpenAI Chat Completions](https://developers.openai.com/api/reference/cli/resources/chat/subresources/completions) function tools | Bearer token from `OPENAI_API_KEY` |
| `anthropic` | Native [Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create) content blocks and tool results | `x-api-key` from `ANTHROPIC_API_KEY` |
| `xai` / `grok` | [xAI Chat Completions](https://docs.x.ai/developers/rest-api-reference/inference/chat) function tools | Bearer token from `XAI_API_KEY` |

Ollama and Anthropic use native adapters because their tool-history formats are
materially different. OpenAI and xAI share the Chat Completions wire adapter,
but keep separate provider modules and defaults. This is the smallest common
cross-provider seam today; a native OpenAI Responses adapter can be added behind
the same behaviour without changing sessions, persistence, CLI orchestration, or
tools.
