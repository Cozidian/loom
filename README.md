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
> supervised teams, terminal/browser clients and bounded Word-template filling
> run today. Reliable autonomous visual delivery, persistent workspace missions
> and a personal control center remain things to prove and build.

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
mix beam_agent.build
./beam_agent
```

The one-time build prepares ION, Phoenix Desk and the CLI. After that,
`./beam_agent` is all you need; ION is the default. The first launch guides
provider setup. To preview the interface without
credentials or model calls:

```sh
./beam_agent_ion --demo
```

After setup, run `./beam_agent doctor` to check the selected provider. In ION,
use `/providers` to manage connections, `/models` to select a model and team
mode, and `Ctrl+P` to discover commands. Start in another repository or document
folder with `--workspace /path/to/workspace`. For guarded Word-template edits,
see the [document workflow](docs/document-workflow.md).

File mutations and commands use the `ask` approval policy by default. Explicit
`--approval auto` reduces prompts while retaining runtime safeguards; it grants
broad tool approval, not a special “never push” policy. The vision's default of
leaving publication to you is not yet a separate enforced permission category.
Sandboxed command execution currently has a macOS backend; other platforms
fail closed until an enforcing backend is available.

The original Go TUI remains available with `mix beam_agent.build --frontend go`
and `./beam_agent --frontend go`. A terminal-only build can use `--frontend rust`.
See the [operations guide](docs/operations.md) for provider
authentication, saved profiles, line mode, sessions and embedding.

### One model. A useful team.

Keep the selected model while allowing task-based delegation:

```sh
./beam_agent \
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
approvals, actor inspection and live public activity. Start everything together:

```sh
./beam_agent desk
```

Desk opens a **live-session overview**, without creating a work session. Normal
TUI launches publish local connections automatically; click a session to see its
output, agents and approvals. Older running binaries need one restart after
rebuilding to become discoverable.

To attach another terminal to existing work, use the command on its session card:

```sh
./beam_agent attach SESSION_ID
```

Attachments share the existing runtime; they never reopen its storage. Closing an
attached TUI does not stop the owner. `desk --tui` remains a combined-launch
shortcut, and `desk --session ID` opens an already-live session. Browser login
uses a one-use link: no token copying or exports.

Keep Desk's terminal open. Stopping it stops sessions created by that Desk
process, but not separately running TUIs. This is same-user, same-machine live
discovery—not an archive browser, daemon or network control center.
[Connection details and limits](cmd/beam_agent_web/README.md).

## What exists—and what we are reaching for

| Area | Working foundation | Next proof |
| --- | --- | --- |
| Delivery | Coding tools, verification, artifact evidence; a real ROS template filled through the runtime and rendered in Word | Repeat reliable app/document delivery with less intervention and automated visual review |
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
