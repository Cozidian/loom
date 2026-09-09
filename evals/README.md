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

## Multi-provider acceptance gate

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
