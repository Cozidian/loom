# BeamAgent Desk

A standalone Phoenix frontend for the real BeamAgent HTTP/JSON control API.
The runtime owns agents, permissions, work and cancellation. Desk attaches as a
local authenticated client; closing it does not cancel a goal.

## Start

In the harness repository, serve an existing session:

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

Open `http://localhost:4100` and enter the same token. The URL must not contain
the token or a query string. `PORT` changes the frontend port. No provider
settings are changed by this frontend. It binds only to loopback; it is not a
remotely deployable multi-user dashboard. Restarting Desk invalidates browser
sessions but does not stop the separate runtime.

## This slice

- Authenticated runtime snapshot, actor tree and expandable public event data.
- Prompt submission, cancellation and allow-once/deny approvals through API v1.
- Two-second polling with visible disconnect/reconnect state; polling pauses
  in hidden tabs. Draft text is kept in this tab's session storage.
- CSRF protection, restricted commands, HTML escaping, strict cookies and CSP.
- The backend bearer token is not embedded in page HTML or client JavaScript.

The runtime's public view intentionally redacts model/tool content. This is an
activity control panel, not yet a replacement for ION's conversation, attachments,
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
