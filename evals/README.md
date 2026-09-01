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
