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
    def get_json(url, headers, options) do
      send(options[:test_pid], {:http_get, url, headers})
      {:ok, Keyword.get(options, :stub_status, 200), options[:stub_response]}
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
end
