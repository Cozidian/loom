# Loom — one runtime, many views

Loom is the product name. `BeamAgent` remains the internal Elixir/API namespace
for compatibility; existing configuration, credential references, discovery and
session storage are not renamed or copied. `LOOM_CONFIG` and `LOOM_TUI_BIN` are
aliases for the previous environment overrides. New service state alone lives
under `~/.local/share/loom/service`, in owner-private files.

## Everyday use on macOS

```sh
mix loom.build
mix loom.install               # optional: symlink `loom` onto your PATH
./loom                         # initialize if needed; attach a workspace TUI
./loom desk                    # open or reauthenticate the web view
./loom tui --workspace /path/to/repo
./loom attach SESSION_ID        # explicitly choose another live session
```

`mix loom.install` (`--bin-dir DIR` to choose where, `--no-build` to skip the
build) links the executable into `~/.local/bin` by default, so `loom` works
from any workspace once that directory is on your PATH. It is a symlink, not a
standalone copy: the checkout still has to stay put next to it.

The service starts on demand under your user account, independent of the invoking
terminal. A TUI reuses the most recently started live session in its canonical
workspace, or creates one if none exists. Use `--session ID` to choose explicitly.
Desk opens the overview without creating a work session; `desk --tui` attaches both
views to the same session. Closing a client does not cancel agents or observers.
Single-shot `loom run` and explicit `loom resume` remain terminal-owned workflows.
`desk --foreground` retains the older combined launcher and its `--port` option.

```sh
./loom service start            # idempotent; current macOS login
./loom service status           # owner, config, Desk readiness, recovery results
./loom service logs             # recent lifecycle log text
./loom service install          # opt in to starting at login
./loom service stop             # interrupts owned active work, retains history
./loom service uninstall        # stop and remove Loom registration, not user data
./loom service run              # foreground backend; also usable without launchd
```

The [per-user LaunchAgent mechanism](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
runs under your account, not root. Login installation is explicit. macOS sleep
pauses execution; logout ends the user service. It is not a machine that keeps
computing while asleep. Automatic service management currently targets macOS.
Run/build from the checkout: the service still requires Elixir/Mix and the Phoenix
source/dependencies beside the executable. This is not yet a standalone installer.

## Getting back in after overnight expiry

Run `./loom desk` again. It asks the already-running backend to mint a fresh,
single-use, 90-second browser login ticket. The browser session lasts eight hours.
The runtime's bearer credential is neither printed nor placed in the browser URL.
Independent launch tickets can coexist; consuming one does not invalidate another.

Local discovery is owner-private, validates the service's live identity, and uses
authenticated loopback APIs. Ticket issuance goes through the backend's private
pipe to its web child, with acknowledgement before returning a link. Browser
mutations still require CSRF protection. Merely visiting localhost cannot mint a
new ticket. `--no-open` prints a sensitive, short-lived link for manual opening.

Desk can restart independently of agents; reopen it with `loom desk` if its port
changes. A pre-Loom Desk/TUI still owns its original sessions: leave that owner
running until ready to interrupt it. The service can discover those live sessions,
but it does not silently adopt or resume their storage.

## Recovery and boundaries

The service records only the IDs, canonical workspaces, data directories and profile
names of sessions it creates. Recovery restores those sessions **idle**, not their
previous model calls. Documentation observers restore paused; stopped/deleted state
is retained. Interrupted fix preparation is not replayed. Missing workspaces or
profiles appear as recovery failures in `service status`; no alternate profile is
chosen silently. Use session history to inspect interrupted work and explicitly
decide what to continue. Existing guards still reject stale findings and preserve
retained worktrees.

There is one service per private service directory. A stable loopback listener and
launchd job identity prevent duplicate owners. A different `--config` cannot silently
retarget a running service. Stop/uninstall its registration before changing its
configuration path or moving the executable. Normal edits within the existing
config still work, but restart the service to refresh its new-session defaults.

Provider API keys exported only in a terminal are **not** automatically copied into
the LaunchAgent. Prefer Loom's existing credential-store login flow. The registration
contains executable/config paths and PATH, never API keys or runtime tokens. Providers
requiring shell-only environment setup may need `service run` in that environment.

## Verification

`mix test test/service_test.exs` covers identity/privacy, real TUI socket disconnect,
paused/deleted observer recovery and registration escaping. Desk tests cover fresh
ticket reauthentication and concurrent one-time links. On macOS, after building:

```sh
cd cmd/beam_agent_web
node scripts/service_smoke.cjs
```

The smoke uses its own temporary config, echo provider, service job and discovery
directory. It exercises launchd, Chrome login renewal, TUI detach and service restart
without installing a login item or changing personal credentials.

## Runtime incident captures

The service enables a supervised diagnostics recorder at startup. It samples
independently of session GenServer calls, so a blocked conversation does not
need to answer a request before it can be observed. The recorder does not
cancel work; Codex's resource limits retain that responsibility.

```sh
./loom diagnostics status
./loom diagnostics capture
./loom diagnostics stop
./loom diagnostics start
```

These commands contact the running service through its authenticated loopback
API. `capture` prints the saved JSON path and size; it also works while automatic
recording is paused. `stop` pauses automatic sampling without removing captures.
Starting the service again enables recording. Commands do not start a service
or resume sessions implicitly.

Reports go into `diagnostics/` under the service directory (normally
`~/.local/share/loom/service`, or `LOOM_SERVICE_DIR`). The directory is mode 0700
and captures are mode 0600. Each capture contains a trigger and recent samples:

- BEAM memory totals, including process, binary and ETS allocation; process heap
  sizes are in words, with `word_size_bytes` supplied for conversion.
- Up to 48 processes selected by memory, mailbox length and change in reductions,
  with session/actor identities where registered and up to 12 stack frames.
- Up to 64 provider progress records: turn age, received bytes/messages, retained
  text bytes, prefix mode, fixed channel counters and owned subprocess IDs.
- OS RSS and `ps` lifetime-average CPU percentages for BEAM and sampled Codex
  subprocesses. An empty OS list means metrics were unavailable, not zero usage.

Defaults are one sample every five seconds, at most 24 samples and 1.5 MB of
encoded history in memory, five retained JSON reports and 2 MiB per report.
Sampling scans at most 4,096 processes per pass, rotating through larger process
sets and marking incomplete coverage. A supervised sampling task has a two-second
watchdog; failures appear in `diagnostics status`. Reductions are an execution
counter, not CPU time; the first observation has no reduction delta.

Automatic capture triggers on a process reaching 256 MiB, a mailbox reaching
10,000 messages, BEAM allocation growing by 64 MiB between samples, or BEAM
allocation/observed OS RSS reaching 1 GiB. Automatic writes are limited to once
per minute. Codex duration/byte/message/line limits additionally save a small
pre-cleanup process snapshot into one fixed pending slot. Concurrent failures
coalesce to the latest snapshot; it is written on an eligible sampling pass even
if the emitting process has already exited.

No process state, dictionaries, mailbox contents, raw messages, prompts,
credentials or command lines are dumped. Binary totals are VM-wide, not proof
that a specific actor owns a particular binary. This is a bounded incident
recorder, not a full heap dump or tracing profiler. Its recent history and pending
limit snapshot are in memory until a report is written; an abrupt whole-VM exit
can lose that unsaved evidence. Deeper analysis can follow from the identified
process and resource category.

For embedded runtimes, `BeamAgent.Diagnostics.configure(directory: path,
owner: self())` enables the same recorder. It remains dormant without a configured
owner; owner death stops recording. Programmatic options `:interval_ms`,
`:memory_threshold`, `:growth_threshold` and `:mailbox_threshold` adjust sampling
and the corresponding automatic triggers. `BeamAgent.Diagnostics.capture/0`,
`status/0` and `enable/1` are the reusable runtime API.
