# Task-based teams

Automatic team mode now asks the owner to propose independent deliverables through
the existing `delegate_tasks` graph API. The runtime validates the graph and
constructs supervised subagents; model text cannot grant tools, filesystem access,
provider eligibility, or resources. This replaces the fixed two-cheap-helper
launcher. Same-model siblings need no special provider support.

## Capacity and work ownership

- There is no four-task input ceiling. Logical nodes stay data until the graph
  executor can admit them. Coordinator/investigator graph parallelism follows the
  goal worker budget; focused/implementation/verification sequences remain ordered.
- `--max-workers N` sets simultaneous non-root allocations per goal.
  `--model-concurrency N` sets slots in each project model pool. Both default to 4;
  neither has a hard maximum. The model pools include owner calls, whereas the
  worker budget excludes the root. Defaults are conservative policy, not discovered
  hardware capacity. Multiple pools can run concurrently; these are not a global
  requests-per-minute or account quota.
- The runtime API equivalents are `budget: %{concurrent_workers: N}` and
  `resource_limits: %{model: M, expensive_model: M}` on session/project creation.
  Existing goals/project pools are not dynamically resized by these startup options.
- Graph work waits for worker capacity held by other work in the same goal. Queued
  requests are monitored and consume no allocation or attempt until admitted.
  Low-level `spawn_worker` and `spawn_subagent` remain fail-fast when full; use a
  graph for managed fan-out, or collect/cancel existing background workers first.
- Model invocations use the existing monitored project queues. One direct child
  can borrow a slot from a parent holding a model lease while synchronously awaiting
  delegation, preventing parent/child deadlock without unbounded fan-out.
- A nested coordinator cannot wait for a worker slot held by its own ancestors:
  nested allocation exhaustion remains an explicit failure. Delegation-depth limits
  and non-delegating implementation/evidence leaves are unchanged.
- Multiple implementation tasks require disjoint `capabilities.paths` or explicit
  dependency handoffs. Path authority limits reads as well as writes. Shared files,
  scaffolding and final integration need one owner. Runtime path leases, command
  sandboxing and evidence-backed completion remain enforced.
- Mandatory review still requires a capable reviewer; diversity is not a quality
  guarantee. Races, tournaments and isolated worktrees retain their existing APIs.

## Lifecycle and visibility

Turn-owned graphs monitor their originating turn. Cancel/exit stops runners and
their workers and removes queued reservations; cancellation is durable. Standalone
runtime work runs remain resumable. Worker reservations are reclaimed if their
caller dies during construction; allocated actors are monitored independently.

The existing work-run/task/delegation events remain authoritative for both TUIs.
`worker_queued`, `worker_dequeued` and `worker_queue_cancelled` add capacity evidence.
ION displays queue waits and task starts; the progress monitor distinguishes queued
workers from active inference. Old helper events still replay.

This does not discover provider quotas, enforce cross-project account limits, add
network worker dispatch, or make arbitrary recursive spawning safe. Workers execute
on the local OTP runtime, even when inference uses a remote provider.

## Verification

Deterministic fake-provider tests exercise one owner plus six simultaneous workers
on one endpoint/model, draining six tasks through two worker slots, cancellation
of active and queued graphs, permission restrictions, overlap rejection and
provisional allocation cleanup. No paid-provider evaluation is implied by those
tests. Task selection/usefulness still depends on the model proposing a good graph.
