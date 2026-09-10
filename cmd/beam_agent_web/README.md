# BeamAgent Desk

A standalone Phoenix frontend for the real BeamAgent HTTP/JSON control API.
The runtime owns agents, permissions, work and cancellation. Desk attaches as a
local authenticated client; closing it does not cancel a goal.

## Start

From the harness repository, build once and launch:

```sh
mix beam_agent.build
./beam_agent desk
```

This opens a live-session overview without creating another work session.
It starts the catalog API and browser client on loopback ports. First-run
provider setup uses the same wizard as ION. No exports or manual token copying.
Use `--workspace PATH`, `--profile NAME`, `--port 4100`, or `--no-open` as needed.

### One session, two views

```sh
./beam_agent desk --tui
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
./beam_agent attach SESSION_ID
./beam_agent desk --session SESSION_ID
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

Desk opts into `/api/v1/conversation`, an owner-content endpoint requiring the
runtime bearer **header**, not a query-string token. The ordinary snapshot and
event view remain redacted, and this endpoint excludes raw tools, reasoning and
child-agent payloads. Embedded HTTP servers must explicitly enable
`conversation: true`; older/activity-only servers show an unavailable-output
notice rather than an apparently empty conversation.

Keep Desk's terminal open. Stopping it stops Desk and sessions created by its
**Start a new session** button, not independently running TUIs. Closing the
browser alone does not cancel work. Durable history remains; Desk is not a daemon.

The printed launch URL contains a random, single-use **bootstrap ticket**, valid
for 90 seconds, in its fragment. The page removes it before login and exchanges
it through a CSRF-protected POST. It is not the runtime bearer token. Treat the
link as private until used or expired; restart the launcher if it expires.

## Advanced: attach to a separately managed runtime

Serve an existing session:

```sh
./beam_agent serve SESSION_ID --web-port 4000
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
- Two-second polling with visible disconnect/reconnect state; polling pauses
  in hidden tabs. Draft text is kept in this tab's session storage.
- CSRF protection, restricted commands, HTML escaping, strict cookies and CSP.
- The backend bearer token is not embedded in page HTML or client JavaScript.

The runtime's public view intentionally redacts model/tool content. Private
conversation output is separate; Desk does not yet replace ION's attachments,
provider management or persistent missions. A command timeout is an uncertain
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

Browser tests use installed Google Chrome through Playwright. They start a
temporary echo-provider workspace and both real API and Phoenix servers; they
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
