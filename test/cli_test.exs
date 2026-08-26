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
    assert output =~ "Configuration saved"
    assert {:ok, config} = BeamAgent.CLI.Config.load(context.config_path)
    assert config["provider"] == "echo"
    assert config["data_dir"] == context.data_dir
    assert config["max_steps"] == 5
    assert config["timeout_ms"] == 4_000
    assert config["approval_policy"] == "ask"

    {:ok, stat} = File.stat(context.config_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "interactive init prompts for every first-run setting", context do
    input = "echo\n#{context.data_dir}\n9\n7000\n"

    {status, output} =
      run_stdout(["init", "--config", context.config_path], input)

    assert status == 0
    assert output =~ "Choose a provider"
    assert output =~ "ollama"
    assert output =~ "OpenAI"
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
    assert output =~ "beam agent  ·  echo  ·  session"
    assert output =~ "◆ assistant"
    assert output =~ "echo(1): hello from cli"
    assert File.ls!(context.data_dir) != []
  end

  test "interactive chat exposes session context and discoverable commands", context do
    {0, _output} = init_cli(context)

    {status, output} =
      run_stdout(
        ["run", "--config", context.config_path],
        "hello\n/status\n/skills\n/reload\n/help\n/nope\n/events\n/exit\n"
      )

    assert status == 0
    assert output =~ "◆ beam agent"
    assert output =~ "echo  ·  session"
    assert output =~ "Type a message · /help commands"
    assert output =~ "◆ assistant"
    assert output =~ "echo(1): hello"
    assert output =~ "No project skills discovered"
    assert output =~ "Context reloaded"
    assert output =~ "provider  echo"
    assert output =~ "/new"
    assert output =~ "Unknown command /nope"
    assert output =~ "events at"
  end

  test "running without configuration starts setup and then opens chat", context do
    input = "echo\n#{context.data_dir}\n5\n4000\n"

    {status, output} = run_stdout(["--config", context.config_path], input)

    assert status == 0
    assert output =~ "First-time setup"
    assert output =~ "Configuration saved"
    assert output =~ "Type a message · /help commands"
    assert {:ok, config} = BeamAgent.CLI.Config.load(context.config_path)
    assert config["provider"] == "echo"
  end

  test "interactive new command rotates to a fresh durable session", context do
    {0, _output} = init_cli(context)

    {status, output} =
      run_stdout(["run", "--config", context.config_path], "/new\n/exit\n")

    assert status == 0
    assert output =~ "Started a new session"
    assert length(File.ls!(context.data_dir)) == 2
  end

  test "command-specific help is available without configuration", context do
    {0, init_help} = run_stdout(["init", "--help", "--config", context.config_path])
    assert init_help =~ "Configure beam agent"
    assert init_help =~ "--non-interactive"

    {0, run_help} = run_stdout(["run", "--help", "--config", context.config_path])
    assert run_help =~ "Chat with beam agent"
  end

  test "approval UI makes the requested authority and arguments explicit" do
    request = %{
      tool: "create_file",
      access: :write,
      arguments: %{"path" => "notes.txt"}
    }

    parent = self()

    output =
      capture_io("yes\n", fn ->
        send(parent, {:approval_decision, BeamAgent.CLI.UI.approval(request)})
      end)

    assert_receive {:approval_decision, :allow_once}
    assert output =~ "approval required"
    assert output =~ "create_file"
    assert output =~ "notes.txt"
    assert output =~ "Approved once"
  end

  test "doctor and capability discovery expose the runnable configuration", context do
    {0, _output} = init_cli(context)

    {0, doctor} = run_stdout(["doctor", "--config", context.config_path])
    assert doctor =~ "ok  provider  echo"
    assert doctor =~ "ok  runtime"

    {0, providers} = run_stdout(["providers"])
    assert providers =~ "demo\tDeterministic tool/subagent demo\tBeamAgent.Providers.Demo"
    assert providers =~ "echo\tDeterministic echo provider\tBeamAgent.Providers.Echo"
    assert providers =~ "ollama\tOllama (local)\tBeamAgent.Providers.Ollama"
    assert providers =~ "openai\tOpenAI\tBeamAgent.Providers.OpenAI"
    assert providers =~ "anthropic\tAnthropic Claude\tBeamAgent.Providers.Anthropic"
    assert providers =~ "xai\txAI (Grok)\tBeamAgent.Providers.XAI"

    {0, tools} = run_stdout(["tools"])
    assert tools =~ "add\tAdd two numbers."
    assert tools =~ "spawn_subagent"
  end

  test "top-level runtime flags open the interactive command", context do
    {0, _output} = init_cli(context)

    parent = self()

    output =
      capture_io("/status\n/exit\n", fn ->
        status =
          BeamAgent.CLI.run([
            "--config",
            context.config_path,
            "--workspace",
            context.root
          ])

        send(parent, {:top_level_status, status})
      end)

    assert_receive {:top_level_status, 0}
    assert output =~ context.root
  end

  test "skills command discovers project skill metadata without configuration", context do
    skill_dir = Path.join(context.root, ".agents/skills/review")
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: review\ndescription: Review repository changes.\n---\n\nRead the diff.\n"
    )

    {status, output} = run_stdout(["skills", "--workspace", context.root])

    assert status == 0
    assert output =~ "review"
    assert output =~ ".agents/skills/review/SKILL.md"
    assert output =~ "Review repository changes."
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

  test "init configures Ollama model and endpoint without credentials", context do
    {status, output} =
      run_stdout([
        "init",
        "--config",
        context.config_path,
        "--provider",
        "ollama",
        "--model",
        "qwen3:8b",
        "--data-dir",
        context.data_dir,
        "--non-interactive"
      ])

    assert status == 0
    assert output =~ "provider:   ollama"
    assert output =~ "model:      qwen3:8b"
    assert output =~ "base_url:   http://127.0.0.1:11434"
    refute output =~ "api_key"
  end

  test "cloud providers require a model and store only an API-key environment name", context do
    {status, missing_model} =
      run_stderr([
        "init",
        "--config",
        context.config_path,
        "--provider",
        "openai",
        "--non-interactive"
      ])

    assert status == 1
    assert missing_model =~ "invalid configuration value for model"

    {status, output} =
      run_stdout([
        "init",
        "--config",
        context.config_path,
        "--provider",
        "openai",
        "--model",
        "test-model",
        "--api-key-env",
        "MY_OPENAI_KEY",
        "--data-dir",
        context.data_dir,
        "--non-interactive"
      ])

    assert status == 0
    assert output =~ "api_key:    environment MY_OPENAI_KEY"
    refute File.read!(context.config_path) =~ "sk-"
  end

  test "version 1 configurations migrate when loaded", context do
    legacy = %{
      "version" => 1,
      "provider" => "echo",
      "data_dir" => context.data_dir,
      "max_steps" => 5,
      "timeout_ms" => 4_000
    }

    File.mkdir_p!(context.root)
    File.write!(context.config_path, JSON.encode!(legacy))

    assert {:ok, migrated} = BeamAgent.CLI.Config.load(context.config_path)
    assert migrated["version"] == 3
    assert Map.has_key?(migrated, "model")
    assert Map.has_key?(migrated, "base_url")
    assert Map.has_key?(migrated, "api_key_env")
  end

  test "grok CLI alias resolves to the xAI runtime provider", context do
    {status, output} =
      run_stdout([
        "init",
        "--config",
        context.config_path,
        "--provider",
        "grok",
        "--model",
        "grok-test",
        "--data-dir",
        context.data_dir,
        "--non-interactive"
      ])

    assert status == 0
    assert output =~ "provider:   grok"
    assert {:ok, :xai} = BeamAgent.CLI.Config.provider_atom("grok")
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
