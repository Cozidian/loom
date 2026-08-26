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
- child agents dynamically supervised beneath their parent session;
- mailbox-driven turn cancellation with linked, monitored turn workers;
- synchronous append-only JSONL events and crash reconstruction;
- `:rest_for_one` recovery from durable-state dependency loss.

The implementation has no third-party dependencies and uses Elixir's built-in
`JSON` module.

## Build and configure the CLI

```sh
mix escript.build
./beam_agent init
```

`init` is the first-run wizard. It configures the provider, durable session
directory, maximum tool-loop steps, and turn timeout. Configuration is stored at
`~/.config/beam_agent/config.json` by default with mode `0600`; set
`BEAM_AGENT_CONFIG` or pass `--config PATH` to use another location.

For automated setup:

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
./beam_agent run
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

The initial executable exposes the harness's two built-in providers: `demo`
drives the deterministic tool/subagent scenario, while `echo` is useful for
testing multiple turns and durable resume. A network model adapter remains a
separate `BeamAgent.LLMProvider` implementation rather than CLI-specific logic.

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
  BeamAgent.start_session(provider: :echo, data_dir: "/var/lib/my-agent/sessions")

{:ok, answer} = BeamAgent.ask(session_id, "hello")
{:ok, events} = BeamAgent.events(session_id)
```

Use a stable `session_id` and the same `data_dir` with
`BeamAgent.resume_session/2` to reconstruct the model history from disk.

See [docs/architecture.md](docs/architecture.md) for the DeepSeek Harness to OTP
mapping, process tree, and deliberate differences from Cordis.
