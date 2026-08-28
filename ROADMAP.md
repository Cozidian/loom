# BeamAgent roadmap

Updated: 2026-08-27

BeamAgent is evolving into an OTP-native runtime for autonomous software work:
a fault-tolerant, observable, and concurrent system where specialized processes
collaborate on goals and dynamically use the best available intelligence for
each piece of work.

This is an evolving product work order, not a frozen specification. Completed
work keeps its implementation evidence; later items should change as real use
produces better evidence.

## North star

Build a living software runtime where goals dynamically create supervised,
fit-for-purpose agents. Each agent receives only the context, intelligence,
resources, and authority it needs; it may form new specialists as problems
emerge and disappears when its purpose is complete.

Models are resources available to the runtime, not the identity of an agent.
Users should primarily specify goals. The runtime should decide which actors
are needed, when work is deterministic, when intelligence is needed, which
available model is suitable, and whether useful work can proceed concurrently.

```text
Agent = process + goal + instructions + context + capabilities + constraints
        + resources + intelligence + lifecycle

Harness = processes + supervisors + tools + models + events + policies + schedulers
```

The project is persistent. Agents are dynamically constructed, specialists
emerge on demand, and workers are disposable. Authority is explicit,
intelligence is a resource, autonomy is earned, failure is cheap, and
verification unlocks action.

OTP is the runtime model, not a reason to turn every module into a `GenServer`.
A process is warranted when a component benefits from an independent lifecycle,
state, failure or cancellation boundary, concurrency model, or observability
surface. Pure transformations and deterministic computations should remain
ordinary functions and modules.

## Current baseline

BeamAgent already has durable supervised sessions, recursive child sessions,
multiple LLM provider adapters and named profiles, guarded coding tools, project
skills, live streaming, approvals, a Charm-based Go TUI, and a line-oriented
terminal client. The append-only session event log is canonical, agents rebuild
their model projection after a crash, and in-flight turns are supervised and
cancellable. Session-scoped auto mode can approve all risky tool requests for
an active chat; the default remains ask.

The runtime now has explicit project and goal boundaries. Every intelligence
request can route across the project's registered endpoints; child agents
inherit a default profile and capability envelope rather than being bound to
that model. Sessions and the sequential model/tool loop still carry more
coordination responsibility than the target worker architecture. The next
slices should preserve the proven supervision and persistence mechanisms while
making specialized workers, distributed context, and governed resources more
explicit.

## Target runtime shape

The target is a hierarchy of long-lived project resources and ephemeral goal
workers. This tree is illustrative: each box only becomes a process when it
needs an independent runtime boundary.

```text
BeamAgent
├── Model Registry
├── Runtime Scheduler
└── Projects
    └── Project
        ├── Repository / Git / Index / Diagnostics / Test State
        ├── Project Context
        ├── Model Router
        ├── Budget Manager
        └── Goals
            └── Goal
                ├── Planner
                ├── Investigation workers
                ├── Implementation workers
                ├── Verification workers
                └── Review workers
```

Long-lived project processes retain reusable repository and operational state
across goals. Ephemeral goal processes own one objective, their child workers,
budgets, capabilities, cancellation, and completion. OTP supervision answers
whether a worker is healthy; goal-level coordination answers whether it is
doing the right work.

The named workers above are examples, not a fixed organization. The runtime
should be able to construct a specialist that did not exist as a predefined
persona or workflow when the project was built.

## Dynamic agent construction

Agents are ephemeral OTP processes populated at runtime for the problem that
caused them to exist. The process is the vessel; the goal explains why it
exists; instructions guide behavior; context supplies current knowledge;
capabilities determine what it can actually do; resources bound its cost and
lifetime; the model router supplies appropriate intelligence; and supervision
owns its lifecycle.

```text
Agent
├── Goal
├── Role / Instructions
├── Context
├── Capabilities
├── Restrictions
├── Resources / Budget
├── Model Requirements
├── Verification Requirements
└── Lifecycle
```

### Dynamic population

Worker construction should be a runtime decision derived from current state,
not merely selection from a static list of personas.

```text
Current Goal
      +
Parent Worker
      +
Project State and Available Context
      +
Capability Policy and Available Resources
      +
Agent Templates / Execution Strategies
      ↓
Runtime Agent Instance
```

The resulting instance may receive a dynamically constructed role, bounded
goal, instructions, relevant context, tools, capability envelope, filesystem
and network scope, restrictions, budget, deadline, model requirements, and
verification requirements.

Workers with delegation authority may request more workers when they discover
that additional expertise, isolation, or parallel work is useful. Those workers
may delegate again when policy permits, allowing an organization to emerge from
the problem rather than being declared in advance.

```text
Authentication Investigator
├── PostgreSQL Concurrency Specialist
│   └── Ecto Transaction Researcher
├── Git History Investigator
└── Reproduction Worker
```

A delegation request describes the desired specialist and requested authority;
it does not grant that authority. A worker may request a database specialist
with `database.schema.read`, but runtime policy decides whether that capability
is granted, narrowed, leased temporarily, escalated for approval, or denied.

### Templates are starting points

Researcher, Implementer, Reviewer, Debugger, Test Investigator, and Security
Reviewer are reusable templates or execution strategies, not the complete
population of possible agents.

```text
Template + Goal + Context + Capabilities + Constraints + Budget + Policy
                              ↓
                    Specialized Agent Instance
```

The runtime must also be able to construct a new specialist on demand, such as
a BEAM Scheduler Investigator with telemetry-read and repository-read authority,
a small context, and a model requirement for strong Elixir/BEAM reasoning.

### Soft configuration and hard authority

Maintain a strict boundary between proposals made by intelligence and controls
owned by the runtime.

Soft configuration may be generated dynamically:

- role, prompt, instructions, and reasoning strategy;
- context selection and requested expertise;
- decomposition and delegation proposals.

Hard configuration remains runtime- and policy-controlled:

- actual tools and capabilities;
- filesystem, network, credential, secret, and production access;
- model eligibility, budget, sandbox, deadline, lifetime, and delegation depth;
- approval and verification gates.

Prompts describe behavior. Capabilities determine reality. Delegation may
request additional authority but cannot acquire it by changing instructions.

### Cheap specialists and dynamic organization

Agent creation should be inexpensive. A worker may live for ten seconds to
identify files, thirty seconds to classify an error, two minutes to test one
hypothesis, or longer to implement and coordinate a bounded change. Narrow
goals, small contexts, limited capabilities, inexpensive models, and explicit
budgets should make disposable specialists preferable to one indefinitely
expanding conversation.

```text
Signal / User Request
 ↓
Goal
 ↓
Determine required work
 ↓
Construct initial agent
 ↓
Populate goal, instructions, context, capabilities, constraints,
resources, intelligence, and verification requirements
 ↓
Work discovers additional need?
 ├── no  ───────────────────────────┐
 └── yes → request worker           │
             ↓                      │
          policy evaluation         │
             ↓                      │
          populate and delegate ────┘
 ↓
Verify → record outcome and useful knowledge → terminate organization
```

As the runtime evolves, apply this architectural test:

> Can the runtime dynamically construct the actors it needs, give each one an
> explicit goal, only the context and authority required for that goal, and
> safely destroy them when their purpose is complete?

Retain the broader OTP test:

> Can this be expressed as an actor responding to a signal, pursuing a goal
> using explicitly granted capabilities and resources?

## Work order

The phase numbers express architectural dependency groups, not a rule that
every earlier item must finish before a high-value safety slice. Based on the
2026-08-27 autonomous `/tree` experiment, item 21 (verified completion) is the
immediate next implementation priority; item 1 (runtime agent representation)
should follow on the stronger execution substrate.

### Delivered platform foundations

- [x] Context budgeting and durable compaction

   - Estimate the complete model request, including system instructions, tool
     schemas, messages, and tool results.
   - Compact only completed turns so assistant tool calls never separate from
     their tool results.
   - Keep the append-only event log canonical and persist summaries as new
     events, making the projection reconstructable after restart.
   - Fall back to the full projection if the summarizer fails.
   - Expose usage in `/status` and the TUI, plus manual `/compact` and CLI
     configuration for the window and threshold.
   - Evidence: `BeamAgent.Session.ConversationContext`, the tool-loop projection
     path, config migration version 5, and `test/conversation_context_test.exs`.

- [x] Establish project and goal runtime boundaries

   - Introduce one supervised project runtime per canonical workspace, separate
     from the lifecycle of an individual conversation or goal.
   - Define which state is project-lived, goal-lived, worker-lived, or durable
     data rather than process state.
   - Let a goal own an ephemeral supervised worker tree with explicit shutdown,
     cancellation, restart, and result semantics.
   - Migrate in vertical slices; do not replace the working session tree in one
     large rewrite.
   - Validate recovery at every boundary, including project-resource failure,
     goal-coordinator failure, and disposable worker failure.
   - Evidence: `BeamAgent.ProjectRootSupervisor`, `BeamAgent.ProjectSupervisor`,
     `BeamAgent.GoalSupervisor`, inherited child-session identity, and
     `test/project_goal_runtime_test.exs`.

- [x] Define the event and message architecture

   - Create a versioned runtime event envelope with goal, worker, causation, and
     correlation identity plus timestamps and typed payloads.
   - Distinguish commands, durable facts, ephemeral progress, and point-to-point
     process messages instead of treating every mailbox message as a public
     event.
   - Cover repository changes, tool and model activity, budgets, task state,
     review findings, failures, retries, and completion.
   - Provide replay plus live subscriptions without making one giant process or
     one giant model context the owner of all knowledge.
   - Keep sensitive tool input, credentials, and excessive model content out of
     broadly visible events by default.
   - First vertical slice delivered: `BeamAgent.RuntimeEvent` defines a
     versioned, goal-scoped projection over canonical session events;
     `BeamAgent.Goal.EventHub` reconstructs and streams parent and child
     activity; and the TUI renders meaningful lifecycle information plus a
     latest-events view. Repeated identical tool results now emit an observable
     `tool_loop_stalled` recovery event instead of creating unbounded work.
     A second slice adds versioned runtime commands, durable goal-wide
     sequences, causal/correlation lineage across subagents, and atomic
     replay-plus-live subscriptions from a cursor. A third slice makes public
     replay and subscriptions fail-closed by default, redacting prompts, model
     content, tool data, errors, paths, and unknown payload fields while
     retaining an explicit trusted internal projection for the local TUI.
     The final slice adds a runtime-owned, filterable public inspector covering
     category, type, worker/session, lineage, cursor range, redaction state,
     ordering, and bounded limits, exposed through the TUI's `/events` command.

- [x] Promote provider profiles into a model registry

   - Keep `BeamAgent.LLMProvider` as the provider protocol seam while registering
     many usable model endpoints simultaneously.
   - Describe model capabilities, modalities, context limits, cost hints,
     locality, privacy constraints, health, and availability separately from
     credentials and provider transport.
   - Give model invocations explicit request, cancellation, timeout, streaming,
     normalized usage, and error contracts.
   - Distinguish configured capability claims from measurements learned by this
     runtime.
   - Treat the current fixed profile per session as a supported manual override,
     not the eventual default architecture.
   - First vertical slice delivered: every configured CLI profile is registered
     simultaneously in a project-owned `ModelRegistry`, separate from the
     global provider adapter catalog. Endpoint descriptors carry model,
     transport, credential reference, capability/modalities, locality, privacy,
     context/cost hints, health, and a distinct measurements field. Supervised
     asynchronous health checks update availability, `/models` exposes the
     inventory in the TUI, and the selected session profile remains the manual
     override. A versioned `ModelRequest` plus normalized response, usage, and
     error contracts now covers streaming and non-streaming calls, optional
     finite timeouts, provider failures, and owner-process cancellation. Both
     tool-loop work and context compaction use the same invocation boundary.

- [x] Separate the runtime API from every interface

   - Extract the current controller boundary into an interface-neutral local
     runtime API for goals, subscriptions, approvals, cancellation, inspection,
     and reconnect.
   - Make the TUI and line client consumers of the same public contracts used by
     terminal, web, editor, and programmatic clients.
   - Preserve append-only replay so a disconnected client can reconstruct state
     and continue from a known event sequence.
   - First vertical slice delivered: `BeamAgent.Runtime` now exposes a public,
     interface-neutral connection contract over a goal. A runtime client owns
     atomic replay plus live subscription, durable cursors, asynchronous turn
     submission, approvals, cancellation, status, event inspection, model
     inventory access, and rebinding to another or resumed session. Public
     connections receive the fail-closed event view by default; trusted local
     clients opt into the internal view. The TUI controller and line-oriented
     turn runner both consume this contract rather than independently owning
     turn tasks and subscriptions. Disconnecting leaves runtime work under OTP
     ownership, and a replacement client can replay only facts after its last
     cursor.

- [x] Add resource-specific permissions and capability envelopes

   - Replace the broad risky-tool choice with decisions scoped to a tool,
     command family, path, host, MCP server, model class, or other resource.
   - Add an explicit durable `allow always` choice with inspectable storage and
     revocation.
   - Give each goal and worker an immutable capability envelope. Delegation may
     preserve or reduce authority but must not silently increase it.
   - Keep workspace confinement, observed-state edits, secret handling, audit
     events, and fail-closed sandbox behavior independent of model decisions.
   - Delivered: immutable `CapabilityEnvelope` values cover tool, path, command,
     host, MCP-server, and model-class authority. Child workers inherit or
     explicitly narrow authority; escalation is rejected. `allow_always` stores
     an exact scoped permission in the canonical session log, survives restart,
     is inspectable and revocable, and is available in both terminal clients.
     Capability denial runs before approval and never bypasses workspace,
     observed-state, or sandbox enforcement.

- [x] Add MCP servers as supervised resources

   - Start with local stdio servers owned by the narrowest appropriate project
     or goal resource supervisor.
   - Add discovery, namespaced tools, lifecycle events, health, cancellation,
     timeouts, and explicit capability failures.
   - Route MCP calls through the same capability and scheduling boundaries as
     native tools.
   - Add remote transports only after local ownership, recovery, and credential
     boundaries are proven.
   - Delivered: each goal owns a dynamic resource supervisor and MCP registry.
     Local stdio servers initialize and discover tools under supervised
     processes, publish namespaced `mcp__server__tool` schemas, expose health,
     use bounded requests, receive cancellation when their calling worker exits,
     start with a scrubbed environment plus explicit variables, and emit durable
     lifecycle events. MCP execution passes through the same capability and
     approval boundary as native tools. Remote transports remain deferred.

### Delivered intelligence foundations

- [x] Introduce automatic model routing

   - Make `Auto` the preferred strategy while retaining specific model/provider,
     local-only, and custom-strategy overrides.
   - Route each intelligence request rather than binding the entire agent to one
     model for its lifetime.
   - Start with inspectable deterministic policy based on task type, language,
     reasoning demand, context size, latency, cost, availability, and privacy.
   - Allow the router to choose no model when Git, parsers, indexes, diagnostics,
     tests, or ordinary code can answer more reliably.
   - Record the candidates, decision inputs, selected model, and reason without
     exposing hidden reasoning or secrets.
   - Delivered: the project-owned `ModelRouter` selects an endpoint for every
     request. CLI configuration version 8 makes `auto` the default and supports
     `manual`, `local_only`, and programmatic custom strategies. The initial
     deterministic policy considers task and language classification, reasoning
     demand, context fit, measured latency, cost, health, locality/privacy, and
     capability envelopes. Exact arithmetic can select ordinary computation
     instead of an LLM. Every decision records safe inputs, candidates,
     selection, strategy, and a concise reason; the TUI renders it inline.

- [x] Capture model and task outcomes

   - Record task type, language, repository identity, model, latency, normalized
     usage, estimated cost, retries, failures, and cancellation.
   - Attach verification outcomes such as tests, diagnostics, review findings,
     acceptance checks, and user correction instead of equating a model response
     with success.
   - Define stable outcome records before building learned routing.
   - Make retention, redaction, export, and opt-out behavior explicit.
   - Delivered: a project-owned `OutcomeStore` persists a bounded append-only
     outcome ledger with stable, content-free model and task records. It stores
     repository/goal identity, task type, language, endpoint/provider/model,
     latency, normalized usage, cost hint, retries, status, failure, and
     cancellation. Verification is an independently attached fact, initially
     `unverified`; public APIs support inspection, attachment, export, restart
     recovery, retention limits, and complete telemetry opt-out. The routing
     evidence work below consumes these measurements in shadow mode without
     changing live choices.

### Foundation

1. [x] Define the runtime agent representation

   - Introduce an interface-neutral `AgentSpec` or equivalent value describing
     goal, role, instructions, context references, requested capabilities,
     restrictions, resource limits, model requirements, verification contract,
     parent, and lifecycle policy.
   - Keep the specification separate from process state and durable results.
   - Make provenance explicit: which fields came from the user, parent worker,
     template, policy, project defaults, or runtime decision.
   - Delivered: `BeamAgent.AgentSpec` is a validated, interface-neutral value
     separate from process state and outcomes. It carries goal, role,
     instructions, context references, requested and effective capabilities,
     restrictions, resources, model and verification requirements, parent,
     lifecycle, template, and per-field provenance. Root and child agents expose
     their applied spec through the runtime.

2. [x] Add dynamic agent construction and population

   - Construct fit-for-purpose worker specifications from the current goal,
     parent worker, project state, context, policy, resources, templates, and
     available intelligence.
   - Validate and normalize the specification before starting a process.
   - Emit safe construction events so the resulting configuration and its
     provenance are replayable and inspectable.
   - Delivered: `BeamAgent.AgentConstructor` builds root coordinators and
     fit-for-purpose child specialists from goal classification, optional parent
     proposals, project context, inherited resources/model policy, and immutable
     capability envelopes. Hard fields are runtime-populated; attempted authority
     expansion fails before a process starts. Every request, constructed spec,
     applied spec, failure, and spawn is durable and safely projected. The
     constructed role/instructions populate the child system context, model
     requirements constrain routing, and restricted agents see only tool schemas
     they are authorized to execute.

3. [x] Represent agent templates and execution strategies

   - Treat researcher, implementer, reviewer, debugger, and similar roles as
     composable starting points rather than a fixed population.
   - Allow runtime-generated specialists with no predefined persona.
   - Version templates independently from the dynamically populated instance.

4. [x] Represent capabilities independently from prompts

   - `CapabilityEnvelope` already represents tool, path, command, host, MCP,
     and model-class authority as runtime data.
   - Continue extending this representation without allowing instructions or
     model output to become an authorization mechanism.

5. [x] Make worker execution capability-aware

   - Existing root and child sessions enforce capability envelopes before
     approvals and tool execution.
   - Generalize this proven boundary to every dynamically constructed worker
     and resource handle.

6. [x] Formalize the soft-configuration / hard-authority boundary

   - Define which worker fields intelligence may propose and which only policy
     may set or narrow.
   - Record requested versus effective hard configuration and a concise policy
     decision without leaking sensitive values.
   - Reject prompt-based attempts to grant tools, credentials, production
     access, budget, lifetime, or deeper delegation.

7. [x] Preserve capability inheritance and attenuation

   - Current child workers inherit or narrow their parent's immutable envelope;
     silent authority expansion is rejected.
   - Preserve this invariant across dynamic construction, templates, retries,
     worktrees, remote nodes, and nested delegation.

8. [x] Add scoped and temporary capability leases

   - Support authority bounded by worker, resource, operation count, deadline,
     or goal phase.
   - Revoke leases automatically when the owning worker or goal terminates.
   - Keep durable grants distinct from temporary runtime leases.

9. [x] Add a capability request and escalation protocol

   - Let workers request missing authority as structured data with purpose,
     scope, duration, and fallback behavior.
   - Route requests through deterministic policy and human approval where
     required; denial must remain a normal observable outcome.
   - Never let a delegate approve its own authority expansion.

10. [x] Represent budgets and resource allocations

    - Give each goal and worker explicit limits for model cost/tokens, wall
      time, retries, concurrency, shell/test use, and other scarce resources.
    - Derive child allocations from the parent's remaining budget and policy.
    - Make consumption, warnings, exhaustion, and release observable.

11. [x] Add secretless capability providers

    - Prefer opaque resource handles, brokered credentials, and narrow service
      capabilities over placing secrets in prompts, worker state, or tool input.
    - Bind handles to worker identity, effective scope, and lifetime.
    - Redact secret material from events while preserving useful audit facts.

### Dynamic runtime

12. [x] Generalize dynamic worker spawning

    - Evolve the existing `spawn_subagent` primitive from prompt-only child
      sessions into validated runtime agent specifications.
    - Start workers under the narrowest appropriate supervisor and return a
      structured handle/result channel rather than only conversational text.
    - Preserve nested spawning, replay, cancellation, and failure isolation.

13. [x] Make agent-to-agent delegation first-class

    - Represent delegation requests, accepted work, progress, result, rejection,
      cancellation, and escalation as explicit messages and events.
    - Give every delegated task a bounded goal and completion criteria.
    - Permit recursive delegation only when the effective capability and budget
      policies allow it.

14. [x] Generate runtime specialists on demand

    - Infer the expertise and model characteristics required for a discovered
      subproblem without requiring a predefined role name.
    - Construct focused instructions and context while runtime policy controls
      actual authority and resources.
    - Retain enough provenance to evaluate whether the specialization helped.

15. [x] Add goal-driven decomposition

    - Let coordinators decompose goals into dependent or parallel bounded work
      without hard-coding one universal workflow.
    - Prefer deterministic dependency/state transitions and use models for the
      semantic decisions that genuinely need intelligence.
    - Re-plan or terminate branches cheaply when evidence invalidates them.

16. [x] Support temporary self-forming worker organizations

    - Allow useful hierarchies to emerge through delegation rather than being
      declared beforehand.
    - Keep purpose, parentage, authority, budgets, blocking state, and result
      flow inspectable throughout the organization.
    - Retain validated results, then terminate and reclaim the ephemeral tree.

17. [x] Add runtime execution strategies

    - Compose sequential, parallel, reviewer, investigator, retry, consensus,
      and deterministic strategies independently from agent identity.
    - Select strategies from goal characteristics, risk, resources, and policy.
    - Keep strategy transitions explicit and observable.

18. [x] Add a model and resource scheduler

    - Coordinate LLM calls, expensive reasoning, shell/tests, browsers, MCP,
      embeddings, and CPU-heavy work through bounded pools.
    - Schedule with priority, cost, rate limits, latency, machine resources, and
      user-interaction needs.
    - Apply backpressure instead of allowing delegation to create unbounded work.

19. [x] Support race-to-solution

    - Spawn competing hypotheses, plans, implementations, tests, or reviews only
      when expected value justifies the extra resources.
    - Evaluate with deterministic evidence first and independent judgment when
      necessary, then collapse losing branches safely.
    - Preserve provenance and never merge a winner implicitly.

20. [x] Complete cancellation and resource reclamation

    - Extend the current cancellable turn and child-session primitives across
      dynamic organizations, model requests, tools, MCP, worktrees, leases, and
      queued resources.
    - Define deadline, parent-death, budget-exhaustion, and user-cancellation
      propagation explicitly.
    - Make cleanup reliable while retaining durable outcomes and diagnostics.

### Runtime trust and supporting intelligence

21. [x] Enforce verified completion

    - Separate `implemented`, `unverified`, `verification_failed`, `verified`,
      and `blocked` instead of equating a final model response with task success.
    - Represent verification requirements in the goal/agent contract and run
      deterministic checks through a dedicated, capability-bounded verifier.
    - Make command exit status trustworthy, prevent pipelines from masking
      failures, provide sandbox-compatible temporary/runtime resources, and
      attach verification evidence automatically.
    - Generate completion reports from recorded evidence and refuse to claim a
      required check ran when no successful event proves it.
    - First vertical slice delivered: a validated `VerificationPlan` loads
      `.beam_agent/verification.json` or discovers conservative Git, Mix, and Go
      checks. `/verify` runs the plan in a disposable goal-supervised verifier,
      streams durable plan/check lifecycle events into the TUI, and attaches the
      result to the latest task outcome. Shell pipelines use `pipefail`, non-zero
      exits are tool errors, and the macOS sandbox provides only loopback IPC
      plus permitted temporary storage so Mix and Go checks can run honestly.
      A model final answer now records `completed/unverified`; attached passing
      evidence promotes it to `succeeded`, while required failures mark it
      `failed`. Applicable completions now trigger verification automatically,
      including worktree-specific checks, and completion reports are derived
      from recorded evidence rather than model claims.

22. [x] Improve routing from evidence

    - Compare models by task and environment rather than seeking one globally
      best model.
    - Use minimum sample sizes, recency, confidence, and exploration limits so
      sparse or stale measurements do not masquerade as certainty.
    - Keep rule-based routing as a debuggable fallback and permit per-project
      exclusions or preferences.
    - Evaluate routing quality offline before allowing learned policy to change
      production choices automatically.
    - First vertical slice delivered: `BeamAgent.RoutingEvidence` computes
      project-local, task- and language-scoped summaries over a bounded recent
      window. Operational reliability and latency remain distinct from model
      quality; quality requires explicit verification and task verification is
      attributed only when one endpoint owned the turn. Minimum verified sample
      sizes, recency weighting, Wilson lower bounds, and confidence prevent
      sparse evidence from looking authoritative. Auto decisions include a
      durable shadow recommendation or an `evidence warming` state, while the
      deterministic policy remains authoritative by default. `/models` exposes
      verified samples, pass rate, call count, and measured latency. Projects
      may explicitly enable confidence-gated evidence routing with deterministic
      bounded exploration, persistent preferences, and endpoint exclusions.

### Supporting runtime systems

23. [x] Build distributed working context

    - Let repository, Git, diagnostics, tests, goals, and files own or derive the
      knowledge for which they are authoritative.
    - Add a context service that assembles task-specific, provenance-bearing
      views on request instead of broadcasting full project state to workers.
    - Track freshness, source, size, and invalidation for every context artifact.
    - Keep prompts as disposable projections of runtime knowledge, not the
      system's memory.

24. [x] Add reactive repository intelligence

    - Maintain a project-level repository snapshot and react to filesystem and
      Git changes rather than repeatedly rediscovering the tree.
    - Incrementally update symbols, dependencies, diagnostics, test relations,
      recent modifications, and active-goal ownership where evidence supports
      doing so.
    - Prefer shared indexes with explicit invalidation over one process per file
      unless a file truly needs an independent lifecycle or contention boundary.
    - Prevent stale analysis from overwriting results derived from newer file
      versions.

25. [x] Strengthen the deterministic coding substrate

    - Add patch-native edits, Git-aware inspection, streamed shell execution,
      language-aware symbols and diagnostics, and structured test results.
    - Preserve observed-state checks, bounded output, workspace confinement,
      typed durable results, and explicit cancellation.
    - Publish repository, diagnostic, and test changes as runtime events so
      interested workers can react without polling or prompt rediscovery.

### Advanced capabilities

26. [x] Isolate implementation workers with Git worktrees

    - Give concurrent or risky coding workers explicit worktree ownership and a
      restricted writable scope.
    - Track base revision, changed files, commands, tests, and produced patch as
      structured worker output.
    - Make cleanup reliable and make abandoned work recoverable or deliberately
      disposable.

27. [x] Support speculative execution and evaluation

    - Implement `spawn alternatives -> evaluate -> collapse` for tasks where the
      expected value justifies extra cost.
    - Support competing implementations, debugging hypotheses, plans, tests, and
      reviews using different models or strategies.
    - Evaluate candidates with deterministic checks first, then independent
      review or model judging where necessary.
    - Never merge a winner implicitly; retain provenance and require the same
      capability and approval checks as ordinary implementation.

28. [x] Harden capability security across every resource hierarchy

    - Extend the existing runtime-enforced worker envelopes to filesystem, Git,
      shell, network, browser, MCP, model, secret, and approval handles.
    - Separate filesystem, Git, shell, network, browser, MCP, model, secret, and
      approval authority.
    - Bind resource handles to worker identity and revoke them when the owning
      process terminates.
    - Add adversarial tests for confused-deputy behavior and authority expansion.

29. [x] Explore distributed execution across BEAM nodes

    - Distribute only after local process ownership, event identity, scheduling,
      and capability boundaries are stable.
    - Define node trust, code/version compatibility, data locality, partitions,
      reconnection, and duplicate-work semantics before moving workers remotely.
    - Preserve one observable goal tree even when execution spans nodes.

### Product layer

30. [x] Expose the live process and task tree

    - Show each goal and worker's purpose, state, parent and children, selected
      model, tools, touched files, usage, cost, duration, failures, restarts,
      queueing, and blocking reason.
    - Make routing decisions, capability boundaries, approvals, and event
      provenance inspectable without exposing secrets or private reasoning.
    - Build on the runtime event stream rather than adding interface-owned state.

    First slice delivered (pure projection + runtime API + /tree):
    - Added BeamAgent.RuntimeGoalTree (pure fold over durable goal events only).
    - Added interface-neutral BeamAgent.goal_tree/1 and Runtime.goal_tree/1.
    - /tree in terminal CLI (chat), TUI command palette and panel render.
    - Compact nested render (Goal/Subagent lines, routed model, last tool, state).
    - Regression tests for root-only, subagent+model, running/failed/cancelled,
      routed vs default model, safe projection, replay equivalence, /tree surfaces.
    - Go TUI remains presentation-only; all state derived in Elixir.
    - Replay/reconnect use the same event fold as live observation.
    - The projection now includes durations, restart counts, verification,
      touched files, worktrees, token/model usage, latency/cost, queueing, and
      blocking state and is shared by terminal, web, and API clients.

31. [x] Build a live web control plane (LiveView-compatible)

    - Add project and goal views, live task trees, approvals, cancellation,
      budgets, event inspection, model routing visibility, and result review.
    - Keep the web application a client of the runtime API so closing a browser
      never owns or terminates autonomous work accidentally.

32. [x] Add CLI, editor, and external API clients

    - Continue improving the TUI as the primary near-term interface.
    - Add stable CLI automation, then Emacs/VS Code integrations and an external
      API over the same goal, event, approval, and cancellation contracts.
    - Support reconnect and multiple simultaneous observers consistently.

33. [x] Persist useful project intelligence

    - Retain validated repository summaries, model/task outcomes, test history,
      dependency knowledge, and project preferences across goals.
    - Store provenance, freshness, confidence, and invalidation rules so cached
      knowledge can be challenged by current code and runtime evidence.
    - Avoid turning old model conclusions into an unquestioned second source of
      truth.

## Completed implementation map

The checked roadmap is backed by runtime code rather than documentation-only
claims:

- `AgentTemplate`, `ExecutionStrategy`, `AgentConstructionPolicy`, and
  `AgentConstructor` construct versioned specialists while keeping requested
  soft configuration separate from effective hard authority.
- Goal-owned capability, secret, budget, delegation, organization,
  decomposition, verification, and race processes provide scoped leases,
  brokered secret handles, bounded resources, recursive delegation, disposable
  organizations, automatic evidence, and explicit branch collapse.
- Project-owned model/resource schedulers, context storage, repository index,
  worktree manager, outcome store, and execution-node registry retain reusable
  state and apply backpressure, freshness, ownership, and trust policy.
- Speculative implementations run in canonical, worker-owned Git worktrees.
  Deterministic checks run inside each worktree, ambiguous passing patches
  require independent review, all patches remain inspectable, and no winner is
  ever merged implicitly.
- `RuntimeGoalTree`, the enriched TUI event projection, `ControlPlane`, the
  authenticated loopback web shell, and the streaming JSON-lines server are
  independent observers of the same durable runtime. `beam_agent serve` starts
  both transports; thin VS Code and Emacs clients consume protocol version 1.
- Proven repository snapshots, symbols/dependencies, test history, routing
  outcomes, and user-owned project preferences persist with provenance,
  freshness, confidence, source versions, and explicit invalidation. Learned
  model evidence remains shadow-only unless the user enables it for a project.

The web shell deliberately keeps Phoenix out of the core dependency graph. A
Phoenix LiveView host can bind directly to `BeamAgent.ControlPlane`; the shipped
loopback UI exercises the same live observer/controller contract without making
the browser process a lifecycle owner.

## Delivery discipline

- Deliver thin end-to-end slices through the real runtime, event stream, and TUI
  before broadening each subsystem.
- Measure routing outcomes before optimizing or learning from them.
- Prefer deterministic computation whenever it can do the work more reliably.
- Make failure isolated, observable, cancellable, and inexpensive; discard a
  confused reasoning context or failed worktree instead of accumulating damage.
- Treat concurrency as a product capability, with bounded resources and clear
  user-visible state, not merely an implementation detail.
- Preserve manual model selection and simple single-worker operation as useful
  fallbacks even as `Auto` and collaborative trees become the primary path.
- Keep the human able to understand what is running, why it is running, what it
  can access, what it costs, and what evidence supports its result.

## Decision notes

- Static personas and workflows are optional templates, not the runtime's agent
  model. Goals and evidence should drive fit-for-purpose construction.
- Intelligence may propose roles, instructions, context, and delegation, but
  only runtime policy may grant authority, resources, secrets, or lifetime.
- A model response is not evidence of successful software work. Verification is
  an independent runtime fact and gates claims or actions that require it.
- The existing session supervisor and event log are foundations to evolve, not
  constraints that every future resource must live inside one conversation.
- Event identity and lifecycle boundaries come before broad autonomous
  concurrency because later routing, observability, and scheduling depend on
  them.
- MCP follows capability and event foundations so external resources inherit
  the same ownership, cancellation, audit, and backpressure model.
- Learned model routing follows outcome collection; configuration claims alone
  are not evidence that a model is effective for a task.
- Distributed BEAM execution follows a correct local runtime. Distribution must
  not hide ambiguous ownership or weaken security boundaries.
- A beautiful TUI remains part of the product throughout the roadmap; visual
  polish continues incrementally instead of blocking runtime foundations.
