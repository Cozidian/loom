defmodule BeamAgent.CodexAppServer.Conversation do
  @moduledoc """
  Session-supervised Codex App Server conversation.

  The process retains one App Server client and native thread across model
  invocations. It owns no filesystem authority; every dynamic tool still calls
  back through the current BeamAgent turn's `ToolRunner` executor.
  """
  use GenServer

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
    with {:ok, conversation} <- ensure_open(state.conversation, state.options, options),
         {:ok, response, conversation} <-
           CodexAppServer.invoke_conversation(conversation, messages, tools, options, emit) do
      {:reply, {:ok, response}, %{state | conversation: conversation}}
    else
      {:error, reason} ->
        close(state.conversation)
        {:reply, {:error, reason}, %{state | conversation: nil}}
    end
  end

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
