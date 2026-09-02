defmodule BeamAgent.ModelRegistry do
  @moduledoc "Long-lived, project-owned inventory and health state for model endpoints."
  use GenServer

  alias BeamAgent.{ModelEndpoint, Names}

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:model_registry, project_id))
  end

  def list(project_id) do
    with {:ok, pid} <- Names.pid(:model_registry, project_id), do: GenServer.call(pid, :list)
  end

  def fetch(project_id, endpoint_id) do
    with {:ok, pid} <- Names.pid(:model_registry, project_id) do
      GenServer.call(pid, {:fetch, endpoint_id})
    end
  end

  def register(project_id, spec) do
    with {:ok, pid} <- Names.pid(:model_registry, project_id) do
      GenServer.call(pid, {:register, spec})
    end
  end

  def replace(project_id, specs) when is_list(specs) do
    with {:ok, pid} <- Names.pid(:model_registry, project_id) do
      GenServer.call(pid, {:replace, specs})
    end
  end

  def refresh_health(project_id, endpoint_id \\ :all) do
    with {:ok, pid} <- Names.pid(:model_registry, project_id) do
      GenServer.call(pid, {:refresh_health, endpoint_id})
    end
  end

  def preflight(project_id, endpoint_id \\ :all) do
    with {:ok, pid} <- Names.pid(:model_registry, project_id),
         {:ok, supervisor} <- Names.pid(:model_health_supervisor, project_id),
         {:ok, endpoints} <- GenServer.call(pid, :list),
         {:ok, targets} <- preflight_targets(endpoints, endpoint_id) do
      results = run_preflights(supervisor, targets)
      GenServer.call(pid, {:record_health_results, results})
    end
  end

  @impl true
  def init(opts) do
    state = %{
      project_id: Keyword.fetch!(opts, :project_id),
      endpoints: %{},
      checks: %{}
    }

    case normalize_many(Keyword.get(opts, :model_endpoints, [])) do
      {:ok, endpoints} -> {:ok, %{state | endpoints: endpoints}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    endpoints = state.endpoints |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, {:ok, endpoints}, state}
  end

  def handle_call({:fetch, endpoint_id}, _from, state) do
    case Map.fetch(state.endpoints, endpoint_id) do
      {:ok, endpoint} -> {:reply, {:ok, endpoint}, state}
      :error -> {:reply, {:error, {:unknown_model_endpoint, endpoint_id}}, state}
    end
  end

  def handle_call({:register, spec}, _from, state) do
    case ModelEndpoint.new(spec) do
      {:ok, endpoint} ->
        endpoint = preserve_runtime_state(state.endpoints[endpoint.id], endpoint)
        {:reply, :ok, put_in(state.endpoints[endpoint.id], endpoint)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replace, specs}, _from, state) do
    case normalize_many(specs, state.endpoints) do
      {:ok, endpoints} -> {:reply, :ok, %{state | endpoints: endpoints}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:refresh_health, endpoint_id}, _from, state) do
    with {:ok, ids} <- refresh_ids(state.endpoints, endpoint_id),
         {:ok, supervisor} <- Names.pid(:model_health_supervisor, state.project_id) do
      state = Enum.reduce(ids, state, &start_health_check(&2, &1, supervisor))
      {:reply, {:ok, ids}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_health_results, results}, _from, state) do
    state =
      Enum.reduce(results, state, fn %{endpoint_id: endpoint_id, result: result}, state ->
        put_health(state, endpoint_id, result)
      end)

    public =
      Enum.map(results, fn %{endpoint_id: endpoint_id, result: result} ->
        %{
          endpoint_id: endpoint_id,
          status: health_status(result),
          reason: health_reason_value(result)
        }
      end)

    {:reply, {:ok, public}, state}
  end

  @impl true
  def handle_info({reference, result}, state) when is_reference(reference) do
    case Map.pop(state.checks, reference) do
      {nil, _checks} ->
        {:noreply, state}

      {endpoint_id, checks} ->
        Process.demonitor(reference, [:flush])
        {:noreply, state |> Map.put(:checks, checks) |> put_health(endpoint_id, result)}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case Map.pop(state.checks, reference) do
      {nil, _checks} ->
        {:noreply, state}

      {endpoint_id, checks} ->
        result = {:error, {:healthcheck_exit, health_reason(reason)}}
        {:noreply, state |> Map.put(:checks, checks) |> put_health(endpoint_id, result)}
    end
  end

  defp start_health_check(state, endpoint_id, supervisor) do
    endpoint = Map.fetch!(state.endpoints, endpoint_id)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        healthcheck(endpoint.provider_module, ModelEndpoint.health_options(endpoint))
      end)

    state
    |> put_in([:checks, task.ref], endpoint_id)
    |> put_in([:endpoints, endpoint_id, Access.key(:health)], %{
      status: :checking,
      checked_at: nil
    })
  end

  defp put_health(state, endpoint_id, result) do
    case Map.fetch(state.endpoints, endpoint_id) do
      :error ->
        state

      {:ok, endpoint} ->
        health = %{
          status: health_status(result),
          checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        put_in(state.endpoints[endpoint_id], %{endpoint | health: health})
    end
  end

  defp healthcheck(module, options) do
    if Code.ensure_loaded?(module) and function_exported?(module, :healthcheck, 1),
      do: module.healthcheck(options),
      else: :ok
  rescue
    _error -> {:error, :healthcheck_exception}
  catch
    _kind, _reason -> {:error, :healthcheck_failure}
  end

  defp routing_preflight(endpoint) do
    module = endpoint.provider_module
    options = ModelEndpoint.health_options(endpoint)

    if Code.ensure_loaded?(module) and function_exported?(module, :routing_preflight, 1),
      do: module.routing_preflight(options),
      else: :ok
  rescue
    _error -> {:error, :routing_preflight_exception}
  catch
    _kind, _reason -> {:error, :routing_preflight_failure}
  end

  defp run_preflights(_supervisor, []), do: []

  defp run_preflights(supervisor, targets) do
    results =
      Task.Supervisor.async_stream_nolink(
        supervisor,
        targets,
        fn endpoint -> {endpoint.id, routing_preflight(endpoint)} end,
        ordered: true,
        max_concurrency: min(length(targets), 8),
        timeout: 5_000,
        on_timeout: :kill_task
      )

    Enum.zip_with(targets, results, fn endpoint, result ->
      health_result =
        case result do
          {:ok, {id, health_result}} when id == endpoint.id -> health_result
          {:exit, _reason} -> {:error, :routing_preflight_timeout}
          _other -> {:error, :routing_preflight_failure}
        end

      %{endpoint_id: endpoint.id, result: health_result}
    end)
  end

  defp preflight_targets(endpoints, :all) do
    {:ok, Enum.filter(endpoints, &(&1.health.status in [:unknown, :checking]))}
  end

  defp preflight_targets(endpoints, endpoint_id) when is_binary(endpoint_id) do
    case Enum.find(endpoints, &(&1.id == endpoint_id)) do
      nil ->
        {:error, {:unknown_model_endpoint, endpoint_id}}

      %{health: %{status: status}} = endpoint when status in [:unknown, :checking] ->
        {:ok, [endpoint]}

      _known ->
        {:ok, []}
    end
  end

  defp preflight_targets(_endpoints, endpoint_id),
    do: {:error, {:unknown_model_endpoint, endpoint_id}}

  defp health_status(:ok), do: :available
  defp health_status({:ok, _detail}), do: :available
  defp health_status({:error, _reason}), do: :unavailable
  defp health_status(_other), do: :unavailable

  defp health_reason_value(:ok), do: nil
  defp health_reason_value({:ok, _detail}), do: nil
  defp health_reason_value({:error, reason}), do: inspect(reason)
  defp health_reason_value(other), do: inspect(other)

  defp health_reason(reason) when is_atom(reason), do: reason
  defp health_reason(_reason), do: :failed

  defp refresh_ids(endpoints, :all), do: {:ok, Map.keys(endpoints)}

  defp refresh_ids(endpoints, endpoint_id) when is_binary(endpoint_id) do
    if Map.has_key?(endpoints, endpoint_id),
      do: {:ok, [endpoint_id]},
      else: {:error, {:unknown_model_endpoint, endpoint_id}}
  end

  defp refresh_ids(_endpoints, endpoint_id),
    do: {:error, {:unknown_model_endpoint, endpoint_id}}

  defp normalize_many(specs, existing \\ %{}) do
    Enum.reduce_while(specs, {:ok, %{}}, fn spec, {:ok, endpoints} ->
      case ModelEndpoint.new(spec) do
        {:ok, endpoint} ->
          endpoint = preserve_runtime_state(existing[endpoint.id], endpoint)
          {:cont, {:ok, Map.put(endpoints, endpoint.id, endpoint)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp preserve_runtime_state(nil, endpoint), do: endpoint

  defp preserve_runtime_state(existing, endpoint) do
    if ModelEndpoint.same_configuration?(existing, endpoint) do
      %{endpoint | health: existing.health, measurements: existing.measurements}
    else
      endpoint
    end
  end
end
