defmodule BeamAgent.Session.FileTracker do
  @moduledoc """
  Session-owned observed file generations.

  Models identify files and exact edits; this process owns the version ledger.
  Legacy callers may still provide a SHA, but model-facing tools no longer need
  to copy hashes through the conversation.
  """
  use GenServer

  alias BeamAgent.Names

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, %{}, name: Names.via(:file_tracker, session_id))
  end

  def observe(context, path, sha256) when is_binary(path) and is_binary(sha256) do
    with session_id when is_binary(session_id) <- Map.get(context, :session_id),
         {:ok, pid} <- Names.pid(:file_tracker, session_id) do
      GenServer.call(pid, {:observe, path, sha256})
    else
      _other -> :ok
    end
  end

  def expected(context, path) when is_binary(path) do
    with session_id when is_binary(session_id) <- Map.get(context, :session_id),
         {:ok, pid} <- Names.pid(:file_tracker, session_id) do
      GenServer.call(pid, {:expected, path})
    else
      _other -> {:error, :file_not_observed}
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:observe, path, sha256}, _from, state) do
    generation = get_in(state, [path, :generation]) || 0
    observation = %{sha256: sha256, generation: generation + 1}
    {:reply, :ok, Map.put(state, path, observation)}
  end

  def handle_call({:expected, path}, _from, state) do
    case Map.fetch(state, path) do
      {:ok, observation} -> {:reply, {:ok, observation}, state}
      :error -> {:reply, {:error, :file_not_observed}, state}
    end
  end
end
