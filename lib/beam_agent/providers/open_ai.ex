defmodule BeamAgent.Providers.OpenAI do
  @moduledoc "OpenAI provider supporting API keys and ChatGPT-plan access through Codex App Server."
  @behaviour BeamAgent.LLMProvider

  alias BeamAgent.CodexAppServer
  alias BeamAgent.Providers.{OpenAICompatible, Support}

  @impl true
  def id, do: :openai

  @impl true
  def configuration do
    %{
      name: "openai",
      label: "OpenAI",
      capabilities: [:text_generation, :tool_use, :streaming, :vision, :reasoning],
      modalities: [:text, :image],
      locality: :remote,
      privacy: :provider,
      cost_hint: :metered,
      model_required: true,
      default_base_url: "https://api.openai.com/v1",
      default_api_key_env: "OPENAI_API_KEY"
    }
  end

  @impl true
  def complete(messages, tools, options) do
    if chatgpt?(options) do
      invoke_chatgpt(messages, tools, options, fn _event -> :ok end)
    else
      options
      |> provider_options()
      |> then(&OpenAICompatible.complete(messages, tools, &1))
    end
  end

  @impl true
  def stream(messages, tools, options, emit) do
    if chatgpt?(options) do
      invoke_chatgpt(messages, tools, options, emit)
    else
      options
      |> provider_options()
      |> then(&OpenAICompatible.stream(messages, tools, &1, emit))
    end
  end

  @impl true
  def healthcheck(options) do
    if chatgpt?(options) do
      with {:ok, model} <- Support.require_option(options, :model),
           {:ok, %{"account" => %{"type" => "chatgpt"} = account}} <-
             CodexAppServer.account(options),
           {:ok, models} <- CodexAppServer.models(options),
           :ok <- validate_model(model, models) do
        plan = account["planType"] || "subscription"
        {:ok, "connected through ChatGPT #{plan}"}
      else
        {:ok, %{"account" => nil}} -> {:error, :chatgpt_login_required}
        {:error, _reason} = error -> error
        other -> {:error, {:invalid_codex_account, other}}
      end
    else
      options = Keyword.put_new(options, :base_url, configuration().default_base_url)

      with {:ok, _model} <- Support.require_option(options, :model),
           {:ok, _base_url} <- Support.require_option(options, :base_url),
           {:ok, _key} <- Support.api_key(options, configuration().default_api_key_env) do
        {:ok, "credentials configured; connectivity is checked on the first request"}
      end
    end
  end

  @impl true
  def routing_preflight(options) do
    if chatgpt?(options), do: :ok, else: healthcheck(options)
  end

  defp validate_model(model, models) do
    available =
      Enum.flat_map(models, fn
        %{"model" => name} when is_binary(name) -> [name]
        _other -> []
      end)

    if model in available,
      do: :ok,
      else: {:error, {:chatgpt_model_unavailable, model, available}}
  end

  defp provider_options(options) do
    options
    |> Keyword.put_new(:base_url, configuration().default_base_url)
    |> Keyword.put_new(:default_api_key_env, configuration().default_api_key_env)
  end

  defp invoke_chatgpt(messages, tools, options, emit) do
    case options[:provider_conversation] do
      pid when is_pid(pid) ->
        BeamAgent.CodexAppServer.Conversation.invoke(pid, messages, tools, options, emit)

      _other ->
        CodexAppServer.invoke(messages, tools, options, emit)
    end
  end

  defp chatgpt?(options) do
    case options[:auth] do
      %{"type" => "chatgpt"} -> true
      %{type: :chatgpt} -> true
      _ -> false
    end
  end
end
