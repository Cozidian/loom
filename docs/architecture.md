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
| Live event fan-out | Session-owned, subscriber-monitoring `StreamHub` process |
| Goal-wide observable event projection | Goal-owned `Goal.EventHub` over root and child sessions |
| Interface connection and reconnect | Ephemeral `BeamAgent.Runtime.Client` over cursor-based goal replay |
| In-process subagent provider | Dynamically supervised child session subtree |
| Long-lived workspace runtime | One registered `ProjectSupervisor` per canonical workspace |
| Project model inventory | Project-owned `ModelRegistry` with supervised health tasks |
| Ephemeral user objective | A project-owned `GoalSupervisor` with explicit identity |
| Scoped/stateful capability | A process under the narrowest goal/session resource supervisor |
| Dependency disposal/reload | Links plus `:rest_for_one` restart ordering |

## Process tree

```text
BeamAgent.Supervisor
├── BeamAgent.Registry
├── BeamAgent.CapabilityCatalog
└── ProjectRootSupervisor (DynamicSupervisor)
    └── ProjectSupervisor (one per canonical workspace, :one_for_one)
        ├── Project (GenServer, identity and project-lived state)
        ├── ModelHealthSupervisor (Task.Supervisor)
        ├── ModelRegistry (GenServer, configured endpoints and health)
        ├── ModelRouter (GenServer, per-request deterministic selection)
        ├── OutcomeStore (GenServer, append-only project outcome ledger)
        └── GoalRootSupervisor (DynamicSupervisor)
            └── GoalSupervisor (one per root goal, :rest_for_one)
                ├── Goal (GenServer, typed work contracts and goal-lived state)
                ├── Goal.EventHub (GenServer, goal-wide replay and live fan-out)
                ├── Goal.ResourceSupervisor (DynamicSupervisor)
                │   └── MCP.Server (one per local stdio server)
                ├── GoalVerificationSupervisor (Task.Supervisor)
                │   └── Goal.Verifier task (temporary, on demand)
                ├── MCP.Registry (GenServer, discovery and namespaced tools)
                └── SessionSupervisor (:rest_for_one)
                    ├── EventLog (GenServer, append-only JSONL)
                    ├── StreamHub (GenServer, live fan-out and checkpoints)
                    ├── ResourceSupervisor (DynamicSupervisor)
                    ├── Context (GenServer, instructions and skill snapshot)
                    ├── ConversationContext (GenServer, model projection)
                    ├── FileTracker (GenServer, observed file generations)
                    ├── ToolPolicy (GenServer, approvals and pending callers)
                    ├── SubagentSupervisor (DynamicSupervisor)
                    │   └── SessionSupervisor (one per child, recursively)
                    └── Agent (GenServer)
```

The canonical workspace determines a stable project identity, so separate goals
for the same workspace share one long-lived project runtime. A project state
process can restart without disturbing its goal supervisor. Stopping the
project intentionally terminates every ephemeral goal it owns.

A root goal wraps the existing durable session subtree: its goal and session
identifiers are equal during this compatibility phase. `BeamAgent.ask/4` now
enters the `Goal` process first. Goal classifies the objective into a small
runtime-owned `WorkContract`, assembles current repository/git/diagnostic
context, owns the executing/cancelling/completed phase, and records a terminal
work artifact. The session `Agent` remains the model worker rather than the
authority that decides the goal lifecycle.
`BeamAgent.start_session/1` opens or reuses the project and starts a goal, so
existing clients do not need to change. A goal-state failure rebuilds the
dependent session from its event log; sibling goals remain isolated. Nested
subagent sessions remain inside the root session for now and inherit the
project and goal identity from their parent process.

Every root and delegated worker receives a validated `AgentSpec` before its
`Agent` process starts. The value keeps soft configuration—goal, role,
instructions, context references, requested expertise, and template—separate
from runtime-owned effective capabilities, restrictions, resources, model
eligibility, verification requirements, and lifecycle. `AgentConstructor`
populates root coordinators and dynamically inferred or explicitly requested
specialists from parent state and project context. Capability requests may only
inherit or attenuate the parent's immutable envelope; prompt fields named like
hard configuration are ignored. Restricted workers receive only authorized
tool schemas, not merely execution-time denial.

Construction request, success, applied-spec, failure, and spawn events contain
safe fingerprints, identifiers, role, authority disposition, and field
provenance rather than goals or instructions. The complete spec stays in the
runtime process/context, where its role, goal, and instructions become an
agent-specific system-prompt section. `/tree` derives dynamic role names from
the durable applied-spec events.

Provider adapters and model endpoints are separate runtime concepts.
`CapabilityCatalog` globally publishes stateless `LLMProvider` modules such as
Ollama and xAI. Each long-lived project owns a `ModelRegistry` containing all
configured profile endpoints simultaneously. An endpoint identifies its
provider module, model, transport location, and credential environment-variable
reference; credential values are never copied into the registry.

Endpoint `claims` describe configured or provider-declared capabilities,
modalities, locality, privacy, context limit, and cost hints. Runtime evidence
remains separate from these declarations: endpoint-local measurements can hold
immediate observations, while durable model/task outcomes are summarized by the
project's evidence layer. Availability starts
as `unknown`; explicit refreshes run provider health checks beneath a
project-owned `Task.Supervisor` and update it to `checking`, `available`, or
`unavailable` without blocking or coupling goal processes. A registry crash
rehydrates configured endpoints without restarting sibling goals.

The CLI loads every stored profile into the project registry. `ModelRouter`
makes an inspectable decision for each intelligence request; Auto prefers local,
free endpoints for simple work, keeps preferred capable endpoints competitive
for orchestration, rejects unavailable/privacy-incompatible endpoints, and can
select deterministic ordinary computation. Manual, local-only, and custom
strategies remain explicit overrides. `RoutingEvidence` compares recent outcomes
by task, language, and endpoint using minimum verified samples, recency weighting,
confidence, and a conservative task-to-model attribution rule. It currently
produces shadow recommendations only: the deterministic selection remains
authoritative until those recommendations have been evaluated. Durable
`model_route_selected` events carry safe decision inputs, candidates, selection,
reason, and aggregate evidence. `/models` exposes inventory, health, verified
pass rate, sample count, and observed latency; the Go TUI remains
presentation-only.

All provider execution enters through a versioned `ModelRequest`, including
ordinary tool-loop steps and context compaction. It explicitly carries request
and endpoint identity, provider/model, messages, tools, streaming choice,
timeout, owner-process cancellation semantics, transport options, and task
metadata. `ModelInvocation` catches provider exceptions and invalid returns,
enforces an optional finite timeout without imposing one by default, and emits
`ModelResponse` or `ModelError` contracts. The tool loop records normalized
request identity in the durable model-response lifecycle, then unwraps the
internal cause at the existing `BeamAgent.ask` compatibility boundary.

`ModelUsage` maps OpenAI prompt/completion tokens, Anthropic input/output tokens,
and Ollama prompt/evaluation counts into input, output, total, and cached token
fields while retaining numeric provider counters. Streaming and non-streaming
providers now share the same durable started/finished/failed lifecycle. Turn
cancellation kills the supervised owner process; the stream hub observes that
boundary and durably closes an interrupted response.

`Goal.EventHub` projects every root and child session event into a versioned
`BeamAgent.RuntimeEvent` envelope. The envelope adds project, goal, session,
worker, correlation, causation, goal sequence, timestamp, category, and
durability metadata while each
session's append-only JSONL remains the canonical durable record. Registering a
session replays its log and follows recorded `subagent_spawned` relationships,
so the goal projection can be rebuilt after a hub restart without introducing a
second durable store. Goal subscribers receive both durable facts and ephemeral
provider progress through one interface-neutral contract.

Every interface request begins as a versioned `BeamAgent.RuntimeCommand`; the
runtime records a `command_received` fact before starting its turn worker. The
command correlation continues through model activity, tool calls, results, and
child sessions. Each durable fact also points at a causation identity. For the
sequential session log this defaults to the preceding fact, while delegated
child sessions explicitly point at the parent tool call that created them.

The goal hub reserves monotonic sequences before a session log writes a fact
and only advances its public cursor after sequences are committed or explicitly
abandoned. The assigned `goal_seq`, correlation, and causation fields live in
the canonical JSONL event, so hub recovery preserves identity. Legacy events
without a goal sequence receive stable negative compatibility sequences and
remain available during a full replay.

`subscribe_goal_from/3` combines subscription and replay in one serialized hub
call. It returns every durable event after an optional cursor plus the current
settled cursor; later events arrive through the same subscription. This avoids
the race created by separately reading history and then subscribing. The TUI
uses that atomic bootstrap and exposes cursor and lineage in `/status` and
`/events`.

Goal replay and subscriptions default to `view: :public`. That projection is
fail-closed: prompt and model content, tool arguments and results, errors,
filesystem paths, and any payload field not explicitly classified as safe are
replaced by descriptors containing only value kind and size. Stable identity,
scope, causation/correlation, event type, model/tool names, status flags, and
numeric usage remain visible. This prevents a newly introduced payload field
from becoming public merely because a producer started emitting it.

Trusted in-process consumers may explicitly request `view: :internal`. The
local TUI does this for its atomic transcript bootstrap and live chat rendering;
its `/events` inspector uses the public projection. `RuntimeEventQuery` parses
and validates composable category, type, worker, session, lineage, cursor,
redaction, ordering, and limit filters without creating atoms from input.
`Goal.EventHub` executes the query over its goal-wide projection and returns
total, matched, returned, cursor, and active-filter metadata with the selected
events. The terminal only submits the expression and renders those results.

`BeamAgent.Runtime` is the public connection boundary above the goal hub and
session services. Its ephemeral client process attaches one interface
subscriber, atomically bootstraps replay and live delivery, tracks the latest
durable cursor, submits turns asynchronously, forwards approvals, and exposes
cancellation, status, inspection, model inventory, and session rebinding. A
connection owns no model-visible or durable state. Disconnecting it does not
terminate work already owned by the session; a replacement connection can use
`after: cursor` to receive only facts it missed.

Runtime connections default to the public fail-closed event view. The local TUI
and line client explicitly request the internal view for model text and tool
rendering. Attaching a client temporarily becomes the session's approval
handler, including for subsequently delegated children; a clean disconnect
restores the previously attached handler when it is still alive. This keeps
approval ownership aligned with the active interface without embedding terminal
logic in the agent process.

View selection is not yet a capability or authorization boundary, so a future
remote interface must expose only the public view until capability enforcement
exists. Canonical JSONL stays complete and unredacted for recovery.

The event log comes first because every model-visible fact depends on it. If the
agent crashes, only the agent restarts and reconstructs messages by replaying the
log. If the event log process dies, `:rest_for_one` rebuilds all downstream
session processes after the log has reopened and validated its file.

`StreamHub` is directly below the log. It monitors terminal, web, and external
subscribers and removes them when their processes disappear. Provider deltas are
broadcast immediately as normalized text, tool-call, and usage events. They are
not individually persisted: the hub groups them for 250 milliseconds or 32
events, then writes one `model_response_checkpoint`. A response also has durable
started and finished/failed events, while `assistant_message` remains the
authoritative model-history record. If the hub crashes, `:rest_for_one` rebuilds
all request-owning processes below it; startup marks a previously started but
unfinished response as failed instead of pretending it completed.

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

`ConversationContext` reconstructs the next model request from the canonical
event log and estimates its size, including the system prompt and tool schemas.
At the configured threshold it asks the active provider to summarize the oldest
completed turns, then appends started/completed compaction events. The summary
is therefore a durable projection checkpoint, not a rewrite of history. Turn
boundaries keep tool calls paired with their results; a summary failure is
recorded and the full projection is used. The token estimate is deliberately
provider-neutral and approximate rather than presented as exact billing usage.

The agent delegates a turn to a task owned by its session `ResourceSupervisor`,
then links to and monitors that task. This keeps the agent mailbox responsive to
status and cancellation requests. Cancellation terminates the worker, records a
durable cancellation event, and replies to the original caller; an agent crash
also takes its in-flight worker down rather than leaving orphan work behind.

## Workspace and tool execution

Every project receives one canonical, immutable workspace root, and every goal
and session inherits it. Model paths must be relative; lexical traversal and
symlink resolution are both checked before a tool sees an absolute path. Child
sessions inherit project and goal identity from the parent process rather than
trusting caller-supplied identity. The workspace, project, and goal are bound
into the durable event log and validated on resume; older logs acquire one-time
`workspace_bound` and `goal_bound` events so they cannot silently move later.

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

The catalog still owns trusted, stateless tool modules. Every goal and worker
also carries an immutable capability envelope for tool, path, command, host,
MCP-server, and model-class resources. Delegation can preserve or narrow it;
an attempted escalation fails. Runtime authority is session-scoped: read tools
are allowed by default, mutations and commands follow the configured risky-tool
policy, and approvals grant one call or a durable exact scoped permission.
Permissions reconstruct from the canonical log and can be inspected/revoked.
The session policy can switch between `ask` and `auto` at runtime. Enabling
auto releases already-pending approvals, records an `approval_policy_changed`
event, and affects future risky calls and child sessions without weakening the
workspace or command sandbox boundaries.
The CLI does not execute approvals inside the model-call task; it owns the human
mailbox, answers `ToolPolicy`, and continues awaiting the supervised turn.
Approval waits have no wall-clock deadline. A disconnected interface releases
its subscription, not the pending decision; a replacement interface receives
the same approval ID, while explicit turn cancellation or caller death removes
the request.

File edits use observed-state concurrency rather than blind overwrite.
`read_file` records the observed hash in the session-owned `FileTracker` and
returns both raw and numbered content. `edit_file` and `apply_patch` normally
consult that actor instead of requiring the model to carry a SHA through its
prompt; legacy direct callers may still provide one. Exact edits must still
match once and creates remain exclusive. Commands use explicit cwd, timeout,
output limits, and an enforcing platform sandbox. Non-zero exits are successful
tool transport with `ok: false`, exit status, and output so failing checks become
repair evidence. A missing sandbox backend remains an error.

When one model response requests multiple independent read-only tools, the tool
loop runs them in bounded supervised tasks and preserves result order. Writes,
commands, delegation, and MCP calls remain serialized.

Goal-scoped local stdio MCP servers live below `Goal.ResourceSupervisor`.
`MCP.Registry` discovers and publishes namespaced tools, while calls pass through
the same capability and approval boundary as native tools. Each transport has
bounded startup/call timeouts, caller monitoring and cancellation notification,
health/lifecycle events, and a scrubbed environment with only `PATH` plus
explicit environment-variable references resolved at spawn time. Remote MCP
transports are intentionally not implemented yet.

`OutcomeStore` owns a bounded append-only project ledger separate from session
conversation logs. Records contain task/repository classification, endpoint,
latency, normalized usage, cost hint, retries, status, failures, and cancellation
but never prompts or model content. Verification starts as `unverified` and is
attached later as its own fact. Retention, export, restart recovery, and opt-out
are explicit. `RoutingEvidence` reads the ledger without owning mutable state;
ordinary successful responses affect operational reliability and latency but do
not affect quality rankings until verification exists.

## Deliberate non-port

There is no generic shared mutable plugin context, effect stack, event waterfall,
or hot-reloadable plugin tree. Replaceability is kept at narrow behaviour seams;
lifecycle is kept in processes and supervisors. Tool execution receives an
explicit immutable context. Stateful resources belong under a session supervisor
instead of hiding inside a module singleton.

The JSONL log is synchronous and calls `fsync` after every durable event. Live
model deltas bypass that path and become batched checkpoint events, avoiding an
`fsync` per token. This remains a small correctness-first implementation, not a
high-throughput persistence backend. A production adapter could batch durable
writes behind the same process/API while retaining sequence validation and
append-only semantics.

## CLI boundary

`BeamAgent.CLI` is an escript entry point over the public harness API. Its JSON
configuration contains named provider profiles—adapter and model, API base URL,
and credential environment-variable name—plus global data directory and runtime
limits, but no secrets or live process state. Config version 8 adds the default
Auto model strategy; version 7 removed the LLM transport deadline after version
6 removed the arbitrary tool-loop step ceiling. Older configurations retain
their context-window settings during migration. The active profile is the manual
preference and Auto may use any eligible registered endpoint per request;
changing the stored active profile does not mutate an already running agent.
Starting or resuming still
goes through `BeamAgent`, capability resolution still goes through the Registry,
and conversation state still goes only to the session event log. The shipped
web control plane, JSON-lines transport, and editor clients use that same public
API and persisted event stream without making any interface a second
orchestration core.

Terminal presentation is isolated from the runtime across a process boundary.
On a real TTY, the Go `beam_agent_tui` client owns Bubble Tea screen state,
keyboard input, the textarea, viewport, command palette, and Lip Gloss
rendering. `BeamAgent.CLI.TUI` exchanges length-framed JSON packets with that
client while `BeamAgent.Runtime.Client` owns subscriptions, the active interface
turn task, cancellation, approvals, and session rebinding. The thin
`BeamAgent.CLI.TUI.Controller` maps runtime notifications and CLI-only commands
to terminal payloads. Go retains stdin and
stdout for terminal presentation while Erlang's port driver reserves file
descriptors 3 and 4 for the private protocol; the view explicitly leaves mouse
reporting limited to cell motion so wheel events scroll only the transcript.

The bridge subscribes to the goal-wide runtime event projection used by future
views; it does not interpret provider protocols or own conversation state. It
renders root conversation entries, tools from every worker, and selected
lifecycle information such as goal startup, model identity, subagent creation,
subagent completion, failures, and policy changes. `/events` opens the public,
goal-wide inspector; filters can select categories, exact event types,
root/child workers, session or lineage prefixes, cursor ranges, redaction state,
ordering, and result limits. The per-session JSONL files remain the complete
record. The line-oriented `BeamAgent.CLI.UI` and `TurnRunner` remain the fallback
for
`--no-tui`, redirected streams, tests, and one-shot prompts. Tool activity is
rendered from durable events as it happens, and a streamed final answer is not
printed a second time in either path. Running the executable with no arguments
is the human path: it opens chat and performs guided setup first when
configuration is absent. Explicit subcommands remain stable for scripts and
diagnostics.

`TurnRunner` is now only a compatibility adapter over `BeamAgent.Runtime`; it no
longer implements a second subscription, approval, timeout, and turn-task loop.

Deterministic completion checks are represented by `VerificationPlan`. A
project may define `.beam_agent/verification.json`; otherwise the runtime
discovers conservative Mix, Go, and Git checks. `/verify` starts a disposable
task beneath the goal's verification supervisor. Every plan/check lifecycle is
recorded durably, command pipelines use `pipefail`, non-zero exits are errors,
and successful or failed evidence updates the latest task outcome. Until such
evidence exists, a final model response records the task as `completed` and
`unverified`, not `succeeded`.

## Provider boundary

All providers implement the same stateless `BeamAgent.LLMProvider` behaviour.
The tool loop supplies normalized conversation history and tool schemas; the
adapter returns normalized text plus zero or more tool calls. Providers may also
implement `stream/4`, emitting normalized text, partial tool-call, and usage
events while assembling that same final response. Transport lives behind
`BeamAgent.HTTPClient`, whose asynchronous streaming callback is implemented by
OTP `:httpc`; protocol tests remain independent of a live service and another
HTTP implementation can replace it.

There is no arbitrary step ceiling: long tool sequences remain valid while
they produce different work or results. The strategy does detect deterministic
no-progress loops. After the same tool plan returns the same result three times
consecutively, it appends `tool_loop_stalled`, exposes the recovery in the event
stream and TUI, and makes one final provider request without tool schemas. The
recovery prompt tells the model to answer from results already present in the
canonical conversation. A model that still emits tool calls fails the turn with
matched error results rather than resuming an unbounded loop.

Profile identity is passed into the session options and recorded on each
`agent_started` event alongside the resolved adapter and model. Child agents
inherit that resolved profile rather than consulting mutable global config.

| CLI provider | API protocol | Authentication |
| --- | --- | --- |
| `ollama` | Native [`/api/chat`](https://docs.ollama.com/api/chat) tool calling | None by default |
| `openai` | OpenAI Chat Completions for API keys, or the official Codex App Server dynamic-tool protocol for ChatGPT plans | ChatGPT browser login, OS-keyring API key, or `OPENAI_API_KEY` |
| `anthropic` | Native [Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create) content blocks and tool results | Keyring credential or `ANTHROPIC_API_KEY` via `x-api-key` |
| `xai` / `grok` | [xAI Chat Completions](https://docs.x.ai/developers/rest-api-reference/inference/chat) function tools | Bearer credential from the OS keyring or `XAI_API_KEY` |

Ollama and Anthropic use native adapters because their tool-history formats are
materially different. OpenAI API-key profiles and xAI share the Chat
Completions wire adapter but keep separate provider modules and defaults.
OpenAI ChatGPT-plan profiles launch the official Codex App Server as an
OTP-owned temporary port process. App Server owns browser OAuth, persistence,
refresh, and model access. Each invocation receives an isolated empty working
directory, no Codex shell/web/apps/plugins/subagents, and only BeamAgent's
authorized dynamic-tool schemas. Native Codex tool requests are executed
immediately through BeamAgent's normal `ToolRunner` capability, approval,
sandbox, event, and budget boundary; the real result is returned to the same
Codex turn so one coding turn can inspect, edit, and finish without an
acknowledgement race. Persisting the App Server thread across separate
BeamAgent turns remains future work.

API-key and generic device-flow credentials are resolved by the supervised
`Auth.CredentialStore`. Configuration and model-endpoint descriptors carry only
opaque keyring references or a secret-free ChatGPT transport marker. API keys
and generic OAuth access/refresh tokens remain in macOS Keychain or Linux Secret
Service; provider processes receive only the currently resolved credential.
OpenAI ChatGPT credentials never enter BeamAgent and remain under Codex App
Server's supported credential lifecycle. OAuth login processes are temporary
and emit only secret-free lifecycle events. An environment variable remains a
fallback when no stored credential is selected.
