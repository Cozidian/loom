# BeamAgent Harness Analysis

## Honest verdict

The instinct that BeamAgent feels "off" is justified, but OTP is not the problem.

BeamAgent currently has a strong control plane—supervision, recovery, capabilities, approvals, event sourcing, and cancellation—but a comparatively weak execution loop. The BEAM owns process lifecycle, while the model still coordinates most real work through prose and repeated tool calls.

That makes it architecturally interesting but operationally worse than Codex, Claude Code, or Grok Build.

The clearest evidence is the recent file-suggestion task:

- 9 related worker sessions
- Roughly 190 model invocations
- Roughly 720 tool calls
- Only 8 file writes
- More than 5 hours of activity
- No successful root completion

That is the "off" feeling in numbers: lots of visible machinery, little forward momentum.

## Why it happens

### 1. The provider integration discards native continuity

The active ChatGPT integration starts a new Codex process and ephemeral thread for every model step, then flattens BeamAgent's conversation into a text transcript. See `lib/beam_agent/codex_app_server.ex`.

It also acknowledges Codex tool requests with "accepted…stop this turn," but does not execute them until the Codex turn has ended. Codex may therefore continue requesting tools until BeamAgent's 16-call limit kills the response. Recent runs actually hit `too_many_codex_tool_calls`.

BeamAgent is using the same underlying intelligence, but giving it worse continuity and a less natural tool protocol.

### 2. Dynamic agents are configurable, but not coherently constructed

There is a naming trap:

- Built-in template: `"implementer"` in `lib/beam_agent/agent_template.ex`
- Execution strategy: `"implement"` in `lib/beam_agent/execution_strategy.ex`

The model repeatedly requested `template: "implement"`. Because that is not a built-in template, it was dynamically generated using the heuristic classifier. The prompt mentioned prior failures, so the classifier chose debugging/investigation. The result was an agent whose role said "implementer" but whose execution strategy was `investigate`, causing the runtime to remove all write tools in `lib/beam_agent/agent_constructor.ex`.

That is a serious semantic invariant violation. An actor should never start with an assignment and authority that contradict one another.

### 3. The execution strategies mostly remain metadata

The default loop is explicitly sequential, and multiple tool calls are executed with `Enum.reduce_while` in `lib/beam_agent/strategies/tool_loop.ex`.

The execution strategies describe modes and parallelism, but they do not substantially change how the model/tool loop behaves. OTP concurrency exists around the loop, not sufficiently inside useful work.

### 4. Verification and review can fight successful work

After any implementation action, BeamAgent runs broad project verification automatically.

Problems include:

- Every check—not only failed checks—is described to the repair model as "failed."
- The independent reviewer does not receive the structured verification result.
- The reviewer is read-only and cannot run tests, yet may reject work because it cannot find test-execution evidence.
- Repeated infrastructure failures have historically been treated as code defects and sent back for more implementation attempts.

The current checkout is green: 277 Elixir tests pass, the Go suite passes, and `mix test` passes through BeamAgent's own command sandbox. The earlier sandbox/Codex test failure therefore appears fixed. The architectural failure-classification problem remains.

### 5. Repository intelligence generates enormous noise

The repository index:

- Rescans the complete tree every two seconds
- Reads every file up to 1 MB
- Ignores only a small hardcoded directory list
- Persists a complete repository snapshot
- Emits one event per changed file into every active goal's session log

See `lib/beam_agent/project/repository_index.ex`.

One recent session accumulated more than 3,100 `file_changed` events, largely from temporary Go build files. During the review test run, the index also crashed while publishing changes after its destination event log had stopped.

This produces disk churn, replay cost, lifecycle coupling, and UI noise without improving model context proportionally.

## Recommended change order

### 1. Make provider conversations OTP resources

Introduce a supervised `ProviderConversation` process per active worker or turn.

For Codex App Server it should:

- Retain one native thread across model/tool steps
- Receive native tool requests
- Route each request synchronously through `ToolRunner` and `ToolPolicy`
- Return the actual result to the same Codex turn
- Support cancellation by killing the provider-conversation process
- Restart only when the provider transport genuinely fails

BeamAgent remains authoritative. Codex never receives filesystem authority. But the model gets the protocol it was designed to use.

This is a place where OTP can be better than conventional harnesses: persistent provider actors with monitored lifecycle, backpressure, health state, and cheap replacement.

### 2. Replace free-form agent construction with typed work contracts

Let models propose something like:

```elixir
%WorkRequest{
  kind: :implementation,
  objective: "...",
  expected_artifact: :workspace_patch,
  context_needs: [...],
  verification_needs: [...]
}
```

The runtime should choose the template and strategy. Do not let the model couple a free-form role, arbitrary template string, and authority.

Before starting a worker, validate invariants:

- Implementation work has a write path
- Reviewers cannot be asked to produce a patch
- Verifiers receive executable checks
- A worker's expected artifact matches its capabilities
- Aliases such as `implement` and `implementer` cannot produce different semantics

### 3. Add a real goal coordinator state machine

This should be an OTP-owned progress protocol, not a fixed workflow:

```text
understand → investigate → change → verify → review → complete
                  ↘ delegate specialist ↗
```

The model proposes actions, but the coordinator owns progress and failure memory.

It should prevent what happened in the recent run:

- Never spawn another nearly identical worker after the same failure fingerprint repeats
- Distinguish code failure, infrastructure failure, approval wait, missing authority, and provider failure
- Stop read-only thrashing after a bounded amount of unchanged evidence
- Preserve one coherent implementer for one coherent patch
- Escalate to the user only when the runtime can explain the concrete blocker

### 4. Make evidence a first-class artifact

Workers should return typed artifacts, not merely prose:

```elixir
%PatchArtifact{
  changed_files: [...],
  diff_fingerprint: "...",
  focused_checks: [...]
}

%VerificationArtifact{
  checks: [...],
  environment: ...,
  status: :passed
}
```

The reviewer then receives the patch, requirements, and verification artifact. It should not have to rediscover whether tests ran.

Only failed checks should enter repair context. Infrastructure failures should go to an environment/recovery actor, not an implementer.

### 5. Rebuild repository observation as an incremental project service

Keep it OTP-native, but:

- Honor `.gitignore`
- Exclude `.beam_agent`, `.tmp`, build caches, generated binaries, and session storage
- Use filesystem notification plus debouncing instead of full scans every two seconds
- Publish one coalesced repository delta
- Keep project telemetry outside conversational event logs
- Derive session-relevant facts on demand
- Persist snapshots only when the repository generation materially changes

### 6. Add safe parallel tool execution

Read-only calls from one model response can run concurrently under a supervised task set. Writes should remain serialized by workspace or file ownership.

Also add better compound tools:

- `read_files`
- Bounded structured search with surrounding context
- Changed-files inspection
- Focused test selection
- Diff plus diagnostics

The 201 `read_file` calls in one worker are evidence that the current tool granularity is wrong.

### 7. Pin models to work units

Choose a model when constructing a worker and lease it to that worker. Do not reconsider routing on every conversational step unless the worker explicitly reaches a handoff boundary.

Provider descriptors should carry actual invocation controls—reasoning level, output budget, caching/thread support—not merely broad capability labels.

The normal OpenAI-compatible adapter currently sends only model, messages, tools, and streaming.

### 8. Make the UI show work, not events

The TUI needs semantic activity projections such as:

- `Investigating file references`
- `Implementing TUI suggestions`
- `Running 2 focused checks`
- `Blocked: approval required`
- `Detached: still running`
- `Suspected stall: no new evidence for 4 minutes`

Raw runtime events should remain available in an inspector, but they should not be the primary product experience.

## What should remain

OTP should not be pushed aside. Keep:

- Supervised session and goal trees
- Event-sourced recovery
- Capability envelopes
- Session-owned approval policy
- Elixir-authoritative runtime with presentation-only clients
- Cancellation and monitor-based cleanup
- Durable attachments and context projection

The image-paste implementation is a good example of the architecture working at the feature level:

- OS clipboard conversion existed in the now-removed Go TUI (`clipboard_image.go`); the current Rust/ION frontend supports file-based image attachment only
- Durable/private storage exists in `lib/beam_agent/session/attachment_store.ex`
- Provider paths receive native images

The problem is not whether BeamAgent can contain such a feature—it can. The problem is whether BeamAgent can reliably implement such a feature itself without hours of accidental work.

## Bottom line

BeamAgent has built an advanced operating system for agents, but the process running inside it is still a basic tool loop.

Push OTP further into coordination, provider continuity, evidence transfer, concurrency, and failure classification. That is how BeamAgent can become genuinely better and different—not merely a more supervised imitation of Claude Code.
