# Working on Loom

Loom is an early, macOS-first personal agent harness. Small, evidence-backed
improvements are welcome. Read the [vision](VISION.md), then verify assumptions
against current code; the roadmap is a direction to discuss, not a specification.

## Set up

Use Elixir 1.19 with compatible Erlang/OTP (tested with OTP 28), Rust 1.88+ and
Git. Go 1.26+ is needed only for the original Go frontend. Node.js/npm and Google
Chrome are needed for browser tests. The guarded document rendering adapter
additionally requires macOS, Microsoft Word and Poppler; see the
[document guide](docs/document-workflow.md).

```sh
mix loom.build
./beam_agent_ion --demo
```

The demo does not need provider credentials. Tests use temporary workspaces and
fixtures; do not substitute real credentials or invoke paid models to test a
routine change. Build output and local trial documents do not belong in Git.

## Check a change

[GitHub Actions](.github/workflows/ci.yml) runs the runtime, terminal and browser
checks on macOS, with pinned action revisions and no provider credentials. Native
Word automation and the launchd lifecycle smoke remain separate local checks.

From the repository root:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
cargo test --locked --manifest-path cmd/beam_agent_ion/Cargo.toml
cargo clippy --locked --manifest-path cmd/beam_agent_ion/Cargo.toml --all-targets -- -D warnings
go test ./cmd/beam_agent_tui
git diff --check
```

For Desk, from `cmd/beam_agent_web`:

```sh
mix deps.get
mix format --check-formatted
mix test
npm ci
npm test
```

Browser tests start their own echo-provider runtime and use installed Chrome.
The optional `node scripts/service_smoke.cjs` check requires macOS and built
clients; it creates and removes its own temporary launchd job. It does not install
a login item or use personal provider credentials.

## Useful contributions

Describe the intended outcome, actual behavior, platform, exact command and
smallest reproduction. Include the checks you ran and anything still unverified.
For visual changes, include a screenshot without private workspace or agent data.
Never include auth tokens, launch links, session dumps or private documents.

Keep changes focused. OTP owns execution and durable state; clients should not
become competing orchestration engines. Add regressions for lifecycle and
permission changes, preserve compatibility deliberately, and distinguish test
evidence from claims of unattended real-world reliability.

Use commit messages that name the behavior changed, such as
`fix(desk): preserve session selection after reconnect`, rather than `fix stuff`.
