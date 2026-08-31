defmodule BeamAgent.ProvidersTest do
  use ExUnit.Case, async: true

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
          test_pid: Keyword.fetch!(opts, :test_pid)
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

    def request(client, "turn/start", params) do
      state = Agent.get(client, & &1)
      send(state.test_pid, {:codex_turn_started, params})

      case state.mode do
        :tool ->
          send(
            state.owner,
            {:codex_app_server, client,
             {:request,
              %{
                "id" => 41,
                "method" => "item/tool/call",
                "params" => %{
                  "callId" => "codex-call",
                  "tool" => "add",
                  "arguments" => %{"a" => 2, "b" => 3}
                }
              }}}
          )

        :text ->
          emit_agent_text(client, state.owner, "hello")
          complete_turn(client, state.owner)

        :streaming_text ->
          emit_agent_text(client, state.owner, "hello", ["he", "llo"])
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

    def respond(client, 41, result) do
      state = Agent.get(client, & &1)
      send(state.test_pid, {:codex_tool_response, result})
      complete_turn(client, state.owner)
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
