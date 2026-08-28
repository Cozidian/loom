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
      capabilities: [:text_generation, :tool_use, :streaming],
      modalities: [:text],
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
      CodexAppServer.invoke(messages, tools, options)
    else
      options
      |> provider_options()
      |> then(&OpenAICompatible.complete(messages, tools, &1))
    end
  end

  @impl true
  def stream(messages, tools, options, emit) do
    if chatgpt?(options) do
      CodexAppServer.invoke(messages, tools, options, emit)
    else
      options
      |> provider_options()
      |> then(&OpenAICompatible.stream(messages, tools, &1, emit))
    end
  end

  @impl true
  def healthcheck(options) do
    if chatgpt?(options) do
      with {:ok, _model} <- Support.require_option(options, :model),
           {:ok, %{"account" => %{"type" => "chatgpt"} = account}} <-
             CodexAppServer.account(options) do
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

  defp provider_options(options) do
    options
    |> Keyword.put_new(:base_url, configuration().default_base_url)
    |> Keyword.put_new(:default_api_key_env, configuration().default_api_key_env)
  end

  defp chatgpt?(options) do
    case options[:auth] do
      %{"type" => "chatgpt"} -> true
      %{type: :chatgpt} -> true
      _ -> false
    end
  end
end
