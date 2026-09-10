# BeamAgent evaluations

Evaluation manifests exercise the complete harness against isolated copies of fixture repositories. The checked-in `coding.json` suite starts with an intentionally incomplete clipboard-image feature and deterministic tests, so a real provider must inspect, implement, and verify code rather than merely return a plausible answer.

```json
{
  "version": 1,
  "scenarios": [
    {
      "id": "implement-image-paste",
      "fixture": "fixtures/image-paste",
      "prompt": "Implement clipboard image paste and add regression coverage.",
      "timeout_ms": 300000,
      "checks": [
        {"id": "tests", "command": "mix test", "timeout_ms": 120000}
      ],
      "expect": {
        "files": ["lib/image_paste.ex"],
        "file_contains": [{"path": "lib/image_paste.ex", "text": "clipboard"}],
        "answer_contains": ["Implemented"]
      }
    }
  ]
}
```

Run the scenarios with the active configured provider:

```sh
mix beam_agent.eval evals/coding.json
```

Check the manifest, fixture and protected originals first, without loading
provider configuration, starting a session or running shell checks:

```sh
mix beam_agent.eval evals/coding.json --preflight
mix beam_agent.eval evals/phoenix_frontend.json --preflight
```

Preflight readiness is not a passing delivery trial. It does not install
dependencies, call a model, render a document or inspect a browser.

Use `--model MODEL --model-strategy manual` to run a control on an available
model without changing saved profiles. Manual mode includes the independent
completion reviewer.

`phoenix_frontend.json` asks the harness to build a real Phoenix frontend over
a small supplied OTP runtime. It starts with no web dependencies or frontend
implementation. Acceptance checks render the endpoint and exercise goal
creation, cancellation, validation and HTML escaping against the actor's state.
This is a bounded frontend task, not a full web client for BeamAgent.

```sh
mix beam_agent.eval evals/phoenix_frontend.json --model YOUR_MODEL --model-strategy manual
```

The live run can take up to ten minutes and needs dependency downloads. The
model must request `run_command` with `network: "external"`; the normal
capability/approval boundary controls it. The evaluation uses auto approvals
inside its isolated fixture workspace and keeps all artifacts and runtime logs.

Every run retains its isolated workspace, canonical runtime logs, and `report.json`. Reports include verified completion, duration, model/tool calls, delegated workers, approval requests, permission denials, repairs, stalls, cancellations, and the contract-scoped workspace artifact.

## Artifact integrity and honest measurement

Scenarios can now declare content invariants in `expect`:

```json
{
  "preserved_files": ["test/acceptance_test.exs", "source/original.bin"],
  "changed_files": ["output/result.bin"]
}
```

These are relative file paths, not globs. SHA-256 fingerprints are captured
before the model runs, outside its conversation, and compared after the turn
and verification. Binary files are supported. A protected original must exist
and be readable before any model call. Missing or changed protected files fail
the scenario; changes detected before acceptance prevent those commands from
running. A requested changed file must be created or have different content;
a no-op or deletion does not count. The checked-in coding and Phoenix scenarios
protect their supplied acceptance tests; Phoenix also protects its runtime.

This detects final content changes, including formatting-only changes. It is
not immutable storage or a security boundary against a malicious process, and
does not check permissions, metadata, transient edits, document layout, or test
runner configuration. Declare all relevant protected inputs; inspecting the
actual result remains necessary.

Reports distinguish `completion_rate` (all configured expectations satisfied)
from `verified_completion_rate` (also at least one required deterministic check
passed). Answer-only scenarios and optional-only checks cannot satisfy a
verified-completion gate. Here **verified means command-verified**, not visually
reviewed, correct in every editor, or proven against an independent hidden suite.

Missing provider usage produces `total_tokens: null`, not zero. `reported_tokens`
retains the observed subtotal; `usage_reported_calls`, `usage_missing_calls` and
`usage_status` distinguish complete, partial, unknown and no-call measurements.
A failed call without reported usage contributes to missing coverage. The CLI
prints an unknown total explicitly. An explicitly reported zero remains zero.
`usage_unavailable_runs` flags runner failures where event evidence could not be
collected at all, which also make the total unknown.
None of these token counters establish financial cost or account quota usage.
Approval-request counts remain a proxy for interventions, not a measure of all
clarifying questions or user effort.

Malformed expectation lists, unknown expectation keys, conflicting changed and
preserved paths, and duplicate scenario IDs are rejected instead of silently
weakening a trial or sharing its workspace.

## Multi-provider acceptance gate

`automatic_specialization.json` is a historical multi-endpoint probe. Its
multiple-endpoint gate is not a current product requirement: task teams may use
the same model, and the runtime no longer injects a fixed pair of cheap helpers.
Run it only when intentionally investigating multiple actual endpoint leases.
Worker success/usefulness should also be inspected in the retained worker logs;
multiple leases alone are not a quality or latency benchmark. See
[task teams](../docs/task-teams.md) for the current execution model.

```sh
mix beam_agent.eval evals/automatic_specialization.json --model YOUR_MODEL --model-strategy auto
```

`multi_provider_acceptance.json` repeats the same feature-sized task five times
and fails unless at least four runs complete with deterministic verification and
actually use multiple endpoint leases. It also rejects permission denials, user
approval prompts in auto mode, confirmed stalls, and excessive average model
calls. Suspected stalls are reported separately because a slow provider that is
still producing checkpoints is not a confirmed no-progress loop.

```sh
mix beam_agent.eval evals/multi_provider_acceptance.json --profile YOUR_PRIMARY_PROFILE
```

The suite intentionally requires at least two eligible configured endpoints.
Use the ordinary `coding.json` suite as the single-provider control and compare
the retained reports rather than treating one successful demonstration as
routing evidence.
