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
    get("/sessions-panel", DeskController, :sessions_panel)
    post("/sessions", DeskController, :create_session)
    get("/sessions/:session_id", DeskController, :session)
    get("/sessions/:session_id/panels", DeskController, :panels)
    post("/sessions/:session_id/commands/:command", DeskController, :command)
    post("/commands/:command", DeskController, :command)
  end

  defp loopback_host(conn, _opts) do
    if conn.host in ["localhost", "127.0.0.1"],
      do: conn,
      else: conn |> send_resp(403, "Local access only") |> halt()
  end
end
