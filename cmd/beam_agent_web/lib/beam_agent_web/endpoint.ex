defmodule BeamAgentWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :beam_agent_web

  plug(Plug.Static,
    at: "/assets",
    from: {:beam_agent_web, "priv/static"},
    only: ~w(desk.css desk.js night-shift.svg)
  )

  plug(Plug.Parsers, parsers: [:urlencoded], pass: [], length: 128_000)

  plug(Plug.Session,
    store: :cookie,
    key: "_beam_agent_desk",
    signing_salt: "desk-v1",
    same_site: "Strict",
    http_only: true,
    max_age: 28_800
  )

  plug(BeamAgentWeb.Router)
end

defmodule BeamAgentWeb.ErrorHTML do
  def render(_template, _assigns), do: "Request rejected. Reload the page and try again."
end
