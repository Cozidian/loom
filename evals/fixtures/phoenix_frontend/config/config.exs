import Config

config :harness_fixture, HarnessFixtureWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: String.duplicate("fixture-development-only-", 4),
  server: false
