defmodule BeamAgent.ModelRegistryTest do
  use ExUnit.Case, async: false

  alias BeamAgent.CLI.Config

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-model-registry-test-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    {:ok, workspace} = BeamAgent.Workspace.canonical_root(workspace)
    project_id = BeamAgent.Project.id_for_workspace(workspace)

    on_exit(fn ->
      _ = BeamAgent.stop_project(project_id)
      File.rm_rf(root)
    end)

    %{workspace: workspace, data_dir: data_dir, project_id: project_id}
  end

  test "a project registers many model endpoints while a session keeps its manual override",
       context do
    endpoints = [
      %{
        id: "local-fast",
        provider: :echo,
        provider_module: BeamAgent.Providers.Echo
      },
      %{
        id: "delegating",
        provider: :demo,
        provider_module: BeamAgent.Providers.Demo
      }
    ]

    assert {:ok, session_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               provider_profile: "local-fast",
               model_endpoints: endpoints
             )

    assert {:ok, registered} = BeamAgent.models(context.project_id)
    assert Enum.map(registered, & &1.id) == ["delegating", "local-fast"]

    local = Enum.find(registered, &(&1.id == "local-fast"))
    assert local.provider == :echo
    assert local.claims.locality == :local
    assert local.claims.privacy == :local
    assert local.claims.capabilities == [:text_generation]
    assert local.measurements == %{}
    assert local.health.status == :unknown

    assert {:ok, events} = BeamAgent.events(session_id)
    started = Enum.find(events, &(&1["type"] == "agent_started"))
    assert started["data"]["provider_profile"] == "local-fast"
    assert started["data"]["provider"] == "echo"
  end

  test "configured profile conversion includes all endpoints and only credential references" do
    config = Config.defaults()

    {:ok, ollama} =
      Config.profile("ollama", "qwen3:8b", "http://127.0.0.1:11434", nil)

    {:ok, grok} =
      Config.profile("grok", "grok-build", "https://api.x.ai/v1", "XAI_API_KEY")

    {:ok, config} = Config.put_profile(config, "ollama-local", ollama)
    {:ok, config} = Config.put_profile(config, "grok-review", grok)

    endpoints = Config.model_endpoints(config)

    assert Enum.map(endpoints, & &1.id) |> Enum.sort() == ["demo", "grok-review", "ollama-local"]
    assert Enum.find(endpoints, &(&1.id == "ollama-local")).provider == :ollama

    grok_endpoint = Enum.find(endpoints, &(&1.id == "grok-review"))
    assert grok_endpoint.provider == :xai
    assert grok_endpoint.api_key_env == "XAI_API_KEY"
    refute inspect(endpoints) =~ "xai-secret"
  end

  test "health checks are supervised and update availability asynchronously", context do
    assert {:ok, project_id} =
             BeamAgent.start_project(
               workspace_root: context.workspace,
               model_endpoints: [
                 %{id: "echo", provider: :echo},
                 %{id: "demo", provider: :demo}
               ]
             )

    assert {:ok, ids} = BeamAgent.refresh_models(project_id)
    assert Enum.sort(ids) == ["demo", "echo"]

    assert eventually(fn ->
             {:ok, endpoints} = BeamAgent.models(project_id)
             Enum.all?(endpoints, &(&1.health.status == :available))
           end)
  end

  test "a registry restart restores configured endpoints without restarting goals", context do
    assert {:ok, session_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               model_endpoints: [
                 %{id: "echo", provider: :echo},
                 %{id: "demo", provider: :demo}
               ]
             )

    assert {:ok, agent} = BeamAgent.agent_pid(session_id)
    assert {:ok, registry} = BeamAgent.model_registry_pid(context.project_id)
    Process.exit(registry, :kill)

    assert eventually(fn ->
             match?(
               {:ok, pid} when pid != registry,
               BeamAgent.model_registry_pid(context.project_id)
             )
           end)

    assert {:ok, ^agent} = BeamAgent.agent_pid(session_id)
    assert {:ok, endpoints} = BeamAgent.models(context.project_id)
    assert Enum.map(endpoints, & &1.id) == ["demo", "echo"]
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
