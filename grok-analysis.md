# BeamAgent analysis

Date: 2026-08-31

This is an honest look at why BeamAgent does not yet feel as good as Claude, Codex, or Grok Build, and what to change without abandoning the OTP experiment.

The point of this harness is to see whether OTP and the actor model can make a better coding runtime. The goal is not to clone Claude. The goal is something that feels good, exposes opportunities those products cannot, and still delivers. A request like "implement copy-paste of images" should land.

## The feeling is real, and it is not mysterious

BeamAgent is a strong runtime. Claude, Codex, and Grok Build are strong coding agents. Those are different products, and the quality people compare lives almost entirely in the model-facing inner loop, not in the process tree.

There is a reason it should not feel as good yet. Energy has gone into OTP topology, capability envelopes, construction policy, routing evidence, and event governance. The conversation the model actually has is still thin, frictional, and sometimes boxed in.

That diagnosis still holds. The wrong conclusion would be: set OTP aside and copy Claude's chat loop. The right conclusion is: the actor model is sitting around a Claude-shaped chat instead of running the work.

## What those products actually optimize

A user session in Claude / Codex / Grok is roughly:

1. A long, specific system prompt about how to do software work.
2. A small set of tools that fail the way models fail.
3. Context that already contains git status, project instructions, and the files that matter.
4. Parallel reads/searches, then a cheap unique-string edit.
5. A UI that collapses that work into "Investigating…", "Edited 3 files", "Ran tests".
6. A strong model.

The user never sees supervisors, envelopes, route decisions, or spec provenance. They see an agent that just does the work.

BeamAgent's north star is different, and should stay different:

> Can the runtime dynamically construct the actors it needs, give each one an explicit goal, only the context and authority required for that goal, and safely destroy them when their purpose is complete?

That is interesting systems work. It is not what currently happens on `ask`.

## What the code actually does today

You already built most of the interesting machinery:

- Project and Goal supervisors
- `ContextStore` and `RepositoryIndex` (git, hashes, symbols, diagnostics)
- `OrganizationManager` and `DecompositionExecutor`
- `WorktreeManager`
- capability envelopes, leases, budgets
- `Goal.Verifier`
- resource scheduler and race policy
- durable event log, crash reconstruction, cancellable turns

A user prompt still goes here:

```text
user → Agent.ask → ToolLoop (LLM "Goal coordinator")
                 → maybe read, maybe plan, maybe spawn, maybe SHA-edit loop
                 → model says done
                 → maybe verify inside the same conversation
```

`BeamAgent.Goal` is currently a snapshot holder. It does not spawn, restart, or complete anything. Workers have to opt into project truth via `request_project_context`. Worktrees and races are almost unused on the default path. The unique architecture is inventory, not leverage.

Every root session is constructed as a Goal coordinator:

```elixir
goal = Keyword.get(opts, :objective) || "Coordinate work requested through this session"
template = AgentTemplate.resolve("coordinator", classification)
```

Its instructions are about decomposition, not about editing code. Claude's default agent is one worker that sometimes delegates. BeamAgent starts as an organization chart, then waits for the model to operate it.

`ExecutionStrategy` is metadata (`mode`, `maximum_parallelism`). The actual loop is still sequential `ToolLoop`. The architecture describes organization; the model still does a normal tool loop, with extra identity noise in the prompt.

## Why the inner loop currently fails delivery

These are not reasons to copy Claude. They are reasons an OTP worker cannot land a patch.

### The system prompt is too small to steer a coding model

The built-in prompt is roughly: you are BeamAgent, inspect evidence before changing files, keep paths workspace-relative, read before edit. Plus a role/goal block, plus a contract that says "you must invoke a write tool" on implementation turns.

Claude/Codex/Grok spend thousands of tokens on when to grep vs read, how to edit, when to run tests, git conventions, parallel tools, and not stopping at a plan. BeamAgent tries to get that behavior from a paragraph plus regexes that reject "I'll start by…".

Those regexes in `completion_guard` are a symptom. A good worker protocol makes the model do the work. A guard that rejects future-tense English is fighting the model after it already failed.

### The tools make the model work harder than it should

**Edits require a SHA-256 from a previous `read_file`.** Observed-state edits are a good OTP idea. Making the model pass `expected_sha256` is not. After compaction, a forgotten hash, or any intervening write, the model plays hash-ledger. That produces retry loops that feel dumb even when the model is fine.

**`read_file` does not number lines.** The description says "numbered-window metadata"; the content is unnumbered text stuffed in JSON. Models are trained on `12→  def foo do`. Line numbers in a side field are much weaker for edits and citations.

**Every tool result is a JSON envelope.** The model spends tokens parsing `{"matches":[...]}` instead of reading `path:line:text`. Errors are `ERROR: {:stale_file, "abc", "def"}`. A worker protocol should say "file changed since last read; here are the nearby 20 lines."

**Tool calls run one at a time** even when the model emits several. `execute_tools` is sequential `reduce_while`. Claude's "read these six files" is one parallel round. BeamAgent is six serial round-trips, each with authorize → budget → execute → fsync. `DecompositionExecutor` already uses `Task.async_stream`. The implementer should too.

**There is no todo/plan tool.** That is how long feature work stays on the rails and how the UI shows progress.

**`add` is in the default catalog.** A coding worker does not need a calculator next to `edit_file`.

**`file_diagnostics` only parses Elixir.** Everything else returns `[]`. A model that trusts "diagnostics: 0" on a TypeScript file is being lied to.

### Context is rebuilt, then impoverished

Default window is 32k tokens, compact at 75%. Real coding work needs much more room, or a way to throw the conversation away.

Compaction is "LLM-summarize older turns into one blob." What you actually need to keep is: user goal, files touched, current hashes/contents, failing tests, decisions. A prose summary is how agents forget the SHA they need to edit.

Older `read_file` results for the same path are replaced with a stub. That saves tokens, but it also deletes evidence the SHA-gated editor depends on.

There is no automatic environment snapshot. Git is a tool the coordinator must remember to call. `RepositoryIndex` already has this; workers do not receive it at init.

Every step reloads the full event log and estimates tokens as `byte_size/4`. That estimate is wrong for code, so compaction fires at the wrong time.

### The runtime often fights the agent

- Keyword task classification: `"test"` beats `"implement"`. "The test is failing, implement a fix" becomes `:verification`.
- Auto-routing can send child work, or even delivery work, to a weaker local model.
- Mandatory completion verification plus a second review agent after the model already said it was done, inside the same conversation.
- macOS sandbox: workspace-write, network outbound denied except localhost. `mix deps.get`, `npm install`, and many real fix flows just die.
- Non-zero command exit is a tool error, not output the model can read as "tests failed, here is the log."
- Capability negotiation is a model-visible tool. The agent has to think about envelopes instead of files.
- `fsync` on every event. A single tool call is multiple durable appends.

None of this is wrong as systems work. It is the wrong default friction for a coding session, and it is the wrong place to put control that OTP processes should own.

### The UI shows a runtime, not work

The TUI appends a transcript row per `tool_called`, plus info lines for `model_route_selected`, `agent_spec_applied`, `agent_constructed`. A turn looks like process telemetry. Claude looks like: thinking, 4 files read, patch, tests passed, answer. Same underlying events. Completely different product.

The roadmap item about grouping events into work blocks is load-bearing, not cosmetic.

## What is actually good

This is not a toy. The durable event log, crash reconstruction, cancellable turns, approval lifecycle, workspace confinement, lazy skills, MCP, streaming, and client-neutral runtime API are real. Several of those are better engineered than the equivalent in the products people compare against.

They just are not the layer users use to judge "can this implement image paste."

## The OTP bet, restated

Do not use OTP to host a Claude clone. Use OTP so:

- the **Goal process** is the coordinator
- **models are workers**
- **project processes hold truth**

Claude cannot do that. It has no supervisor, no mailbox, no file authority, no cheap restart.

The interesting opportunities — cheap worker restart, path leases, worktree isolation, mailbox steering, deterministic verification as a process, racing implementations — only show up after Goal owns the work.

## What should happen for "implement image paste"

What the architecture is for:

```text
user → Goal (OTP)
         ├── Investigator (read-only) → writes findings into ContextStore
         ├── Implementer (write + path lease, maybe a worktree)
         │     mailbox: diagnostics, test failures, user steering
         ├── Verifier (deterministic sibling, already exists)
         └── Reviewer (only after tests pass)
       Goal decides spawn / restart / complete
```

The user talks to the Goal. Workers die. Project state remains. That is the feeling Claude cannot give.

## Suggested changes

These keep OTP as the product. They stop using an LLM as the supervisor.

### 1. Make Goal the supervisor, not an LLM with a coordinator prompt

This is the actual experiment.

- Default implementation request does not start as "Role: Goal coordinator."
- Goal classifies enough to pick a strategy, then starts workers under `GoalSupervisor`.
- `delegate_tasks` becomes Goal API. The model can still propose extra specialists; it should not own the tree.
- Worker finishing is a message to Goal, not a chat ending.

Unique thing: you can kill a looping implementer and keep the goal. Claude has to compact or start a new chat.

For image paste, Goal should start an implementer (plus a short investigation wave if the surface is unknown). Do not wait for the model to decide it is allowed to write.

### 2. Give workers project truth at init, not as a tool they must remember

`RepositoryIndex` already scans git, hashes, symbols, diagnostics. `ContextStore` already stores artifacts. The implementer still boots with a short prompt and has to call `request_project_context`.

That is the anti-OTP pattern: the process exists, then the model has to fetch the world.

An implementer should start with a runtime-assembled packet:

- the goal and acceptance criteria
- git status + current diff
- investigator notes from ContextStore
- relevant file windows
- current diagnostics
- last test output
- what it is allowed to touch

When the index sees a relevant file change, it should cast into the implementer's mailbox: diagnostics changed, hash changed. The worker does not re-explore the repo.

Unique thing: context is a process, not a growing transcript. Claude can only stuff more tokens into one conversation.

### 3. Restart workers instead of compacting them

Compaction is what you do when the conversation is the agent. You do not want that.

If the implementer repeats tools, blows the window, or loses the plot:

1. persist artifacts (diff, failing tests, files touched, last error)
2. terminate the process
3. start a new implementer with those artifacts + current RepositoryIndex

Fresh model context, same goal, same repo truth. That is how OTP makes long feature work viable without a 200k Claude transcript.

Keep compaction only as a fallback inside a still-healthy worker.

### 4. Use actor state for file consistency, not SHA in the tool schema

Observed-state edits are a good OTP idea. Making the model pass `expected_sha256` is not.

You already have hashes in `RepositoryIndex`. Use them behind the tool:

- `read_file` is a query against the index (numbered window + generation)
- `edit_file` is unique-string replace
- ToolRunner checks the index generation; if stale, return the new numbered window and the nearby lines
- one implementer gets a path lease for the files it owns

The model stops being a transaction manager. The File/Index process is.

Same for shell: non-zero `mix test` is data mailed to the implementer, not `{:error, {:command_failed, ...}}`. A verifier process can run that without the model asking.

### 5. The implementer still needs a working coding protocol

This does not sideline OTP. It is the worker's public API, the same way a GenServer needs a coherent message contract.

Without this, Goal can spawn a beautiful tree that cannot land a patch:

- numbered reads
- hashless unique edits with nearby context on failure
- parallel reads/searches
- tool results as text, not JSON envelopes
- failing commands as output
- capable model on the implementer; cheap/local models on investigators and summarizers

If Auto routes the delivery worker to a small local model, the tree will look impressive and the feature will not land.

### 6. Worktrees and races should be Goal policy, not tools the model discovers

`WorktreeManager` and race machinery exist. They are almost unused on the default path.

Goal should decide:

- this change is isolated → implementer gets a worktree
- this is hard and checkable → race two implementers in two worktrees, tests pick the winner
- this is a coherent feature → one implementer, no race

The worker just sees `workspace_root`. That is an opportunity Claude does not have: real isolated git workspaces with supervised cleanup, not prompt-level "be careful."

Do not race the original user prompt before the tool loop. Race implementations against tests.

### 7. "Done" is a Goal state, not a model sentence

`Goal.Verifier` already exists. Wire it as a sibling, not as a recovery prompt inside ToolLoop.

- Implementer exits with a candidate
- Goal starts Verifier
- fail → restart implementer with the test artifact
- pass → optional reviewer
- only then is the goal complete

The TUI should say `verifying` because a process is verifying, not because the model wrote "I ran the tests."

### 8. Talk to the live tree

This is the UX that makes the architecture feel like itself:

- transcript is Goal-level: objective, questions, final result
- worker activity is a live tree: investigating / writing / waiting for approval / verifying
- you can inject "also support drag-drop" into the running Goal; it mails the implementer; the turn does not restart
- you can cancel one worker without killing the goal
- approvals stay worker-scoped, which is already right

If the UI is a log of `model_route_selected` and `agent_spec_applied`, it will feel like telemetry. If it is a process tree chasing a goal, it will feel like OTP.

## What not to do next

Do not add more templates, envelopes, routing evidence, or construction provenance until a feature-sized ask completes on the default path. That machinery is already ahead of the wiring.

The experiment is no longer "can we represent an agent as a process." It is: the next `ask` is executed by those processes.

Do not set the actor model aside to make a better sequential chat. That would succeed at becoming a weaker Claude and fail the experiment.

## A concrete delivery slice

One vertical slice, using image paste or the next similar feature as the acceptance test:

1. Goal receives an implementation objective and starts Investigator then Implementer itself.
2. Implementer boots from ContextStore + git + diagnostics; no `request_project_context` required.
3. Edits go through RepositoryIndex generations; model does not pass SHAs.
4. After writes, Verifier runs as a sibling; failures restart the implementer with evidence.
5. TUI shows Goal phases, not every inner event.
6. Root implementer uses the user's capable model.

When that slice can land a multi-file feature with tests, the OTP experiment is working. Until then the unique architecture is inventory, not leverage.
