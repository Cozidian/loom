# Loom Desk

A standalone Phoenix frontend for Loom's existing BeamAgent HTTP/JSON control API.
The runtime owns agents, permissions, work and cancellation. Desk attaches as a
local authenticated client; closing it does not cancel a goal.

## Start

From the harness repository, build once and launch:

```sh
mix loom.build
./loom desk
```

This opens a live-session overview without creating another work session.
It connects to the local Loom service, starting it if needed on macOS. First-run
provider setup uses the same wizard as ION. No exports or manual token copying.
Use `--session ID`, `--tui`, or `--no-open` as needed. Service-owned new-session
defaults come from the selected config. Legacy profile/port overrides remain
available with `desk --foreground`.

You do not need to launch a TUI first. **Start a new session** uses Desk's launch
workspace. **Choose another workspace** opens a computer-wide folder browser with
Home, filesystem root, parent navigation, a typed absolute path and paginated
directory listings. It browses the computer running the runtime, not uploaded
browser files. OS permissions still apply. Confirming a folder creates a separate
session with that canonical root and Desk's configured provider/approval policy;
it never retargets an existing session. No inference starts merely by browsing or
creating the session.

Session startup is a supervised operation rather than one long HTTP request.
The **Opening your workspace** page polls its status; refreshing or repeating the
same form request does not create a duplicate. A slow cold start can exceed the
normal API timeout without turning into a false startup failure. Failed or unknown
operations stay explicit; inspect the overview before starting another operation.
Operation tracking lasts for this runtime process, not across launcher restarts.

### One session, two views

```sh
./loom desk --tui
```

This starts ION and Desk on the **same live runtime session**. A prompt submitted
in either appears in both; the terminal observes externally started/finished
turns too. Exiting the TUI stops this combined launcher and its Desk server.
The command requires an interactive terminal and a built TUI.

Normal interactive CLI launches publish their runtime connection. Desk discovers
them across processes and workspaces. The overview counts sessions; the separate
agent count inside a session counts that owner and its subagents. Older running
binaries need one restart to become discoverable.

Click **Open session** in Desk, or use the command shown on its card:

```sh
./loom attach SESSION_ID
./loom desk --session SESSION_ID
```

These attach to the existing owner, never resume a second copy. Exiting an
attached terminal leaves the owner running. Remote `/new` and `/resume` are
disabled; exit and attach to another ID instead. Browser forms and polling carry
the session ID explicitly, so one tab cannot redirect another tab's commands.

Discovery is same-user and same-machine, bounded to 200 registrations. Only
authenticated, responding endpoints are listed as live. Stopped sessions, older
unregistered runtimes, document/evaluation runs and remote machines are not
included yet. Saved history remains available through CLI session commands.

Private connection descriptors live under `~/.local/share/beam_agent/live`
(directory 0700, files 0600). Bearer tokens stay out of browser pages and URLs.
Symlink descriptors and permissive files are rejected; endpoint identity is
checked before use. This is a local same-user boundary, not multi-user security.

### Read the result

The conversation/output panel displays root-agent prompts and assistant output,
model identity, lifecycle state, and reported verification/review status. It
retains the latest 24 messages with bounded text; longer messages are explicitly
marked as shortened. Full content remains in durable session history. Text is
escaped and whitespace preserved, never executed as model-provided HTML.

The session shell fits the viewport. The prompt composer remains accessible while
session details and long message history scroll inside bounded panels. Polling
preserves their scroll positions. Overview and folder-picker pages scroll inside
their own viewport rather than extending the document beyond the screen.

Desk opts into `/api/v1/conversation`, an owner-content endpoint requiring the
runtime bearer **header**, not a query-string token. The ordinary snapshot and
event view remain redacted, and this endpoint excludes raw tools, reasoning and
child-agent payloads. Embedded HTTP servers must explicitly enable
`conversation: true`; older/activity-only servers show an unavailable-output
notice rather than an apparently empty conversation.

The launcher exits after opening Desk; the Loom service owns the sessions. Closing
the browser or TUI does not cancel work. Use `loom service stop` explicitly to
interrupt it. `loom service install` opts into macOS login startup. See the
[service guide](../../docs/loom-service.md) for recovery and provider setup limits.

The printed launch URL contains a random, single-use **bootstrap ticket**, valid
for 90 seconds, in its fragment. The page removes it before login and exchanges
it through a CSRF-protected POST. It is not the runtime bearer token. Treat the
link as private until used or expired. Run `loom desk` again if it expires or the
eight-hour browser session ends; this renews login without restarting the backend.

## Advanced: attach to a separately managed runtime

Serve an existing session:

```sh
./loom serve SESSION_ID --web-port 4000
```

Copy the printed access token. In another terminal:

```sh
cd cmd/beam_agent_web
mix deps.get
export BEAM_AGENT_RUNTIME_URL=http://127.0.0.1:4000
read -s BEAM_AGENT_RUNTIME_TOKEN
export BEAM_AGENT_RUNTIME_TOKEN
mix phx.server
```

Open `http://localhost:4100` and enter the same token. Never put this runtime
bearer token in a URL. `PORT` changes the frontend port. No provider
settings are changed by this frontend. It binds only to loopback; it is not a
remotely deployable multi-user dashboard. Restarting Desk invalidates browser
sessions but does not stop the separate runtime in this advanced attachment mode.

## This slice

- Authenticated runtime snapshot, actor tree and expandable public event data.
- Prompt submission, cancellation and allow-once/deny approvals through API v1.
- Per-session [documentation observer](../../docs/documentation-missions.md):
  workspace folder/file picker, explicit start, pause, resume, dismiss and readable reports.
  Stop cancels its assessments and fix agents; Delete then removes observer configuration
  while retaining session history and worktrees. The owning workspace harness stays running.
  Change watched paths while paused without resetting the allowance. Read-only, bounded
  assessments use the session model; keep the runtime owner running.
- Two-second polling with visible disconnect/reconnect state; polling pauses
  in hidden tabs. Draft text is kept in this tab's session storage.
- CSRF protection, restricted commands, HTML escaping, strict cookies and CSP.
- The backend bearer token is not embedded in page HTML or client JavaScript.

The runtime's public view intentionally redacts model/tool content. Private
conversation output is separate; Desk does not yet replace ION's attachments,
provider management or an always-on background service. A command timeout is an uncertain
outcome, not proof of rejection; commands are never automatically retried.
Attaching multiple controlling clients inherits the runtime's approval-handler
semantics. `serve` reopens a durable session; do not run two OS processes against
the same active session store.

## Verification

```sh
mix test
mix format --check-formatted
mix compile --warnings-as-errors
npm ci
npm test
```

Browser tests use installed Google Chrome through Playwright. They start with no
sessions or TUI, deliberately delay the first session beyond the old HTTP timeout,
then exercise refresh/deduplication, a different root, observer configuration and
long-output viewport bounds. They use temporary echo-provider workspaces and both
real API and Phoenix servers; they
never attach to your saved sessions. Desktop/mobile screenshots are written to
`test-results/desk-desktop.png` and `test-results/desk-mobile.png` for inspection.
The development fixture can also be opened manually:

```sh
MIX_ENV=test mix run --no-start scripts/browser_fixture.exs
```

Open `http://localhost:4174` with token `local-browser-fixture-token-only`.
This token is for the disposable loopback fixture, never a real workspace.

Tests start the actual BeamAgent runtime with its deterministic echo provider
and communicate over authenticated HTTP. They do not consume provider quota or
prove autonomous code generation. Phoenix is a separate application; the core
harness still has no third-party Elixir dependencies.

Endpoint setup follows the official
[Phoenix endpoint documentation](https://hexdocs.pm/phoenix/Phoenix.Endpoint.html).
