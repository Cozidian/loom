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

  def reconcile(project_id, specs, removed_ids) when is_list(specs) and is_list(removed_ids) do
    with {:ok, pid} <- Names.pid(:model_registry, project_id) do
      GenServer.call(pid, {:reconcile, specs, removed_ids})
    end
  end

  def refresh_health(project_id, endpoint_id \\ :all) do
    with {:ok, pid} <- Names.pid(:model_registry, project_id) do
      GenServer.call(pid, {:refresh_health, endpoint_id})
    end
  end

  def catalog(project_id) do
    with {:ok, pid} <- Names.pid(:model_registry, project_id), do: GenServer.call(pid, :catalog)
  end

  def refresh_catalog(project_id) do
    with {:ok, pid} <- Names.pid(:model_registry, project_id),
         do: GenServer.call(pid, :refresh_catalog)
  end

  def await_catalog(project_id) do
    with {:ok, pid} <- Names.pid(:model_registry, project_id),
         do: GenServer.call(pid, :await_catalog, 30_000)
  end

  def preflight(project_id, endpoint_id \\ :all) do
    with :ok <- await_catalog(project_id),
         {:ok, pid} <- Names.pid(:model_registry, project_id),
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
      checks: %{},
      catalogs: %{},
      catalog_task: nil,
      catalog_waiters: [],
      discover_models: Keyword.get(opts, :discover_models, false),
      discovery: Keyword.get(opts, :model_discovery, BeamAgent.ModelCatalog),
      discovery_options: Keyword.get(opts, :model_discovery_options, []),
      catalog_dirty: false,
      catalog_timer: nil
    }

    case normalize_many(Keyword.get(opts, :model_endpoints, [])) do
      {:ok, endpoints} ->
        if state.discover_models, do: send(self(), :refresh_catalog)
        {:ok, %{state | endpoints: endpoints}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:catalog, _from, state) do
    sources =
      Enum.map(state.endpoints, fn {id, endpoint} ->
        entry = Map.get(state.catalogs, id, %{})

        %{
          profile: id,
          enabled: endpoint.enabled,
          status: entry[:status] || :configured,
          checked_at: entry[:checked_at],
          message: entry[:message],
          model_count: length(entry[:models] || [])
        }
      end)
      |> Enum.sort_by(& &1.profile)

    {:reply,
     {:ok, %{models: inventory(state), sources: sources, refreshing: state.catalog_task != nil}},
     state}
  end

  def handle_call(:refresh_catalog, _from, state),
    do: {:reply, :ok, start_catalog(%{state | discover_models: true})}

  def handle_call(:await_catalog, from, state) do
    if state.catalog_task,
      do: {:noreply, %{state | catalog_waiters: [from | state.catalog_waiters]}},
      else: {:reply, :ok, state}
  end

  def handle_call(:list, _from, state) do
    endpoints = inventory(state)
    {:reply, {:ok, endpoints}, state}
  end

  def handle_call({:fetch, endpoint_id}, _from, state) do
    case Map.fetch(all_endpoints(state), endpoint_id) do
      {:ok, endpoint} -> {:reply, {:ok, endpoint}, state}
      :error -> {:reply, {:error, {:unknown_model_endpoint, endpoint_id}}, state}
    end
  end

  def handle_call({:register, spec}, _from, state) do
    case ModelEndpoint.new(spec) do
      {:ok, endpoint} ->
        endpoint = preserve_runtime_state(state.endpoints[endpoint.id], endpoint)
        {:reply, :ok, configured(put_in(state.endpoints[endpoint.id], endpoint))}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replace, specs}, _from, state) do
    case normalize_many(specs, state.endpoints) do
      {:ok, endpoints} -> {:reply, :ok, configured(%{state | endpoints: endpoints})}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reconcile, specs, removed_ids}, _from, state) do
    case normalize_many(specs, state.endpoints) do
      {:ok, updated} ->
        endpoints = state.endpoints |> Map.drop(removed_ids) |> Map.merge(updated)
        {:reply, :ok, configured(%{state | endpoints: endpoints})}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:refresh_health, endpoint_id}, _from, state) do
    with {:ok, ids} <- refresh_ids(all_endpoints(state), endpoint_id),
         {:ok, supervisor} <- Names.pid(:model_health_supervisor, state.project_id) do
      state = Enum.reduce(ids, state, &start_health_check(&2, &1, supervisor))
      {:reply, {:ok, ids}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_health_results, results}, _from, state) do
    state =
      Enum.reduce(results, state, fn %{endpoint: endpoint, result: result}, state ->
        put_checked_health(state, endpoint, result)
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
  def handle_info(:refresh_catalog, state), do: {:noreply, start_catalog(state)}

  def handle_info({ref, results}, %{catalog_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      Enum.reduce(results, state, fn {original, result}, acc ->
        case acc.endpoints[original.id] do
          nil ->
            acc

          current ->
            if same_connection?(original, current),
              do: record_catalog(acc, current, result),
              else: acc
        end
      end)

    {:noreply, finish_catalog(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{catalog_task: %{ref: ref}} = state) do
    {:noreply, finish_catalog(state)}
  end

  def handle_info({reference, result}, state) when is_reference(reference) do
    case Map.pop(state.checks, reference) do
      {nil, _checks} ->
        {:noreply, state}

      {endpoint, checks} ->
        Process.demonitor(reference, [:flush])
        {:noreply, state |> Map.put(:checks, checks) |> put_checked_health(endpoint, result)}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case Map.pop(state.checks, reference) do
      {nil, _checks} ->
        {:noreply, state}

      {endpoint, checks} ->
        result = {:error, {:healthcheck_exit, health_reason(reason)}}
        {:noreply, state |> Map.put(:checks, checks) |> put_checked_health(endpoint, result)}
    end
  end

  defp start_health_check(state, endpoint_id, supervisor) do
    endpoint = Map.fetch!(all_endpoints(state), endpoint_id)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        healthcheck(endpoint.provider_module, ModelEndpoint.health_options(endpoint))
      end)

    state
    |> put_in([:checks, task.ref], endpoint)
    |> update_endpoint_health(endpoint_id, %{status: :checking, checked_at: nil})
  end

  defp put_health(state, endpoint_id, result) do
    case Map.fetch(all_endpoints(state), endpoint_id) do
      :error ->
        state

      {:ok, _endpoint} ->
        health = %{
          status: health_status(result),
          checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        update_endpoint_health(state, endpoint_id, health)
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

      %{endpoint_id: endpoint.id, endpoint: endpoint, result: health_result}
    end)
  end

  defp preflight_targets(endpoints, :all) do
    {:ok, Enum.filter(endpoints, &(&1.enabled and &1.health.status in [:unknown, :checking]))}
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

  defp configured(state) do
    catalogs =
      Map.filter(state.catalogs, fn {id, entry} ->
        current = state.endpoints[id]
        current && same_connection?(current, entry.connection)
      end)

    if state.discover_models, do: send(self(), :refresh_catalog)
    %{state | catalogs: catalogs}
  end

  defp start_catalog(%{catalog_task: task} = state) when not is_nil(task),
    do: %{state | catalog_dirty: true}

  defp start_catalog(state) do
    if state.catalog_timer, do: Process.cancel_timer(state.catalog_timer)
    {:ok, supervisor} = Names.pid(:model_health_supervisor, state.project_id)
    connections = state.endpoints |> Map.values() |> Enum.filter(& &1.enabled)
    discovery = state.discovery
    options = state.discovery_options

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        results =
          Task.Supervisor.async_stream_nolink(
            supervisor,
            connections,
            &discovery.discover(&1, options),
            max_concurrency: 8,
            ordered: true,
            timeout: 15_000,
            on_timeout: :kill_task
          )
          |> Enum.to_list()

        Enum.zip_with(connections, results, fn endpoint, result ->
          {endpoint,
           case result do
             {:ok, value} -> value
             _ -> {:error, :catalogue_timeout}
           end}
        end)
      end)

    %{state | catalog_task: task, catalog_timer: nil}
  end

  defp finish_catalog(state) do
    if state.catalog_dirty, do: send(self(), :refresh_catalog)
    Enum.each(state.catalog_waiters, &GenServer.reply(&1, :ok))
    timer = if state.discover_models, do: Process.send_after(self(), :refresh_catalog, 300_000)
    %{state | catalog_task: nil, catalog_waiters: [], catalog_timer: timer, catalog_dirty: false}
  end

  defp record_catalog(state, connection, result) do
    previous = state.catalogs[connection.id] || %{}

    base = %{
      connection: connection,
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      message: nil
    }

    entry =
      case result do
        {:ok, rows} when is_list(rows) ->
          existing = Map.new(previous[:models] || [], &{&1.id, &1})

          models =
            BeamAgent.ModelCatalog.endpoints(connection, rows)
            |> Enum.map(&preserve_catalog_state(existing[&1.id], &1))

          Map.merge(base, %{status: :live, models: models})

        {:manual, _} ->
          Map.merge(base, %{status: :manual, models: nil})

        _ ->
          Map.merge(base, %{
            status: if(previous[:models], do: :stale, else: :unavailable),
            models: previous[:models],
            message: "Discovery unavailable; refresh or check connection"
          })
      end

    put_in(state.catalogs[connection.id], entry)
  end

  defp inventory(state) do
    Enum.flat_map(state.endpoints, fn {id, endpoint} ->
      case state.catalogs[id] do
        %{models: models} when is_list(models) ->
          models

        %{status: :unavailable} ->
          [%{endpoint | health: %{status: :unavailable, checked_at: nil}}]

        _ ->
          [endpoint]
      end
    end)
    |> Enum.sort_by(&{&1.connection_id, &1.model || ""})
  end

  defp all_endpoints(state),
    do: Map.merge(state.endpoints, Map.new(inventory(state), &{&1.id, &1}))

  defp update_endpoint_health(state, id, health) do
    case state.endpoints[id] do
      nil ->
        catalogs =
          Map.new(state.catalogs, fn {key, entry} ->
            models =
              if is_list(entry[:models]),
                do:
                  Enum.map(entry.models, fn e ->
                    if e.id == id, do: %{e | health: health}, else: e
                  end)

            {key, Map.put(entry, :models, models)}
          end)

        %{state | catalogs: catalogs}

      endpoint ->
        put_in(state.endpoints[id], %{endpoint | health: health})
    end
  end

  defp same_connection?(a, b) do
    fields = [:provider, :provider_module, :transport, :credential, :auth, :enabled]
    Map.take(a, fields) == Map.take(b, fields)
  end

  defp preserve_catalog_state(existing, endpoint) do
    preserved = preserve_runtime_state(existing, endpoint)

    if preserved.health.status == :unavailable,
      do: %{preserved | health: %{status: :unknown, checked_at: nil}},
      else: preserved
  end

  defp put_checked_health(state, original, result) do
    current = all_endpoints(state)[original.id]

    if current && ModelEndpoint.same_configuration?(current, original),
      do: put_health(state, original.id, result),
      else: state
  end
end
