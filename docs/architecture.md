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
        ├── SubagentSupervisor (DynamicSupervisor)
        │   └── SessionSupervisor (one per child, recursively)
        └── Agent (GenServer)
```

The event log comes first because every model-visible fact depends on it. If the
agent crashes, only the agent restarts and reconstructs messages by replaying the
log. If the event log process dies, `:rest_for_one` rebuilds all downstream
session processes after the log has reopened and validated its file.

The agent delegates a turn to a task owned by its session `ResourceSupervisor`,
then links to and monitors that task. This keeps the agent mailbox responsive to
status and cancellation requests. Cancellation terminates the worker, records a
durable cancellation event, and replies to the original caller; an agent crash
also takes its in-flight worker down rather than leaving orphan work behind.

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
configuration contains deployment inputs—provider name, data directory, loop
limit, and timeout—but no runtime state. Starting or resuming a session still
goes through `BeamAgent`, capability resolution still goes through the Registry,
and conversation state still goes only to the session event log. A future web
view can therefore use the same public API and persisted events without the CLI
becoming a second orchestration core.
