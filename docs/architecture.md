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
        ├── PathLeaseManager (GenServer, project-wide actor write ownership)
        ├── RepositoryScanSupervisor (Task.Supervisor)
        ├── RepositoryIndex (GenServer, non-blocking project snapshot)
        └── GoalRootSupervisor (DynamicSupervisor)
            └── GoalSupervisor (one per root goal, :rest_for_one)
                ├── Goal (GenServer, typed work contracts and goal-lived state)
                ├── Goal.EventHub (GenServer, goal-wide replay and live fan-out)
                ├── Goal.ModelLease (GenServer, stable route per work contract)
                ├── Goal.ResourceSupervisor (DynamicSupervisor)
                │   ├── Goal stage tasks (execute, repair, review)
                │   └── MCP.Server (one per local stdio server)
                ├── GoalVerificationSupervisor (Task.Supervisor)
                │   └── Goal.Verifier task (temporary, on demand)
                ├── MCP.Registry (GenServer, discovery and namespaced tools)
                ├── SessionSupervisor (:rest_for_one)
                │   ├── EventLog (GenServer, append-only JSONL)
                │   ├── StreamHub (GenServer, live fan-out and checkpoints)
                │   ├── ResourceSupervisor (DynamicSupervisor)
                │   ├── Context (GenServer, instructions and skill snapshot)
                │   ├── ConversationContext (GenServer, model projection)
                │   ├── FileTracker (GenServer, observed file generations)
                │   ├── ToolPolicy (GenServer, approvals and pending callers)
                │   ├── SubagentSupervisor (DynamicSupervisor)
                │   │   └── SessionSupervisor (one per child, recursively)
                │   ├── Agent (GenServer)
                │   └── CodexAppServer.Conversation (ChatGPT profiles only)
                └── Goal.ProgressMonitor (GenServer, worker activity and stall state)
```

The canonical workspace determines a stable project identity, so separate goals
for the same workspace share one long-lived project runtime. A project state
process can restart without disturbing its goal supervisor. Stopping the
project intentionally terminates every ephemeral goal it owns.

A root goal wraps the existing durable session subtree: its goal and session
identifiers are equal during this compatibility phase. `BeamAgent.ask/4` now
enters the `Goal` process first. Goal classifies the objective into a small
runtime-owned `WorkContract`, assembles current repository/git/diagnostic
context, and runs an explicit candidate → verification → repair/restart →
independent review → completion state machine. Failed deterministic checks or
review findings become bounded repair work; the Goal restarts the model worker
while retaining the contract, evidence, route lease, and caller. Repeated
failure fingerprints stop the loop. The session `Agent` remains the model
worker rather than the authority that decides the goal lifecycle.
`BeamAgent.start_session/1` opens or reuses the project and starts a goal, so
existing clients do not need to change. A goal-state failure rebuilds the
dependent session from its event log; sibling goals remain isolated. Nested
subagent sessions remain inside the root session for now and inherit the
project and goal identity from their parent process.
Explicit goal/session shutdown is bounded. Supervisors get a short graceful
termination window; a child that traps shutdown or a provider call that never
returns is then killed by its owning dynamic supervisor. This keeps evaluation
timeouts, cancellation, and project teardown finite without placing a deadline
on productive model work itself.

Each contract captures a filesystem-authoritative starting snapshot. Its final
`WorkArtifact` compares actual repository state rather than trusting named edit
tools, so command-generated, deleted, and externally produced paths participate
in verification and patch fingerprints while pre-existing dirty state remains
distinguishable. Runtime data is excluded even when tests deliberately place the
data directory inside the workspace.

Delegation has both compatibility and actor-native forms. The original
`spawn_subagent` call may still await one child synchronously; background mode
returns a durable delegation handle immediately. `DelegationManager` starts the
runner beneath the Goal resource supervisor, monitors it, stores its terminal
`WorkerResult`, wakes independent awaiters, and owns cancellation. Several
children can therefore run concurrently while the parent continues useful work.

`Goal.ProgressMonitor` subscribes to the same canonical runtime stream and owns
the shared worker-state vocabulary. It distinguishes active work, provider
inference, tools, delegation, verification, review, repair, approval waits,
queueing, blocking, confirmed no-progress loops, and suspected silence. A later
meaningful event records recovery rather than leaving an interface timer to
guess. It also identifies the critical worker and concrete blocker.
`RuntimeWorkBlocks` is a pure replayable projection of those facts for all
clients; the TUI throttles projection refreshes, renders a compact live-work
card, expands the Tree representation, and submits worker actions without
becoming authoritative.

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
At the tool boundary, absolute `path` and `cwd` arguments that canonically resolve
inside the immutable workspace are converted back to workspace-relative
resources before capability and path-lease evaluation. This accommodates model
output and macOS `/var` to `/private/var` aliasing without widening authority;
canonical paths outside the workspace remain absolute and are denied.

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
confidence, and a conservative task-to-model attribution rule. Recommendations
remain shadow-only by default. A project may explicitly enable confidence-gated
selection with bounded deterministic exploration. Durable
`model_route_selected` events carry safe decision inputs, candidates, selection,
reason, and aggregate evidence. `/models` exposes inventory, health, verified
pass rate, sample count, and observed latency; the TUI remains
presentation-only.

Each goal supervises a `ProviderBidCoordinator` and a bidder `Task.Supervisor`.
Before a route becomes a lease, the coordinator asks every policy-eligible
endpoint actor for a content-free quote. A bid contains endpoint/provider/model
identity, a deterministic fit score, confidence, verified sample count, cost
tier, estimated latency, and the individual score components used to calculate
the total. It contains neither prompt text nor credentials.
Manual routing remains a hard selection constraint; Auto uses the normal router
policy and evidence, while additional tournament or race awards follow ranked eligible bids.
The deterministic classifier is deliberately conservative about workspace
change intent: short construction requests remain implementation contracts
rather than falling through to cheap prose work. A model may propose semantic
decomposition and endpoint preferences, but it cannot downgrade that runtime
classification or disable verification. Observed filesystem mutations force
the Goal verification boundary even when initial classification was imperfect.
Free/local cost is a tie-breaker rather than a substitute for verified
implementation quality.
`WorkPlanningPolicy` separately decides whether a turn should remain direct,
invite bounded specialization, or require it because the user explicitly asked
for multiple providers. It does not invent authority: the model proposes task
semantics and dependencies, while `DecompositionPlan`, `AgentConstructor`,
provider auctions, stable leases, capabilities, and verification stay runtime
owned. `semantic_planning_observed` is a shadow comparison between policy and
the coordinator's actual direct/decomposed choice; it adds no extra classifier
model call and cannot alter routing. `delegate_tasks` captures a before/after
workspace snapshot so read-only delegation cannot masquerade as delivered
implementation. Constructed evidence workers (`investigate`, `review`, and
`verify`) are allowed to return reports even when their prompts discuss edits or
implementation; their runtime role outranks ambiguous change-language heuristics.
For a required turn, tool-schema projection is also a planning gate: the root
receives model inventory, `delegate_tasks`, and read-only evidence tools first.
Write, command, MCP, and ad-hoc delegation tools are projected only after the
current turn records a successful organization using at least two endpoint
leases. This prevents a direct implementation followed by a redundant plan at
completion time.

Validated plans are owned by `Goal.WorkRunManager`, not by a model turn or a
temporary worker. `work_run_started` durably records the graph before execution;
attempt, block, recovery, interruption, and completion events advance its state
machine. `Goal.DecompositionExecutor` remains the stateless execution engine:
it runs dependency-ready waves, constructs disposable workers, propagates their
actual verification facts, and reports checkpoints back to the manager. On
recovery the manager replays the root log, reconciles the organization view,
and resumes pending nodes. Per-node attempt limits and the goal retry budget
bound recovery. `FailureDecision` deterministically selects `retry_same`,
`rebind`, `repair`, `replan`, `ask`, or `stop`; these decisions never expand authority or
budget. Public event projection exposes safe lifecycle and decision metadata
while redacting the persisted plan, result content, and raw error details.

The coordinator owns recent market state and the session event log records
`provider_auction_started`, `provider_bid_submitted`,
`provider_auction_awarded`, and `provider_auction_settled` facts.

`Goal.Tournament` requests two to four awards, assigns distinct endpoint leases
where possible, runs every candidate, and selects only from deterministic
consensus, verification, or a caller-supplied evaluator. Its durable
`tournament_*` events keep quality judging distinct from completion order. In
interactive chat, an inconclusive result emits `tournament_judgment_requested`;
the root agent must return one original candidate verbatim. The runtime matches
that answer to its durable candidate set, emits `tournament_winner_selected`
with `selection_source: parent_judgment`, settles the provider auction again as
selected, and emits `tournament_collapsed`. The TUI therefore never infers the
judge's choice.

`Goal.Race` uses the same provider market and constrained worker construction,
but its coordinator selects the first successful admissible terminal result.
It records `race_winner_selected` before cancelling the remaining worker trees,
waits for their runner processes to terminate, and emits `race_settled` only
after cleanup. Errors, empty results, and candidates that fail the configured
verification or admissibility gate cannot win. Shared-workspace lanes receive
only read/trusted built-in tools; write/execute tools require worktree
isolation. Verified coding races require worktree isolation. The TUI projects
both modes into one interactive arena; it never infers a winner or owns
cancellation. Historical `race_*` events
without `selection_policy: first_admissible` replay as legacy tournaments.

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
Anthropic sends it through the top-level `system` field. Project-instruction
bodies are eager because they define workspace behavior within runtime
authority. Skill bodies are lazy: only a
bounded name/description catalog enters the system prompt, while `read_skill`
returns the complete selected `SKILL.md` and records `skill_activated`.

The prompt is deliberately layered. `CodingPrompt` supplies versioned,
provider-neutral coding behavior: intent recognition, repository evidence,
workspace hygiene, actor delegation, verification, and completion reporting.
`ProjectContext` adds workspace instructions and the lazy skill catalog;
`AgentSpec` adds the runtime-created role and bounded assignment; `WorkContract`
adds the current goal artifact and acceptance criteria; and `ToolLoop` adds only
tool-aware execution or recovery guidance for the current step. The coding
prompt version is part of the context fingerprint recorded with each turn. Hard
authority and completion remain runtime checks rather than claims made by prompt
text.

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
match once and creates remain exclusive. Before a write, the project-owned
`PathLeaseManager` grants the path to one actor. A competing worker receives a
structured conflict, while actor death or Goal completion releases its leases.
This protection spans sibling goals sharing a canonical workspace; isolated
worktrees remain separate lease namespaces. Commands use explicit cwd, timeout,
output limits, and an enforcing platform sandbox. Non-zero exits are tool errors
with `ok: false`, exit status, and output so failing checks become repair evidence.
A missing sandbox backend remains an error. Commands default to loopback-only
networking. An explicit external-network request is authorized as `hosts: "*"`
before approval; a finite host allowlist cannot grant an arbitrary networked shell.
The approval resource distinguishes offline and external commands. External
networking changes outbound access only; workspace write confinement remains.
Hex, Go and npm caches live under the workspace-specific private temporary root.

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
On a real TTY, the Rust/Ratatui `beam_agent_ion` client owns screen state,
keyboard input, the textarea, viewport, command palette, and styled rendering
(including a `pulldown-cmark`-based Markdown renderer for headings, emphasis,
code, tables, and lists). `BeamAgent.CLI.TUI` exchanges length-framed JSON
packets with that client while `BeamAgent.Runtime.Client` owns subscriptions,
the active interface turn task, cancellation, approvals, and session
rebinding. The thin `BeamAgent.CLI.TUI.Controller` maps runtime notifications
and CLI-only commands to terminal payloads. The client retains stdin and
stdout for terminal presentation while Erlang's port driver reserves file
descriptors 3 and 4 for the private protocol; the view leaves mouse reporting
limited to scroll-wheel events, which page the transcript.

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
discovers conservative Mix, Go, and Git checks. Implementation work that
actually changed files is verified automatically by Goal before the caller can
observe completion. `/verify` also starts a disposable
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
OTP-owned, session-supervised conversation process. App Server owns browser OAuth, persistence,
refresh, and model access. Each invocation receives an isolated empty working
directory, no Codex shell/web/apps/plugins/subagents, and only BeamAgent's
authorized dynamic-tool schemas. The client and native thread survive across
BeamAgent user turns. A provider transport failure restarts only that
conversation actor; restarting the session worker deliberately rebuilds it.
Native Codex tool requests are executed
immediately through BeamAgent's normal `ToolRunner` capability, approval,
sandbox, event, and budget boundary; the real result is returned to the same
Codex turn so one coding turn can inspect, edit, and finish without an
acknowledgement race. BeamAgent does not impose an arbitrary number of native
tool calls on that turn. Cancellation, resource budgets, approval and
capability policy, command bounds, and repeated-result stall detection remain
the meaningful runtime limits.

Model routing is selected once per `WorkContract` and retained by
`Goal.ModelLease` through tool steps, verification, and repair attempts. Child
workers without an explicit contract receive a worker-lifetime lease, so their
provider does not change between tool steps. Child work may still select a
different endpoint. Coordinators can inspect safe endpoint inventory and attach
soft model requirements to each task in a validated dependency plan. This
supports, for example, a local scaffold worker followed by a stronger remote
implementation worker and a separately leased test worker. Independent tasks
run in parallel; overlapping implementation ownership is admitted only when an
explicit dependency orders the handoff. A user can send
`BeamAgent.steer/2`, the runtime `steer` command, or `/steer MESSAGE`; Goal puts
the message into the active worker mailbox and the tool loop applies it before
the next model decision without cancelling or rebuilding the work.

API-key and generic device-flow credentials are resolved by the supervised
`Auth.CredentialStore`. Configuration and model-endpoint descriptors carry only
opaque keyring references or a secret-free ChatGPT transport marker. API keys
and generic OAuth access/refresh tokens remain in macOS Keychain or Linux Secret
Service; provider processes receive only the currently resolved credential.
OpenAI ChatGPT credentials never enter BeamAgent and remain under Codex App
Server's supported credential lifecycle. OAuth login processes are temporary
and emit only secret-free lifecycle events. An environment variable remains a
fallback when no stored credential is selected.
