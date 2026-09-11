# Working on Loom

Start with [VISION.md](VISION.md) for evolving product intent. Read the relevant
part of [ROADMAP.md](ROADMAP.md) for proposed experiments, then inspect current
code, tests and observed behavior before acting on implementation claims.

## Knowledge, never specifications

Vision, roadmap, notes and historical decisions are evidence and current
understanding—not frozen specifications or authorization for extra work.
The user welcomes changing direction when something new is learned. Do not
enforce an old note against a newer user decision or treat a task list as an
instruction to implement everything on it.

When capturing knowledge, keep it small and readable. Include the reason and
supporting evidence, distinguish facts from hypotheses, and mark superseded
beliefs rather than erasing their history. Reuse the relevant document instead
of creating competing sources of truth. No requirement ceremonies or new
approval gates just to update an understanding.

## Working habits

- Follow the current request. Analysis is not implicit permission to edit;
  local implementation is not implicit permission to push, publish or deploy.
- Preserve unrelated changes and user artifacts. Check the worktree before
  editing. Do not modify real provider credentials/settings or invoke paid
  providers merely to test a documentation or runtime change.
- Preserve runtime-owned authority: OTP owns execution, lifecycle, permissions,
  cancellation and durable state. Clients are views/controllers, not competing
  orchestration engines. Revisit architecture when evidence warrants it without
  silently bypassing active safety boundaries.
- Judge completion by usable artifacts and proportionate verification, not
  model claims. For web work, exercise and visually inspect the running result
  where possible. For document work, preserve the original and inspect rendered
  output. Clearly report any check that was not performed.
- Keep the handoff centered on what changed, why and what remains unfinished.
  Prefer the smallest useful experiment over speculative platform expansion.

## Navigation and checks

- [Operations](docs/operations.md): setup, providers, runtime APIs and commands.
- [Architecture](docs/architecture.md): implementation-oriented background;
  verify details against source rather than treating it as permanent design.
- [ION](docs/ion-tui.md) and [task teams](docs/task-teams.md): current UI/runtime notes.
- [Earlier roadmap](docs/roadmap-history.md): historical context, not an active backlog.

For code changes, select relevant tests before broader checks:

```sh
mix test
mix format --check-formatted
cargo test --locked --manifest-path cmd/beam_agent_ion/Cargo.toml
cargo clippy --locked --manifest-path cmd/beam_agent_ion/Cargo.toml --all-targets -- -D warnings
go test ./cmd/beam_agent_tui
git diff --check
```

Documentation-only work normally needs link/path checks, CLI example validation
where practical, and visual review of added artwork—not a paid model evaluation.
Knowledge can change; live permissions and honest verification still matter.
