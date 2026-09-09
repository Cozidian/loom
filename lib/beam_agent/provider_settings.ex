defmodule BeamAgent.ProviderSettings do
  @moduledoc "Credential-reference-only model settings, persisted with the owning session."
  alias BeamAgent.Providers
  @fields ~w(provider profile model base_url api_key_env credential_ref auth model_strategy)

  def normalize(config) when is_map(config) do
    settings = Map.take(config, @fields)

    with {:ok, provider} <- Providers.fetch(settings["provider"]),
         true <- matches?(settings["profile"], ~r/\A[a-zA-Z0-9._-]{1,64}\z/),
         true <- settings["model_strategy"] in ["manual", "auto", "local_only"],
         true <-
           provider[:model_required] != true or
             (is_binary(settings["model"]) and settings["model"] != ""),
         true <- not Map.has_key?(config, "api_key"),
         true <- optional_match?(settings["api_key_env"], ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/),
         true <-
           optional_match?(
             settings["credential_ref"],
             ~r/\Akeychain:\/\/beam-agent\/[a-zA-Z0-9._-]{1,64}\z/
           ),
         true <- safe_url?(settings["base_url"]),
         true <- valid_auth?(settings["auth"]) do
      {:ok, settings}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_settings}
    end
  end

  def normalize(_), do: {:error, :invalid_provider_settings}

  defp matches?(value, regex), do: is_binary(value) and Regex.match?(regex, value)
  defp optional_match?(nil, _), do: true
  defp optional_match?(value, regex), do: matches?(value, regex)
  defp safe_url?(nil), do: true

  defp safe_url?(value) when is_binary(value) do
    uri = URI.parse(value)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp safe_url?(_), do: false
  defp valid_auth?(nil), do: true
  defp valid_auth?(%{"type" => "api_key"} = auth), do: map_size(auth) == 1

  defp valid_auth?(%{"type" => "chatgpt", "transport" => "codex_app_server"} = auth),
    do: map_size(auth) == 2

  defp valid_auth?(%{"type" => "device_code"} = auth) do
    Map.keys(auth) -- ~w(type device_endpoint token_endpoint client_id scope audience) == [] and
      is_binary(auth["device_endpoint"]) and safe_url?(auth["device_endpoint"]) and
      is_binary(auth["token_endpoint"]) and safe_url?(auth["token_endpoint"]) and
      is_binary(auth["client_id"])
  end

  defp valid_auth?(_), do: false

  def apply_to_state(state, settings) do
    {:ok, provider} = Providers.fetch(settings["provider"])

    options =
      Enum.flat_map(
        [
          model: "model",
          base_url: "base_url",
          api_key_env: "api_key_env",
          credential_ref: "credential_ref",
          auth: "auth",
          profile: "profile"
        ],
        fn {key, field} ->
          if is_nil(settings[field]), do: [], else: [{key, settings[field]}]
        end
      )

    requirements =
      state.agent_spec.model_requirements
      |> Map.drop([
        :preferred_endpoint_id,
        "preferred_endpoint_id",
        "locality",
        "privacy"
      ])
      |> Map.put(
        :locality,
        if(settings["model_strategy"] == "local_only", do: :local, else: :any)
      )
      |> Map.put(
        :privacy,
        if(settings["model_strategy"] == "local_only", do: :local, else: :provider_allowed)
      )

    %{
      state
      | provider: provider.id,
        provider_module: provider.module,
        provider_profile: settings["profile"],
        provider_options: options,
        model_strategy: strategy(settings["model_strategy"]),
        agent_spec: %{state.agent_spec | model_requirements: requirements}
    }
  end

  def restore(state, events) do
    Enum.reduce(events, state, fn
      %{"type" => "provider_settings_changed", "data" => settings}, acc ->
        case normalize(settings) do
          {:ok, settings} -> apply_to_state(acc, settings)
          _ -> acc
        end

      _, acc ->
        acc
    end)
  end

  defp strategy("manual"), do: :manual
  defp strategy("auto"), do: :auto
  defp strategy("local_only"), do: :local_only
end
