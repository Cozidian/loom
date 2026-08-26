# BeamAgent

BeamAgent is a small, runnable Elixir/OTP-native AI agent harness. It explores
what an agent runtime looks like when the BEAM owns isolation, lifecycle,
discovery, recovery, and concurrency instead of recreating a shared plugin
context.

It includes:

- dynamically supervised session subtrees;
- mailbox-owning agent processes;
- replaceable LLM-provider, tool, and agent-strategy behaviours;
- a Registry-backed capability catalog;
- a cancellable multi-step tool-calling loop without an arbitrary step ceiling;
- an immutable, canonical workspace per session;
- supervised project instructions and lazily activated `SKILL.md` workflows;
- session-owned allow/ask/deny policy with monitored one-shot approvals;
- guarded file discovery, reading, creation, versioned editing, and commands;
- child agents dynamically supervised beneath their parent session;
- mailbox-driven turn cancellation with linked, monitored turn workers;
- live, provider-native response streaming with session-scoped subscribers;
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
location. It can contain multiple named provider profiles, but only
environment-variable names—never credential values.

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
idle). Approval dialogs default to deny and require an explicit one-shot choice.

The useful slash commands remain `/new`, `/sessions`, `/status`, `/compact`,
`/skills`, `/reload`, `/events`, `/clear`, and `/exit`. Ollama, OpenAI, xAI/Grok, and
Anthropic responses render as they arrive; deterministic or custom
non-streaming providers render their final response through the same interface.
Use `./beam_agent --no-tui` for the line-oriented interface. Redirected input,
redirected output, and tests select that fallback automatically.

BeamAgent estimates the full model request and automatically summarizes older
completed turns when it reaches the configured threshold. Raw events remain in
the append-only log; only the next model projection is compacted. `/status`
shows the estimate and `/compact` requests compaction immediately. Override the
configured defaults for one run with `--context-window TOKENS` and
`--compact-at PERCENT`.

LLM requests and multi-step turns have no fixed deadline. They continue until
the provider finishes, a real transport error occurs, or the user cancels with
`Ctrl+C`. Tool-specific limits, such as sandboxed command timeouts, remain.

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
- `edit_file` requires the SHA-256 returned by `read_file` and rejects stale or
  ambiguous edits;
- `run_command` has bounded time/output and runs with network denied and writes
  restricted to the workspace and temporary directories;
- `reload_context` refreshes changed instruction and skill files after approval;
- `spawn_subagent` delegates into another supervised session with the same
  workspace and policy.

Paths must be workspace-relative. Canonical path and symlink checks reject
escapes outside the root. Tool requests, approvals, denials, typed failures, and
results are appended to the session JSONL log.

The default risky-tool policy is `ask`, producing an interactive, one-shot
approval before file mutations or commands execute. It can be configured during
setup or overridden for one run:

```sh
./beam_agent --approval deny       # read-only tools plus delegation
./beam_agent --approval ask        # recommended interactive default
./beam_agent --approval allow      # no prompts for writes or commands
```

`allow` is intentionally explicit because it grants model-selected writes and
commands. Command confinement currently has a macOS Seatbelt backend; other
platforms fail closed with `sandbox_unavailable` until an enforcing backend is
added. Run `./beam_agent tools` to inspect the active tool catalog.

## Project instructions and skills

At session start, BeamAgent loads root-level project instructions in this
deterministic order when present:

1. `AGENTS.md`
2. `CLAUDE.md`
3. `BEAM_AGENT.md`

Instruction contents are placed in the provider's native system channel.
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

## Run the demonstration

```sh
mix test
mix beam_agent.demo
```

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

{:ok, answer} = BeamAgent.ask(session_id, "hello")
{:ok, events} = BeamAgent.events(session_id)
```

Use a stable `session_id` and the same `data_dir` with
`BeamAgent.resume_session/2` to reconstruct the model history from disk.

See [docs/architecture.md](docs/architecture.md) for the DeepSeek Harness to OTP
mapping, process tree, and deliberate differences from Cordis.
