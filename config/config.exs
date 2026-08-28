import Config

config :beam_agent,
  data_dir: Path.join(System.tmp_dir!(), "beam_agent_sessions"),
  provider: :demo,
  strategy: BeamAgent.Strategies.ToolLoop,
  credential_keyring:
    if(config_env() == :test,
      do: BeamAgent.Auth.Keyring.Memory,
      else: BeamAgent.Auth.Keyring.Native
    )
