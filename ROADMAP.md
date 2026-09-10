# BeamAgent — next experiments

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
cross-machine dispatch product. Persistent missions and a personal control center
remain future work.

## Now — earn trust with two real deliveries

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

- [ ] Choose a real, non-sensitive Word document and a meaningful edit. Start
  from a copy; note the content and formatting that should remain unaffected.
- [ ] Inspect existing tools/skills and choose the smallest viable editing and
  rendering path. Make its dependencies and supported platforms visible.
- [ ] Make the edit through the guarded runtime workflow and retain the original.
- [ ] Render and inspect the output, including affected pages, tables, images,
  pagination and styles where relevant. Check the file's structural integrity.
- [ ] Open the result in the intended document application, or explicitly record
  that this check still needs the user. Do not imply rendering proves every editor.
- [ ] Deliver the edited document with a concise change summary and remaining
  issues. Capture a reusable regression fixture from any corruption/layout failure.

**Evidence we want:** the requested edit, preserved unrelated material, successful
rendering and a document that opens correctly—not merely a generated `.docx` path.

## Next — refine what those trials expose

### Reliability and visibility

- [ ] Review both trials for false completion, repeated questions, idle-looking
  activity and confusing failures. Prioritize observed friction, not hypothetical
  architecture work.
- [ ] Make “what changed / why / what is unfinished” the primary handoff and
  overview. Connect each assertion to inspectable artifact or runtime evidence.
- [ ] Make individual-agent assignments, results, decisions and handoffs easy to
  follow without requiring the user to read the full event stream.
- [ ] Test interruption, cancellation and reconnect around the actual coding and
  document workflows, including partially completed artifacts.

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

- [ ] Define a mission's purpose, scope, reporting coordinator and permitted
  actions. Candidate modes: documentation, regressions, analysis/goal discovery.
- [ ] Observe changes cheaply. Experiment with checkpoints, quiet periods and
  change coalescing before invoking models; distinguish unfinished from forgotten.
- [ ] Deduplicate repeated observations and test that continuous edits do not
  cause repeated expensive analyses of essentially the same change.
- [ ] Prepare proactive edits in isolation and record the source revision or
  document version. Revalidate relevance before presenting or integrating them.
- [ ] Report findings, proposed goals and unfinished work to the coordinator.
  A proposed goal is not automatic authority to execute it.
- [ ] Design review/apply/dismiss/pause controls; learn from rejected suggestions
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
