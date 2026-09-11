defmodule BeamAgent.ProviderManagerTest do
  use ExUnit.Case, async: false
  alias BeamAgent.CLI.{Config, ProviderManager}
  alias BeamAgent.{Agent, ModelRegistry, Names, Runtime}

  defmodule Catalogue do
    def account, do: {:ok, %{"account" => %{"type" => "chatgpt"}}}
    def models, do: {:ok, [%{"model" => "available"}, %{"model" => "hidden", "hidden" => true}]}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "provider-manager-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    {:ok, echo} = Config.profile("echo", nil, nil, nil)

    stored =
      Config.defaults()
      |> Map.put("active_profile", "echo")
      |> Map.put("profiles", %{"echo" => echo, "other" => echo})
      |> Map.put("data_dir", Path.join(root, "sessions"))

    path = Path.join(root, "config.json")
    {:ok, _} = Config.write(stored, path)
    {:ok, config} = Config.runtime(stored)
    config = Map.put(config, "workspace_root", workspace)

    {:ok, session} =
      BeamAgent.start_session(
        provider: :echo,
        provider_profile: "echo",
        workspace_root: workspace,
        data_dir: config["data_dir"],
        model_endpoints: Config.model_endpoints(stored, config)
      )

    {:ok, identity} = Agent.runtime_identity(session)
    {:ok, runtime} = Runtime.connect(session)

    on_exit(fn ->
      if Process.alive?(runtime), do: Runtime.disconnect(runtime)
      BeamAgent.stop_project(identity.project_id)
      File.rm_rf!(root)
    end)

    %{
      config: config,
      config_path: path,
      session_id: session,
      goal_id: identity.goal_id,
      project_id: identity.project_id,
      runtime: runtime,
      codex_app_server: Catalogue
    }
  end

  defp request(state, attrs) do
    {:ok, snapshot} = ProviderManager.snapshot(state)
    Map.put(attrs, "revision", snapshot.revision)
  end

  defp select(state, profile, model, strategy \\ "manual") do
    request(state, %{
      "action" => "select",
      "profile" => profile,
      "model" => model,
      "strategy" => strategy
    })
  end

  test "select persists a model in the existing conversation and preserves external endpoints",
       state do
    assert {:ok, "echo(1): first"} = BeamAgent.ask(state.session_id, "first")
    assert :ok = ModelRegistry.register(state.project_id, %{id: "remote-worker", provider: :echo})
    assert {:ok, config} = ProviderManager.mutate(state, select(state, "other", "echo-v2"))
    assert config["profile"] == "other"
    assert config["model_strategy"] == "manual"
    assert {:ok, saved} = Config.load(state.config_path)
    assert saved["active_profile"] == "other"
    assert saved["profiles"]["other"]["model"] == "echo-v2"
    assert {:ok, context} = Agent.construction_context(state.session_id)
    assert context.provider_profile == "other"
    assert context.provider_options[:model] == "echo-v2"
    assert context.model_strategy == :manual
    assert {:ok, endpoint} = ModelRegistry.fetch(state.project_id, "other")
    assert endpoint.model == "echo-v2"
    assert {:ok, _} = ModelRegistry.fetch(state.project_id, "remote-worker")
    assert {:ok, "echo(2): second"} = BeamAgent.ask(state.session_id, "second")
    assert {:ok, events} = BeamAgent.events(state.session_id)
    assert Enum.any?(events, &(&1["type"] == "provider_settings_changed"))
  end

  test "model settings replay after the supervised worker restarts", state do
    assert {:ok, _} =
             ProviderManager.mutate(
               state,
               select(state, "other", "recovered-model", "local_only")
             )

    {:ok, old} = Names.pid(:agent, state.session_id)
    Process.exit(old, :kill)

    assert eventually(fn ->
             with {:ok, pid} <- Names.pid(:agent, state.session_id),
                  true <- pid != old,
                  {:ok, context} <- Agent.construction_context(state.session_id) do
               context.provider_profile == "other" and
                 context.provider_options[:model] == "recovered-model" and
                 context.model_strategy == :local_only and context.team_mode == :auto
             else
               _ -> false
             end
           end)
  end

  test "selecting a model preserves team mode unless explicitly changed", state do
    assert {:ok, config} =
             ProviderManager.mutate(
               state,
               Map.put(select(state, "other", "pinned"), "team_mode", "auto")
             )

    state = %{state | config: config}
    assert {:ok, config} = ProviderManager.mutate(state, select(state, "other", "another"))
    assert config["model_strategy"] == "manual"
    assert config["team_mode"] == "auto"
    assert {:ok, context} = Agent.construction_context(state.session_id)
    assert context.team_mode == :auto
    assert {:ok, saved} = Config.load(state.config_path)
    assert saved["team_mode"] == "auto"
  end

  test "legacy manual configuration migrates to solo without writing the file", state do
    {:ok, saved} = Config.load(state.config_path)

    legacy =
      saved
      |> Map.put("version", 9)
      |> Map.put("model_strategy", "manual")
      |> Map.delete("team_mode")

    File.write!(state.config_path, JSON.encode!(legacy))
    assert {:ok, migrated} = Config.load(state.config_path)
    assert migrated["team_mode"] == "solo"
    assert File.read!(state.config_path) == JSON.encode!(legacy)
  end

  test "stale preparation cannot overwrite a subsequent save", state do
    assert {:ok, prepared} = ProviderManager.prepare(state, select(state, "echo", "stale"))
    assert {:ok, _} = ProviderManager.mutate(state, select(state, "echo", "newer"))

    assert {:error, :settings_changed_reload_before_saving} =
             ProviderManager.commit(state, prepared)

    assert {:ok, stored} = Config.load(state.config_path)
    assert stored["profiles"]["echo"]["model"] == "newer"
  end

  test "routing strategy can leave local-only mode without retaining stale model requirements",
       state do
    assert {:ok, config} =
             ProviderManager.mutate(state, select(state, "echo", "local", "local_only"))

    assert {:ok, local} = Agent.construction_context(state.session_id)
    assert local.agent_spec.model_requirements.locality == :local
    state = %{state | config: config}
    assert {:ok, _} = ProviderManager.mutate(state, select(state, "echo", "auto-model", "auto"))
    assert {:ok, routed} = Agent.construction_context(state.session_id)
    assert routed.agent_spec.model_requirements.locality == :any
    assert routed.agent_spec.model_requirements.privacy == :provider_allowed
    assert routed.capability_envelope == local.capability_envelope
  end

  test "a busy runtime rejects the commit and restores the saved config", state do
    {:ok, before} = Config.load(state.config_path)
    {:ok, prepared} = ProviderManager.prepare(state, select(state, "echo", "uncommitted"))
    # Runtime's final guard covers work starting after read-only preparation.
    :sys.replace_state(state.runtime, &Map.put(&1, :current, :busy))
    assert {:error, :goal_busy} = ProviderManager.commit(state, prepared)
    :sys.replace_state(state.runtime, &Map.put(&1, :current, nil))
    assert {:ok, ^before} = Config.load(state.config_path)
    assert {:ok, context} = Agent.construction_context(state.session_id)
    refute context.provider_options[:model] == "uncommitted"
  end

  test "adding and deleting inactive profiles leaves the current choice alone", state do
    fields = %{"provider" => "echo", "model" => "spare-model", "auth_mode" => "environment"}

    save =
      request(state, %{
        "action" => "save",
        "profile" => "spare",
        "editing" => false,
        "fields" => fields
      })

    assert {:ok, config} = ProviderManager.mutate(state, save)
    assert config["profile"] == "echo"
    assert {:ok, _} = ModelRegistry.fetch(state.project_id, "spare")
    delete = request(state, %{"action" => "delete", "profile" => "spare", "confirmed" => true})
    assert {:ok, _} = ProviderManager.mutate(state, delete)

    assert {:error, {:unknown_model_endpoint, "spare"}} =
             ModelRegistry.fetch(state.project_id, "spare")

    assert {:ok, saved} = Config.load(state.config_path)
    refute Map.has_key?(saved["profiles"], "spare")
  end

  test "deletion is confirmed and active/default profiles are protected", state do
    assert {:error, :invalid_settings_action} =
             ProviderManager.mutate(
               state,
               request(state, %{"action" => "delete", "profile" => "other"})
             )

    assert {:error, :cannot_remove_active_provider} =
             ProviderManager.mutate(
               state,
               request(state, %{"action" => "delete", "profile" => "echo", "confirmed" => true})
             )
  end

  test "live catalogue excludes hidden models and rejects unavailable selections", state do
    {:ok, saved} = Config.load(state.config_path)

    {:ok, profile} =
      Config.profile("openai", "available", "https://api.openai.com/v1", "OPENAI_API_KEY")

    profile = Map.put(profile, "auth", %{"type" => "chatgpt", "transport" => "codex_app_server"})
    {:ok, saved} = Config.put_profile(saved, "chatgpt", profile)
    {:ok, _} = Config.write(saved, state.config_path)

    assert {:ok, %{models: [%{"model" => "available"}]}} =
             ProviderManager.catalog(state, "chatgpt")

    assert {:error, {:model_not_in_catalogue, "unavailable"}} =
             ProviderManager.mutate(state, select(state, "chatgpt", "unavailable"))

    assert {:ok, ^saved} = Config.load(state.config_path)
  end

  test "forms expose references only and do not carry credentials to a changed endpoint", state do
    {:ok, saved} = Config.load(state.config_path)

    {:ok, profile} =
      Config.profile("openai", "model-id", "https://api.openai.com/v1", "OPENAI_API_KEY")

    profile = Map.put(profile, "credential_ref", "keychain://beam-agent/test-ref")
    {:ok, saved} = Config.put_profile(saved, "cloud", profile)
    {:ok, _} = Config.write(saved, state.config_path)
    {:ok, snapshot} = ProviderManager.snapshot(state)
    cloud = Enum.find(snapshot.providers, &(&1["profile"] == "cloud"))
    assert cloud["auth_mode"] == "saved"
    refute Map.has_key?(cloud, "credential_ref")

    fields = %{
      "provider" => "openai",
      "model" => "model-id",
      "base_url" => "https://example.test/v1",
      "api_key_env" => "TEST_PROVIDER_KEY",
      "auth_mode" => "environment"
    }

    assert {:ok, _} =
             ProviderManager.mutate(
               state,
               request(
                 state,
                 %{
                   "action" => "save",
                   "profile" => "cloud",
                   "editing" => true,
                   "fields" => fields
                 }
               )
             )

    {:ok, saved} = Config.load(state.config_path)
    assert saved["profiles"]["cloud"]["credential_ref"] == nil
    assert saved["profiles"]["cloud"]["api_key_env"] == "TEST_PROVIDER_KEY"
  end

  test "provider form rejects literal keys and credentials embedded in URLs", state do
    for fields <- [
          %{"provider" => "echo", "api_key" => "never-store-me"},
          %{"provider" => "echo", "base_url" => "https://user:secret@example.test"},
          %{"provider" => "echo", "api_key_env" => "not an env name"}
        ] do
      assert {:error, :invalid_provider_fields} =
               ProviderManager.mutate(
                 state,
                 request(state, %{"action" => "save", "profile" => "bad", "fields" => fields})
               )
    end

    refute File.read!(state.config_path) =~ "never-store-me"
  end

  test "controller emits settings acknowledgements without replacing the session", state do
    {:ok, controller} =
      BeamAgent.CLI.TUI.Controller.start_link(
        client: self(),
        session_id: state.session_id,
        config: state.config,
        config_path: state.config_path,
        codex_app_server: Catalogue
      )

    on_exit(fn -> if Process.alive?(controller), do: GenServer.stop(controller) end)
    BeamAgent.CLI.TUI.Controller.settings(controller, %{"action" => "list"})
    assert_receive {:beam_agent_tui, {:provider_settings, snapshot}}, 2_000

    BeamAgent.CLI.TUI.Controller.settings(controller, %{
      "action" => "select",
      "profile" => "other",
      "model" => "selected",
      "strategy" => "manual",
      "revision" => snapshot.revision
    })

    assert_receive {:beam_agent_tui, {:settings_applied, %{"profile" => "other"}}}, 2_000
    assert_receive {:beam_agent_tui, {:provider_settings, %{active_profile: "other"}}}, 2_000
    assert :sys.get_state(controller).session_id == state.session_id
    refute_receive {:beam_agent_tui, {:session_changed, _, _}}
  end

  test "locking is session-scoped, inherited despite child overrides, and reversible", state do
    before = File.read!(state.config_path)

    assert {:ok, config} =
             ProviderManager.mutate(
               state,
               request(state, %{
                 "action" => "lock",
                 "profile" => "other",
                 "model" => "locked-model"
               })
             )

    assert File.read!(state.config_path) == before
    assert config["model_strategy"] == "manual"

    assert {:ok, child} =
             BeamAgent.spawn_subagent(state.session_id,
               provider: :echo,
               provider_profile: "echo",
               model_strategy: :auto,
               provider_options: [model: "escape"],
               agent_proposal: %{
                 goal: "Explain a small detail",
                 model_requirements: %{preferred_endpoint_id: "echo"}
               }
             )

    {:ok, context} = Agent.construction_context(child)
    assert context.model_strategy == :manual
    assert context.provider_profile == "other"
    assert context.provider_options[:model] == "locked-model"
    assert context.agent_spec.model_requirements.preferred_endpoint_id == "other"
    assert {:ok, _} = BeamAgent.ask(child, "Explain a small detail")
    :ok = BeamAgent.stop_session(child)
    state = %{state | config: config}

    assert {:ok, released} =
             ProviderManager.mutate(state, request(state, %{"action" => "automatic"}))

    assert released["model_strategy"] == "auto"
    assert File.read!(state.config_path) == before
  end

  test "adding a provider requires no favorite model and active automatic providers can be disabled",
       state do
    fields = %{
      "provider" => "xai",
      "base_url" => "https://example.test/v1",
      "api_key_env" => "LOOM_UNUSED_TEST_KEY",
      "auth_mode" => "environment"
    }

    assert {:ok, _} =
             ProviderManager.mutate(
               state,
               request(state, %{"action" => "save", "profile" => "cloud", "fields" => fields})
             )

    {:ok, stored} = Config.load(state.config_path)
    assert stored["profiles"]["cloud"]["model"] == nil

    assert {:ok, config} =
             ProviderManager.mutate(
               state,
               request(state, %{"action" => "toggle", "profile" => "echo"})
             )

    assert {:ok, %{enabled: false}} = ModelRegistry.fetch(state.project_id, "echo")
    state = %{state | config: config}

    assert {:ok, _} =
             ProviderManager.mutate(
               state,
               request(state, %{"action" => "toggle", "profile" => "echo"})
             )

    assert {:ok, %{enabled: true}} = ModelRegistry.fetch(state.project_id, "echo")
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, remaining) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, remaining - 1)
        )
  end
end
