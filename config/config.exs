import Config

config :beam_agent,
  data_dir: Path.join(System.tmp_dir!(), "beam_agent_sessions"),
  provider: :demo,
  strategy: BeamAgent.Strategies.ToolLoop
