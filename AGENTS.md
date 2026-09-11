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

## Public maintainer workflow

As of 2026-09-11, Loom is public at https://github.com/Cozidian/loom. The owner
asked for a maintainer mindset and useful GitHub-native workflows going forward.
This supersedes assumptions that development history is private or disposable;
it is not blanket permission to publish, merge, change access or rewrite history.

- Work on focused branches. When publication is authorized, use pull requests
  with intent, linked issues, verification evidence and remaining limitations.
- Inspect live GitHub checks, reviews and mergeability with `gh`; a local green
  suite is not proof that hosted CI passed. Never bypass a failing check casually.
- Use issues and labels for actionable bugs/tasks, milestones for coherent
  delivery goals, and Projects or Discussions when coordination warrants them.
  Avoid duplicating every roadmap idea into an issue automatically.
- Prefer clear PR titles and squash-merge summaries for future history. Do not
  reword published commits, force-push shared branches or delete release tags
  without explicit, scoped authorization.
- Use releases for verified milestones, with changes, upgrade notes and known
  limits. Route vulnerability details through private reporting, not public issues.
- Recheck repository rules, dependency updates and security features as the
  project evolves. Propose protections that fit a solo maintainer; do not require
  an unavailable second reviewer or silently change permissions/automation.

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
