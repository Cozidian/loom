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
- a bounded multi-step tool-calling loop;
- an immutable, canonical workspace per session;
- supervised project instructions and lazily activated `SKILL.md` workflows;
- session-owned allow/ask/deny policy with monitored one-shot approvals;
- guarded file discovery, reading, creation, versioned editing, and commands;
- child agents dynamically supervised beneath their parent session;
- mailbox-driven turn cancellation with linked, monitored turn workers;
- synchronous append-only JSONL events and crash reconstruction;
- `:rest_for_one` recovery from durable-state dependency loss.

The implementation has no third-party dependencies. It uses Elixir's built-in
`JSON` module and OTP's `:httpc` client for provider calls.

## Build and configure the CLI

```sh
mix escript.build
./beam_agent
```

Running `beam_agent` opens the terminal chat. On the first launch it walks
through setup first, configuring the provider, model, durable session directory,
maximum tool-loop steps, and turn timeout. You can also rerun the wizard later
with `./beam_agent init`.

Configuration is stored at `~/.config/beam_agent/config.json` by default with
mode `0600`; set `BEAM_AGENT_CONFIG` or pass `--config PATH` to use another
location.

For automated setup with the deterministic echo provider:

```sh
./beam_agent init \
  --provider echo \
  --data-dir ~/.local/share/beam_agent/sessions \
  --max-steps 8 \
  --timeout 30000 \
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
./beam_agent tools
./beam_agent config show
./beam_agent help
```

Inside chat, type `/help` to discover the small interactive command set. The
most useful commands are `/new`, `/sessions`, `/status`, `/skills`, `/reload`,
`/events`, `/clear`, and `/exit`. Provider/model and a shortened durable session ID remain visible in
the header; tool calls and tool results are shown separately from the final
assistant response. The interface uses ANSI styling when the terminal supports
it and remains plain text in redirected output and tests.

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

## Configure an LLM provider

The CLI includes native adapters for Ollama and Anthropic, plus a shared Chat
Completions adapter for OpenAI and xAI/Grok. `demo` drives the deterministic
tool/subagent scenario, while `echo` remains useful for testing multiple turns
and durable resume without a model.

For local use, start Ollama, pull a tool-capable model, and configure it:

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

Cloud providers require a model name and read credentials from an environment
variable. The config stores the variable's name, never the secret itself:

```sh
# OpenAI
export OPENAI_API_KEY="..."
./beam_agent init --force --provider openai --model YOUR_MODEL --non-interactive

# Anthropic
export ANTHROPIC_API_KEY="..."
./beam_agent init --force --provider anthropic --model YOUR_MODEL --non-interactive

# xAI / Grok (`--provider grok` is accepted as an alias)
export XAI_API_KEY="..."
./beam_agent init --force --provider xai --model YOUR_MODEL --non-interactive
```

Run `./beam_agent doctor` after configuring a provider. Ollama diagnostics check
the server and confirm that the configured model is installed. Cloud diagnostics
validate the required model and credential; the first request validates remote
connectivity.

Use `--base-url URL` for a compatible endpoint or proxy, and
`--api-key-env VARIABLE` to select a different credential variable. The same
options can temporarily override saved settings on `run`. Provider adapters are
ordinary `BeamAgent.LLMProvider` modules registered through the capability
catalog, so another provider does not require changes to the agent or tool loop.

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
