import Config

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["token", "ticket", "_csrf_token"]

config :beam_agent_web, BeamAgentWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4100],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [formats: [html: BeamAgentWeb.ErrorHTML], layout: false],
  secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
  server: false

config :logger, level: :warning
