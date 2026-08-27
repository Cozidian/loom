defmodule BeamAgent.ModelEndpoint do
  @moduledoc """
  A configured model endpoint separated from its provider transport module.

  Endpoint descriptors contain credential references, never credential values.
  Configured claims and runtime measurements are deliberately separate so a
  future router can distinguish declared capability from observed performance.
  """

  alias BeamAgent.CapabilityCatalog

  @enforce_keys [:id, :provider, :provider_module]
  defstruct [
    :id,
    :provider,
    :provider_module,
    :model,
    :transport,
    :credential,
    :claims,
    :measurements,
    :health
  ]

  @type t :: %__MODULE__{}

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(spec) when is_list(spec), do: spec |> Map.new() |> new()

  def new(spec) when is_map(spec) do
    id = value(spec, :id)
    provider = value(spec, :provider)

    with :ok <- validate_id(id),
         {:ok, provider, module} <- provider_module(provider, value(spec, :provider_module)) do
      configuration = configuration(module, provider)

      {:ok,
       %__MODULE__{
         id: id,
         provider: provider,
         provider_module: module,
         model: value(spec, :model) || Map.get(configuration, :default_model),
         transport: transport(spec, configuration),
         credential: credential(spec, configuration),
         claims: claims(configuration, value(spec, :claims)),
         measurements: value(spec, :measurements) || %{},
         health: value(spec, :health) || initial_health()
       }}
    end
  end

  def new(_spec), do: {:error, :invalid_model_endpoint}

  def health_options(%__MODULE__{} = endpoint) do
    [
      model: endpoint.model,
      base_url: endpoint.transport.base_url,
      api_key_env: credential_environment(endpoint.credential),
      profile: endpoint.id
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  def same_configuration?(%__MODULE__{} = left, %__MODULE__{} = right) do
    Map.take(left, [:provider, :provider_module, :model, :transport, :credential, :claims]) ==
      Map.take(right, [:provider, :provider_module, :model, :transport, :credential, :claims])
  end

  defp provider_module(provider, module)
       when is_atom(provider) and is_atom(module) and not is_nil(module),
       do: {:ok, provider, module}

  defp provider_module(provider, nil) when is_atom(provider) do
    with {:ok, module} <- CapabilityCatalog.provider(provider), do: {:ok, provider, module}
  end

  defp provider_module(_provider, _module), do: {:error, :invalid_model_provider}

  defp configuration(module, provider) do
    if Code.ensure_loaded?(module) and function_exported?(module, :configuration, 0) do
      module.configuration()
    else
      %{name: Atom.to_string(provider), label: "Custom provider"}
    end
  end

  defp claims(configuration, overrides) do
    defaults = %{
      capabilities: Map.get(configuration, :capabilities, [:text_generation]),
      modalities: Map.get(configuration, :modalities, [:text]),
      context_window_tokens: Map.get(configuration, :context_window_tokens),
      cost_hint: Map.get(configuration, :cost_hint, :unknown),
      locality: Map.get(configuration, :locality, :remote),
      privacy: Map.get(configuration, :privacy, :provider),
      source: :provider
    }

    overrides = normalize_claims(overrides)
    Map.merge(defaults, overrides)
  end

  defp normalize_claims(nil), do: %{}
  defp normalize_claims(claims) when is_map(claims), do: claims
  defp normalize_claims(_claims), do: %{}

  defp transport(spec, configuration) do
    %{
      base_url: value(spec, :base_url) || Map.get(configuration, :default_base_url)
    }
  end

  defp credential(spec, configuration) do
    case value(spec, :api_key_env) || Map.get(configuration, :default_api_key_env) do
      name when is_binary(name) and name != "" -> %{type: :environment, name: name}
      _missing -> %{type: :none}
    end
  end

  defp credential_environment(%{type: :environment, name: name}), do: name
  defp credential_environment(_credential), do: nil

  defp initial_health do
    %{status: :unknown, checked_at: nil}
  end

  defp validate_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/, id),
      do: :ok,
      else: {:error, {:invalid_model_endpoint_id, id}}
  end

  defp validate_id(id), do: {:error, {:invalid_model_endpoint_id, id}}

  defp value(map, key), do: map[key] || map[to_string(key)]
end
