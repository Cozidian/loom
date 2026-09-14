defmodule BeamAgent.CodexAppServer.Conversation do
  @moduledoc """
  Session-supervised Codex App Server conversation.

  The process retains one App Server client and native thread across model
  invocations. It owns no filesystem authority; every dynamic tool still calls
  back through the current BeamAgent turn's `ToolRunner` executor.
  """
  use GenServer
  require Logger

  alias BeamAgent.{CodexAppServer, Names}

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:provider_conversation, session_id))
  end

  def invoke(conversation, messages, tools, options, emit) when is_pid(conversation) do
    GenServer.call(conversation, {:invoke, messages, tools, options, emit}, :infinity)
  end

  def pid(session_id), do: Names.pid(:provider_conversation, session_id)

  def cancel(session_id) do
    case pid(session_id) do
      {:ok, pid} ->
        Process.exit(pid, :kill)
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  @impl true
  def init(opts) do
    {:ok, %{options: Keyword.get(opts, :provider_options, []), conversation: nil}}
  end

  @impl true
  def handle_call({:invoke, messages, tools, options, emit}, _from, state) do
    options = Keyword.merge(state.options, options)

    case ensure_open(state.conversation, state.options, options) do
      {:ok, conversation} ->
        case CodexAppServer.invoke_conversation(conversation, messages, tools, options, emit) do
          {:ok, response, updated} ->
            {:reply, {:ok, response}, %{state | conversation: updated}}

          {:error, reason} ->
            # Also close a client opened during this call, before it entered state.
            close(conversation)
            {:reply, {:error, reason}, %{state | conversation: nil}}
        end

      {:error, reason} ->
        close(state.conversation)
        {:reply, {:error, reason}, %{state | conversation: nil}}
    end
  end

  @impl true
  def handle_info(
        {:codex_app_server, client, {:notification, %{"method" => "error", "params" => _error}}},
        %{conversation: %{client: client} = conversation} = state
      ) do
    Logger.warning(
      "Codex App Server reported an error while the conversation was idle; resetting"
    )

    close(conversation)
    {:noreply, %{state | conversation: nil}}
  end

  def handle_info(
        {:codex_app_server, client, {:notification, %{"method" => method}}},
        %{conversation: %{client: client}} = state
      ) do
    Logger.debug("Codex App Server idle notification: #{method}")
    {:noreply, state}
  end

  def handle_info(
        {:codex_app_server, client, {:request, %{"method" => method}}},
        %{conversation: %{client: client} = conversation} = state
      ) do
    Logger.warning(
      "Codex App Server sent request #{method} without an active invocation; resetting conversation"
    )

    close(conversation)
    {:noreply, %{state | conversation: nil}}
  end

  def handle_info(
        {:codex_app_server, client, {:protocol_error, reason, _line}},
        %{conversation: %{client: client} = conversation} = state
      ) do
    Logger.warning(
      "Codex App Server protocol error while the conversation was idle: #{inspect(reason)}; resetting"
    )

    close(conversation)
    {:noreply, %{state | conversation: nil}}
  end

  def handle_info(
        {:codex_app_server, client, {:exit, reason}},
        %{conversation: %{client: client} = conversation} = state
      ) do
    Logger.warning("Codex App Server exited while the conversation was idle: #{inspect(reason)}")
    close(conversation)
    {:noreply, %{state | conversation: nil}}
  end

  def handle_info({:codex_app_server, _stale_client, _event}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close(state.conversation)
    :ok
  end

  defp ensure_open(nil, configured, invocation) do
    CodexAppServer.open_conversation(Keyword.merge(configured, invocation))
  end

  defp ensure_open(conversation, _configured, _invocation), do: {:ok, conversation}

  defp close(nil), do: :ok
  defp close(conversation), do: CodexAppServer.close_conversation(conversation)
end
