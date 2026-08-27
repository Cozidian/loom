defmodule BeamAgent.ModelInvocationTest do
  use ExUnit.Case, async: true

  alias BeamAgent.{ModelInvocation, ModelRequest, ModelUsage}

  defmodule ContractProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :model_invocation_contract_test

    @impl true
    def complete(_messages, _tools, options) do
      case options[:mode] do
        :slow ->
          Process.sleep(:infinity)

        :raise ->
          raise "provider exploded"

        :invalid ->
          {:ok, %{content: 42, tool_calls: :invalid}}

        _normal ->
          {:ok,
           %{
             content: "complete",
             tool_calls: [],
             usage: %{"prompt_tokens" => 4, "completion_tokens" => 2}
           }}
      end
    end

    @impl true
    def stream(_messages, _tools, _options, emit) do
      emit.({:text_delta, "streamed"})
      emit.({:usage, %{"prompt_eval_count" => 3, "eval_count" => 2}})
      {:ok, %{content: "streamed", tool_calls: []}}
    end
  end

  test "requests make streaming, timeout, cancellation, and identity explicit" do
    assert {:ok, request} =
             request(stream: true, timeout: 5_000, endpoint_id: "local-coder")

    assert request.version == 1
    assert request.request_id =~ "model-request-"
    assert request.endpoint_id == "local-coder"
    assert request.stream
    assert request.timeout == 5_000
    assert request.cancellation == :owner_process
  end

  test "streaming usage and successful responses use normalized contracts" do
    owner = self()
    {:ok, request} = request(stream: true)

    assert {:ok, response} =
             ModelInvocation.invoke(request, fn event -> send(owner, {:event, event}) end)

    assert response.request_id == request.request_id
    assert response.content == "streamed"
    assert response.tool_calls == []

    assert_receive {:event, {:text_delta, "streamed"}}

    assert_receive {:event,
                    {:usage,
                     %{
                       "input_tokens" => 3,
                       "output_tokens" => 2,
                       "total_tokens" => 5,
                       "provider_usage" => %{
                         "prompt_eval_count" => 3,
                         "eval_count" => 2
                       }
                     }}}
  end

  test "non-streaming response usage is normalized" do
    {:ok, request} = request(stream: false)
    assert {:ok, response} = ModelInvocation.invoke(request)
    assert response.content == "complete"
    assert response.usage["input_tokens"] == 4
    assert response.usage["output_tokens"] == 2
    assert response.usage["total_tokens"] == 6
  end

  test "timeouts, exceptions, and malformed returns become normalized errors" do
    {:ok, timeout_request} = request(stream: false, timeout: 10, options: [mode: :slow])
    assert {:error, timeout_error} = ModelInvocation.invoke(timeout_request)
    assert timeout_error.code == :model_timeout
    assert timeout_error.retryable
    assert timeout_error.cause == :model_timeout

    {:ok, exception_request} = request(stream: false, options: [mode: :raise])
    assert {:error, exception_error} = ModelInvocation.invoke(exception_request)
    assert exception_error.code == :provider_exception
    refute exception_error.retryable

    {:ok, invalid_request} = request(stream: false, options: [mode: :invalid])
    assert {:error, invalid_error} = ModelInvocation.invoke(invalid_request)
    assert invalid_error.code == :invalid_provider_response
  end

  test "usage normalization covers OpenAI, Anthropic, and Ollama counters" do
    assert ModelUsage.normalize(%{"prompt_tokens" => 8, "completion_tokens" => 3})[
             "total_tokens"
           ] == 11

    assert ModelUsage.normalize(%{"input_tokens" => 5, "output_tokens" => 2})[
             "total_tokens"
           ] == 7

    assert ModelUsage.normalize(%{"prompt_eval_count" => 6, "eval_count" => 4})[
             "total_tokens"
           ] == 10
  end

  defp request(overrides) do
    defaults = [
      endpoint_id: "contract-test",
      provider: :model_invocation_contract_test,
      provider_module: ContractProvider,
      model: "test-model",
      messages: [%{role: :user, content: "hello"}],
      tools: [],
      options: [],
      metadata: %{}
    ]

    ModelRequest.new(Keyword.merge(defaults, overrides))
  end
end
