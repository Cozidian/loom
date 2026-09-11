# Phoenix frontend acceptance task

Build a usable Phoenix frontend over the supplied `HarnessFixture.Runtime` actor.
This small runtime stands in for BeamAgent's public goal API. Keep it authoritative:
the web layer must call its functions, not keep another copy of goal state.

Implement `HarnessFixtureWeb.Endpoint` and `HarnessFixtureWeb.Router`, start the
endpoint under the existing application supervisor, and add the required Phoenix
dependencies. Use normal server-rendered Phoenix pages; a database, JavaScript
build tool, and LiveView are unnecessary for this bounded acceptance task.

- GET `/` shows a heading `Harness`, a goal form with `name="objective"`, and
  the current goals with their objective and status.
- POST `/goals` starts a goal through the runtime and redirects to `/` (302 or
  303). Reject a blank objective with status 422 and a useful error message.
- POST `/goals/:id/cancel` cancels through the runtime and redirects to `/`.
- Escape goal text as HTML. Include CSRF protection in the browser pipeline.
- Provide nonempty error pages: unknown routes must return HTTP 404, and a
  POST without a valid CSRF token must return HTTP 403 without starting a goal.
  Error rendering itself must not crash. Run `mix run --no-start test/http_delivery.exs`
  in addition to `mix test`; the protected HTTP check starts its own loopback server.
- Provide a clear, responsive page with readable goal status and a cancel action
  for active goals. Document `mix phx.server` as the local launch command.

The tests call the endpoint directly and compare the UI to the real actor state.
Do not modify the runtime or weaken the supplied tests. Add files and change
`mix.exs`, application supervision, and configuration as needed. Fetch dependencies
with `run_command` and `network: "external"`. The sandbox exposes a writable
`HEX_HOME`; if Hex is not installed, install it with a workspace-local `MIX_HOME`
and use that same `MIX_HOME` for subsequent commands.
