defmodule BeamAgent.Providers.OpenAI do
  @moduledoc "OpenAI Chat Completions provider with client-side function tools."
  @behaviour BeamAgent.LLMProvider

  alias BeamAgent.Providers.{OpenAICompatible, Support}

  @impl true
  def id, do: :openai

  @impl true
  def configuration do
    %{
      name: "openai",
      label: "OpenAI",
      model_required: true,
      default_base_url: "https://api.openai.com/v1",
      default_api_key_env: "OPENAI_API_KEY"
    }
  end

  @impl true
  def complete(messages, tools, options) do
    options =
      options
      |> Keyword.put_new(:base_url, configuration().default_base_url)
      |> Keyword.put_new(:default_api_key_env, configuration().default_api_key_env)

    OpenAICompatible.complete(messages, tools, options)
  end

  @impl true
  def healthcheck(options) do
    options = Keyword.put_new(options, :base_url, configuration().default_base_url)

    with {:ok, _model} <- Support.require_option(options, :model),
         {:ok, _base_url} <- Support.require_option(options, :base_url),
         {:ok, _key} <- Support.api_key(options, configuration().default_api_key_env) do
      {:ok, "credentials configured; connectivity is checked on the first request"}
    end
  end
end
