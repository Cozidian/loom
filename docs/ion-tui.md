# ION / OTP control surface

A separate Rust/Ratatui frontend for Loom. Ink-dark surfaces, acid-yellow
intent, cyan actors, violet evidence. It is organized around directing work,
inspecting its owners, and examining what actually happened.

ION does not create a second agent runtime. Elixir still owns provider routing,
supervision, delegation, races/tournaments, tools, policy, persistence and recovery.
ION is the only terminal frontend.

## Run

Requires Elixir/OTP and Rust 1.88 or newer, on a Unix terminal. Use a UTF-8
terminal with true-color support for the full palette; the UI also adapts to
narrow terminals without requiring a Nerd Font.

```sh
mix loom.build
./loom
```

The existing CLI configuration, setup wizard, flags, workspace and provider
profiles apply unchanged. To launch from another directory, use an absolute path
to `loom` and keep `beam_agent_ion` beside it. The default `mix loom.build`
prepares both ION and Desk; `--frontend rust` or `--frontend web` builds just one.
For a terminal-only build (`--frontend rust`), use `loom run` instead of the
service-backed entry point; the service normally hosts Desk as well.

```sh
./beam_agent_ion --demo       # interactive simulated workspace, no model calls
./beam_agent_ion --snapshot   # plain-text 120x38 rendering of that same demo
```

The standalone executable needs inherited bridge descriptors unless `--demo` or
`--snapshot` is selected. Do not launch it directly for a real session.

To join an existing live runtime, use `./loom attach SESSION_ID` with the ID
shown in Desk. This starts only a frontend/connection, not a second session owner.
Closing it leaves the owner running. Desk discovers interactive CLI sessions
started with the rebuilt binary; older processes need one restart.

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

**Recall and copy.** Up recalls previous prompts at the first draft line; Down
advances through recalled prompts and restores your original draft and cursor.
Inside a multiline draft, the arrows still move between lines. Ctrl+R opens a
searchable history drawer; Enter recalls a prompt for editing, never submits it.
History includes up to 200 prompts from runtime replay and this client session,
including failed submissions. It does not create a separate on-disk history file.

Ctrl+Y copies the latest output in Mission, the selected actor/event, or the
record in an open dossier. `/output` browses earlier output (including errors);
Enter inspects it and Ctrl+Y copies its full text. `/copy all` copies the retained
transcript. Copying is explicit and never executes a runtime action. Native
clipboard helpers are used on macOS (`pbcopy`) and on Linux when `wl-copy` or
`xclip` is available. SSH/other terminals use OSC52; terminal clipboard permission
is required. The status says when a request was sent rather than claiming it was
acknowledged. Set `BEAM_AGENT_ION_CLIPBOARD=osc52` to force that transport. Native
copies are limited to 1 MiB and terminal copies to 100 KB.

Typing `/a` offers `/auto` and `/attach`. Tab completes the selected command;
Enter completes a partial command without executing it. Enter on a complete
command executes it. Arguments and pasted multiline text are preserved. Esc
dismisses completion. Dossier help stays pinned; arrow keys move the selection
without scrolling until it reaches the viewport edge. Esc from a locally opened
record returns to its previous list and selection.

## Controls

| Key or command | Action |
| --- | --- |
| F1 / F2 / F3 | Mission / Actors / Ledger; close an open dossier with Esc first |
| Ctrl+P | Search command deck |
| `/prefix`, Tab | Complete slash commands (Up/Down select suggestions) |
| Up/Down at draft boundaries | Recall prompts and restore the original draft |
| Ctrl+R, `/history` | Search prompt history; Enter recalls without submitting |
| Ctrl+Y, `/copy` | Copy latest output or selected/open record |
| Ctrl+T | Expand/collapse tool details in Mission |
| `/output`, `/copy all` | Browse earlier output / copy the retained transcript |
| Enter in Mission | Submit when idle; steer while running |
| Ctrl+J | Insert newline (Alt/Shift+Enter also work when the terminal distinguishes them) |
| Bracketed paste | Insert multiline draft without submitting it |
| `@query`, Up/Down, Tab/Enter | Select repository reference; paths with spaces are quoted; selection does not submit |
| Home/End, Ctrl+A/Ctrl+E | Move within the current draft line |
| PageUp/PageDown | Scroll transcript or dossier |
| Esc | Close overlay, leave actor/ledger view, or resume following live output |
| Ctrl+C | Request active-turn cancellation, or clear an idle draft |
| Ctrl+Q | Exit from any surface, including a pending approval |
| `/models` | Loom picks by default; Enter locks a model, `/` searches, `p` manages providers |
| `/providers` | Add, edit, use, log in to, or remove saved provider profiles |
| `/connect` | Existing authentication flow (can start a new session) |
| `/sessions`, `/resume ID`, `/new` | Inspect, resume, or create a session; `r` resumes an open session dossier |
| `/attach PATH`, `/detach ID` | Import an image file (up to 10 MiB), or remove a draft attachment |
| `/verify`, `/budget`, `/status` | Existing runtime verification and operational views |
| `/mission` | Documentation observer: `s` start, `p` pause, `r` resume, `d` dismiss report, `x` stop observer and fixes, `X` delete stopped observer, `f` refresh |
| `/help` | In-app field manual |

The [documentation observer](documentation-missions.md) is opt-in and read-only.
Its panel shows the bounded assessment allowance before starting; assessments use
the session's selected model and may consume provider allowance. Mission state and
reports come from the runtime, including updates made through Desk. With Loom's
service-backed entry point, the owner remains running after the TUI closes.
Login startup is optional: `loom service install`. Legacy `loom run` is still
terminal-owned. See the [service guide](loom-service.md).

### Providers and models

`/models` opens one catalogue across the enabled provider connections. The first
row, **Loom picks**, releases any model lock. Select another row and press Enter
to lock that exact connection and model for the current conversation, including
its workers and review. A lock never silently switches to another model. It is
journaled for session recovery and does not change the default for new sessions.
Press `/` to search by model or connection, Enter/Esc to finish searching, `r` to
refresh discovery, or `p` to manage providers. The header distinguishes **LOOM
PICKS**, **MODEL LOCKED**, and **LOCAL ONLY**; model calls update the displayed
connection/model and record the selection reason.

Team mode remains independent. `auto` permits bounded helpers using the locked
model; `solo` disables automatic helpers without disabling automatic model
selection. The legacy per-provider selection form still exposes `team_mode`,
`manual`, `auto`, and `local_only`, and saves a default with Ctrl+S. Existing
saved manual defaults remain manual until explicitly changed.

Mission now shows live tool starts/results, command output, team decisions, and
a pinned activity line even when the model sends no assistant text. Tool details
are collapsed by default; Ctrl+T expands the retained previews, while `/events`
and `/output` provide inspection. Durations are measured locally when both tool
events were observed; replay does not invent a duration. The waiting timer measures
time since the last activity received by this client, not model reasoning or a
completion percentage. Approval/disconnection states take precedence.

Codex exposes readable reasoning summaries on a separate
[`item/reasoning/summaryTextDelta` channel](https://learn.chatgpt.com/docs/app-server#item-deltas).
ION labels these separately from final answers. The adapter requests concise
summaries and ignores raw reasoning-text notifications. Providers need not emit
summaries; tool activity and the waiting indicator work without them. Summary
events are checkpointed internally and remain redacted in public event views.

The project runtime discovers models on CLI startup and refreshes every five
minutes. Adapters cover ChatGPT/Codex, Ollama, OpenAI API, xAI language models,
and Anthropic (including pagination). Ollama discovery also reads `/api/show`
metadata; it does not load models or generate responses. An embedding-only model
is visible but cannot own chat work. Unknown capabilities are labeled and excluded
from automatic work; an explicit manual selection can use an unknown model.
Known context limits and tool/modality requirements constrain routing. Model
quality ranking remains heuristic; catalogue metadata is not proof of performance.

A failed refresh retains the last successful in-memory catalogue and marks it
stale. A failed connection with no catalogue is shown as unavailable; it does not
prevent other connections from being used. Catalogue caches rebuild after a
registry restart. No credentials or generated content are stored in the catalogue.

In `/providers`: `n` adds a connection without requiring a favorite model, `e`
edits it, Space enables/disables it, `l` starts login, `r` reloads, and `x` opens
removal confirmation. Enter browses a single provider's models; providers without
a discovery adapter allow `m` for a manual model ID. Forms use Tab/Up/Down to
select fields, Ctrl+U to clear, Ctrl+S to save, and Esc to cancel. API-key fields
accept environment variable names. Saved credentials can be retained; changing
the endpoint clears their reference. Removing a connection preserves its keychain
credentials and session history.

Settings mutations require idle work and preserve the current conversation.
Release a model lock before disabling its connection. Active/default profiles
cannot be removed. Stale forms are rejected; reload before retrying. Provider
connections are shared within a project; unrelated runtime endpoints are preserved.

## Startup and protocol

The release binary is precompiled; launch does not invoke Cargo. ION paints a
connecting screen before waiting for `init`, and allows drafting at that point.
It redraws on input/runtime changes, plus once per second while busy for the
activity timer. This removes UI-side waiting
for initialization, but does **not** remove Elixir VM/session startup before the
CLI launches its frontend. First-frame timing is not end-to-end launch timing.

The transport is defined by `BeamAgent.CLI.TUI`: fd 3 receives and fd 4 sends
four-byte big-endian length prefixed UTF-8 JSON packets, with a 16 MiB maximum
frame. stdin/stdout belong only to the terminal. Provider management adds
`provider_settings` actions and `provider_settings`, `model_catalog`,
`settings_applied`, and `settings_failed` notifications to the same bridge.
Discovery is read-only and runs off the controller; no model inference is used
to populate a catalogue. Settings saves are acknowledged by the runtime.

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
backpressure recovery, approval reconciliation, pinned menus, clipboard payloads,
prompt recall, slash completion, provider forms and responsive views/overlays. The PTY test also
checks history, command completion and OSC52 output without overwriting the
tester's actual clipboard.

To exercise the **actual Elixir bridge**, run in a terminal:

```sh
BEAM_AGENT_TUI_BIN=./beam_agent_ion mix run cmd/beam_agent_ion/tests/runtime_smoke.exs
```

Submit any prompt: the deterministic Echo provider responds without credentials
or model charges. Try `/models`, then Ctrl+Q. The fixture uses its own temporary
workspace and durable state and removes them after normal exit.

## ChatGPT model availability

A saved API model name is not proof of access through a ChatGPT login. Before
opening a new native thread, the backend now validates the exact configured
model against the installed Codex App Server's paginated `model/list` catalogue.
This follows [OpenAI's model discovery guidance](https://learn.chatgpt.com/docs/app-server#list-models-modellist).
Existing threads are reused without repeating the check on every tool response.
Unavailable-model errors list the catalogue and explain `--model MODEL`; nested
provider JSON errors are unwrapped into readable messages in the TUI.

If a saved model is rejected, select an available model explicitly using
`./loom --model MODEL`, or update
the saved provider profile through `/models` or `/providers`. No model or account
configuration is silently changed.

## Current boundaries

It supports file-based image attachment, not OS clipboard image capture. Text
rendering (`src/markdown.rs`) covers headings, emphasis, inline/fenced code,
tables, lists (including task lists), block quotes, links and rules, wrapped and
styled for the pane width — not a full CommonMark/HTML engine. Some operational
views intentionally expose the runtime's JSON in a dossier. The live transcript
keeps up to 600 entries; the live ledger keeps 1,200 events. There is no mouse
interaction or direct remote-node connection: networking and distributed agents
remain runtime responsibilities behind the same bridge.
