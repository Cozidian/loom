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

  test "new entry points are discoverable without loading a provider configuration", ctx do
    {0, help} = run_stdout(["--help", "--config", ctx.config_path])
    assert help =~ "loom desk"
    assert help =~ "loom document"
    assert help =~ "loom mission"
    {0, mission} = run_stdout(["mission", "--help", "--config", ctx.config_path])
    assert mission =~ "--max-assessments 3"
    assert mission =~ "not an installed background service"
    {0, desk} = run_stdout(["desk", "--help", "--config", ctx.config_path])
    assert desk =~ "No exported variables"
    assert desk =~ "--tui"
    assert desk =~ "SAME live session"
    {0, document} = run_stdout(["document", "--help", "--config", ctx.config_path])
    assert document =~ "visual review"
  end

  test "Desk without a TUI reaches normal option validation instead of crashing", context do
    {0, _} = init_cli(context)

    for flags <- [[], ["--no-tui"]] do
      {status, output} =
        run_stderr(
          ["desk", "--foreground", "--config", context.config_path, "--port", "-1"] ++ flags
        )

      assert status == 2
      assert output =~ "--port must be between 0 and 65535"
    end
  end

  test "non-interactive init writes a complete private first-run config", context do
    {status, output} = init_cli(context)

    assert status == 0
    assert output =~ "Configuration saved"
    assert {:ok, config} = BeamAgent.CLI.Config.load(context.config_path)
    assert config["active_profile"] == "echo"
    assert get_in(config, ["profiles", "echo", "provider"]) == "echo"
    assert config["data_dir"] == context.data_dir
    refute Map.has_key?(config, "max_steps")
    refute Map.has_key?(config, "timeout_ms")
    assert config["approval_policy"] == "ask"
    assert config["model_strategy"] == "auto"
    assert config["context_window_tokens"] == 32_000
    assert config["compaction_threshold_percent"] == 75

    {:ok, stat} = File.stat(context.config_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "interactive init prompts for every first-run setting", context do
    input = "echo\n#{context.data_dir}\n"

    {status, output} =
      run_stdout(["init", "--config", context.config_path], input)

    assert status == 0
    assert output =~ "Choose a provider"
    assert output =~ "ollama"
    assert output =~ "OpenAI"
    assert output =~ "Session data directory"

    assert {:ok, config} = BeamAgent.CLI.Config.load(context.config_path)
    assert config["active_profile"] == "echo"
    assert config["data_dir"] == context.data_dir
    refute Map.has_key?(config, "timeout_ms")
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
    assert output =~ "Loom  ·  echo  ·  session"
    assert output =~ "◆ assistant"
    assert output =~ "echo(1): hello from cli"
    assert File.ls!(context.data_dir) != []
  end

  test "interactive chat exposes session context and discoverable commands", context do
    {0, _output} = init_cli(context)

    {status, output} =
      run_stdout(
        ["run", "--config", context.config_path],
        "hello\n/status\n/models\n/models refresh\n/compact\n/skills\n/reload\n/help\n/nope\n/events\n/tree\n/exit\n"
      )

    assert status == 0
    assert output =~ "◆ Loom"
    assert output =~ "echo  ·  session"
    assert output =~ "Type a message · /help commands"
    assert output =~ "◆ assistant"
    assert output =~ "echo(1): hello"
    assert output =~ "No project skills discovered"
    assert output =~ "Context reloaded"
    assert output =~ "provider  echo"
    assert output =~ "Nothing to compact"
    assert output =~ "/compact"
    assert output =~ "/new"
    assert output =~ "Model registry"
    assert output =~ "* echo  echo/provider default  local"
    assert output =~ "Checking 1 model endpoints"
    assert output =~ "Unknown command /nope"
    assert output =~ "events at"
    assert output =~ "Goal tree"
    assert output =~ "Goal" or output =~ "completed"
  end

  test "startup capacity flags reach the goal and project without rewriting config", context do
    {0, _} = init_cli(context)
    id = "capacity-#{System.unique_integer([:positive])}"

    {0, _} =
      run_stdout([
        "run",
        "hello",
        "--config",
        context.config_path,
        "--workspace",
        context.root,
        "--session",
        id,
        "--max-workers",
        "6",
        "--model-concurrency",
        "7"
      ])

    assert {:ok, budget} = BeamAgent.budget(id)
    allocation = Enum.find(budget.allocations, &(&1.worker_id == id))
    assert allocation.limits.concurrent_workers == 6
    assert {:ok, goal} = BeamAgent.goal(id)

    assert {:ok, %{model: %{limit: 7}, expensive_model: %{limit: 7}}} =
             BeamAgent.resource_pools(goal.project_id)

    assert {:ok, saved} = BeamAgent.CLI.Config.load(context.config_path)
    assert saved["max_workers"] == 4
    assert saved["model_concurrency"] == 4
  end

  test "auto mode can be configured and toggled during chat", context do
    {status, setup_output} =
      run_stdout([
        "init",
        "--config",
        context.config_path,
        "--provider",
        "echo",
        "--data-dir",
        context.data_dir,
        "--approval",
        "auto",
        "--non-interactive"
      ])

    assert status == 0
    assert setup_output =~ "approval:   auto"
    assert setup_output =~ "routing:    auto"
    assert {:ok, config} = BeamAgent.CLI.Config.load(context.config_path)
    assert config["approval_policy"] == "auto"

    {status, output} =
      run_stdout(
        ["run", "--config", context.config_path],
        "/status\n/auto\n/status\n/auto\n/status\n/help\n/exit\n"
      )

    assert status == 0
    assert output =~ "approval  auto"
    assert output =~ "routing   auto"
    assert output =~ "Auto mode disabled"
    assert output =~ "approval  ask"
    assert output =~ "Auto mode enabled"
    assert output =~ "/auto"
  end

  test "running without configuration starts setup and then opens chat", context do
    input = "echo\n#{context.data_dir}\n"

    {status, output} = run_stdout(["--config", context.config_path], input)

    assert status == 0
    assert output =~ "First-time setup"
    assert output =~ "Configuration saved"
    assert output =~ "Type a message · /help commands"
    assert {:ok, config} = BeamAgent.CLI.Config.load(context.config_path)
    assert config["active_profile"] == "echo"
  end

  test "interactive new command rotates to a fresh durable session", context do
    {0, _output} = init_cli(context)

    {status, output} =
      run_stdout(["run", "--config", context.config_path], "/new\n/exit\n")

    assert status == 0
    assert output =~ "Started a new session"

    sessions =
      context.data_dir
      |> File.ls!()
      |> Enum.filter(&File.regular?(Path.join([context.data_dir, &1, "events.jsonl"])))

    assert length(sessions) == 2
  end

  test "command-specific help is available without configuration", context do
    {0, init_help} = run_stdout(["init", "--help", "--config", context.config_path])
    assert init_help =~ "Configure Loom"
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

    if :os.type() == {:unix, :darwin} do
      assert doctor =~ "ok  sandbox   macos-seatbelt (workspace-write)"
    else
      assert doctor =~ "warn sandbox   unavailable"
    end

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
            context.root,
            "--no-tui"
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
    assert output =~ "loom init"
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

  test "cloud providers store only an API-key environment name", context do
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
    assert migrated["version"] == 11
    refute Map.has_key?(migrated, "max_steps")
    refute Map.has_key?(migrated, "timeout_ms")
    assert migrated["active_profile"] == "echo"
    assert get_in(migrated, ["profiles", "echo", "provider"]) == "echo"
    assert Map.has_key?(migrated["profiles"]["echo"], "model")
    assert migrated["context_window_tokens"] == 32_000
    assert migrated["compaction_threshold_percent"] == 75
  end

  test "version 3 single-provider configuration becomes one active profile", context do
    legacy = %{
      "version" => 3,
      "provider" => "ollama",
      "model" => "qwen3:8b",
      "base_url" => "http://127.0.0.1:11434",
      "api_key_env" => nil,
      "approval_policy" => "ask",
      "data_dir" => context.data_dir,
      "max_steps" => 8,
      "timeout_ms" => 30_000
    }

    File.mkdir_p!(context.root)
    File.write!(context.config_path, JSON.encode!(legacy))

    assert {:ok, migrated} = BeamAgent.CLI.Config.load(context.config_path)
    assert migrated["version"] == 11
    refute Map.has_key?(migrated, "max_steps")
    refute Map.has_key?(migrated, "timeout_ms")
    assert migrated["active_profile"] == "ollama"
    assert get_in(migrated, ["profiles", "ollama", "model"]) == "qwen3:8b"
    assert {:ok, runtime} = BeamAgent.CLI.Config.runtime(migrated)
    assert runtime["provider"] == "ollama"
    assert runtime["profile"] == "ollama"
  end

  test "version 4 profile configuration gains context defaults", context do
    legacy = %{
      "version" => 4,
      "active_profile" => "echo",
      "profiles" => %{
        "echo" => %{
          "provider" => "echo",
          "model" => nil,
          "base_url" => nil,
          "api_key_env" => nil
        }
      },
      "approval_policy" => "ask",
      "data_dir" => context.data_dir,
      "max_steps" => 8,
      "timeout_ms" => 30_000
    }

    File.mkdir_p!(context.root)
    File.write!(context.config_path, JSON.encode!(legacy))

    assert {:ok, migrated} = BeamAgent.CLI.Config.load(context.config_path)
    assert migrated["version"] == 11
    refute Map.has_key?(migrated, "max_steps")
    refute Map.has_key?(migrated, "timeout_ms")
    assert migrated["context_window_tokens"] == 32_000
    assert migrated["compaction_threshold_percent"] == 75
  end

  test "version 5 configuration drops the retired tool-loop ceiling", context do
    legacy = %{
      "version" => 5,
      "active_profile" => "echo",
      "profiles" => %{
        "echo" => %{
          "provider" => "echo",
          "model" => nil,
          "base_url" => nil,
          "api_key_env" => nil
        }
      },
      "approval_policy" => "ask",
      "data_dir" => context.data_dir,
      "max_steps" => 8,
      "timeout_ms" => 30_000,
      "context_window_tokens" => 32_000,
      "compaction_threshold_percent" => 75
    }

    File.mkdir_p!(context.root)
    File.write!(context.config_path, JSON.encode!(legacy))

    assert {:ok, migrated} = BeamAgent.CLI.Config.load(context.config_path)
    assert migrated["version"] == 11
    refute Map.has_key?(migrated, "max_steps")
    refute Map.has_key?(migrated, "timeout_ms")
  end

  test "version 6 configuration drops the retired provider timeout", context do
    legacy = %{
      "version" => 6,
      "active_profile" => "echo",
      "profiles" => %{
        "echo" => %{
          "provider" => "echo",
          "model" => nil,
          "base_url" => nil,
          "api_key_env" => nil
        }
      },
      "approval_policy" => "ask",
      "data_dir" => context.data_dir,
      "timeout_ms" => 30_000,
      "context_window_tokens" => 32_000,
      "compaction_threshold_percent" => 75
    }

    File.mkdir_p!(context.root)
    File.write!(context.config_path, JSON.encode!(legacy))

    assert {:ok, migrated} = BeamAgent.CLI.Config.load(context.config_path)
    assert migrated["version"] == 11
    refute Map.has_key?(migrated, "timeout_ms")
  end

  test "version 10 configuration gains memory defaults", context do
    legacy = %{
      "version" => 10,
      "active_profile" => "echo",
      "profiles" => %{
        "echo" => %{
          "provider" => "echo",
          "model" => nil,
          "base_url" => nil,
          "api_key_env" => nil
        }
      },
      "approval_policy" => "ask",
      "model_strategy" => "auto",
      "data_dir" => context.data_dir,
      "context_window_tokens" => 32_000,
      "compaction_threshold_percent" => 75,
      "team_mode" => "solo"
    }

    File.mkdir_p!(context.root)
    File.write!(context.config_path, JSON.encode!(legacy))

    assert {:ok, migrated} = BeamAgent.CLI.Config.load(context.config_path)
    assert migrated["version"] == 11
    assert migrated["memory_enabled"] == true
    assert migrated["memory_max_entries"] == 200
    assert migrated["memory_max_bytes"] == 500_000
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

  test "provider profiles can be added, listed, activated, and switched", context do
    {0, _output} = init_cli(context)

    {status, added} =
      run_stdout([
        "provider",
        "add",
        "grok-work",
        "--config",
        context.config_path,
        "--provider",
        "grok",
        "--model",
        "grok-test",
        "--api-key-env",
        "MY_XAI_KEY",
        "--activate",
        "--non-interactive"
      ])

    assert status == 0
    assert added =~ "Provider profile saved: grok-work"
    assert added =~ "Active profile is now grok-work"

    assert {:ok, config} = BeamAgent.CLI.Config.load(context.config_path)
    assert config["active_profile"] == "grok-work"
    assert get_in(config, ["profiles", "grok-work", "provider"]) == "grok"
    assert get_in(config, ["profiles", "grok-work", "api_key_env"]) == "MY_XAI_KEY"
    refute File.read!(context.config_path) =~ "xai-secret"

    {:ok, stat} = File.stat(context.config_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600

    {0, listed} = run_stdout(["provider", "list", "--config", context.config_path])
    assert listed =~ "  echo  echo"
    assert listed =~ "* grok-work  grok  grok-test"

    {0, switched} =
      run_stdout(["provider", "use", "echo", "--config", context.config_path])

    assert switched =~ "Active provider profile: echo"
    assert {:ok, switched_config} = BeamAgent.CLI.Config.load(context.config_path)
    assert switched_config["active_profile"] == "echo"
  end

  test "guided Grok profile setup infers the adapter and safe credential variable", context do
    {0, _output} = init_cli(context)

    {status, output} =
      run_stdout(
        ["provider", "add", "grok", "--activate", "--config", context.config_path],
        "grok-test\n\n\n"
      )

    assert status == 0
    assert output =~ "Model"
    assert output =~ "API key environment variable [XAI_API_KEY]"
    assert output =~ "Active profile is now grok"

    assert {:ok, config} = BeamAgent.CLI.Config.load(context.config_path)
    assert config["active_profile"] == "grok"
    assert get_in(config, ["profiles", "grok", "provider"]) == "grok"
    assert get_in(config, ["profiles", "grok", "model"]) == "grok-test"
    assert get_in(config, ["profiles", "grok", "api_key_env"]) == "XAI_API_KEY"
  end

  test "a named profile can be selected for one run without changing the active profile",
       context do
    {0, _output} = init_cli(context)

    {0, _added} =
      run_stdout([
        "provider",
        "add",
        "alternate",
        "--config",
        context.config_path,
        "--provider",
        "echo",
        "--non-interactive"
      ])

    {0, output} =
      run_stdout([
        "run",
        "hello",
        "--config",
        context.config_path,
        "--profile",
        "alternate"
      ])

    assert output =~ "alternate  ·  echo"
    assert output =~ "echo(1): hello"
    assert {:ok, config} = BeamAgent.CLI.Config.load(context.config_path)
    assert config["active_profile"] == "echo"
  end

  test "provider profiles reject accidental overwrite and unknown selection", context do
    {0, _output} = init_cli(context)

    {status, duplicate} =
      run_stderr([
        "provider",
        "add",
        "echo",
        "--config",
        context.config_path,
        "--non-interactive"
      ])

    assert status == 1
    assert duplicate =~ "already exists"
    assert duplicate =~ "--force"

    {status, unknown} =
      run_stderr(["provider", "use", "missing", "--config", context.config_path])

    assert status == 1
    assert unknown =~ "was not found"
    assert unknown =~ "provider list"
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
