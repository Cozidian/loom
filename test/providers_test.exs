defmodule BeamAgent.ProvidersTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias BeamAgent.Providers.{Anthropic, Ollama, OpenAI, XAI}

  test "grok is an alias for the xAI provider" do
    assert {:ok, %{id: :xai, module: XAI, name: "xai"}} = BeamAgent.Providers.fetch("grok")
  end

  defmodule HTTPStub do
    @behaviour BeamAgent.HTTPClient

    @impl true
    def post_json(url, headers, body, options) do
      send(options[:test_pid], {:http_post, url, headers, body})
      {:ok, Keyword.get(options, :stub_status, 200), options[:stub_response]}
    end

    @impl true
    def post_json_stream(url, headers, body, options, initial_state, chunk_fun) do
      send(options[:test_pid], {:http_stream, url, headers, body})
      status = Keyword.get(options, :stub_status, 200)

      if status in 200..299 do
        with {:ok, state} <-
               Enum.reduce_while(options[:stream_chunks] || [], {:ok, initial_state}, fn chunk,
                                                                                         {:ok,
                                                                                          state} ->
                 case chunk_fun.(chunk, state) do
                   {:ok, state} -> {:cont, {:ok, state}}
                   {:error, reason} -> {:halt, {:error, reason}}
                 end
               end) do
          {:ok, status, :streamed, state}
        end
      else
        {:ok, status, options[:stub_response]}
      end
    end

    @impl true
    def get_json(url, headers, options) do
      send(options[:test_pid], {:http_get, url, headers})
      {:ok, Keyword.get(options, :stub_status, 200), options[:stub_response]}
    end
  end

  defmodule CodexClientStub do
    def start_link(opts) do
      Agent.start_link(fn ->
        %{
          mode: Keyword.get(opts, :mode, :tool),
          owner: Keyword.fetch!(opts, :owner),
          test_pid: Keyword.fetch!(opts, :test_pid),
          tool_calls: 0
        }
      end)
    end

    def request(_client, "initialize", _params), do: {:ok, %{}}

    def request(_client, "account/read", _params) do
      {:ok, %{"account" => %{"type" => "chatgpt", "planType" => "plus"}}}
    end

    def request(client, "thread/start", params) do
      state = Agent.get(client, & &1)
      send(state.test_pid, {:codex_thread_started, params})
      {:ok, %{"thread" => %{"id" => "thread-test"}}}
    end

    def request(client, "model/list", params) do
      state = Agent.get(client, & &1)
      send(state.test_pid, {:catalog_requested, params})

      case {state.mode, params["cursor"]} do
        {:catalog_failure, _} -> {:error, :catalog_unavailable}
        {:catalog_loop, _} -> {:ok, %{"data" => [], "nextCursor" => "again"}}
        {_, nil} -> {:ok, %{"data" => [%{"model" => "gpt-test"}], "nextCursor" => "page2"}}
        {_, "page2"} -> {:ok, %{"data" => [%{"model" => "other-test"}], "nextCursor" => nil}}
      end
    end

    def request(client, "turn/start", params) do
      state = Agent.get(client, & &1)
      send(state.test_pid, {:codex_turn_started, params})

      case state.mode do
        mode when mode in [:tool, :native_tool] ->
          emit_tool_request(client, state.owner, 41, "codex-call", %{"a" => 2, "b" => 3})

        :many_native_tools ->
          emit_tool_request(client, state.owner, 1, "codex-call-1", %{"a" => 1, "b" => 1})

        :text ->
          emit_agent_text(client, state.owner, "hello")
          complete_turn(client, state.owner)

        :streaming_text ->
          emit_agent_text(client, state.owner, "hello", ["he", "llo"])
          complete_turn(client, state.owner)

        :reasoning_summary ->
          for {method, delta} <- [
                {"item/reasoning/summaryTextDelta", "Checking the public API"},
                {"item/reasoning/textDelta", "raw-private-reasoning"}
              ] do
            send(
              state.owner,
              {:codex_app_server, client,
               {:notification,
                %{
                  "method" => method,
                  "params" => %{"delta" => delta, "itemId" => "reason-1", "summaryIndex" => 0}
                }}}
            )
          end

          emit_agent_text(client, state.owner, "done")
          complete_turn(client, state.owner)

        :serialized_tool ->
          emit_agent_text(
            client,
            state.owner,
            "ASSISTANT\n\n" <>
              JSON.encode!(%{
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "serialized-call",
                    "name" => "add",
                    "arguments" => %{"a" => 2, "b" => 3}
                  }
                ]
              }),
            ["ASSI", "STANT\n", "\n{", "\"content\":null,"]
          )

          complete_turn(client, state.owner)

        :serialized_disallowed_tool ->
          emit_agent_text(
            client,
            state.owner,
            "ASSISTANT\n" <>
              JSON.encode!(%{
                "content" => nil,
                "tool_calls" => [
                  %{"id" => "bad-call", "name" => "run_command", "arguments" => %{}}
                ]
              })
          )

          complete_turn(client, state.owner)
      end

      {:ok, %{"turn" => %{"id" => "turn-test"}}}
    end

    def notify(_client, "initialized", %{}), do: :ok

    def respond(client, _id, result) do
      state =
        Agent.get_and_update(client, fn state ->
          {state, %{state | tool_calls: state.tool_calls + 1}}
        end)

      send(state.test_pid, {:codex_tool_response, result})

      case state.mode do
        :native_tool ->
          emit_agent_text(client, state.owner, "The host result was 5.")
          complete_turn(client, state.owner)

        :many_native_tools when state.tool_calls + 1 < 20 ->
          next = state.tool_calls + 2

          emit_tool_request(client, state.owner, next, "codex-call-#{next}", %{
            "a" => next,
            "b" => 1
          })

        :many_native_tools ->
          emit_agent_text(client, state.owner, "Completed 20 host tool calls.")
          complete_turn(client, state.owner)

        _other ->
          complete_turn(client, state.owner)
      end

      :ok
    end

    def stop(client), do: Agent.stop(client)

    defp complete_turn(client, owner) do
      send(
        owner,
        {:codex_app_server, client,
         {:notification,
          %{
            "method" => "turn/completed",
            "params" => %{"turn" => %{"status" => "completed"}}
          }}}
      )
    end

    defp emit_tool_request(client, owner, id, call_id, arguments) do
      send(
        owner,
        {:codex_app_server, client,
         {:request,
          %{
            "id" => id,
            "method" => "item/tool/call",
            "params" => %{
              "callId" => call_id,
              "tool" => "add",
              "arguments" => arguments
            }
          }}}
      )
    end

    defp emit_agent_text(client, owner, text, deltas \\ []) do
      Enum.each(deltas, fn delta ->
        send(
          owner,
          {:codex_app_server, client,
           {:notification,
            %{"method" => "item/agentMessage/delta", "params" => %{"delta" => delta}}}}
        )
      end)

      send(
        owner,
        {:codex_app_server, client,
         {:notification,
          %{
            "method" => "item/completed",
            "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}
          }}}
      )
    end
  end

  defmodule PersistentCodexClientStub do
    def start_link(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :persistent_codex_client_started)

      Agent.start_link(fn ->
        %{owner: Keyword.fetch!(opts, :owner), test_pid: test_pid, turns: 0}
      end)
    end

    def request(_client, "initialize", _params), do: {:ok, %{}}

    def request(_client, "account/read", _params),
      do: {:ok, %{"account" => %{"type" => "chatgpt", "planType" => "plus"}}}

    def request(client, "model/list", _params) do
      send(Agent.get(client, & &1.test_pid), {:persistent_catalog_requested, client})
      {:ok, %{"data" => [%{"model" => "gpt-test"}], "nextCursor" => nil}}
    end

    def request(client, "thread/start", params) do
      send(Agent.get(client, & &1.test_pid), {:persistent_thread_started, params})
      {:ok, %{"thread" => %{"id" => "persistent-thread"}}}
    end

    def request(client, "turn/start", params) do
      state =
        Agent.get_and_update(client, fn state -> {state, %{state | turns: state.turns + 1}} end)

      turn = state.turns + 1
      send(state.test_pid, {:persistent_turn_started, turn, params})

      send(
        state.owner,
        {:codex_app_server, client,
         {:notification,
          %{
            "method" => "item/completed",
            "params" => %{
              "item" => %{"type" => "agentMessage", "text" => "reply-#{turn}"}
            }
          }}}
      )

      send(
        state.owner,
        {:codex_app_server, client,
         {:notification,
          %{
            "method" => "turn/completed",
            "params" => %{"turn" => %{"status" => "completed"}}
          }}}
      )

      {:ok, %{"turn" => %{"id" => "turn-#{turn}"}}}
    end

    def notify(_client, "initialized", %{}), do: :ok
    def stop(client), do: Agent.stop(client)
  end

  @tools [
    %{
      name: "add",
      description: "Add two numbers.",
      input_schema: %{
        type: "object",
        properties: %{a: %{type: "number"}, b: %{type: "number"}},
        required: ["a", "b"]
      }
    }
  ]

  @image_attachment %{
    id: "attachment-test",
    mime_type: "image/png",
    data: "iVBORw0KGgo=",
    path: "/tmp/beam-agent-test-image.png"
  }

  test "session conversation retains one Codex client and native thread across user turns" do
    session_id = "persistent-codex-#{System.unique_integer([:positive])}"

    options = [
      model: "gpt-test",
      codex_client: PersistentCodexClientStub,
      codex_client_options: [test_pid: self()]
    ]

    {:ok, conversation} =
      BeamAgent.CodexAppServer.Conversation.start_link(
        session_id: session_id,
        provider_options: options
      )

    assert {:ok, %{content: "reply-1"}} =
             BeamAgent.CodexAppServer.Conversation.invoke(
               conversation,
               [%{role: :user, content: "first request"}],
               [],
               Keyword.put(options, :beam_turn, 1),
               fn _event -> :ok end
             )

    assert {:ok, %{content: "reply-2"}} =
             BeamAgent.CodexAppServer.Conversation.invoke(
               conversation,
               [
                 %{role: :user, content: "first request"},
                 %{role: :assistant, content: "reply-1", tool_calls: []},
                 %{role: :user, content: "second request"}
               ],
               [],
               Keyword.put(options, :beam_turn, 2),
               fn _event -> :ok end
             )

    assert_receive :persistent_codex_client_started
    assert_receive {:persistent_thread_started, _params}
    refute_receive {:persistent_thread_started, _params}
    assert_receive {:persistent_turn_started, 1, first}
    assert_receive {:persistent_turn_started, 2, second}
    assert hd(first["input"])["text"] =~ "first request"
    assert hd(second["input"])["text"] =~ "second request"
    refute hd(second["input"])["text"] =~ "first request"
  end

  test "idle Codex notifications are consumed without resetting the native conversation" do
    session_id = "idle-codex-notification-#{System.unique_integer([:positive])}"

    options = [
      model: "gpt-test",
      codex_client: PersistentCodexClientStub,
      codex_client_options: [test_pid: self()]
    ]

    {:ok, conversation} =
      BeamAgent.CodexAppServer.Conversation.start_link(
        session_id: session_id,
        provider_options: options
      )

    assert {:ok, %{content: "reply-1"}} =
             BeamAgent.CodexAppServer.Conversation.invoke(
               conversation,
               [%{role: :user, content: "first request"}],
               [],
               Keyword.put(options, :beam_turn, 1),
               fn _event -> :ok end
             )

    client = :sys.get_state(conversation).conversation.client

    log =
      capture_log(fn ->
        send(
          conversation,
          {:codex_app_server, client,
           {:notification,
            %{
              "method" => "mcpServer/startupStatus/updated",
              "params" => %{
                "threadId" => "persistent-thread",
                "name" => "context7",
                "status" => "ready",
                "error" => nil,
                "failureReason" => nil
              }
            }}}
        )

        _state = :sys.get_state(conversation)
      end)

    refute log =~ "received unexpected message"
    assert Process.alive?(conversation)

    assert {:ok, %{content: "reply-2"}} =
             BeamAgent.CodexAppServer.Conversation.invoke(
               conversation,
               [
                 %{role: :user, content: "first request"},
                 %{role: :assistant, content: "reply-1", tool_calls: []},
                 %{role: :user, content: "second request"}
               ],
               [],
               Keyword.put(options, :beam_turn, 2),
               fn _event -> :ok end
             )

    assert_receive :persistent_codex_client_started
    assert_receive {:persistent_thread_started, _params}
    refute_receive :persistent_codex_client_started
    refute_receive {:persistent_thread_started, _params}
  end

  test "idle Codex errors reset the native conversation before the next invocation" do
    session_id = "idle-codex-error-#{System.unique_integer([:positive])}"

    options = [
      model: "gpt-test",
      codex_client: PersistentCodexClientStub,
      codex_client_options: [test_pid: self()]
    ]

    {:ok, conversation} =
      BeamAgent.CodexAppServer.Conversation.start_link(
        session_id: session_id,
        provider_options: options
      )

    assert {:ok, %{content: "reply-1"}} =
             BeamAgent.CodexAppServer.Conversation.invoke(
               conversation,
               [%{role: :user, content: "first request"}],
               [],
               Keyword.put(options, :beam_turn, 1),
               fn _event -> :ok end
             )

    client = :sys.get_state(conversation).conversation.client

    capture_log(fn ->
      send(
        conversation,
        {:codex_app_server, client,
         {:notification, %{"method" => "error", "params" => %{"message" => "late"}}}}
      )

      assert :sys.get_state(conversation).conversation == nil
    end)

    assert {:ok, %{content: "reply-1"}} =
             BeamAgent.CodexAppServer.Conversation.invoke(
               conversation,
               [%{role: :user, content: "new request"}],
               [],
               Keyword.put(options, :beam_turn, 2),
               fn _event -> :ok end
             )

    assert_receive :persistent_codex_client_started
    assert_receive {:persistent_thread_started, _params}
    assert_receive :persistent_codex_client_started
    assert_receive {:persistent_thread_started, _params}
  end

  test "ChatGPT session supervision reuses the native thread through BeamAgent.ask" do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-codex-session-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)

    assert {:ok, session_id} =
             BeamAgent.start_session(
               workspace_root: workspace,
               data_dir: data_dir,
               provider: :openai,
               provider_options: [
                 model: "gpt-test",
                 auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
                 codex_client: PersistentCodexClientStub,
                 codex_client_options: [test_pid: self()]
               ]
             )

    on_exit(fn ->
      _ = BeamAgent.stop_session(session_id)
      File.rm_rf(root)
    end)

    assert {:ok, "reply-1"} = BeamAgent.ask(session_id, "first request")
    assert {:ok, "reply-2"} = BeamAgent.ask(session_id, "second request")

    assert_receive :persistent_codex_client_started
    assert_receive {:persistent_thread_started, _params}
    refute_receive {:persistent_thread_started, _params}
    assert_receive {:persistent_turn_started, 1, first}
    assert_receive {:persistent_turn_started, 2, second}
    assert hd(first["input"])["text"] =~ "first request"
    assert hd(second["input"])["text"] =~ "second request"
    refute hd(second["input"])["text"] =~ "first request"
  end

  test "OpenAI serializes Chat Completions history and parses function calls" do
    response = %{
      "choices" => [
        %{
          "message" => %{
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "server-call",
                "type" => "function",
                "function" => %{"name" => "add", "arguments" => ~s({"a":2,"b":3})}
              }
            ]
          }
        }
      ]
    }

    messages = [
      %{role: :user, content: "calculate"},
      %{
        role: :assistant,
        content: nil,
        tool_calls: [%{id: "prior-call", name: "add", arguments: %{"a" => 1, "b" => 1}}]
      },
      %{
        role: :tool,
        tool_call_id: "prior-call",
        name: "add",
        content: "2",
        is_error: false
      }
    ]

    assert {:ok, result} =
             OpenAI.complete(messages, @tools,
               model: "test-model",
               base_url: "https://openai.example/v1",
               api_key: "secret",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: response
             )

    assert result.tool_calls == [
             %{id: "server-call", name: "add", arguments: %{"a" => 2, "b" => 3}}
           ]

    assert_receive {:http_post, "https://openai.example/v1/chat/completions", headers, body}
    assert {"authorization", "Bearer secret"} in headers

    assert Enum.at(body["messages"], 2) == %{
             "role" => "tool",
             "tool_call_id" => "prior-call",
             "content" => "2"
           }

    assert get_in(hd(body["tools"]), ["function", "name"]) == "add"
  end

  test "vision-capable transports serialize hydrated image attachments natively" do
    openai_response = %{
      "choices" => [%{"message" => %{"content" => "I see it", "tool_calls" => []}}]
    }

    messages = [%{role: :user, content: "describe", attachments: [@image_attachment]}]

    assert {:ok, %{content: "I see it"}} =
             OpenAI.complete(messages, [],
               model: "test-model",
               base_url: "https://openai.example/v1",
               api_key: "secret",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: openai_response
             )

    assert_receive {:http_post, _url, _headers, openai_body}

    assert [text, image] = hd(openai_body["messages"])["content"]
    assert text == %{"type" => "text", "text" => "describe"}
    assert image["type"] == "image_url"
    assert get_in(image, ["image_url", "url"]) == "data:image/png;base64,iVBORw0KGgo="

    anthropic_response = %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => "I see it"}]
    }

    assert {:ok, %{content: "I see it"}} =
             Anthropic.complete(messages, [],
               model: "claude-test",
               base_url: "https://anthropic.example",
               api_key: "secret",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: anthropic_response
             )

    assert_receive {:http_post, _url, _headers, anthropic_body}
    assert [text, image] = hd(anthropic_body["messages"])["content"]
    assert text == %{"type" => "text", "text" => "describe"}
    assert image["type"] == "image"
    assert get_in(image, ["source", "media_type"]) == "image/png"
    assert get_in(image, ["source", "data"]) == "iVBORw0KGgo="
  end

  test "ChatGPT-plan transport passes attachments as native local images" do
    messages = [%{role: :user, content: "describe", attachments: [@image_attachment]}]

    assert {:ok, %{content: "hello", tool_calls: []}} =
             OpenAI.complete(messages, [],
               model: "gpt-test",
               auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
               codex_client: CodexClientStub,
               codex_client_options: [test_pid: self(), mode: :text]
             )

    assert_receive {:codex_turn_started, %{"input" => input}}

    assert Enum.any?(input, fn
             %{"type" => "localImage", "path" => "/tmp/beam-agent-test-image.png"} -> true
             _item -> false
           end)
  end

  test "OpenAI ChatGPT-plan transport exposes only BeamAgent tools and returns host calls" do
    assert {:ok, %{content: nil, tool_calls: [call]}} =
             OpenAI.complete([%{role: :user, content: "calculate"}], @tools,
               model: "gpt-test",
               auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
               codex_client: CodexClientStub,
               codex_client_options: [test_pid: self(), mode: :tool]
             )

    assert call == %{id: "codex-call", name: "add", arguments: %{"a" => 2, "b" => 3}}

    assert_receive {:codex_thread_started, thread}
    assert thread["approvalPolicy"] == "never"
    assert thread["sandbox"] == "read-only"
    assert Enum.map(thread["dynamicTools"], & &1["name"]) == ["add"]
    assert thread["baseInstructions"] =~ "host-provided dynamic tools whenever"
    assert thread["baseInstructions"] =~ "The presence of a dynamic tool means you are allowed"
    assert thread["baseInstructions"] =~ "path arguments workspace-relative"
    assert thread["baseInstructions"] =~ "do not inspect Codex configuration or memory"
    refute thread["baseInstructions"] =~ "Never inspect the filesystem"

    assert_receive {:codex_tool_response, response}
    assert response["success"] == true
    assert_receive {:codex_turn_started, %{"sandboxPolicy" => %{"type" => "readOnly"}}}
  end

  test "OpenAI ChatGPT-plan transport executes a host tool inside the same Codex turn" do
    executor = fn call ->
      send(self(), {:native_codex_call, call})
      {:ok, %{content: "5", is_error: false, error: nil}}
    end

    assert {:ok, %{content: "The host result was 5.", tool_calls: []}} =
             OpenAI.complete([%{role: :user, content: "calculate"}], @tools,
               model: "gpt-test",
               auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
               dynamic_tool_executor: executor,
               codex_client: CodexClientStub,
               codex_client_options: [test_pid: self(), mode: :native_tool]
             )

    assert_receive {:native_codex_call,
                    %{id: "codex-call", name: "add", arguments: %{"a" => 2, "b" => 3}}}

    assert_receive {:codex_tool_response, response}

    assert response == %{
             "contentItems" => [%{"type" => "inputText", "text" => "5"}],
             "success" => true
           }
  end

  test "OpenAI ChatGPT-plan transport has no arbitrary host tool-call ceiling" do
    executor = fn call ->
      send(self(), {:native_codex_call, call})
      {:ok, %{content: "ok", is_error: false, error: nil}}
    end

    assert {:ok, %{content: "Completed 20 host tool calls.", tool_calls: []}} =
             OpenAI.complete([%{role: :user, content: "inspect a large project"}], @tools,
               model: "gpt-test",
               auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
               dynamic_tool_executor: executor,
               codex_client: CodexClientStub,
               codex_client_options: [test_pid: self(), mode: :many_native_tools]
             )

    calls =
      for _index <- 1..20 do
        assert_receive {:native_codex_call, call}
        call
      end

    assert Enum.map(calls, & &1.id) == Enum.map(1..20, &"codex-call-#{&1}")
  end

  test "ChatGPT transport forwards only public reasoning summaries" do
    assert {:ok, %{content: "done"}} =
             OpenAI.stream(
               [%{role: :user, content: "inspect"}],
               @tools,
               [
                 model: "gpt-test",
                 auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
                 codex_client: CodexClientStub,
                 codex_client_options: [test_pid: self(), mode: :reasoning_summary]
               ],
               fn event -> send(self(), {:summary_event, event}) end
             )

    assert_receive {:summary_event,
                    {:reasoning_summary_delta,
                     %{delta: "Checking the public API", item_id: "reason-1", summary_index: 0}}}

    assert_receive {:summary_event, {:text_delta, "done"}}
    refute_receive {:summary_event, _}
    assert_receive {:codex_turn_started, %{"summary" => "concise"}}
  end

  test "OpenAI ChatGPT-plan transport returns final text without HTTP credentials" do
    assert {:ok, %{content: "hello", tool_calls: []}} =
             OpenAI.complete([%{role: :user, content: "say hello"}], [],
               model: "gpt-test",
               auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
               codex_client: CodexClientStub,
               codex_client_options: [test_pid: self(), mode: :text]
             )
  end

  test "OpenAI ChatGPT-plan transport keeps streaming ordinary text" do
    emit = fn event -> send(self(), {:codex_delta, event}) end

    assert {:ok, %{content: "hello", tool_calls: []}} =
             OpenAI.stream(
               [%{role: :user, content: "say hello"}],
               [],
               [
                 model: "gpt-test",
                 auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
                 codex_client: CodexClientStub,
                 codex_client_options: [test_pid: self(), mode: :streaming_text]
               ],
               emit
             )

    assert_receive {:codex_delta, {:text_delta, "he"}}
    assert_receive {:codex_delta, {:text_delta, "llo"}}
  end

  test "OpenAI ChatGPT-plan transport recovers an exact serialized tool envelope" do
    emit = fn event -> send(self(), {:codex_delta, event}) end

    assert {:ok, %{content: nil, tool_calls: [call]}} =
             OpenAI.stream(
               [%{role: :user, content: "calculate"}],
               @tools,
               [
                 model: "gpt-test",
                 auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
                 codex_client: CodexClientStub,
                 codex_client_options: [test_pid: self(), mode: :serialized_tool]
               ],
               emit
             )

    assert call == %{
             id: "serialized-call",
             name: "add",
             arguments: %{"a" => 2, "b" => 3}
           }

    assert_receive {:codex_delta,
                    {:tool_call_delta,
                     %{
                       "id" => "serialized-call",
                       "function" => %{"name" => "add"}
                     }}}

    refute_receive {:codex_delta, {:text_delta, _text}}
  end

  test "OpenAI ChatGPT-plan transport never promotes an unadvertised serialized tool" do
    assert {:error, {:invalid_codex_serialized_tool_envelope, {:tool_not_allowed, "run_command"}}} =
             OpenAI.complete([%{role: :user, content: "calculate"}], @tools,
               model: "gpt-test",
               auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
               codex_client: CodexClientStub,
               codex_client_options: [test_pid: self(), mode: :serialized_disallowed_tool]
             )
  end

  test "OpenAI ChatGPT-plan transcript separates history from native tool protocol" do
    messages = [
      %{role: :user, content: "calculate <carefully>"},
      %{
        role: :assistant,
        content: nil,
        tool_calls: [%{id: "prior-call", name: "add", arguments: %{"a" => 1, "b" => 1}}]
      },
      %{
        role: :tool,
        tool_call_id: "prior-call",
        name: "add",
        content: "2",
        is_error: false
      }
    ]

    assert {:ok, %{content: "hello", tool_calls: []}} =
             OpenAI.complete(messages, @tools,
               model: "gpt-test",
               auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
               codex_client: CodexClientStub,
               codex_client_options: [test_pid: self(), mode: :text]
             )

    assert_receive {:codex_turn_started, %{"input" => [%{"text" => transcript}]}}
    assert transcript =~ "<beam-agent-conversation>"
    assert transcript =~ "<message role=\"assistant\">"
    assert transcript =~ "<tool-request id=\"prior-call\" name=\"add\">"
    assert transcript =~ "calculate &lt;carefully&gt;"
    refute transcript =~ ~s("tool_calls")
    refute transcript =~ "ASSISTANT\n"
  end

  test "xAI uses the compatible tool protocol with its own defaults" do
    response = %{"choices" => [%{"message" => %{"content" => "hello", "tool_calls" => []}}]}

    assert {:ok, %{content: "hello", tool_calls: []}} =
             XAI.complete([%{role: :user, content: "hi"}], [],
               model: "grok-test",
               api_key: "xai-secret",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: response
             )

    assert_receive {:http_post, "https://api.x.ai/v1/chat/completions", _headers, body}
    assert body["model"] == "grok-test"
  end

  test "cloud healthchecks report an unset credential environment variable" do
    env = "BEAM_AGENT_TEST_MISSING_#{System.unique_integer([:positive])}"

    assert {:error, {:missing_api_key, ^env}} =
             OpenAI.healthcheck(model: "test-model", api_key_env: env)
  end

  test "ChatGPT health checks validate the configured model against the complete catalogue" do
    opts = [
      auth: %{"type" => "chatgpt"},
      codex_client: CodexClientStub,
      codex_client_options: [test_pid: self()]
    ]

    assert {:ok, _} = OpenAI.healthcheck([model: "other-test"] ++ opts)
    assert_receive {:catalog_requested, %{"cursor" => "page2"}}

    assert {:error, {:chatgpt_model_unavailable, "retired-model", ["gpt-test", "other-test"]}} =
             OpenAI.healthcheck([model: "retired-model"] ++ opts)

    assert {:error, :catalog_unavailable} =
             BeamAgent.CodexAppServer.models(
               codex_client: CodexClientStub,
               codex_client_options: [test_pid: self(), mode: :catalog_failure]
             )

    assert {:error, :invalid_model_catalog_cursor} =
             BeamAgent.CodexAppServer.models(
               codex_client: CodexClientStub,
               codex_client_options: [test_pid: self(), mode: :catalog_loop]
             )
  end

  test "ChatGPT invocation rejects an unavailable model before starting a native thread or turn" do
    opts = [
      model: "retired-model",
      auth: %{"type" => "chatgpt"},
      codex_client: CodexClientStub,
      codex_client_options: [test_pid: self()]
    ]

    assert {:error, {:chatgpt_model_unavailable, "retired-model", ["gpt-test", "other-test"]}} =
             OpenAI.complete([%{role: :user, content: "do not send"}], [], opts)

    assert_receive {:catalog_requested, _}
    refute_receive {:codex_thread_started, _}
    refute_receive {:codex_turn_started, _}
  end

  test "an unavailable model closes a newly opened session client and permits a corrected retry" do
    opts = [
      model: "retired-model",
      codex_client: PersistentCodexClientStub,
      codex_client_options: [test_pid: self()]
    ]

    conversation =
      start_supervised!(
        {BeamAgent.CodexAppServer.Conversation,
         session_id: "invalid-model-#{System.unique_integer([:positive])}", provider_options: opts}
      )

    assert {:error, {:chatgpt_model_unavailable, _, _}} =
             BeamAgent.CodexAppServer.Conversation.invoke(
               conversation,
               [%{role: :user, content: "draft"}],
               [],
               opts,
               fn _ -> :ok end
             )

    assert_receive {:persistent_catalog_requested, client}
    refute Process.alive?(client)
    refute_receive {:persistent_thread_started, _}

    assert {:ok, %{content: "reply-1"}} =
             BeamAgent.CodexAppServer.Conversation.invoke(
               conversation,
               [%{role: :user, content: "draft"}],
               [],
               Keyword.put(opts, :model, "gpt-test"),
               fn _ -> :ok end
             )
  end

  test "Anthropic groups consecutive tool results into one user content block" do
    messages = [
      %{role: :user, content: "calculate twice"},
      %{
        role: :assistant,
        content: "I'll calculate.",
        tool_calls: [
          %{id: "tool-1", name: "add", arguments: %{"a" => 1, "b" => 2}},
          %{id: "tool-2", name: "add", arguments: %{"a" => 3, "b" => 4}}
        ]
      },
      %{role: :tool, tool_call_id: "tool-1", name: "add", content: "3", is_error: false},
      %{role: :tool, tool_call_id: "tool-2", name: "add", content: "7", is_error: true}
    ]

    response = %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => "The results are 3 and 7."}]
    }

    assert {:ok, %{content: "The results are 3 and 7.", tool_calls: []}} =
             Anthropic.complete(messages, @tools,
               model: "claude-test",
               base_url: "https://anthropic.example",
               api_key: "secret",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: response
             )

    assert_receive {:http_post, "https://anthropic.example/v1/messages", headers, body}
    assert {"anthropic-version", "2023-06-01"} in headers

    tool_results = get_in(Enum.at(body["messages"], 2), ["content"])
    assert length(tool_results) == 2
    assert Enum.at(tool_results, 1)["is_error"] == true
    assert get_in(Enum.at(body["messages"], 1), ["content", Access.at(1), "type"]) == "tool_use"
  end

  test "Anthropic parses tool_use blocks" do
    response = %{
      "stop_reason" => "tool_use",
      "content" => [
        %{"type" => "text", "text" => "Checking."},
        %{
          "type" => "tool_use",
          "id" => "toolu-1",
          "name" => "add",
          "input" => %{"a" => 2, "b" => 3}
        }
      ]
    }

    assert {:ok,
            %{
              content: "Checking.",
              tool_calls: [%{id: "toolu-1", name: "add", arguments: %{"a" => 2, "b" => 3}}]
            }} =
             Anthropic.complete([%{role: :user, content: "add"}], @tools,
               model: "claude-test",
               base_url: "https://anthropic.example",
               api_key: "secret",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: response
             )
  end

  test "Ollama uses native tool_name history and parses map arguments" do
    response = %{
      "done" => true,
      "message" => %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{"function" => %{"name" => "add", "arguments" => %{"a" => 4, "b" => 5}}}
        ]
      }
    }

    messages = [
      %{role: :user, content: "add"},
      %{role: :tool, tool_call_id: "ignored", name: "add", content: "2", is_error: false}
    ]

    assert {:ok, %{content: "", tool_calls: [call]}} =
             Ollama.complete(messages, @tools,
               model: "qwen3:8b",
               base_url: "http://ollama.example",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: response
             )

    assert call.name == "add"
    assert call.arguments == %{"a" => 4, "b" => 5}

    assert_receive {:http_post, "http://ollama.example/api/chat", _headers, body}

    assert Enum.at(body["messages"], 1) == %{
             "role" => "tool",
             "tool_name" => "add",
             "content" => "2"
           }

    assert body["stream"] == false
  end

  test "Ollama strips a Harmony functions/ prefix from tool names" do
    response = %{
      "done" => true,
      "message" => %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{
            "function" => %{
              "name" => "functions/create_file",
              "arguments" => %{"path" => "a.txt"}
            }
          }
        ]
      }
    }

    assert {:ok, %{tool_calls: [call]}} =
             Ollama.complete([%{role: :user, content: "write"}], @tools,
               model: "gpt-oss:20b",
               base_url: "http://ollama.example",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: response
             )

    assert call.name == "create_file"
    assert call.arguments == %{"path" => "a.txt"}
  end

  test "Ollama warns when the configured model does not report tool-calling support" do
    assert "phi3 does not report tool-calling support" <> _ =
             Ollama.tool_support_notice(
               model: "phi3",
               base_url: "http://ollama.example",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: %{"capabilities" => ["completion"]}
             )

    assert_receive {:http_post, "http://ollama.example/api/show", _headers, %{"model" => "phi3"}}
  end

  test "Ollama stays silent when the configured model reports tool-calling support" do
    assert Ollama.tool_support_notice(
             model: "qwen3:8b",
             base_url: "http://ollama.example",
             http_client: HTTPStub,
             test_pid: self(),
             stub_response: %{"capabilities" => ["completion", "tools"]}
           ) == nil
  end

  test "Ollama stays silent about tool support when it cannot be determined" do
    assert Ollama.tool_support_notice(
             model: "custom",
             base_url: "http://ollama.example",
             http_client: HTTPStub,
             test_pid: self(),
             stub_response: %{"no_capabilities_field" => true}
           ) == nil

    assert Ollama.tool_support_notice(
             model: "custom",
             base_url: "http://ollama.example",
             http_client: HTTPStub,
             test_pid: self(),
             stub_status: 500,
             stub_response: %{"error" => "unavailable"}
           ) == nil
  end

  test "provider HTTP errors retain status without exposing request credentials" do
    response = %{"error" => %{"message" => "bad request"}}

    assert {:error, {:provider_http_error, 400, "bad request"}} =
             OpenAI.complete([%{role: :user, content: "hi"}], [],
               model: "test-model",
               base_url: "https://openai.example/v1",
               api_key: "top-secret",
               http_client: HTTPStub,
               test_pid: self(),
               stub_status: 400,
               stub_response: response
             )
  end

  test "provider HTTP errors may contain a string error without crashing" do
    assert {:error, {:provider_http_error, 400, "model does not support images"}} =
             Ollama.complete([%{role: :user, content: "hi"}], [],
               model: "qwen3:8b",
               base_url: "http://ollama.example",
               http_client: HTTPStub,
               test_pid: self(),
               stub_status: 400,
               stub_response: %{"error" => "model does not support images"}
             )
  end

  test "provider adapters preserve the project context in their native system channel" do
    openai_response = %{
      "choices" => [%{"message" => %{"content" => "ok", "tool_calls" => []}}]
    }

    assert {:ok, _response} =
             OpenAI.complete([%{role: :user, content: "hi"}], [],
               model: "test-model",
               base_url: "https://openai.example/v1",
               api_key: "secret",
               system_prompt: "project rules",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: openai_response
             )

    assert_receive {:http_post, _url, _headers, openai_body}
    assert hd(openai_body["messages"]) == %{"role" => "system", "content" => "project rules"}

    anthropic_response = %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => "ok"}]
    }

    assert {:ok, _response} =
             Anthropic.complete([%{role: :user, content: "hi"}], [],
               model: "claude-test",
               base_url: "https://anthropic.example",
               api_key: "secret",
               system_prompt: "project rules",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: anthropic_response
             )

    assert_receive {:http_post, _url, _headers, anthropic_body}
    assert anthropic_body["system"] == "project rules"
    assert hd(anthropic_body["messages"])["role"] == "user"

    ollama_response = %{
      "done" => true,
      "message" => %{"role" => "assistant", "content" => "ok", "tool_calls" => []}
    }

    assert {:ok, _response} =
             Ollama.complete([%{role: :user, content: "hi"}], [],
               model: "qwen3:8b",
               base_url: "http://ollama.example",
               system_prompt: "project rules",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: ollama_response
             )

    assert_receive {:http_post, _url, _headers, ollama_body}
    assert hd(ollama_body["messages"]) == %{"role" => "system", "content" => "project rules"}
  end

  test "OpenAI streams fragmented text and function arguments into one response" do
    chunks = [
      "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n",
      "\ndata: {\"choices\":[{\"delta\":{\"content\":\"lo\",\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"function\":{\"name\":\"ad\",\"arguments\":\"{\\\"a\\\":2,\"}}]}}]}\n\n",
      "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"d\",\"arguments\":\"\\\"b\\\":3}\"}}]}}]}\n\n",
      "data: [DONE]\n\n"
    ]

    emit = fn event -> send(self(), {:delta, event}) end

    assert {:ok,
            %{
              content: "Hello",
              tool_calls: [%{id: "call-1", name: "add", arguments: %{"a" => 2, "b" => 3}}]
            }} =
             OpenAI.stream(
               [%{role: :user, content: "calculate"}],
               @tools,
               [
                 model: "test-model",
                 base_url: "https://openai.example/v1",
                 api_key: "secret",
                 http_client: HTTPStub,
                 test_pid: self(),
                 stream_chunks: chunks
               ],
               emit
             )

    assert_receive {:delta, {:text_delta, "Hel"}}
    assert_receive {:delta, {:text_delta, "lo"}}
    assert_receive {:http_stream, "https://openai.example/v1/chat/completions", _headers, body}
    assert body["stream"] == true
  end

  test "Ollama parses Qwen XML tool calls when native tool_calls are absent" do
    response = %{
      "done" => true,
      "message" => %{
        "role" => "assistant",
        "content" =>
          "<tool_call>\n{\"name\": \"add\", \"arguments\": {\"a\": 4, \"b\": 5}}\n</tool_call>",
        "tool_calls" => []
      }
    }

    assert {:ok, %{content: nil, tool_calls: [call]}} =
             Ollama.complete([%{role: :user, content: "add"}], @tools,
               model: "qwen3:8b",
               base_url: "http://ollama.example",
               http_client: HTTPStub,
               test_pid: self(),
               stub_response: response
             )

    assert call.name == "add"
    assert call.arguments == %{"a" => 4, "b" => 5}
  end

  test "Ollama streams Qwen XML tool calls out of content when native tool_calls are absent" do
    chunks = [
      ~s({"message":{"content":"<tool_call>\\n{\\"name\\": \\"add\\", \\"arguments\\": {\\"a\\": 8, \\"b\\": 1}}\\n</tool_call>"},"done":true}\n)
    ]

    emit = fn event -> send(self(), {:delta, event}) end

    assert {:ok, %{content: nil, tool_calls: [call]}} =
             Ollama.stream(
               [%{role: :user, content: "add"}],
               @tools,
               [
                 model: "qwen3:8b",
                 base_url: "http://ollama.example",
                 http_client: HTTPStub,
                 test_pid: self(),
                 stream_chunks: chunks
               ],
               emit
             )

    assert call.name == "add"
    assert call.arguments == %{"a" => 8, "b" => 1}
  end

  test "Ollama streams fragmented NDJSON and preserves final tool calls" do
    chunks = [
      ~s({"message":{"content":"local "},"done":false}\n{"message":{"cont),
      ~s(ent":"answer"},"done":false}\n),
      ~s({"message":{"content":"","tool_calls":[{"function":{"name":"add","arguments":{"a":4,"b":5}}}]},"done":true,"eval_count":2}\n)
    ]

    emit = fn event -> send(self(), {:delta, event}) end

    assert {:ok, %{content: "local answer", tool_calls: [call]}} =
             Ollama.stream(
               [%{role: :user, content: "add"}],
               @tools,
               [
                 model: "qwen3:8b",
                 base_url: "http://ollama.example",
                 http_client: HTTPStub,
                 test_pid: self(),
                 stream_chunks: chunks
               ],
               emit
             )

    assert call.name == "add"
    assert call.arguments == %{"a" => 4, "b" => 5}
    assert_receive {:delta, {:text_delta, "local "}}
    assert_receive {:delta, {:text_delta, "answer"}}
    assert_receive {:delta, {:usage, %{"eval_count" => 2}}}
  end

  test "Anthropic streams text and partial tool JSON across SSE chunks" do
    events = [
      sse("message_start", %{
        "type" => "message_start",
        "message" => %{"usage" => %{"input_tokens" => 3}}
      }),
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Checking."}
      }),
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu-1",
          "name" => "add",
          "input" => %{}
        }
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"a":2,)}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s("b":3})}
      }),
      sse("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use"},
        "usage" => %{"output_tokens" => 4}
      }),
      sse("message_stop", %{"type" => "message_stop"})
    ]

    wire = Enum.join(events)
    chunks = [binary_part(wire, 0, 37), binary_part(wire, 37, byte_size(wire) - 37)]
    emit = fn event -> send(self(), {:delta, event}) end

    assert {:ok,
            %{
              content: "Checking.",
              tool_calls: [%{id: "toolu-1", name: "add", arguments: %{"a" => 2, "b" => 3}}]
            }} =
             Anthropic.stream(
               [%{role: :user, content: "add"}],
               @tools,
               [
                 model: "claude-test",
                 base_url: "https://anthropic.example",
                 api_key: "secret",
                 http_client: HTTPStub,
                 test_pid: self(),
                 stream_chunks: chunks
               ],
               emit
             )

    assert_receive {:delta, {:text_delta, "Checking."}}
    assert_receive {:delta, {:tool_call_delta, %{"index" => 1, "arguments" => ~s({"a":2,)}}}
  end

  defp sse(event, payload), do: "event: #{event}\ndata: #{JSON.encode!(payload)}\n\n"
end
