defmodule BeamAgentWeb.Router do
  use Phoenix.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
      "referrer-policy" => "no-referrer",
      "cache-control" => "no-store"
    })

    plug(:loopback_host)
  end

  scope "/", BeamAgentWeb do
    pipe_through(:browser)
    get("/", DeskController, :index)
    post("/login", DeskController, :login)
    post("/launch", DeskController, :launch)
    post("/logout", DeskController, :logout)
    get("/panels", DeskController, :panels)
    get("/observer", DeskController, :observer)
    get("/observer/paths", DeskController, :observer_paths)
    get("/observer/followup", DeskController, :observer_followup)
    get("/observatory", DeskController, :observatory)
    get("/observatory/data", DeskController, :observatory_data)
    get("/sessions-panel", DeskController, :sessions_panel)
    post("/sessions", DeskController, :create_session)
    get("/sessions", DeskController, :index)
    get("/workspaces", DeskController, :workspaces)
    get("/workspaces/paths", DeskController, :workspace_paths)
    get("/session-starts/:id", DeskController, :session_start)
    get("/session-starts/:id/status", DeskController, :session_start_status)
    get("/sessions/:session_id", DeskController, :session)
    get("/sessions/:session_id/panels", DeskController, :panels)
    get("/sessions/:session_id/observer", DeskController, :observer)
    get("/sessions/:session_id/observer/paths", DeskController, :observer_paths)
    get("/sessions/:session_id/observer/followup", DeskController, :observer_followup)
    get("/sessions/:session_id/observatory", DeskController, :observatory)
    get("/sessions/:session_id/observatory/data", DeskController, :observatory_data)
    post("/sessions/:session_id/commands/:command", DeskController, :command)
    post("/commands/:command", DeskController, :command)
  end

  defp loopback_host(conn, _opts) do
    if conn.host in ["localhost", "127.0.0.1"],
      do: conn,
      else: conn |> send_resp(403, "Local access only") |> halt()
  end
end
