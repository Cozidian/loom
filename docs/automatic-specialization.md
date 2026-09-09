# Automatic specialization — 2026-09-09

The runtime can now assign bounded assistance without asking the implementation
model to invent a team. This builds on the existing goal-owned delegation
manager, budget manager, provider auctions, stable leases and supervised workers.
It does not add a second orchestration runtime or make the TUI own agent state.

## Behavior

- A root implementation request classified as high-reasoning and advisory in
  `team_mode: auto` may start up to two investigators, independently of model
  routing. A manually pinned owner can have automatic helpers; an automatically
  routed owner can run solo. Explicit provider-team requests retain their existing
  decomposition workflow. Small edits and `team_mode: solo` do not start helpers
  automatically. Solo does not prohibit explicitly requested delegation or review.
- CLI: `--model-strategy manual --team-mode auto` pins the owner while enabling
  bounded assistance. ION exposes both fields in its model selection form.
  Version-9 settings migrate in memory with legacy behavior preserved: automatic
  routing gets automatic teams, manual/local-only routing gets solo. No saved
  settings are rewritten or new helper spending enabled just by loading them.
- The owner is selected and leased first. Only distinct, healthy/not-unavailable
  endpoints with declared `free` or `low` cost and tool support are considered
  for helpers. Normal endpoint eligibility, exclusions, authority and budget
  checks still apply. Unknown price is not assumed cheap. There is at most one
  automatic helper per endpoint per owner turn; this is not a global GPU quota.
- One helper surveys relevant repository conventions and verification. With two
  endpoints, repository/API investigation and test/acceptance investigation are
  separate jobs. They cannot edit, run shell commands or delegate. The owner
  retains source-write authority, integration and verification responsibility.
- The runtime supplies a bounded file listing and README read through the same
  capability, approval, observation and event boundary as model tools. These
  routine operations do not need model inference. Helpers may request additional
  scoped reads where necessary; the requested six-call limit is guidance, while
  time and resource limits are enforced by the runtime.
- Helpers have at most 8,192 context tokens, 16,000 reported model tokens, zero
  retry/shell/test budget, and 90 seconds of wall time. Reported-token accounting
  cannot bound usage an adapter fails to report; wall time still applies.
- Findings are unverified advisory evidence. Ordinary model turns receive
  current results in their context. Native tool conversations receive handles
  and can collect results with `await_subagent`, including nonblocking polling.
  The owner does not need to wait for research to begin editing or finish.
- The delegation manager monitors the owner turn process. Completion cancels
  pending assistance; cancellation/crash also reclaims workers. Budget deadlines
  use supervised OTP shutdown, not an ignored exit signal to a trapping supervisor.
- Mandatory review uses a fresh read-only actor. Another model is preferred only
  when it declares reasoning capability; otherwise normal capable routing applies.
  Provider diversity alone is not sufficient qualification for critical review.

## Observability and boundaries

Durable assignment events record role, owner, endpoint, policy reason and execution
location. Work-block projections preserve pre-turn metadata and combine it with
actual invocation provider/model and routing reasons. The TUI displays roles and
models in live work and reasons/ownership in expanded Tree blocks. Public event
views retain safe policy metadata without exposing prompt or helper content.

An `automatic_helpers_decided` event explains how many helpers started, or whether
there were no suitable cheap endpoints or starts were denied/unavailable. This is
an observation, not a guarantee of helper usefulness or successful completion.

`local` means the worker process executes on this harness machine, not that the
model provider is local. Remote worker registration/selection is not network
dispatch. This slice does not ship cross-machine clients, revision/patch transfer,
global per-endpoint capacity enforcement or writable automatic scaffold workers.
Existing races, tournaments, isolated worktrees and explicit task graphs remain.

## Verification

The deterministic regression suite exercises simultaneous owner/two-helper
inference, write-authority retention, context/budget bounds, native result
collection, optional failure, delegation denial, owner completion/cancellation,
untrappable owner death, deadline reclamation and capable mandatory review.
Projection and Go tests cover replay, public metadata and visible role/model/reasons.

Run a real-provider evaluation with a capable endpoint and a free/low-cost helper
configured:

```sh
mix beam_agent.eval evals/automatic_specialization.json \
  --model YOUR_AVAILABLE_MODEL --model-strategy auto
```

The fixture is isolated. Acceptance requires verified implementation and actual
use of multiple endpoint leases, with no permission denials, user interventions
or confirmed stalls. Multiple leases alone do not prove the helper improved
latency or quality: inspect its completed findings and compare repeated runs
against the manual `evals/coding.json` control.

The first live run selected GPT-5.6 Sol as owner and Qwen3 8B as investigator.
It timed out after 300 seconds despite passing implementation tests: the helper
was too slow, and the old diversity-first reviewer policy selected the weak
alternate and triggered repair. This motivated deterministic context seeding,
the supervisor-deadline correction and capable-review policy. The failed report
is retained at `/tmp/beam-agent-automatic-specialization/eval-xedBxASpefWb/report.json`.

The corrected live rerun passed in 173.5 seconds: Sol implemented the fixture,
local Qwen returned a README-backed report with explicit uncertainties in about
61 seconds, and the owner successfully collected it through `await_subagent`.
A separate Sol reviewer passed. The run used 3 model calls and 22 recorded tool
calls, with no repairs, denials, user interventions, cancellations or suspected/
confirmed stalls. Both deterministic checks passed; only
`lib/clipboard_fixture/editor.ex` changed, and both fixture test files were
byte-for-byte unchanged. Report:
`/tmp/beam-agent-automatic-specialization/eval-6IxWUTajPFZA/report.json`.

This is one passing run, not evidence of a net latency/cost improvement. The
reported token count is zero because the adapters did not provide usable usage
data, not because inference was free. Final local checks: 379 Elixir tests and
the Go TUI suite passed; compilation with warnings as errors, changed-file
formatting and diff checks passed. Both CLI/TUI binaries were rebuilt and CLI
help executed successfully. Saved provider settings were not changed.
