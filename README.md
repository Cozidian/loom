<p align="center">
  <img src="docs/assets/beam-agent-header.svg" alt="BeamAgent — Independent work. Visible progress." width="100%">
</p>

<p align="center">
  An Elixir/OTP harness for work that deserves more than a chat response.
</p>

<p align="center">
  <a href="#start-with-ion">Get started</a> ·
  <a href="VISION.md">The vision</a> ·
  <a href="ROADMAP.md">What comes next</a> ·
  <a href="docs/operations.md">Operations guide</a>
</p>

## Give it a goal. Stay in control.

Build the feature. Understand the codebase. Edit the document. Follow a longer
goal through to something you can actually use.

BeamAgent is growing into an independent collaborator for code, documents and
long-running work. The ambition is simple: it makes sensible decisions, asks
when your judgment genuinely matters, and verifies the result before calling
the job done. You see **what changed, why, and what remains unfinished**—with
the evidence and individual agents one level deeper.

Built first for one person's workflow, and for others who want that same mix
of independence, reliability and visibility.

> **Early, working foundation—not the finished promise.** Coding tools,
> supervised teams and terminal clients run today. Reliable visual end-to-end
> delivery, document editing, persistent workspace missions and a personal
> control center are the next things to prove and build.

## Why this harness?

**Independence without opacity.** Delegate an outcome, not every keystroke.
Keep the overview readable and the decisions, changes and verification inspectable.

**Useful intelligence, used carefully.** Deterministic tools for mechanical
work. Models chosen for the job. Parallel agents when they help—not to fill a
dashboard. Avoid repeated investigation and needless model calls.

**Actors, not a pile of prompts.** OTP supplies supervision, independent
lifecycles, cancellation and recovery. A model is a resource an agent uses,
not its identity. Several agents can use the same provider and model.

**Knowledge that can change its mind.** Keep useful context in readable files.
Record evidence, uncertainty and why a decision made sense. Revise it when
something better is learned. Knowledge is never a frozen specification.

## Start with ION

ION is the Rust/Ratatui terminal frontend. Build from the repository root with
Elixir 1.19 and compatible OTP, plus Rust 1.88 or newer:

```sh
mix beam_agent.build --frontend rust
BEAM_AGENT_TUI_BIN="$PWD/beam_agent_ion" ./beam_agent
```

The first launch guides provider setup. To preview the interface without
credentials or model calls:

```sh
./beam_agent_ion --demo
```

After setup, run `./beam_agent doctor` to check the selected provider. In ION,
use `/providers` to manage connections, `/models` to select a model and team
mode, and `Ctrl+P` to discover commands. Start in another repository or document
folder with `--workspace /path/to/workspace`; document-folder support does not
yet imply a proven Word-editing workflow.

File mutations and commands use the `ask` approval policy by default. Explicit
`--approval auto` reduces prompts while retaining runtime safeguards; it grants
broad tool approval, not a special “never push” policy. The vision's default of
leaving publication to you is not yet a separate enforced permission category.
Sandboxed command execution currently has a macOS backend; other platforms
fail closed until an enforcing backend is available.

The original Go TUI remains available with `mix beam_agent.build --frontend go`.
Keep the explicit ION binary override when you want Rust; the default launcher
still selects Go. See the [operations guide](docs/operations.md) for provider
authentication, saved profiles, line mode, sessions and embedding.

### One model. A useful team.

Keep the selected model while allowing task-based delegation:

```sh
BEAM_AGENT_TUI_BIN="$PWD/beam_agent_ion" ./beam_agent \
  --model-strategy manual --team-mode auto \
  --max-workers 5 --model-concurrency 6
```

This permits an owner and up to five subagents; it does not force five workers
onto every task. Graph work queues behind configured capacity. Concurrent
editors need disjoint path authority or ordered handoffs, and the owner remains
responsible for integration and verification. Model slots are per project pool,
not an account-wide quota. [How teams work →](docs/task-teams.md)

### A desk in your browser

[BeamAgent Desk](cmd/beam_agent_web/README.md) is a separate Phoenix client for
the real authenticated HTTP API: prompt submission, active cancellation,
approvals, actor inspection and live public activity. It attaches to a served
session without owning its work. Desktop/mobile browser checks exercise the
actual runtime with an isolated echo provider; autonomous delivery and the
broader multi-workspace control center remain separate things to prove.

## What exists—and what we are reaching for

| Area | Working foundation | Next proof |
| --- | --- | --- |
| Delivery | Coding tools, command execution, verification and artifact evidence | Build, run and visually inspect a usable app; edit and render a real document |
| Teams | Same-model subagents, task graphs, capacity queues, races and tournaments | Show that the chosen workflow improves useful outcomes without waste |
| Visibility | ION mission/actor/evidence views, live events and replay | Make changes, decision explanations and unfinished work effortless to understand |
| Continuity | Durable sessions, project context, instructions and skills | Share revisable knowledge across sessions and tools without turning notes into rules |
| Background work | Delegation and isolation building blocks | Persistent, mission-scoped observers that avoid reacting to unfinished work |
| Reach | Shared runtime API, local clients and execution-node policy foundations | A personal multi-workspace control center and workers on trusted machines |

The long-term shape has two entry points: open a harness inside a workspace,
or open a personal control center that sees work across repositories and
document folders. Background missions—documentation, regressions, investigation—
report to a coordinator and prepare isolated proposals. They do not race another
tool to edit its working tree. This is **direction**, not shipped functionality.

## Explore

- [Vision](VISION.md) — what we believe, why, and what remains open.
- [Roadmap](ROADMAP.md) — the next real-world trials and proposed follow-up work.
- [ION field manual](docs/ion-tui.md) — controls and terminal workflows.
- [Desk](cmd/beam_agent_web/README.md) — Phoenix frontend, setup and browser checks.
- [Operations guide](docs/operations.md) — setup, providers, APIs and detailed usage.
- [Architecture](docs/architecture.md) — the runtime and its OTP boundaries.
- [Evaluations](evals/README.md) — reproducible runs and delivery evidence.
- [Earlier roadmap](docs/roadmap-history.md) — preserved history, not a second backlog.

Working on this repository with an AI? Start with [AGENTS.md](AGENTS.md).

---

The first milestone is not a larger feature list. It is opening the finished
app and edited document and thinking: **yes, it actually did the work.**
