# Coding usability repair — 2026-09-09

Inspected checkout: `8d65d02`. The original 358-test suite passed, but the live
coding workflow failed. Source diffs and executed evaluations, rather than commit
messages, established the following causes.

| Evidence | Cause | Change |
| --- | --- | --- |
| `88dcad96`, `WorkPlanningPolicy` | Substantial automatic requests forced a provider team and removed coordinator write tools | Ordinary coding keeps one owner and optional specialists; explicit multi-provider requests retain the planning gate |
| `88dcad96`, `Goal.Reviewer`; `aba67d8a`, `ToolLoop.provider_options` | Manual review selected another provider but inherited the original model/options | Manual review stays on the selected profile; explicitly assigned other endpoints receive their own options |
| First live evaluation | Saved ChatGPT model `gpt-5.4` was rejected before any tool executed | Health checks validate the paginated model catalogue; evaluation model overrides allow testing without changing saved profiles |
| `turn_decomposition_recovery` | A successful result with no recovery action let the scan fall through to an older `replan` | Only the latest result determines recovery; terminal failed organizations cannot report success |
| Completion guard | Any earlier action denial permanently blocked the turn | Later approved implementation can complete through normal verification; the denied operation remains denied |
| `Sandbox.command` | Every shell command denied external networking, including approved dependency installation | Explicit outbound networking requires host authority and a distinct approval resource; filesystem confinement remains |

The OTP boundaries remain authoritative: projects own goals, a goal owns the
work contract and verification, sessions own agent mailboxes and durable events,
and disposable supervised workers perform independent review or delegated work.
An actor does not need a different model to be independently supervised. The
critical implementation path can remain with one worker while useful specialists
are constructed as needed.

Model discovery follows the official
[Codex app-server model/list contract](https://learn.chatgpt.com/docs/app-server#list-models-modellist),
including pagination and hidden entries. The current account's catalogue was
queried directly; `gpt-5.6-sol` was available and used for both passing evaluations.
The saved profile was not changed.

## Verification

- Final Elixir suite: 369 tests, zero failures.
- Compilation with warnings as errors, touched-file formatting, and diff checks passed.
- `mix beam_agent.build` rebuilt both the escript and Go TUI; the escript help command ran.
- Clipboard implementation: passed with deterministic checks and independent review,
  in approximately 163 seconds. Report:
  `/tmp/beam-agent-usability-fixed/eval-bboVcMVOyyNm/report.json`.
- Phoenix frontend: passed in approximately 543 seconds. The harness installed
  dependencies, created a Phoenix endpoint/router/controller, connected actions to
  the supplied GenServer, passed all three acceptance tests, and served HTTP 200
  in a loopback smoke test. Runtime verification and independent review passed.
  Report: `/tmp/beam-agent-phoenix-acceptance/eval--il_jOWt5U6k/report.json`.

The Phoenix fixture's original tests and runtime were compared with the generated
workspace: only formatting changed. The reported workspace artifact includes local
Hex archives as well as product files, so its changed-file count is not a count of
source changes. The adapter reports zero tokens in these runs; that is missing
usage evidence, not free inference. A suspected-stall event occurred in each run,
but neither run recorded a confirmed stall or cancellation.

These are single-run acceptance results, not a reliability benchmark or proof of
parity with a mature coding agent. The supplied Phoenix runtime is a small stand-in
for the public BeamAgent API. A full frontend for this repository still needs the
real streaming, approval, attachment, cancellation and reconnect contracts.

## Run the repaired harness

```sh
./beam_agent --model gpt-5.6-sol --model-strategy manual --approval auto
```

Then submit the coding request. Omit `--approval auto` to approve risky operations
interactively. The model override is necessary while the saved profile still
selects the unsupported `gpt-5.4` model. The available model list can change; use
`doctor` to check the saved profile.

Reproduce the bounded frontend evaluation:

```sh
mix beam_agent.eval evals/phoenix_frontend.json \
  --model gpt-5.6-sol --model-strategy manual
```
