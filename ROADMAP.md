# Loom — next experiments

Updated: 2026-09-10 · [Vision](VISION.md) · [Implementation history](docs/roadmap-history.md)

This is a working task list informed by the vision interview and the current
checkout. It is **not a specification**, a promise of dates, or authorization
to execute every item. Change the tasks and order when evidence improves our
understanding. An unchecked item is a candidate for work, not an obligation.

The owner chose the first priority: **build a real coding project and edit a
real document, then refine the experience.** The later sequence below is a
proposal, not a settled user decision.

## What we can build on

These are code/test foundations, not proof that the whole product vision works.

| Foundation | Evidence to inspect |
| --- | --- |
| Workspace/project/goal lifecycles and shared runtime clients | [Runtime](lib/beam_agent/runtime.ex), [project/goal tests](test/project_goal_runtime_test.exs), [client tests](test/runtime_client_test.exs) |
| Same-model teams, capacity queues and cancellation | [Task-team notes](docs/task-teams.md), [team tests](test/task_team_test.exs), [resource tests](test/resource_governance_test.exs) |
| Guarded writes and completion/verification evidence | [Tool boundary](lib/beam_agent/tool_runner.ex), [work checks](test/work_contract_test.exs), [verification tests](test/verification_test.exs) |
| ION overview and per-agent/event inspection | [ION manual](docs/ion-tui.md), [UI tests](cmd/beam_agent_ion/src/tests.rs) |
| Project instructions and skill/context loading | [Context actor](lib/beam_agent/session/context.ex), [operations guide](docs/operations.md#project-instructions-and-skills) |
| Isolated experiments and alternate execution paths | [Worktree tests](test/worktree_runtime_test.exs), [organization tests](test/dynamic_organization_test.exs) |

Earlier [coding evaluations](docs/coding-usability.md) are useful evidence, but
not a reliability benchmark or proof of visual inspection and document delivery.
The execution-node registry provides policy/selection foundations, not a working
cross-machine dispatch product. A bounded read-only documentation observer now
exists under a live owner. Loom now has an initial per-user macOS service and
live-session Desk; broader control-center and distributed work remain experiments.

### Service-backed Loom progression

- [x] Rebrand the CLI and client surfaces without moving credentials or durable storage.
- [x] Separate the backend lifetime from Desk/TUI clients; make login renewal local and explicit.
- [x] Add start/stop/status/logs and opt-in login startup, with idle/paused recovery.
- [ ] Package a standalone install/update flow; the current service uses the checkout and Mix.
- [ ] Exercise prolonged sleep/wake, provider refresh and interrupted real coding work.

See [service behavior and checks](docs/loom-service.md). Recovery is not permission
to replay unfinished model calls or automatically apply old proposed edits.

## Now — earn trust with two real deliveries

### Trial follow-up — current slice

- [x] Mark completion-review owners as waiting; monitor the reviewer separately.
- [x] Advertise only permitted Git operations and desktop-rendering capabilities.
- [x] Add fingerprint-bound, read-only image assessment and a review-only retry
  command for Word outputs; exercise it on the existing two-page ROS output.
- [x] Repeat the larger Phoenix fixture and inspect its running desktop/mobile UI.
- [x] Extend app acceptance with protected real-HTTP 403/404 checks. The new check
  rejects the previous artifact's missing error renderer without provider calls.
- [ ] Add harness-owned browser QA and rerun autonomous app delivery. The old
  artifact remains unchanged; broader unattended delivery is not yet proven.
- [ ] Run a fresh full document generation with the new automatic QA step;
  the review-only path has live evidence, the combined path does not yet.

See [coding trial](docs/coding-usability.md#2026-09-10--fresh-phoenix-trial-and-wider-browser-checks)
and [document QA](docs/document-workflow.md#image-assessment-trial--2026-09-10).
The read-only documentation mission below is a first live-owner implementation,
not a persistent OS service.

### Trial readiness — first implementation slice

- [x] Add a read-only evaluation preflight so missing fixtures/originals can be
  caught before spending provider calls.
- [x] Fingerprint protected tests and binary originals before a run; reject
  changed/missing inputs and check preservation again after verification.
- [x] Require a content delta for declared changed outputs; separate passing
  expectations from completion backed by required deterministic checks.
- [x] Report unreported usage as unknown, retaining observed token subtotals and
  coverage instead of showing a misleading zero.

Evidence: [evaluation tests](test/evaluation_test.exs),
[file/usage regressions](test/evaluation_evidence_test.exs),
[trial instructions and limits](evals/README.md#artifact-integrity-and-honest-measurement).
These are offline evaluation safeguards, **not completion of either delivery**.
The old Phoenix fixture still uses a stand-in runtime. A real API client now
exists and has browser evidence (below), but autonomous delivery remains to be
tried. The Word trial now has a real source, runtime delivery and native Word
rendering evidence, with interventions recorded below.

### Phoenix client — real API integration milestone

- [x] Build a standalone Phoenix client of the existing authenticated HTTP/JSON
  protocol, with no frontend-owned goal state or core Phoenix dependency.
- [x] Exercise login, submission, active inference cancellation, approvals and
  duplicate-decision rejection against actual supervised runtime sessions.
- [x] Run desktop/mobile Chrome checks and inspect screenshots; preserve drafts
  across refresh and errors; reject CSRF and foreign-host requests.
- [x] Fix issues exposed by embedding: JSON boolean/null serialization and eager
  global default reads that failed despite explicit caller options.

Evidence: [Desk](cmd/beam_agent_web/README.md),
[runtime integration tests](cmd/beam_agent_web/test/desk_test.exs),
[browser checks](cmd/beam_agent_web/test/browser/desk.spec.js).
The provider is deterministic echo (or a blocked test provider for cancellation).
This demonstrates a running client, **not a model independently building it**,
cross-machine execution, document delivery or an efficiency benchmark. It uses
the public redacted activity view; ION remains the richer conversation surface.

The owner supplied a Word source and authorized the live ROS delivery using the
existing provider profile. Further strategy comparisons still need a chosen
scope and spending authority; distributed proof needs a second trusted computer
with an explicit connection scope. Do not substitute simulations for these proofs.

### Startup DX — one command after the build

- [x] Make ION the default; retain explicit Go selection and binary overrides.
- [x] Prepare ION, Desk and the CLI with one `mix beam_agent.build` command.
- [x] Add `./beam_agent desk`: shared setup, session creation, managed servers,
  browser opening and short-lived one-use login without user-managed exports.
- [x] Exercise automatic browser login and prompt submission against the real
  runtime; verify stopping the launcher also stops its Phoenix process/listener.
- [x] Show private prompt/answer output separately from redacted events; test
  actual answer visibility, refresh persistence, escaping and bearer-only access.
- [x] Add `desk --tui` for one live session with two views and exercise external
  submissions through the terminal controller. Separate launches remain separate.
- [x] Add a local live-session overview, private owner discovery and
  `attach SESSION_ID`. Verify two separate OS owners, unauthorized attachment,
  disconnect survival, answer visibility and browser-tab isolation.
- [ ] Extend discovery to archived sessions and other run entrypoints; prove
  crash/recovery registration handling before adding automatic takeover.

Evidence: [startup guide](docs/operations.md#build-and-configure-the-cli),
[launcher](lib/beam_agent/cli/desk.ex),
[bootstrap/browser regressions](cmd/beam_agent_web/test/browser/desk.spec.js).
This is a foreground checkout launcher, not an installed standalone release,
background daemon or multi-workspace control center.

### A. Build something the owner can use

- [ ] Choose a bounded but representative app/feature and a starting workspace.
  A Phoenix frontend consuming the actual harness API is one candidate, not a
  settled requirement or a substitute for choosing a manageable first scope.
- [ ] Capture the user's intended outcome and a few observable success examples.
  Resolve consequential ambiguity together; let the harness choose routine details.
- [ ] Run the work end to end through the normal frontend and runtime. Record
  questions, interventions, provider/tool calls, retries and available usage data.
- [ ] Exercise the running app through relevant user interactions and visually
  inspect it. Add or connect the browser/rendering tools needed for that evidence.
- [ ] Compare the actual changed files with the delivered result. Report what
  works, why the approach was chosen, and anything incomplete or unverified.
- [ ] Keep publishing/pushing with the user unless explicitly requested. Identify
  any permission gap between that preference and the current broad auto mode.
- [ ] Turn the failures from this trial into small, reproducible fixes and rerun.

**Evidence we want:** a runnable artifact, automated checks, interaction/visual
evidence, an honest handoff and a record of how much supervision it needed.
Passing existing unit tests alone does not answer whether this experience works.

### B. Edit a document without breaking it

- [x] Choose a real, non-sensitive Word document and a meaningful edit. Start
  from a copy; note the content and formatting that should remain unaffected.
- [x] Inspect existing tools/skills and choose the smallest viable editing and
  rendering path. Make its dependencies and supported platforms visible.
- [x] Make the edit through the guarded runtime workflow and retain the original.
- [x] Render and inspect the output, including affected pages, tables, images,
  pagination and styles where relevant. Check the file's structural integrity.
- [x] Open the result in the intended document application, or explicitly record
  that this check still needs the user. Do not imply rendering proves every editor.
- [x] Deliver the edited document with a concise change summary and remaining
  issues. Capture a reusable regression fixture from any corruption/layout failure.

**Evidence we want:** the requested edit, preserved unrelated material, successful
rendering and a document that opens correctly—not merely a generated `.docx` path.

**Observed result:** `test-ros-agent.docx` fills the supplied ROS template with
repository-grounded current-state and residual-risk entries. The original is
unchanged; runtime integrity verification and independent review passed. Native
Word produced two pages, both visually checked by the supervising assistant.
The trial required runtime fixes and render-only recovery, so it does **not**
establish unattended reliability. See [commands, limits and trial evidence](docs/document-workflow.md).

## Next — refine what those trials expose

### Reliability and visibility

- [ ] Rerun the document workflow from a clean launch without development-time
  intervention; exercise denial/cancellation and partial-render recovery.
- [ ] Integrate page-image inspection and an evidence-backed final handoff into
  the harness, rather than relying on an external supervising assistant.
- [ ] Review both trials for false completion, repeated questions, idle-looking
  activity and confusing failures. Prioritize observed friction, not hypothetical
  architecture work.
- [ ] Make “what changed / why / what is unfinished” the primary handoff and
  overview. Connect each assertion to inspectable artifact or runtime evidence.
- [ ] Make individual-agent assignments, results, decisions and handoffs easy to
  follow without requiring the user to read the full event stream.
- [ ] Test interruption, cancellation and reconnect around the actual coding and
  document workflows, including partially completed artifacts.

### Runtime feel: live updates and sandboxed execution

- [ ] Move Desk (and the Observatory) off full-page POST/reload and one-second
  snapshot polling onto Phoenix LiveView, so turn progress, tool calls and
  token streaming render live instead of waiting for a refresh or a poll tick.
- [ ] Add an optional sandboxed code-execution tool with swappable backends
  (Docker, macOS Seatbelt, Linux Bubblewrap), selected per host, so agents can
  run and verify code without assuming one container runtime is available
  everywhere. Surface which backend ran a given execution.

Neither item has evidence yet; both are candidates to try, not commitments.
### Sandboxed command execution

- [x] Host-selected command sandbox backends, with macOS Seatbelt as the first
  enforcing backend. `run_command` and verification report `sandbox_backend`.
  Missing backends fail closed; models cannot choose the backend.
- [ ] Add Docker and Linux Bubblewrap backends so the same command/verification
  path can run on hosts without Seatbelt.

### Efficient use of intelligence

- [ ] Establish a baseline of calls, repeated context, retries, elapsed time and
  useful outcomes from the two trials. Treat unreported usage as unknown.
- [ ] Compare solo and delegated execution on the same representative work.
  Include coordination and verification overhead; retain strategies that help.
- [ ] Identify inventory, checks and transformations that need tools but no
  separate model round trip. Reuse evidence only while it remains relevant.
- [ ] Evaluate provider/model selection against actual outcomes, including
  whether cheaper choices increase repair or verification effort.
- [ ] Clarify which provider accounts/resources a deployment uses before building
  quota behavior. Do not assign the owner's personal Codex allowance to workers
  by assumption, or infer permission to switch to separately billed credentials.

No quota dashboard or elaborate optimization system is a prerequisite for the
first two deliveries. Existing configurable capacity and safety limits stay useful.

## Then — continuity without rigid memory

- [ ] Start with small readable workspace notes for goals, observations, choices,
  rejected ideas and open questions. Avoid duplicating the same knowledge in
  several competing files.
- [ ] Include provenance, dates and uncertainty where they matter; keep credentials
  and sensitive content out of shared notes.
- [ ] Retrieve relevant knowledge without loading every historical note into each
  model call. Recheck change-sensitive facts against the workspace.
- [ ] Try a session where the user reverses an earlier decision. The agent should
  adapt, explain the changed understanding and preserve useful history—not argue
  that an old note is a specification.
- [ ] Try another tool reading the same notes. Check whether it understands their
  provisional nature and avoids repeating already answered questions.

## Later — accountable background missions

Start with one opt-in mission in one workspace before managing a fleet.
The [documentation observer](docs/documentation-missions.md) now provides a bounded
read-only first slice. These checks do not claim proactive edit delivery.

- [x] Define a mission's purpose, scope, reporting coordinator and permitted
  actions. Candidate modes: documentation, regressions, analysis/goal discovery.
- [x] Observe changes without model calls. Experiment with checkpoints, quiet periods and
  change coalescing before invoking models; distinguish unfinished from forgotten.
- [x] Deduplicate repeated observations and test that continuous edits do not
  cause repeated expensive analyses of essentially the same change.
- [x] Prepare user-requested documentation fixes in isolated, snapshot-seeded
  worktrees; record the source revision/fingerprint and reject stale findings.
  Automatic integration and live-model usefulness remain unproven.
- [x] Report advisory findings to the coordinating runtime's durable history.
  Suggestions are not automatic authority to execute goals; model steering is separate.
- [x] Start, pause, resume and dismiss the read-only documentation observer from
  ION and Desk using the shared runtime; show reports and synchronize state.
- [ ] Design isolated-edit review/apply controls; learn from rejected suggestions
  without making those rejections permanent bans.
- [ ] Test coexistence with another editor/agent actively changing the workspace,
  plus coordinator restarts, stale proposals and cancellation.

**Useful trial:** another tool finishes a feature without updating documentation.
The mission notices once, prepares a relevant isolated edit and explains it.
When that tool is merely still working, the harness avoids redundant activity.

## Horizon — a personal control center and trusted machines

- [ ] Keep workspace-local entry useful for both repositories and document folders.
- [ ] Explore a separate personal overview that can discover/attach to multiple
  workspaces and their persistent missions through runtime APIs.
- [ ] Show changes, decisions and unfinished work across those workspaces, then
  drill into a workspace, mission or agent without duplicating execution authority.
- [ ] Define lifecycle and knowledge/privacy boundaries between workspace
  coordinators and the personal center. Decide interface and packaging from use.
- [ ] Prototype an authenticated worker on one other trusted machine. Prove
  artifact transfer, provenance, cancellation, disconnect recovery and duplicate
  result handling before claiming distributed execution.
- [ ] Keep races, tournaments and other strategies available where their outcomes
  justify their extra work; they are options, not mandatory orchestration stages.

## How to keep this useful

Pick the next smallest experiment that teaches us something important. Record
its result with links to durable evidence, revise the relevant belief in
[VISION.md](VISION.md), and reorder this list when the evidence calls for it.
Do not turn a checked box into proof of permanent correctness or an unchecked
box into a reason to ignore the user's current goal.

The [earlier roadmap](docs/roadmap-history.md) preserves detailed prior ideas and
implementation claims for reference. It is not a second active task list.
