# Documentation missions

An opt-in, read-only observer for one Git workspace, owned by an OTP goal.
It notices future stable changes and reports possible documentation gaps to that
owner's durable event log. It never edits the checkout or applies a suggestion.

## Start

After `mix escript.build`:

```sh
./beam_agent mission docs --workspace /path/to/repo
```

This creates and publishes a live owner using the selected profile. The terminal
prints its session ID, status and reports. Desk can discover it; `beam_agent attach
SESSION_ID` opens its TUI. Keep the owner terminal running. This is not an installed
daemon or a service that survives terminating its BEAM process.

To add a mission to an already published TUI/Desk owner instead:

```sh
./beam_agent mission SESSION_ID start
./beam_agent mission SESSION_ID status
./beam_agent mission SESSION_ID pause
./beam_agent mission SESSION_ID resume
./beam_agent mission SESSION_ID dismiss
./beam_agent mission SESSION_ID stop
./beam_agent mission SESSION_ID delete
```

These commands attach to the existing authenticated local runtime; they do not
resume a second owner. Pause cancels in-flight inference. Dismiss clears the latest
report from the status view but preserves history and duplicate suppression.

**Stop** cancels the observer assessment, pending fix preparations and its active
fix agents. It preserves scope and reports, so **Resume** can restart observation
without resetting consumed assessment allowance. **Delete** also removes the
observer configuration and current report. In Desk, stop first to reveal Delete.
Neither action deletes session history, source files or retained fix worktrees;
completed fixes keep their outcomes rather than being relabelled cancelled.
Retained fix cards remain available after deleting the observer.

Stopped/deleted state survives observer recovery. Re-adding an observer does not
reset this owner's consumed allowance. The supervised state/controller actor stays
available for management, but its polling timer and execution workers are stopped.
These controls do **not** terminate the owning workspace harness or delete a session.

## Start from a frontend

In **ION**, enter `/mission` (also available in the Ctrl+P command deck).
The observer panel shows its scope, assessment allowance, status and latest report.
Press `s` to start, `p` to pause, `r` to resume, `d` to dismiss the report,
`x` to stop, `X` to delete a stopped observer, or `f`
to refresh. Only currently available actions are enabled; Esc closes the panel.
Both ION and the **Go TUI** also accept `/mission start`, `/mission pause`,
`/mission resume`, `/mission dismiss`, `/mission stop`, `/mission delete` and `/mission status`.

In **Desk**, open the desired live session and find **Documentation observer**.
Choose **Choose folders** to browse the session's repository and add tracked folders
or individual files. The workspace's absolute path is shown above the picker.
Select **Add this folder** at the root (or enter `.`) to watch all tracked files;
otherwise add specific paths, one per line. Submit **Start documentation observer**
when ready. Browsing does not upload files, start inference or change the scope.
The direct Start button in the session panel still uses the defaults below.

To change an existing observer's scope, pause it, choose folders, then **Save watched
paths**. This records a fresh baseline, clears the current report and keeps it paused.
Resume explicitly. Used assessments and the cooldown are preserved, not replenished.
Pause, resume and dismiss controls appear as applicable, and the latest report is
readable directly in the session panel.

The **scope picker** lists only readable Git-tracked paths in the owning session's workspace,
not arbitrary folders on the browser's computer. Traversal and symlinks are excluded.
Listings show up to 200 entries;
enter a more specific relative path for larger directories.

To choose a completely different root, use **Observe a different repository** in
the observer panel (or the corresponding link in its scope editor). This opens a
computer-wide directory browser: Home, `/`, parent folders, or a typed absolute
path. **Use folder for an observer** creates a separate session at that canonical
root using Desk's configured profile, then opens its scope editor. The existing
session and observer stay unchanged. Choose the scope and explicitly start the
new observer there. Creating its session does not start inference. The observer
still needs a Git workspace; choosing a non-Git folder does not initialize Git.
Computer-wide browsing is a local authenticated control-center action, not an
agent tool or expanded access for existing workers.

These controls manage the same supervised mission, not a frontend-owned worker.
Desk polls its current state; open TUI observer panels update on mission events,
including actions taken by another client. Each session has its own observer.
ION starts with the defaults below; Desk also supports custom scope. Use the CLI
or API for custom timing. Keep the owning runtime running, even if you close an attached
TUI or browser tab. Restart older runtime/frontend processes after rebuilding to
load these controls.

## Boundaries and cost

### From a finding to a proposed fix

Desk presents numbered findings as cards with evidence, uncertainty and suggested
action. These labels are parsed from advisory text, not independently verified facts.
The original report and coverage notes remain expandable.

**Prepare a fix** opens a confirmation page; **Start isolated fix agent** is the
explicit authorization. The runtime resolves the selected finding from its own
report and rejects replaced or stale references. It pauses observation, reserves a
single follow-up per finding before starting work, and creates a separate supervised
implementation worker in a retained Git worktree. Duplicate submissions do not start
another worker. Status, output, worker ID, cancellation and the retained path appear
in the observer panel, even if the report is later dismissed.

The worktree is seeded from a bounded snapshot of current tracked files, including
uncommitted changes; untracked files are absent. Source fingerprints are rechecked
during preparation. This requires a valid Git HEAD and the same bounded read access
as observation. The source checkout is not edited. The worker can read/create/edit
files but has no shell, network, publication or delegation tools. Normal runtime
approval and implementation-review rules still apply. It must first re-read the
full evidence and avoid edits if the finding is unsupported.

Follow-ups consume additional model allowance, separate from the observer's assessment
counter. Their status is not proof of verified delivery. Shell tests/rendering cannot
run with this tool set. Review the output and retained worktree; its diff against
HEAD can include pre-existing tracked edits that were copied in. No automatic merge,
commit, push or cleanup is performed. Recheck the original checkout before any later
integration. Cancelling the fix is separate from pausing the read-only observer.
Interrupted preparations are not automatically retried after observer recovery.

### Observation limits

- Nothing runs until explicitly started. Starting records a baseline, so existing
  changes do not immediately trigger an assessment.
- Default scope: tracked files under `lib`, `src`, `test`, `docs`, and `README.md`.
  Use repeated `--path PATH` to narrow it. New untracked files are intentionally
  excluded until added to Git. This first version requires a Git worktree.
- Poll every five seconds; wait for 60 seconds of observed stability and an idle
  coordinating goal with no pending/running delegations. Continuous changes restart the quiet period. Quietness is
  not proof that another editor has finished.
- Default cooldown: 300 seconds. Default maximum: three assessment attempts per
  mission, after which it pauses. `--quiet-seconds`, `--cooldown-seconds` and
  `--max-assessments` configure these at start (minimum timings: ten seconds;
  maximum assessments: twenty). A failed attempt also consumes the allowance.
- Observation uses Git and hashes, not inference. It is bounded to 2,000 tracked
  files, 2 MB per file and 20 MB total. Symlinks, unavailable authority and oversized
  observations fail closed. This is bounded polling, not an optimized filesystem
  watcher for very large repositories.
- Each assessment uses the owner's selected model through an ordinary supervised
  reviewer worker. It receives limited source/documentation excerpts and **no
  tools or write authority**. It cannot inspect the entire repository; incomplete
  coverage must remain explicit. It may consume provider allowance. A run-count
  cap is not a token or monetary quota, and missing usage remains unknown.
- Results are checked against the observed fingerprint before reporting. A change
  during inference produces a stale notice with findings withheld. Later edits can
  also make an older advisory obsolete: revalidate before acting on it.
- Reports and consumed attempts are durable. An observer/coordinator restart
  restores the mission **paused**, never automatically repeating paid work. Resume
  explicitly while the owner is running. The finite allowance is not reset by
  pause, dismiss or restart; use a new mission owner when exhausted.

## Runtime API

All controls use `BeamAgent.Runtime.documentation_mission(client, action, options)`
or the existing authenticated JSON command protocol:

```json
{"version":1,"command":"documentation_mission","arguments":{"action":"start","paths":["lib","README.md"],"max_assessments":3}}
```

Actions: `start`, `status`, `pause`, `resume`, `dismiss`, `browse`, `configure`.
Follow-up actions: `preview_fix` and `prepare_fix` take `report_id` and `finding_id`
from status; `cancel_fix` takes `followup_id`. `preview_fix` is read-only.
`browse` takes a relative `path` (default `.`) and returns the workspace, current
path, parent and readable tracked entries without reading their contents.
`configure` accepts `paths` only while paused and does not reset the allowance.
Start options use string
keys. Public event views retain their normal redaction; authenticated owner
controls expose the report. Status includes `available_actions` for client controls;
the runtime still validates every action.
Main model conversations are not automatically steered by these advisories.

## Evidence and remaining work

Offline tests exercise quiet-period coalescing, duplicate suppression, stale
results, bounded attempts, authority and symlink rejection, cancellation, observer
crash recovery, disconnected clients, CLI controls and one-command discovery/cleanup.
Frontend tests cover command forwarding, runtime-acknowledged TUI updates, Desk
authentication/CSRF, duplicate-start rejection, report escaping, session isolation
and two-tab state synchronization. Desktop and mobile layouts are browser-checked.
They use deterministic providers; this is not yet evidence that a real model
reliably finds useful documentation omissions.

Next: evaluate live finding quality and isolated patch usefulness, then design
diff review/apply controls. The current preparation path is explicitly user-requested,
not autonomous proactive editing. No automatic
integration, cross-workspace fleet, OS service installation or autonomous goal
execution is included in this first slice.
