# Why BeamAgent feels off compared to Claude Code / Codex / Grok

Grounded in the actual code: `strategies/tool_loop.ex`, the subagent/delegation
tools, the race/decomposition modules, and the image-paste path end to end.

## First, a myth-bust

The "ask it to implement copy-paste of images" example already works. Go
reads the clipboard PNG → sends an `attachment_import` packet → `AttachmentStore`
validates the PNG, strips EXIF/text metadata, hashes it → the id rides on
`submit` → gets hydrated into the message → encoded as native image blocks for
Anthropic, OpenAI, *and* Ollama (xAI declares text-only, presumably because
the target models don't do vision). That's a genuinely well-built feature —
versioned, privacy-conscious, provider-normalized.

So "ask it to build copy-paste of images and it should deliver" isn't actually
blocked by a missing capability. Which means the real problem is somewhere
else: what happens when you ask the harness to build something *like that
itself*, live, through its own tool loop. That's where the "off" feeling
actually lives.

## Diagnosis

The actor model is barely used on the path that matters, and a lot of
process-theater is used where it doesn't.

### 1. The concurrency is opt-in, not structural

`execute_tools/4` in the tool loop runs the model's tool calls through
`Enum.reduce_while` — strictly one at a time, even when the model asks for
five independent reads in one turn. `spawn_subagent` is a blocking RPC
(`BeamAgent.ask/2` inside the parent's own tool call) — the parent process
sits there awaiting a reply exactly like a synchronous function call would in
any other language.

Meanwhile `delegate_tasks` and `Goal.Race` *do* use real `Task.async_stream`
concurrency — parallel specialists, even parallel git-worktree candidates
raced against each other with consensus/verification-based winner selection.
That race feature is genuinely something Claude Code's architecture cannot
offer. But it's buried behind a special tool the model has to remember to
call, or a heuristic (`RacePolicy.consider/2`) that fires before the model
ever gets a turn. The default, model-preferred path is sequential. The
actor-model payoff was built and then never wired into the thing that runs
95% of the time.

### 2. Every ordinary turn pays a bureaucracy tax before you see an answer

Look at what one "fix this bug" request triggers by default:

- a model-routing decision (logged with full candidate list)
- a budget check
- the actual model call
- `completion_guard` — which runs **regex over the model's own prose**
  (`future_intent?` looks for phrases like "I'll start by…", "let me…") to
  decide if the answer is allowed to count as final
- for any implementation-classified task, a *mandatory* verification pass
- then a *mandatory second subagent* spawned just to review the diff and
  answer `REVIEW_PASS`/`REVIEW_FAIL` before your turn is allowed to finish

None of that is opt-in; it's the silent default for `review_required?` and
automatic verification. That's not "BEAM doing something interesting" — it's
a second LLM call auditing a third LLM call auditing your first request,
stacked serially, plus a brittle string-matcher second-guessing whether the
model *sounds* done.

Claude Code and Codex feel snappy because their loop trusts itself: ask →
tool call → answer. This harness re-litigates the model's own completion
before handing it back.

### 3. Minor but compounding

`edit_file` requires an exact single-occurrence match against a SHA-256 read
version — good for correctness under concurrent writers, but with no
fuzzy/whitespace tolerance it fails more often than Claude Code's edit tool
on minor whitespace drift, feeding back into the "why did it get stuck
re-trying" feeling.

## What to actually change, in priority order

1. **Make tool execution concurrent by default**, not opt-in. Independent
   (`:read`-access) tool calls in a single turn should run via
   `Task.async_stream`, same as `delegate_tasks` already does. This is a pure
   win and it's the single cheapest way to make the harness *feel* fast in a
   way that's authentically BEAM.

2. **Make `spawn_subagent` non-blocking.** Return a handle immediately, let
   the parent keep talking to the user or keep reasoning, surface subagent
   progress/completion through the goal event stream that already exists
   (the tree UI already supports multiple simultaneous `:running` nodes — the
   visualization is ready, the execution isn't). This is the actual
   "Claude can't give you this" opportunity: live, superviseable,
   crash-isolated concurrent children you can watch progress in real time,
   not a blocking function call that happens to be a process underneath.

3. **Turn off mandatory review/verification-as-default.** Keep both — they're
   legitimate, differentiated features — but gate them behind an explicit ask
   (`/review`, a strategy flag, or a task-classifier confidence threshold)
   instead of silently doubling the latency and cost of every implementation
   turn.

4. **Drop or loosen the regex completion-policing.** Trust tool-call evidence
   as the signal of "did work happen," not phrase-matching on the model's
   prose.

5. **Promote `Goal.Race`** from a heuristic-triggered background feature to
   something the user can invoke directly (`/race`) with the tree UI actually
   showing parallel branches lighting up concurrently — that's the headline
   differentiator; make it visible instead of implicit.

The smallest, safest change with the most noticeable effect on "feel," and
one that doesn't touch the review/verification policy debate at all, is #1:
concurrent tool execution.
