defmodule BeamAgent.Providers do
  @moduledoc "Authoritative catalog of providers shipped with BeamAgent."

  @modules [
    BeamAgent.Providers.Demo,
    BeamAgent.Providers.Echo,
    BeamAgent.Providers.Ollama,
    BeamAgent.Providers.OpenAI,
    BeamAgent.Providers.Anthropic,
    BeamAgent.Providers.XAI
  ]

  def modules, do: @modules

  def configurations do
    Map.new(@modules, fn module ->
      config = module.configuration()
      {config.name, Map.merge(config, %{id: module.id(), module: module})}
    end)
  end

  def names, do: configurations() |> Map.keys() |> Enum.sort()

  def fetch("grok"), do: fetch("xai")

  def fetch(name) when is_binary(name) do
    case Map.fetch(configurations(), name) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, {:unsupported_provider, name}}
    end
  end

  def fetch(id) when is_atom(id) do
    case Enum.find(@modules, &(&1.id() == id)) do
      nil -> {:error, {:unsupported_provider, id}}
      module -> {:ok, Map.merge(module.configuration(), %{id: id, module: module})}
    end
  end
end
