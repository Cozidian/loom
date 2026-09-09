# ION / OTP control surface

A separate Rust/Ratatui frontend for BeamAgent. Ink-dark surfaces, acid-yellow
intent, cyan actors, violet evidence. It is organized around directing work,
inspecting its owners, and examining what actually happened.

ION does not create a second agent runtime. Elixir still owns provider routing,
supervision, delegation, races/tournaments, tools, policy, persistence and recovery.
The original Go frontend remains available and remains the default.

## Run

Requires Elixir/OTP and Rust 1.88 or newer, on a Unix terminal. Go is unnecessary
when building only ION. Use a UTF-8 terminal with true-color support for the full
palette; the UI also adapts to narrow terminals without requiring a Nerd Font.

```sh
mix beam_agent.build --frontend rust
BEAM_AGENT_TUI_BIN=./beam_agent_ion ./beam_agent
```

The existing CLI configuration, setup wizard, flags, workspace and provider
profiles apply unchanged. To launch from another directory, use absolute paths to
both executables. `mix beam_agent.build --frontend all` builds both clients.

```sh
./beam_agent_ion --demo       # interactive simulated workspace, no model calls
./beam_agent_ion --snapshot   # plain-text 120x38 rendering of that same demo
```

The standalone executable needs inherited bridge descriptors unless `--demo` or
`--snapshot` is selected. Do not launch it directly for a real session.

## Work differently

**Mission / F1** is the intent and steering surface. Describe an outcome rather
than assigning models yourself. While a turn runs, Enter sends steering to the
active owner. At wide widths a telemetry column shows actual runtime worker
roles, endpoint/model assignments and blockers. PageUp pauses following; Esc
returns to live output. Your draft survives view switches.

**Actors / F2** is the work map. Navigate with Up/Down; the adjacent inspector
shows ownership, phase, assignment/routing explanations and touched files when
provided by the runtime. Enter opens the full worker record. Ctrl+X asks for
confirmation before requesting cancellation of the selected worker. This is a
runtime request, not a local process kill.

**Ledger / F3** shows the bounded live journal of canonical runtime events, with
sequence numbers. Enter opens the complete selected JSON record. `/events` asks
the runtime for its event view; `/files` opens changed files and their diffs.
The durable source remains Elixir's event log, not this presentation cache.

**Command deck / Ctrl+P** searches runtime commands. `/race GOAL` and
`/tournament GOAL` retain the existing competition workflows; selecting either
from the deck prepares a draft so you can supply the goal. Competition progress
appears through runtime events and work projections, not invented client state.

**Authority gate** interrupts the surface when approval is needed. It shows the
tool and arguments, defaults to deny, and waits for runtime acknowledgement.
Left/Right select deny, allow once, or scoped allow always; Enter requests that
decision. Up/Down scroll long arguments without changing the decision. Esc
selects deny but does not submit it. `/auto` uses the existing
runtime policy toggle; the header reflects the acknowledged policy.

## Controls

| Key or command | Action |
| --- | --- |
| F1 / F2 / F3 | Mission / Actors / Ledger; close an open dossier with Esc first |
| Ctrl+P | Search command deck |
| Enter in Mission | Submit when idle; steer while running |
| Ctrl+J | Insert newline (Alt/Shift+Enter also work when the terminal distinguishes them) |
| Bracketed paste | Insert multiline draft without submitting it |
| `@query`, Up/Down, Tab/Enter | Select repository reference; paths with spaces are quoted; selection does not submit |
| Home/End, Ctrl+A/Ctrl+E | Move within the current draft line |
| PageUp/PageDown | Scroll transcript or dossier |
| Esc | Close overlay, leave actor/ledger view, or resume following live output |
| Ctrl+C | Request active-turn cancellation, or clear an idle draft |
| Ctrl+Q | Exit from any surface, including a pending approval |
| `/models`, `/connect` | Inspect runtime endpoints; choose a saved provider profile |
| `/sessions`, `/resume ID`, `/new` | Inspect, resume, or create a session; `r` resumes an open session dossier |
| `/attach PATH`, `/detach ID` | Import an image file (up to 10 MiB), or remove a draft attachment |
| `/verify`, `/budget`, `/status` | Existing runtime verification and operational views |
| `/help` | In-app field manual |

Model inspection does not silently change model selection. Profiles are selected
through the existing `connect` action; the runtime remains responsible for
automatic routing. All other operational commands in the command deck likewise
delegate to the existing API.

## Startup and protocol

The release binary is precompiled; launch does not invoke Cargo. ION paints a
connecting screen before waiting for `init`, and allows drafting at that point.
It redraws only when input or runtime state changes. This removes UI-side waiting
for initialization, but does **not** remove Elixir VM/session startup before the
CLI launches its frontend. First-frame timing is not end-to-end launch timing.

The transport is identical to `cmd/beam_agent_tui/main.go` and
`BeamAgent.CLI.TUI`: fd 3 receives and fd 4 sends four-byte big-endian length
prefixed UTF-8 JSON packets, with a 16 MiB maximum frame. stdin/stdout belong only
to the terminal. No backend API changes or provider calls are introduced.

Separate reader/writer threads and bounded queues keep bridge I/O off the render
thread. Invalid frames and EOF produce an offline state; unsent submissions and
unresolved approvals are preserved locally. Approvals are not removed until the
runtime confirms them. There is no automatic replay of actions after disconnect.
Normal exit restores raw mode, cursor, alternate screen and bracketed paste;
panic cleanup also restores the terminal (SIGKILL cannot be handled).

## Verify

```sh
cargo test --locked --manifest-path cmd/beam_agent_ion/Cargo.toml
cargo clippy --locked --manifest-path cmd/beam_agent_ion/Cargo.toml --all-targets -- -D warnings
python3 cmd/beam_agent_ion/tests/pty_smoke.py ./beam_agent_ion
```

The PTY test runs the real binary with a protocol fixture. It checks first paint
before init, early drafting, submit/stream/steer packets, approval acknowledgement,
paste safety, reference selection, exit and restoration of terminal modes.
Rust tests cover protocol corruption, Unicode editing, replay filtering,
backpressure recovery, approval reconciliation and responsive views/overlays.

To exercise the **actual Elixir bridge**, run in a terminal:

```sh
BEAM_AGENT_TUI_BIN=./beam_agent_ion mix run cmd/beam_agent_ion/tests/runtime_smoke.exs
```

Submit any prompt: the deterministic Echo provider responds without credentials
or model charges. Try `/models`, then Ctrl+Q. The fixture uses its own temporary
workspace and durable state and removes them after normal exit.

## Current boundaries

This is a new alternative, not a claim of complete Go-client feature parity.
It supports file-based image attachment, not OS clipboard image capture. Text
rendering recognizes headings and fenced code but is not a full Markdown engine.
Some operational views intentionally expose the runtime's JSON in a dossier.
The live transcript keeps up to 600 entries; the live ledger keeps 1,200 events.
There is no mouse interaction or direct remote-node connection: networking and
distributed agents remain runtime responsibilities behind the same bridge.
