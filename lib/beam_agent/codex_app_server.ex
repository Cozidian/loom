defmodule BeamAgent.CodexAppServer do
  @moduledoc """
  Supported OpenAI Codex App Server integration used for ChatGPT-plan access.

  Codex owns browser authentication, credential persistence, and refresh. The
  harness remains authoritative for conversation state, tool execution, and
  approvals: app-server receives only BeamAgent's dynamic tool schemas and each
  invocation is constrained to one model decision.
  """

  alias BeamAgent.CodexAppServer.Client

  @client_info %{"name" => "beam_agent", "title" => "BeamAgent", "version" => "0.1.0"}
  @disabled_features ~w(
    apps browser_use computer_use image_generation in_app_browser multi_agent
    plugins shell_tool skill_search web_search_request
  )
  @max_tool_calls 16

  def available?(opts \\ []) do
    not is_nil(
      Keyword.get(opts, :executable) || System.get_env("BEAM_AGENT_CODEX_BIN") ||
        System.find_executable("codex")
    )
  end

  def initialize(client, client_module \\ Client) do
    with {:ok, _result} <-
           client_module.request(client, "initialize", %{
             "clientInfo" => @client_info,
             "capabilities" => %{"experimentalApi" => true}
           }),
         :ok <- client_module.notify(client, "initialized", %{}) do
      :ok
    end
  end

  def account(opts \\ []) do
    with_client(opts, fn client, client_module ->
      with {:ok, result} <-
             client_module.request(client, "account/read", %{"refreshToken" => false}) do
        {:ok, result}
      end
    end)
  end

  def logout(opts \\ []) do
    with_client(opts, fn client, client_module ->
      with {:ok, _result} <- client_module.request(client, "account/logout", %{}) do
        :ok
      end
    end)
  end

  def invoke(messages, tools, options, emit \\ fn _event -> :ok end) do
    with_client(options, fn client, client_module ->
      with {:ok, account} <-
             client_module.request(client, "account/read", %{"refreshToken" => true}),
           :ok <- require_chatgpt(account),
           {:ok, thread} <- start_thread(client, client_module, tools, options),
           {:ok, _turn} <- start_turn(client, client_module, thread, messages, options) do
        await_turn(client, client_module, thread, emit, empty_invocation())
      end
    end)
  end

  defp with_client(options, fun) do
    client_module = Keyword.get(options, :codex_client, Client)

    client_options =
      options
      |> Keyword.get(:codex_client_options, [])
      |> Keyword.put_new(:owner, self())
      |> Keyword.put_new(:arguments, arguments())

    with {:ok, client} <- client_module.start_link(client_options) do
      try do
        with :ok <- initialize(client, client_module), do: fun.(client, client_module)
      after
        client_module.stop(client)
      end
    end
  end

  defp arguments do
    ["app-server", "--stdio"] ++ Enum.flat_map(@disabled_features, &["--disable", &1])
  end

  defp require_chatgpt(%{"account" => %{"type" => "chatgpt"}}), do: :ok
  defp require_chatgpt(%{"account" => nil}), do: {:error, :chatgpt_login_required}

  defp require_chatgpt(%{"account" => %{"type" => type}}),
    do: {:error, {:chatgpt_login_required, type}}

  defp require_chatgpt(other), do: {:error, {:invalid_codex_account, other}}

  defp start_thread(client, client_module, tools, options) do
    with {:ok, model} <- BeamAgent.Providers.Support.require_option(options, :model),
         {:ok, result} <-
           client_module.request(client, "thread/start", %{
             "model" => model,
             "cwd" => isolated_cwd(),
             "ephemeral" => true,
             "approvalPolicy" => "never",
             "sandbox" => "read-only",
             "serviceName" => "beam_agent",
             "baseInstructions" => base_instructions(),
             "developerInstructions" => developer_instructions(),
             "dynamicTools" => Enum.map(tools, &dynamic_tool/1),
             "environments" => []
           }),
         thread_id when is_binary(thread_id) <- get_in(result, ["thread", "id"]) do
      {:ok, thread_id}
    else
      nil -> {:error, :invalid_codex_thread_response}
      {:error, _reason} = error -> error
    end
  end

  defp start_turn(client, client_module, thread, messages, options) do
    params = %{
      "threadId" => thread,
      "input" => [%{"type" => "text", "text" => transcript(messages, options)}],
      "approvalPolicy" => "never",
      "sandboxPolicy" => %{"type" => "readOnly"},
      "environments" => []
    }

    client_module.request(client, "turn/start", params)
  end

  defp await_turn(client, client_module, thread, emit, state) do
    receive do
      {:codex_app_server, ^client,
       {:notification, %{"method" => "item/agentMessage/delta", "params" => %{"delta" => delta}}}}
      when is_binary(delta) ->
        if state.calls == [], do: emit.({:text_delta, delta})
        await_turn(client, client_module, thread, emit, %{state | deltas: [delta | state.deltas]})

      {:codex_app_server, ^client,
       {:notification, %{"method" => "item/completed", "params" => %{"item" => item}}}} ->
        state = capture_completed_item(state, item)
        await_turn(client, client_module, thread, emit, state)

      {:codex_app_server, ^client,
       {:request, %{"id" => id, "method" => "item/tool/call", "params" => params}}} ->
        with {:ok, state} <- capture_tool_call(state, params, emit),
             :ok <-
               client_module.respond(client, id, %{
                 "contentItems" => [
                   %{
                     "type" => "inputText",
                     "text" =>
                       "BeamAgent accepted this tool request for host execution. Stop this turn now."
                   }
                 ],
                 "success" => true
               }) do
          await_turn(client, client_module, thread, emit, state)
        end

      {:codex_app_server, ^client,
       {:notification, %{"method" => "turn/completed", "params" => %{"turn" => turn}}}} ->
        finish_turn(turn, state)

      {:codex_app_server, ^client, {:notification, %{"method" => "error", "params" => error}}} ->
        {:error, {:codex_app_server_error, error}}

      {:codex_app_server, ^client, {:protocol_error, reason, _line}} ->
        {:error, {:codex_app_server_protocol_error, reason}}

      {:codex_app_server, ^client, {:exit, reason}} ->
        {:error, reason}

      {:codex_app_server, ^client, _other} ->
        await_turn(client, client_module, thread, emit, state)
    end
  end

  defp empty_invocation, do: %{calls: [], content: nil, deltas: []}

  defp capture_completed_item(state, %{"type" => "agentMessage", "text" => text})
       when is_binary(text),
       do: %{state | content: text}

  defp capture_completed_item(state, _item), do: state

  defp capture_tool_call(%{calls: calls}, _params, _emit) when length(calls) >= @max_tool_calls,
    do: {:error, :too_many_codex_tool_calls}

  defp capture_tool_call(state, params, emit) do
    with name when is_binary(name) and name != "" <- params["tool"],
         arguments when is_map(arguments) <- params["arguments"] do
      index = length(state.calls)
      id = params["callId"] || BeamAgent.Providers.Support.call_id()
      call = %{id: id, name: name, arguments: arguments}

      emit.(
        {:tool_call_delta,
         %{
           "index" => index,
           "id" => id,
           "type" => "function",
           "function" => %{"name" => name, "arguments" => JSON.encode!(arguments)}
         }}
      )

      {:ok, %{state | calls: state.calls ++ [call]}}
    else
      other -> {:error, {:invalid_codex_tool_call, other}}
    end
  end

  defp finish_turn(%{"status" => "completed"}, %{calls: [_ | _]} = state) do
    {:ok, %{content: nil, tool_calls: state.calls}}
  end

  defp finish_turn(%{"status" => "completed"}, state) do
    content = state.content || state.deltas |> Enum.reverse() |> IO.iodata_to_binary()
    {:ok, %{content: empty_to_nil(content), tool_calls: []}}
  end

  defp finish_turn(%{"status" => status, "error" => error}, _state),
    do: {:error, {:codex_turn_failed, status, error}}

  defp finish_turn(turn, _state), do: {:error, {:invalid_codex_turn, turn}}

  defp dynamic_tool(tool) do
    %{
      "type" => "function",
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => tool.input_schema
    }
  end

  defp transcript(messages, options) do
    system =
      case options[:system_prompt] do
        prompt when is_binary(prompt) and prompt != "" -> ["SYSTEM\n", prompt, "\n\n"]
        _ -> []
      end

    body =
      Enum.map(messages, fn message ->
        [String.upcase(to_string(message.role)), "\n", message_content(message), "\n\n"]
      end)

    IO.iodata_to_binary([
      "Perform one assistant step for this BeamAgent transcript.\n\n",
      system,
      body
    ])
  end

  defp message_content(%{role: :assistant} = message) do
    calls = Map.get(message, :tool_calls, [])

    if calls == [] do
      Map.get(message, :content) || ""
    else
      JSON.encode!(%{"content" => Map.get(message, :content), "tool_calls" => calls})
    end
  end

  defp message_content(%{role: :tool} = message) do
    JSON.encode!(%{"tool_call_id" => message.tool_call_id, "content" => message.content})
  end

  defp message_content(message), do: Map.get(message, :content) || ""

  defp base_instructions do
    """
    You are an intelligence resource inside BeamAgent, not an autonomous coding runtime.
    Make exactly one assistant decision for the supplied conversation. Never inspect the
    filesystem and never use shell, web, apps, MCP, skills, plugins, or subagents. The only
    tools you may call are the host-provided dynamic tools. If a dynamic tool is needed,
    call it with exact arguments. When its result says BeamAgent accepted the request,
    stop immediately without calling more tools or answering the original question.
    Otherwise provide the final assistant answer directly.
    """
  end

  defp developer_instructions do
    "BeamAgent owns tool execution, approvals, repository access, and orchestration. Do not bypass it."
  end

  defp isolated_cwd do
    path = Path.join(System.tmp_dir!(), "beam-agent-codex-model")
    :ok = File.mkdir_p(path)
    path
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(content), do: content
end
