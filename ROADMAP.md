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

Models are resources available to the runtime, not the identity of an agent.
Users should primarily specify goals. The runtime should decide when work is
deterministic, when intelligence is needed, which available model is suitable,
and whether useful work can proceed concurrently.

```text
Agent = process + goal + state + capabilities + mailbox + available intelligence

Harness = processes + supervisors + tools + models + events + policies + schedulers
```

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

This is a useful foundation, but it is still session- and model-loop-centered.
A session currently resolves one provider profile, and child agents inherit it.
The next architecture should preserve the proven supervision and persistence
mechanisms while making projects, goals, workers, models, and resources explicit
runtime concepts.

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

## Work order

### Foundation

1. [x] Context budgeting and durable compaction

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

2. [x] Establish project and goal runtime boundaries

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

3. [ ] Define the event and message architecture

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

4. [ ] Promote provider profiles into a model registry

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

5. [ ] Separate the runtime API from every interface

   - Extract the current controller boundary into an interface-neutral local
     runtime API for goals, subscriptions, approvals, cancellation, inspection,
     and reconnect.
   - Make the TUI and line client consumers of the same public contracts used by
     future LiveView, editor, and programmatic clients.
   - Preserve append-only replay so a disconnected client can reconstruct state
     and continue from a known event sequence.

6. [ ] Add resource-specific permissions and capability envelopes

   - Replace the broad risky-tool choice with decisions scoped to a tool,
     command family, path, host, MCP server, model class, or other resource.
   - Add an explicit durable `allow always` choice with inspectable storage and
     revocation.
   - Give each goal and worker an immutable capability envelope. Delegation may
     preserve or reduce authority but must not silently increase it.
   - Keep workspace confinement, observed-state edits, secret handling, audit
     events, and fail-closed sandbox behavior independent of model decisions.

7. [ ] Add MCP servers as supervised resources

   - Start with local stdio servers owned by the narrowest appropriate project
     or goal resource supervisor.
   - Add discovery, namespaced tools, lifecycle events, health, cancellation,
     timeouts, and explicit capability failures.
   - Route MCP calls through the same capability and scheduling boundaries as
     native tools.
   - Add remote transports only after local ownership, recovery, and credential
     boundaries are proven.

### Intelligence

8. [ ] Introduce automatic model routing

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

9. [ ] Capture model and task outcomes

   - Record task type, language, repository identity, model, latency, normalized
     usage, estimated cost, retries, failures, and cancellation.
   - Attach verification outcomes such as tests, diagnostics, review findings,
     acceptance checks, and user correction instead of equating a model response
     with success.
   - Define stable outcome records before building learned routing.
   - Make retention, redaction, export, and opt-out behavior explicit.

10. [ ] Improve routing from evidence

    - Compare models by task and environment rather than seeking one globally
      best model.
    - Use minimum sample sizes, recency, confidence, and exploration limits so
      sparse or stale measurements do not masquerade as certainty.
    - Keep rule-based routing as a debuggable fallback and permit per-project
      exclusions or preferences.
    - Evaluate routing quality offline before allowing learned policy to change
      production choices automatically.

### Agent runtime

11. [ ] Make supervised task decomposition first-class

    - Add named planner, research, implementation, verification, review, and
      custom worker roles without hard-coding one universal workflow.
    - Give every child a bounded goal, parent, capability set, budget, priority,
      lifecycle, structured result channel, and completion criteria.
    - Support dynamic spawn, cancellation, clean retry, and semantic escalation
      while isolating operational failures to the smallest useful subtree.
    - Do not require an LLM for deterministic coordination or state transitions.

12. [ ] Build distributed working context

    - Let repository, Git, diagnostics, tests, goals, and files own or derive the
      knowledge for which they are authoritative.
    - Add a context service that assembles task-specific, provenance-bearing
      views on request instead of broadcasting full project state to workers.
    - Track freshness, source, size, and invalidation for every context artifact.
    - Keep prompts as disposable projections of runtime knowledge, not the
      system's memory.

13. [ ] Add reactive repository intelligence

    - Maintain a project-level repository snapshot and react to filesystem and
      Git changes rather than repeatedly rediscovering the tree.
    - Incrementally update symbols, dependencies, diagnostics, test relations,
      recent modifications, and active-goal ownership where evidence supports
      doing so.
    - Prefer shared indexes with explicit invalidation over one process per file
      unless a file truly needs an independent lifecycle or contention boundary.
    - Prevent stale analysis from overwriting results derived from newer file
      versions.

14. [ ] Strengthen the deterministic coding substrate

    - Add patch-native edits, Git-aware inspection, streamed shell execution,
      language-aware symbols and diagnostics, and structured test results.
    - Preserve observed-state checks, bounded output, workspace confinement,
      typed durable results, and explicit cancellation.
    - Publish repository, diagnostic, and test changes as runtime events so
      interested workers can react without polling or prompt rediscovery.

15. [ ] Govern resources and apply backpressure

    - Add separately configurable pools for LLM calls, expensive reasoning,
      shell commands, tests, browsers, MCP calls, embeddings, and CPU-heavy jobs.
    - Schedule with explicit priority, budget, rate limit, user-interaction
      latency, and machine-resource constraints.
    - Queue or reject work predictably when capacity is exhausted; autonomous
      workers must not create unbounded process or external-service load.
    - Make budget warnings, blocking reasons, queue time, cancellation, and
      resource use observable.

### Advanced capabilities

16. [ ] Isolate implementation workers with Git worktrees

    - Give concurrent or risky coding workers explicit worktree ownership and a
      restricted writable scope.
    - Track base revision, changed files, commands, tests, and produced patch as
      structured worker output.
    - Make cleanup reliable and make abandoned work recoverable or deliberately
      disposable.

17. [ ] Support speculative execution and evaluation

    - Implement `spawn alternatives -> evaluate -> collapse` for tasks where the
      expected value justifies extra cost.
    - Support competing implementations, debugging hypotheses, plans, tests, and
      reviews using different models or strategies.
    - Evaluate candidates with deterministic checks first, then independent
      review or model judging where necessary.
    - Never merge a winner implicitly; retain provenance and require the same
      capability and approval checks as ordinary implementation.

18. [ ] Extend capability security across the process hierarchy

    - Enforce capability inheritance at runtime rather than relying only on
      prompts or role names.
    - Separate filesystem, Git, shell, network, browser, MCP, model, secret, and
      approval authority.
    - Bind resource handles to worker identity and revoke them when the owning
      process terminates.
    - Add adversarial tests for confused-deputy behavior and authority expansion.

19. [ ] Explore distributed execution across BEAM nodes

    - Distribute only after local process ownership, event identity, scheduling,
      and capability boundaries are stable.
    - Define node trust, code/version compatibility, data locality, partitions,
      reconnection, and duplicate-work semantics before moving workers remotely.
    - Preserve one observable goal tree even when execution spans nodes.

### Product layer

20. [ ] Expose the live process and task tree

    - Show each goal and worker's purpose, state, parent and children, selected
      model, tools, touched files, usage, cost, duration, failures, restarts,
      queueing, and blocking reason.
    - Make routing decisions, capability boundaries, approvals, and event
      provenance inspectable without exposing secrets or private reasoning.
    - Build on the runtime event stream rather than adding interface-owned state.

21. [ ] Build a LiveView control plane

    - Add project and goal views, live task trees, approvals, cancellation,
      budgets, event inspection, model routing visibility, and result review.
    - Keep the web application a client of the runtime API so closing a browser
      never owns or terminates autonomous work accidentally.

22. [ ] Add CLI, editor, and external API clients

    - Continue improving the TUI as the primary near-term interface.
    - Add stable CLI automation, then Emacs/VS Code integrations and an external
      API over the same goal, event, approval, and cancellation contracts.
    - Support reconnect and multiple simultaneous observers consistently.

23. [ ] Persist useful project intelligence

    - Retain validated repository summaries, model/task outcomes, test history,
      dependency knowledge, and project preferences across goals.
    - Store provenance, freshness, confidence, and invalidation rules so cached
      knowledge can be challenged by current code and runtime evidence.
    - Avoid turning old model conclusions into an unquestioned second source of
      truth.

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
