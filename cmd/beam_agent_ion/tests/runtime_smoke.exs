# Run inside a real terminal/PTY with BEAM_AGENT_TUI_BIN pointing at ION.
# Starts only the deterministic Echo provider, with temporary durable state.
root = Path.join(System.tmp_dir!(), "ion-smoke-#{System.unique_integer([:positive])}")
File.mkdir_p!(root)

{:ok, session} =
  BeamAgent.start_session(
    provider: :echo,
    provider_profile: "echo",
    model_strategy: :manual,
    model_endpoints: [%{id: "echo", provider: :echo}],
    workspace_root: root,
    data_dir: Path.join(root, "runtime")
  )

config = %{
  "provider" => "echo",
  "profile" => "echo",
  "model" => "echo",
  "workspace_root" => root,
  "approval_policy" => "ask",
  "model_strategy" => "manual",
  "data_dir" => Path.join(root, "runtime"),
  "context_window_tokens" => 128_000,
  "compaction_threshold_percent" => 80
}

try do
  :ok = BeamAgent.CLI.TUI.run(session, config, Path.join(root, "config.json"))
after
  BeamAgent.stop_session(session)
  File.rm_rf!(root)
end
