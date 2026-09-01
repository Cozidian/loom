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
