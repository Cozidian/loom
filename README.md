# BeamAgent

BeamAgent is a small, runnable Elixir/OTP-native AI agent harness. It explores
what an agent runtime looks like when the BEAM owns isolation, lifecycle,
discovery, recovery, and concurrency instead of recreating a shared plugin
context.

It includes:

- one long-lived supervised project runtime per canonical workspace;
- project-owned, ephemeral goal trees backed by durable session subtrees;
- mailbox-owning agent processes;
- replaceable LLM-provider, tool, and agent-strategy behaviours;
- a Registry-backed capability catalog;
- a cancellable multi-step tool-calling loop without an arbitrary step ceiling;
- an immutable, canonical workspace per session;
- supervised project instructions and lazily activated `SKILL.md` workflows;
- immutable goal/worker capability envelopes and durable scoped permissions;
- session-owned auto/ask/deny policy with once/always approvals and revocation;
- goal-supervised local stdio MCP servers with namespaced tools;
- goal-scoped provider auctions and stable model leases across configured profiles;
- bounded quality tournaments plus first-admissible provider races with early loser cancellation;
- content-free model/task outcomes with later verification attachment;
- guarded file discovery, reading, creation, versioned editing, and commands;
- child agents dynamically supervised beneath their parent session;
- background child workers with durable handles, independent await/status/cancel, and concurrent execution;
- contract-scoped filesystem deltas that attribute actual workspace mutations, including command-generated files;
- goal-owned progress/stall supervision and expandable semantic work blocks;
- mailbox-driven turn cancellation with linked, monitored turn workers;
- live, provider-native response streaming with session-scoped subscribers;
- versioned, goal-wide runtime events spanning parent and child sessions;
- interface-neutral runtime clients with cursor-based replay and reconnect;
- batched durable stream checkpoints without an `fsync` per token;
- synchronous append-only JSONL events and crash reconstruction;
- budgeted model-context projection with durable, restart-safe compaction;
- `:rest_for_one` recovery from durable-state dependency loss.

The runtime uses Elixir's built-in `JSON` module and OTP's `:httpc` client for
provider calls. The full-screen terminal interface is a small Go client built
with Charm's Bubble Tea, Bubbles, and Lip Gloss libraries.

## Build and configure the CLI

```sh
mix beam_agent.build
./beam_agent
```

The build requires Elixir/OTP and Go. It produces sibling `beam_agent` and
`beam_agent_tui` executables; keep them together when moving the CLI. Set
`BEAM_AGENT_TUI_BIN` to an explicit Go frontend path when packaging them in
different locations. `mix escript.build` still builds only the Elixir CLI.

Running `beam_agent` opens the terminal chat. On the first launch it walks
through setup first, configuring the provider, model, durable session directory,
model context window, and compaction threshold. You can also rerun the wizard
later with `./beam_agent init`.

Configuration is stored at `~/.config/beam_agent/config.json` by default with
mode `0600`; set `BEAM_AGENT_CONFIG` or pass `--config PATH` to use another
location. It can contain multiple named provider profiles, but only credential
references and authentication-method metadata—never credential values.

For automated setup with the deterministic echo provider:

```sh
./beam_agent init \
  --provider echo \
  --data-dir ~/.local/share/beam_agent/sessions \
  --non-interactive
```

Validate the installation, then enter an interactive chat:

```sh
./beam_agent doctor
./beam_agent
```

Or run a single prompt:

```sh
./beam_agent run "hello"
```

The CLI also exposes durable-session and capability discovery:

```sh
./beam_agent sessions
./beam_agent resume SESSION_ID
./beam_agent providers
./beam_agent provider list
./beam_agent tools
./beam_agent config show
./beam_agent help
```

Interactive chat opens a full-screen TUI when a capable terminal is attached.
Go owns the terminal and disables mouse reporting; Elixir continues to own the
session, provider stream, tools, cancellation, and approvals through a framed
local bridge.
It keeps the workspace, active profile/model, durable session, turn state,
streaming response, tool activity, and approval requests visible without
scrolling the shell. Press `Ctrl+P` for the command palette, `Ctrl+O` to add a
line in the composer, `Ctrl+T` to expand tool results, `Page Up`/`Page Down` to
move through the transcript, and `Ctrl+C` to cancel a running turn (or exit when
idle). Approval dialogs default to deny and offer explicit once or durable
scoped-always choices.

Number keys open the shared session views when the composer is empty: chat,
tree, files, events, sessions, models, and the competition arena (`7`). The arena
groups provider bidding and candidate activity into parallel lanes for both
quality tournaments and first-finish races. Arrow keys
focus a lane and Enter expands its bid evidence.

The useful slash commands remain `/new`, `/sessions`, `/status`, `/models`, `/tournament GOAL`, `/race GOAL`,
`/auto`, `/compact`, `/skills`, `/reload`, `/verify`, `/steer MESSAGE`, `/events`, `/tree`, `/clear`,
and `/exit`. `/verify` runs either `.beam_agent/verification.json` or conservative
checks discovered from Mix, Go, and Git project files. Ollama, OpenAI, xAI/Grok,
and Anthropic responses render as they arrive; deterministic or custom
non-streaming providers render their final response through the same interface.
Goal, model, dynamically constructed agent, failure, and policy lifecycle events
appear as muted information entries in the transcript. Child agents receive a
runtime-populated role, instructions, context references, model requirements,
and an authority envelope that can only inherit or narrow parent capabilities.
Child tool calls are shown with their worker identifier, `/tree` shows their
constructed roles, `/status` exposes the real project and goal IDs, and
`/events` shows the latest durable events aggregated across the goal tree,
including their goal cursor, correlation, and causation identity.
The event inspector accepts composable filters, for example:

```text
/events category=tool worker=children limit=20
/events type=model_response_failed order=desc
/events correlation=AbC123 after=40 redacted=true
/events help
```

Available filters cover category, event type, root/child worker, session prefix,
correlation and causation prefixes, cursor range, redaction state, ordering, and
a bounded result limit. Filtering and counting run in the Elixir goal runtime;
the Go terminal only submits the query and renders the safe public results.
The local interfaces, loopback web control plane, VS Code/Emacs adapters, and
streaming JSON-lines API use the same `BeamAgent.Runtime` contract. A connection atomically receives
replay and subscribes to later goal events, exposes its durable cursor, and can
be recreated with `after: cursor` without making terminal state authoritative.
Public connections use redacted events unless a trusted in-process client
explicitly requests `view: :internal`.

`/models` lists every configured profile registered in the current project,
including provider/model, locality, health, declared capabilities, verified
sample count, verified pass rate, call count, and observed latency. Use
`/models refresh` to run supervised provider health checks, or `/models PROFILE`
to refresh one endpoint. Its Provider Market section shows the most recent
content-free auction, every endpoint bid, the awarded leases, confidence,
latency estimate, and cost tier. During work, the chat reports `providers
bidding` and `racing N providers` instead of hiding orchestration behind a
generic spinner.

Use `/tournament GOAL` when quality matters more than latency. It runs every
candidate, then retains one winner only when consensus or deterministic
verification justifies it. If that evidence is inconclusive during chat, the
root agent acts as a second-stage judge, selects exactly one original candidate,
and durably closes the same tournament. The arena shows that winner and marks
the other candidates discarded. `BeamAgent.tournament_workers/3` exposes the
lower-level deterministic mechanism, and `BeamAgent.speculate_implementations/3`
uses isolated worktrees and verified-patch judging.

Use `/race GOAL` when latency matters. `BeamAgent.race_workers/3` durably selects
the first successful, non-empty, admissible terminal result, cancels every other
worker tree, waits for their runner processes to stop, and then settles the
provider auction. A fast failure cannot win. Shared-workspace race lanes are
restricted to read-only tools so a cancelled loser cannot leave mutations
behind; callers can opt into isolated write-capable lanes with `isolation:
:worktree`. Candidate `endpoint_id`,
`provider_profile`, or `provider` pins remain subject to capability, locality,
privacy, health, and budget policy. Verified coding races require worktree
isolation.

Ordinary delegation can also overlap without becoming a race. A model may call
`spawn_subagent` with `background: true`, continue useful parent work, inspect
the handle with `subagent_status`, collect it with `await_subagent`, or terminate
its supervised subtree with `cancel_subagent`. Completion does not treat merely
starting or polling a background worker as delivered implementation; the parent
must collect a completed result before relying on it. `/tree` groups the
canonical activity into expandable work blocks and shows runtime-owned
active/waiting/blocked/stalled totals.
The default routing strategy is `auto`: orchestration and difficult work may
stay on the selected cloud profile while simple child work can route to an
available local Ollama profile. Use `--model-strategy manual` for the selected
profile only or `--model-strategy local_only` to prohibit remote models. Each
choice appears as a `Model routed` information event in the chat. Recent
verified outcomes also produce a shadow recommendation. It remains advisory
until enough comparative evidence has been evaluated; unverified provider
success never counts as model-quality evidence.
Use `./beam_agent --no-tui` for the line-oriented interface. Redirected input,
redirected output, and tests select that fallback automatically.

BeamAgent estimates the full model request and automatically summarizes older
completed turns when it reaches the configured threshold. Raw events remain in
the append-only log; only the next model projection is compacted. `/status`
shows the estimate and `/compact` requests compaction immediately. Override the
configured defaults for one run with `--context-window TOKENS` and
`--compact-at PERCENT`.

LLM requests and productive multi-step turns have no fixed deadline. If the
same tool plan returns the same result three times consecutively, the runtime
records `tool_loop_stalled` and performs one answer-only recovery step with
tools disabled. Otherwise work continues until the provider finishes, a real
transport error occurs, or the user cancels with `Ctrl+C`. Tool-specific limits,
such as sandboxed command timeouts, remain.

See [ROADMAP.md](ROADMAP.md) for the current product work order.

## Work in a repository

The directory where `beam_agent` starts is the immutable workspace for the new
session. Use `--workspace PATH` to select another root:

```sh
./beam_agent --workspace ~/code/my-project
```

Every real LLM sees the same model-callable coding tools:

- `list_files`, `read_file`, and `search_files` run without approval;
- `list_skills` and `read_skill` discover and lazily activate project workflows;
- `create_file` refuses to overwrite an existing path;
- `read_file` records its observed generation in a session actor and returns
  numbered content; `edit_file` and `apply_patch` reject stale or ambiguous
  edits without making the model pass hashes;
- `run_command` has bounded time/output, returns non-zero exits as diagnostic
  data, and runs with network denied and writes restricted to the workspace and
  temporary directories;
- `reload_context` refreshes changed instruction and skill files after approval;
- `spawn_subagent` dynamically constructs a bounded specialist with attenuated
  authority and reclaims its live worker after recording the result;
- `delegate_tasks` executes a validated dependency DAG with bounded parallelism;
- `request_capability` submits structured temporary-authority requests;
- `request_project_context`, `file_symbols`, `git_inspect`, and `apply_patch`
  consume deterministic project state rather than asking a model to rediscover it.

Paths must be workspace-relative. Canonical path and symlink checks reject
escapes outside the root. Tool requests, approvals, denials, typed failures, and
results are appended to the session JSONL log.

The default risky-tool policy is `ask`, producing an interactive once-or-always
approval before file mutations or commands execute. Durable grants are scoped
to the concrete tool/resource request, can be listed with
`BeamAgent.permissions/1`, and revoked with `BeamAgent.revoke_permission/2`.
It can be configured during
setup or overridden for one run:

```sh
./beam_agent --approval deny       # read-only tools plus delegation
./beam_agent --approval ask        # recommended interactive default
./beam_agent --approval auto       # auto-approve writes and commands
```

`/auto` toggles that policy for the active session, and the TUI displays `AUTO`
prominently while it is enabled. The older `allow` spelling remains accepted as
an alias. Auto mode is intentionally explicit because it grants model-selected
writes and commands. It does not disable workspace confinement, observed-file
checks, or command sandboxing. Command confinement currently has a macOS
Seatbelt backend; other platforms fail closed with `sandbox_unavailable` until
an enforcing backend is added. Run `./beam_agent tools` to inspect the active
tool catalog.

Local MCP servers can be attached to a running goal with
`BeamAgent.start_mcp_server/2`. Discovered tools use
`mcp__SERVER__TOOL` names and follow the same capabilities, approvals, timeout,
and cancellation rules as native tools. An optional `env` map supplies child
variable names mapped to host environment-variable names, so credential values
do not enter runtime configuration or events. Model and task outcome records are
available through `BeamAgent.outcomes/2`; verification is attached separately
with `BeamAgent.attach_verification/3`, and `BeamAgent.export_outcomes/1`
returns a redacted JSONL export without prompts or model content.
`BeamAgent.routing_evidence/2` returns project-local empirical summaries and the
current recommendation. Evidence is advisory by default; projects may enable
confidence-gated routing with bounded exploration.

## Web, editor, and external clients

Serve an existing durable goal through authenticated loopback interfaces:

```sh
./beam_agent serve SESSION_ID
```

This prints a browser control-plane URL and the address of the versioned
JSON-lines API. Both bind to `127.0.0.1`; stopping either interface leaves the
goal alive. The browser can inspect the complete runtime snapshot, submit work,
verify it, and cancel a running turn. API connections receive live goal events
in addition to command responses and support multiple simultaneous observers.

Thin editor clients live in [`clients/`](clients/): a dependency-free VS Code
extension entrypoint and an Emacs Lisp network client. Configure either with
the host, port, and token printed by `beam_agent serve`.

The runtime can also create worker-owned Git worktrees and compare isolated
implementations with `BeamAgent.speculate_implementations/3`. Candidate checks
run inside their worktree, ambiguous verified patches remain inconclusive until
reviewed, every patch is retained for inspection, and no result is merged
implicitly.

Every model choice first passes through the goal-owned
`ProviderBidCoordinator`. It starts one short-lived OTP bidder task per eligible
endpoint, collects secret-free bids from declared capability, cost and latency
claims plus verified outcome evidence, then awards a bounded lease. Ordinary
work receives one stable lease; tournaments and races receive distinct leases where the registry
has enough eligible providers. Auction, bid, award, candidate, winner, and
settlement facts are durable runtime events, while prompts and model output are
never copied into market records.

## Project instructions and skills

At session start, BeamAgent loads root-level project instructions in this
deterministic order when present:

1. `AGENTS.md`
2. `CLAUDE.md`
3. `BEAM_AGENT.md`

Instruction contents are placed in the provider's native system channel.
They are layered over a versioned BeamAgent coding prompt that defines
evidence-led repository work, intent-sensitive mutation, dirty-worktree
hygiene, bounded actor delegation, proportionate verification, and honest
completion. The prompt version participates in the durable context fingerprint,
so model outcomes from different instruction generations remain distinguishable.
BeamAgent discovers skills one directory below these roots, in precedence order:

1. `.beam_agent/skills/*/SKILL.md`
2. `.agents/skills/*/SKILL.md`
3. `.claude/skills/*/SKILL.md`
4. `skills/*/SKILL.md`

Only skill names and descriptions enter the initial system context. The model
must call `read_skill` to activate and receive a complete matching `SKILL.md`;
that activation is recorded in the durable event log. Duplicate names keep the
first skill from the precedence list and produce a context warning. Invalid,
oversized, or workspace-escaping entries are excluded with warnings.

Inspect skills without starting a session:

```sh
./beam_agent skills --workspace .
```

The harness can extend itself through the guarded tool path: create a new
`.beam_agent/skills/NAME/SKILL.md`, then call `reload_context`, then
`read_skill`. Model-selected creation and reload both require one-shot approval
under the default policy. From interactive chat, `/reload` explicitly refreshes
context after edits made outside the agent.

## Configure LLM provider profiles

The CLI includes native adapters for Ollama and Anthropic, plus a shared Chat
Completions adapter for OpenAI and xAI/Grok. `demo` drives the deterministic
tool/subagent scenario, while `echo` remains useful for testing multiple turns
and durable resume without a model.

For local use, start Ollama, pull a tool-capable model, and configure the first
profile:

```sh
ollama serve
ollama pull qwen3:8b

./beam_agent init --force \
  --provider ollama \
  --model qwen3:8b \
  --non-interactive
./beam_agent doctor
./beam_agent run "Use the add tool to calculate 20 + 22."
```

Add cloud profiles without replacing Ollama. Cloud providers require a model
name and read credentials from an environment variable:

```sh
# OpenAI
export OPENAI_API_KEY="..."
./beam_agent provider add openai --model YOUR_MODEL --non-interactive

# Anthropic
export ANTHROPIC_API_KEY="..."
./beam_agent provider add anthropic --model YOUR_MODEL --non-interactive

# xAI / Grok
export XAI_API_KEY="..."
./beam_agent provider add grok --model YOUR_MODEL --activate --non-interactive
```

OpenAI profiles can instead use a ChatGPT subscription through browser login.
This path requires the official `codex` executable with `codex app-server`
available on `PATH`; Codex owns the OAuth ceremony, durable credential, and
automatic refresh. A session-supervised Codex client and native thread persist
across user turns, while BeamAgent keeps ownership of the agent loop and exposes only
its current dynamic tool schemas to the model process. Tool requests execute
through BeamAgent policy and their real results return inside the same Codex
turn:

```sh
./beam_agent provider add openai-chatgpt \
  --provider openai \
  --model YOUR_CHATGPT_MODEL \
  --non-interactive
./beam_agent auth login openai-chatgpt --chatgpt
./beam_agent provider use openai-chatgpt
./beam_agent doctor
./beam_agent
```

The login command opens OpenAI in the browser and waits for completion; use
`--no-browser` to print the URL instead. In the TUI, `/connect` opens the
configured-provider picker. Selecting an unconnected OpenAI profile links an
existing Codex ChatGPT session when one is available, otherwise it starts the
same browser flow. The selected profile is persisted as active and a correctly
configured session replaces the old one. Explicit API-key profiles keep using
the ordinary OpenAI API transport. `auth logout PROFILE` disconnects the
BeamAgent profile without signing other Codex clients out of their shared
ChatGPT session.

Credentials can instead be brokered through the operating-system keyring. The
configuration stores only an opaque `keychain://beam-agent/PROFILE` reference;
the secret is never written to the configuration or event log:

```sh
./beam_agent auth login grok --api-key
./beam_agent auth list
./beam_agent auth logout grok
```

Providers that explicitly support an OAuth 2.0 device-authorization client can
also use browser-and-code login. Supply the endpoints and public client ID from
that provider's approved application registration:

```sh
./beam_agent auth login PROFILE \
  --device-endpoint https://provider.example/oauth/device/code \
  --token-endpoint https://provider.example/oauth/token \
  --client-id PUBLIC_CLIENT_ID \
  --scope "REQUESTED_SCOPES"
```

The CLI opens the verification page and waits until the provider completes or
expires the device code. Access and refresh tokens remain in the OS keyring;
expired access tokens refresh inside the credential broker. Use `--no-browser`
to open the displayed URL manually. The TUI exposes the saved device flow as
`/connect`. Outside the supported OpenAI/Codex integration, BeamAgent does not
imitate a provider's consumer login or embed unregistered client
credentials—device login must be supported and authorized by the provider.

Omit `--model` and `--non-interactive` for a short guided Grok setup. The CLI
will ask for the model and offer the correct xAI endpoint and `XAI_API_KEY`
variable as defaults; do not paste the secret itself into those prompts.

List profiles, switch the persistent default, or select one for a single run:

```sh
./beam_agent provider list
./beam_agent provider use ollama
./beam_agent run --profile grok "Inspect this repository"
./beam_agent doctor --profile grok
```

Profile names need not match adapters. For example, two OpenAI-compatible
accounts can be named `work` and `personal` by supplying `--provider openai`.
Use `provider add NAME --force ...` to deliberately replace an existing profile.
Changing the active profile affects new sessions; it never mutates an agent
already running inside its supervised session tree.

Run `./beam_agent doctor` after configuring a provider. Ollama diagnostics check
the server and confirm that the configured model is installed. Cloud diagnostics
validate the required model and credential; the first request validates remote
connectivity.

Use `--base-url URL` for a compatible endpoint or proxy, and
`--api-key-env VARIABLE` to select a different credential variable. The same
options can temporarily override saved settings on `run`. Provider adapters are
ordinary `BeamAgent.LLMProvider` modules registered through the capability
catalog, so another provider does not require changes to the agent or tool loop.
Streaming is an optional provider callback, so existing provider modules remain
compatible. The built-in real adapters use native wire formats: NDJSON for
Ollama, Chat Completions SSE for OpenAI/xAI, and typed Messages SSE blocks for
Anthropic.

Every provider call enters through a versioned `ModelRequest`. The request
names its endpoint/provider/model, streaming mode, timeout, owner-process
cancellation boundary, messages, tools, and metadata. `ModelInvocation`
normalizes successful content/tool calls, provider failures, exceptions,
timeouts, and OpenAI/Anthropic/Ollama usage counters. Both ordinary turns and
context compaction use this contract; session cancellation still terminates the
supervised owner process and therefore its in-flight invocation.

## Run the demonstration

```sh
mix test
mix beam_agent.demo
```

Run repeatable end-to-end coding evaluations against configured providers with:

```sh
mix beam_agent.eval evals/coding.json --profile openai-chatgpt
```

See [`evals/README.md`](evals/README.md) for the manifest format. Each run keeps
its isolated fixture workspace, runtime logs, and a JSON report containing
verified completion, latency, routes, tokens, tool/model calls, interventions,
repairs, stalls, cancellations, and final workspace evidence.

The deterministic demo provider first calls `add`, then calls
`spawn_subagent`, then produces a final answer. This makes the complete harness
path runnable without API credentials while the `BeamAgent.LLMProvider`
behaviour remains available for a real model adapter.

## Embed it

```elixir
{:ok, session_id} =
  BeamAgent.start_session(
    provider: :echo,
    data_dir: "/var/lib/my-agent/sessions",
    workspace_root: "/srv/my-project",
    approval_policy: :deny
  )

{:ok, runtime} = BeamAgent.Runtime.connect(session_id)
{:ok, %{events: replay, cursor: cursor}} = BeamAgent.Runtime.bootstrap(runtime)

:ok = BeamAgent.Runtime.submit(runtime, "hello")

receive do
  {:beam_agent_runtime, ^runtime, {:event, event}} -> event
end

# Recreate a disconnected client without missing or duplicating durable facts.
BeamAgent.Runtime.disconnect(runtime)
{:ok, runtime} = BeamAgent.Runtime.connect(session_id, after: cursor)

{:ok, events} = BeamAgent.events(session_id)

:ok = BeamAgent.subscribe_goal(session_id)
{:ok, goal_events} = BeamAgent.goal_events(session_id)

{:ok, %{events: missed, cursor: cursor}} =
  BeamAgent.subscribe_goal_from(session_id, previous_cursor)

# Trusted in-process clients can explicitly request the unredacted projection.
{:ok, internal_events} = BeamAgent.goal_events(session_id, view: :internal)

{:ok, inspection} =
  BeamAgent.inspect_goal_events(
    session_id,
    "category=tool worker=children order=desc limit=20"
  )

{:ok, endpoints} = BeamAgent.models(project_id)
{:ok, _started} = BeamAgent.refresh_models(project_id)
```

Use a stable `session_id` and the same `data_dir` with
`BeamAgent.resume_session/2` to reconstruct the model history from disk.
`start_session/1` is the compatibility API: it opens or reuses the workspace's
project runtime and creates a goal with the same identifier as its durable root
session. Embedders can use `start_project/1` and `start_goal/2` directly when
they need explicit lifecycle control. A goal subscriber receives
`{:beam_agent_runtime_event, event}` messages for live and durable activity from
the root session and its subagents; the versioned envelope is a projection and
does not replace the canonical per-session event logs. Durable envelopes carry
a goal-wide `goal_seq`; `subscribe_goal_from/3` atomically subscribes and
returns events after a prior cursor so a client cannot open a replay/live gap.
Goal replay and subscriptions use a fail-closed public projection by default:
prompts, model text, tool arguments/results, errors, paths, and unknown payload
fields are replaced with typed size descriptors. Event identity, scope,
lineage, lifecycle, model/tool names, status flags, and numeric usage remain
observable. `view: :internal` is an explicit trusted-process override, not an
authorization boundary; canonical session JSONL remains complete and
unredacted.

See [docs/architecture.md](docs/architecture.md) for the DeepSeek Harness to OTP
mapping, process tree, and deliberate differences from Cordis.
