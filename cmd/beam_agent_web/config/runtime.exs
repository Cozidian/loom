import Config

if config_env() != :test do
  config :beam_agent_web,
    runtime_url: System.get_env("BEAM_AGENT_RUNTIME_URL", "http://127.0.0.1:4000"),
    runtime_token: System.get_env("BEAM_AGENT_RUNTIME_TOKEN")

  config :beam_agent_web, BeamAgentWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4100"))]
end
