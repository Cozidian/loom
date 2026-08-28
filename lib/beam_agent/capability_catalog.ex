defmodule BeamAgent.CapabilityCatalog do
  @moduledoc """
  Process-owned registrations for stateless provider and tool modules.

  Registry entries disappear with this process, giving capability publication a
  concrete OTP owner instead of a shared mutable plugin context.
  """
  use GenServer

  alias BeamAgent.Names

  @default_tools [
    BeamAgent.Tools.Add,
    BeamAgent.Tools.ListFiles,
    BeamAgent.Tools.ReadFile,
    BeamAgent.Tools.SearchFiles,
    BeamAgent.Tools.ListSkills,
    BeamAgent.Tools.ReadSkill,
    BeamAgent.Tools.ReloadContext,
    BeamAgent.Tools.RequestCapability,
    BeamAgent.Tools.RequestProjectContext,
    BeamAgent.Tools.DelegateTasks,
    BeamAgent.Tools.CreateFile,
    BeamAgent.Tools.EditFile,
    BeamAgent.Tools.ApplyPatch,
    BeamAgent.Tools.GitInspect,
    BeamAgent.Tools.FileSymbols,
    BeamAgent.Tools.FileDiagnostics,
    BeamAgent.Tools.RunCommand,
    BeamAgent.Tools.SpawnSubagent
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register_provider(module), do: GenServer.call(__MODULE__, {:register_provider, module})
  def register_tool(module), do: GenServer.call(__MODULE__, {:register_tool, module})
  def providers, do: GenServer.call(__MODULE__, :providers)
  def tools, do: GenServer.call(__MODULE__, :tools)

  def provider(id) when is_atom(id) do
    case Names.lookup(:provider, id) do
      {:ok, _owner, module} -> {:ok, module}
      :error -> {:error, {:unknown_provider, id}}
    end
  end

  def tool(name) when is_binary(name) do
    case Names.lookup(:tool, name) do
      {:ok, _owner, module} -> {:ok, module}
      :error -> {:error, {:unknown_tool, name}}
    end
  end

  def tool_schemas do
    tools()
    |> Enum.map(fn module ->
      %{
        name: module.name(),
        description: module.description(),
        input_schema: module.input_schema()
      }
    end)
  end

  @impl true
  def init(opts) do
    providers = Keyword.get(opts, :providers, BeamAgent.Providers.modules())
    tools = Keyword.get(opts, :tools, @default_tools)

    with {:ok, state} <- register_all(%{providers: %{}, tools: %{}}, :provider, providers),
         {:ok, state} <- register_all(state, :tool, tools) do
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:register_provider, module}, _from, state) do
    case register(state, :provider, module) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register_tool, module}, _from, state) do
    case register(state, :tool, module) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:providers, _from, state), do: {:reply, Map.values(state.providers), state}
  def handle_call(:tools, _from, state), do: {:reply, Map.values(state.tools), state}

  defp register_all(state, kind, modules) do
    Enum.reduce_while(modules, {:ok, state}, fn module, {:ok, acc} ->
      case register(acc, kind, module) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:stop, reason}}
      end
    end)
    |> case do
      {:stop, reason} -> {:stop, reason}
      other -> other
    end
  end

  defp register(state, :provider, module) do
    with :ok <- ensure_behaviour(module, BeamAgent.LLMProvider),
         id when is_atom(id) <- module.id(),
         {:ok, _} <- Registry.register(BeamAgent.Registry, {:provider, id}, module) do
      {:ok, put_in(state, [:providers, id], module)}
    else
      {:error, {:already_registered, _pid}} -> {:error, :duplicate_provider}
      other -> {:error, {:invalid_provider, module, other}}
    end
  end

  defp register(state, :tool, module) do
    with :ok <- ensure_behaviour(module, BeamAgent.Tool),
         name when is_binary(name) <- module.name(),
         {:ok, _} <- Registry.register(BeamAgent.Registry, {:tool, name}, module) do
      {:ok, put_in(state, [:tools, name], module)}
    else
      {:error, {:already_registered, _pid}} -> {:error, :duplicate_tool}
      other -> {:error, {:invalid_tool, module, other}}
    end
  end

  defp ensure_behaviour(module, behaviour) do
    behaviours =
      module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    if behaviour in behaviours, do: :ok, else: {:error, :missing_behaviour}
  end
end
