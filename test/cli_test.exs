defmodule BeamAgent.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias BeamAgent.CLI

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-cli-test-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")
    data_dir = Path.join(root, "sessions")

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, config_path: config_path, data_dir: data_dir}
  end

  test "non-interactive init writes a complete private first-run config", context do
    {status, output} = init_cli(context)

    assert status == 0
    assert output =~ "Configuration written"
    assert {:ok, config} = BeamAgent.CLI.Config.load(context.config_path)
    assert config["provider"] == "echo"
    assert config["data_dir"] == context.data_dir
    assert config["max_steps"] == 5
    assert config["timeout_ms"] == 4_000

    {:ok, stat} = File.stat(context.config_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "interactive init prompts for every first-run setting", context do
    input = "echo\n#{context.data_dir}\n9\n7000\n"

    {status, output} =
      run_stdout(["init", "--config", context.config_path], input)

    assert status == 0
    assert output =~ "Provider (demo/echo)"
    assert output =~ "Session data directory"

    assert {:ok, config} = BeamAgent.CLI.Config.load(context.config_path)
    assert config["provider"] == "echo"
    assert config["data_dir"] == context.data_dir
    assert config["max_steps"] == 9
    assert config["timeout_ms"] == 7_000
  end

  test "init refuses to overwrite configuration unless force is explicit", context do
    {0, _output} = init_cli(context)

    {status, output} = run_stderr(["init", "--config", context.config_path])
    assert status == 1
    assert output =~ "already exists"
    assert output =~ "--force"
  end

  test "run executes a one-shot prompt from saved configuration", context do
    {0, _output} = init_cli(context)

    {status, output} = run_stdout(["run", "hello from cli", "--config", context.config_path])

    assert status == 0
    assert output =~ "Session session-"
    assert output =~ "agent> echo(1): hello from cli"
    assert File.ls!(context.data_dir) != []
  end

  test "run without a prompt provides an interactive chat and event command", context do
    {0, _output} = init_cli(context)

    {status, output} =
      run_stdout(["run", "--config", context.config_path], "hello\n/events\n/exit\n")

    assert status == 0
    assert output =~ "Interactive mode"
    assert output =~ "agent> echo(1): hello"
    assert output =~ "events at"
  end

  test "doctor and capability discovery expose the runnable configuration", context do
    {0, _output} = init_cli(context)

    {0, doctor} = run_stdout(["doctor", "--config", context.config_path])
    assert doctor =~ "ok  provider  echo"
    assert doctor =~ "ok  runtime"

    {0, providers} = run_stdout(["providers"])
    assert providers =~ "demo\tBeamAgent.Providers.Demo"
    assert providers =~ "echo\tBeamAgent.Providers.Echo"

    {0, tools} = run_stdout(["tools"])
    assert tools =~ "add\tAdd two numbers."
    assert tools =~ "spawn_subagent"
  end

  test "run fails with an actionable message before initialization", context do
    {status, output} =
      run_stderr(["run", "hello", "--config", context.config_path])

    assert status == 1
    assert output =~ "not configured"
    assert output =~ "beam_agent init"
  end

  test "resume refuses to silently create a missing durable session", context do
    {0, _output} = init_cli(context)

    {status, output} =
      run_stderr(["resume", "missing-session", "hello", "--config", context.config_path])

    assert status == 1
    assert output =~ "durable session \"missing-session\" was not found"
  end

  defp init_cli(context) do
    run_stdout([
      "init",
      "--config",
      context.config_path,
      "--provider",
      "echo",
      "--data-dir",
      context.data_dir,
      "--max-steps",
      "5",
      "--timeout",
      "4000",
      "--non-interactive"
    ])
  end

  defp run_stdout(args, input \\ nil) do
    parent = self()
    ref = make_ref()

    fun = fn -> send(parent, {ref, CLI.run(args)}) end

    output =
      if input do
        capture_io(input, fun)
      else
        capture_io(fun)
      end

    assert_receive {^ref, status}
    {status, output}
  end

  defp run_stderr(args) do
    parent = self()
    ref = make_ref()
    output = capture_io(:stderr, fn -> send(parent, {ref, CLI.run(args)}) end)
    assert_receive {^ref, status}
    {status, output}
  end
end
