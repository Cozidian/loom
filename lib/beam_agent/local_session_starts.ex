defmodule BeamAgent.LocalSessionStarts do
  @moduledoc "Runtime-owned, idempotent local session startup, independent of HTTP request lifetimes."
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def begin(id, config, config_path, server \\ __MODULE__),
    do: GenServer.call(server, {:begin, id, config, config_path})

  def status(id, server \\ __MODULE__), do: GenServer.call(server, {:status, id})

  def init(opts),
    do:
      {:ok,
       %{
         jobs: %{},
         refs: %{},
         create: Keyword.get(opts, :create, &BeamAgent.CLI.create_local_session/2)
       }}

  def handle_call({:begin, id, config, config_path}, _, state) do
    signature = :crypto.hash(:sha256, :erlang.term_to_binary({config, config_path}))

    cond do
      not is_binary(id) or not Regex.match?(~r/\A[a-zA-Z0-9_-]{16,100}\z/, id) ->
        {:reply, {:error, :invalid_start_id}, state}

      Map.has_key?(state.jobs, id) ->
        {previous, job} = state.jobs[id]
        result = if previous == signature, do: {:ok, job}, else: {:error, :start_id_conflict}
        {:reply, result, state}

      map_size(state.refs) >= 4 or map_size(state.jobs) >= 1024 ->
        {:reply, {:error, :session_start_capacity}, state}

      true ->
        task =
          Task.Supervisor.async_nolink(BeamAgent.LocalStartupTasks, fn ->
            state.create.(config, config_path)
          end)

        job = %{request_id: id, status: "starting"}

        {:reply, {:ok, job},
         %{
           state
           | jobs: Map.put(state.jobs, id, {signature, job}),
             refs: Map.put(state.refs, task.ref, id)
         }}
    end
  end

  def handle_call({:status, id}, _, state) do
    result =
      case state.jobs[id] do
        {_, job} -> {:ok, job}
        _ -> {:error, :unknown_session_start}
      end

    {:reply, result, state}
  end

  def handle_info({ref, result}, state) when is_map_key(state.refs, ref) do
    Process.demonitor(ref, [:flush])

    update =
      case result do
        {:ok, id, _} -> %{status: "ready", session_id: id}
        {:error, reason} -> %{status: "failed", error: error_code(reason)}
        _ -> %{status: "failed", error: "session_start_failed"}
      end

    {:noreply, finish(state, ref, update)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) when is_map_key(state.refs, ref),
    do: {:noreply, finish(state, ref, %{status: "failed", error: "session_start_interrupted"})}

  def handle_info(_, state), do: {:noreply, state}

  defp finish(state, ref, update) do
    id = state.refs[ref]
    {signature, job} = state.jobs[id]

    %{
      state
      | jobs: Map.put(state.jobs, id, {signature, Map.merge(job, update)}),
        refs: Map.delete(state.refs, ref)
    }
  end

  defp error_code(reason) when is_atom(reason), do: to_string(reason)
  defp error_code(reason) when is_tuple(reason), do: error_code(elem(reason, 0))
  defp error_code(_), do: "session_start_failed"
end
