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

## 2026-09-10 — Preparation for the new delivery trials

Source review found that evaluation reports summed absent usage as zero and
counted answer-only success as verified completion. Both now have explicit
distinctions: unknown/partial usage retains its known subtotal, and verified
completion requires a passing required command check. This does not retroactively
give the older live reports missing usage or visual evidence.

The coding and Phoenix manifests now fingerprint their supplied tests, and
Phoenix protects its stand-in runtime too. Changes to those files fail the
scenario, including formatting-only changes like those noted in the older
Phoenix run. This deliberately makes the new trial stricter than that old result;
the new rules have offline regression coverage, not a fresh live-provider pass.
An output can also be required to have a real content delta, and binary originals
can be retained and checked without text decoding.

Use `--preflight` before a live evaluation. See the
[evaluation guide](../evals/README.md#artifact-integrity-and-honest-measurement)
for the report fields and limitations. Tests remain editable files, not a
tamper-proof external verifier. The actual app/API/browser trial and a rendered
Word edit remain open; no provider quota was consumed for these regression checks.

## 2026-09-10 — Desk against the actual runtime

[Desk](../cmd/beam_agent_web/README.md) is now a standalone Phoenix application
over the existing authenticated loopback HTTP API. Its tests embed the real
harness and use its HTTP server; no stand-in goal actor is used. The frontend
keeps runtime execution separate, authenticates the browser, and exposes prompt
submission, cancellation, allow-once/deny approvals and public actor/activity
inspection. Closing the observer does not cancel the goal.

Two concrete integration defects were found and fixed: JSON normalization
converted booleans/null into strings, and several runtime components eagerly
evaluated missing global configuration even when explicit options were supplied.
The new web integration suite reproduces the dependency-embedding case without
loading the root application's config file.

Chrome desktop/mobile checks exercise login, real prompt submission, refresh,
draft retention, idle cancellation feedback, logout and CSRF rejection. Separate
runtime integration checks cancel genuinely blocked inference and resolve an
approval exactly once. Screenshots were visually inspected: readable layouts,
no horizontal overflow on the narrow viewport. A rejected command now keeps the
workspace/draft visible and distinguishes an unconfirmed result from success.

Limits: this application was implemented during repository development, not
autonomously generated by a harness provider. Echo and blocking test providers
prove integration/lifecycle paths, not model quality or quota efficiency. Browser
polling is not token streaming; public event content is intentionally redacted.
The full document, autonomous coding, background mission, personal-center and
second-machine trials remain open. Current broad auto approval still does not
enforce a separate publication category; no push or deployment was performed.

## 2026-09-10 — Fresh Phoenix trial and wider browser checks

Run `eval-aAqFDlRcCJ3h` used the configured provider in an isolated workspace.
The protected three-test acceptance suite and compilation passed; supplied tests
and the stand-in runtime retained their original hashes. The owner plus independent
reviewer finished in 449,622 ms, with 66 tool calls, no permission denials or repair
attempts. Two runtime model invocations had no token counters; total usage remains
unknown. One executing-owner silence warning occurred before review, not a confirmed
stall. No task fan-out occurred beyond completion review.

Operator Chrome checks then exercised creation, refresh, cancellation, blank-input
422 responses and escaped script text. Desktop and 390px-wide screenshots were
inspected; neither had horizontal overflow. However, missing routes and rejected
CSRF requests returned HTTP 500 because the generated app omitted its error-rendering
module. The CSRF operation was rejected, but the error handoff was broken. The app
was left unchanged so this defect remains visible in the trial evidence.

**Assessment:** bounded acceptance passed; broader delivery is incomplete. The
fixture still uses a stand-in API and browser checks were performed by the operator,
not the harness. Next add HTTP error-path acceptance and an automated browser
handoff before calling this unattended app delivery. Local report and screenshots:
`/tmp/beam-phoenix-trial-0nwKdj/` (temporary, not portable evidence).

Follow-up: the manifest now requires and fingerprints `test/http_delivery.exs`.
It starts the real endpoint on loopback and requires a nonempty 200, unknown-route
404 and missing-CSRF 403 with unchanged actor state. It rejects the previous
artifact at the observed 500. An in-memory control supplying error templates and
the missing HTML encoder dependency passes; neither the old artifact nor its
recorded result was altered. No new autonomous provider run or harness-owned
visual assessment has been performed for this follow-up.
