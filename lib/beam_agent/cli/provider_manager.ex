defmodule BeamAgent.CLI.ProviderManager do
  @moduledoc false
  alias BeamAgent.CLI.Config
  alias BeamAgent.{Providers, Runtime}
  @editable ~w(provider model base_url api_key_env)

  def snapshot(state) do
    with {:ok, stored} <- Config.load(state.config_path) do
      sources =
        case Runtime.model_catalog(state.runtime) do
          {:ok, catalog} -> Map.new(catalog.sources, &{&1.profile, &1})
          _ -> %{}
        end

      providers =
        Enum.map(Config.profiles(stored), fn {name, profile} ->
          profile
          |> Map.take(@editable)
          |> Map.merge(%{
            "profile" => name,
            "auth_mode" => auth_mode(profile),
            "has_credentials" => not is_nil(profile["credential_ref"]),
            "enabled" => Map.get(profile, "enabled", true),
            "discovery" => to_string(get_in(sources, [name, :status]) || :configured),
            "model_count" => get_in(sources, [name, :model_count]) || 0,
            "active" => name == state.config["profile"]
          })
        end)

      kinds =
        Enum.map(Providers.configurations(), fn {name, p} ->
          %{
            provider: name,
            model: p[:default_model],
            base_url: p[:default_base_url],
            api_key_env: p[:default_api_key_env]
          }
        end)
        |> Enum.sort_by(& &1.provider)

      {:ok,
       %{
         providers: providers,
         kinds: kinds,
         revision: revision(stored),
         active_profile: state.config["profile"],
         model: state.config["model"],
         model_strategy: state.config["model_strategy"],
         team_mode: state.config["team_mode"] || stored["team_mode"]
       }}
    end
  end

  def catalog(state, nil) do
    with {:ok, stored} <- Config.load(state.config_path),
         {:ok, catalog} <- Runtime.model_catalog(state.runtime) do
      models =
        Enum.map(catalog.models, fn endpoint ->
          %{
            "id" => endpoint.id,
            "profile" => endpoint.connection_id,
            "provider" => to_string(endpoint.provider),
            "model" => endpoint.model,
            "enabled" => endpoint.enabled,
            "health" => to_string(endpoint.health.status),
            "capabilities" => Enum.map(endpoint.claims.capabilities, &to_string/1),
            "selectable" =>
              :text_generation in endpoint.claims.capabilities or
                endpoint.claims.source in [:unknown, :provider],
            "capability_source" => to_string(endpoint.claims.source)
          }
        end)

      {:ok,
       %{
         models: models,
         sources: catalog.sources,
         refreshing: catalog.refreshing,
         revision: revision(stored),
         model_strategy: state.config["model_strategy"],
         active_profile: state.config["profile"],
         configured_model: state.config["model"],
         combined: true
       }}
    end
  end

  def catalog(state, name) do
    with {:ok, stored} <- Config.load(state.config_path),
         {:ok, profile} <- Config.runtime(stored, name) do
      case discover(profile, state.codex_app_server) do
        {:ok, models} ->
          {:ok,
           %{
             profile: name,
             models: models,
             revision: revision(stored),
             configured_model: profile["model"],
             discovery: "live"
           }}

        {:manual, reason} ->
          {:ok,
           %{
             profile: name,
             models: [],
             revision: revision(stored),
             configured_model: profile["model"],
             discovery: "manual",
             message: reason
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def mutate(state, request) do
    with {:ok, prepared} <- prepare(state, request), do: commit(state, prepared)
  end

  def prepare(state, request) do
    with :ok <- idle(state),
         {:ok, before} <- Config.load(state.config_path),
         :ok <- current_revision(before, request["revision"]),
         {:ok, next, runtime} <- change(before, state.config, request),
         :ok <- validate_selection(runtime, request, state.codex_app_server),
         {:ok, settings} <- BeamAgent.ProviderSettings.normalize(runtime) do
      {:ok, {before, next, runtime, settings}}
    end
  end

  def commit(state, {before, next, runtime, settings}) do
    :global.trans({{__MODULE__, Path.expand(state.config_path)}, self()}, fn ->
      with :ok <- idle(state),
           {:ok, latest} <- Config.load(state.config_path),
           :ok <- current_revision(latest, revision(before)),
           {:ok, _} <- write_if_changed(before, next, state.config_path) do
        endpoints = Config.model_endpoints(next, runtime)
        removed_ids = Map.keys(before["profiles"]) -- Map.keys(next["profiles"])

        case Runtime.configure_provider(state.runtime, settings, endpoints, removed_ids) do
          :ok ->
            {:ok, Map.put(runtime, "model_endpoints", endpoints)}

          {:error, reason} ->
            case Config.write(before, state.config_path) do
              {:ok, _} -> {:error, reason}
              {:error, rollback} -> {:error, {:settings_rollback_failed, reason, rollback}}
            end
        end
      end
    end)
  end

  defp write_if_changed(same, same, path), do: {:ok, path}
  defp write_if_changed(_before, next, path), do: Config.write(next, path)

  defp change(stored, current, %{"action" => "lock", "profile" => name, "model" => model}) do
    with {:ok, profile} <- fetch(stored, name),
         true <- Map.get(profile, "enabled", true),
         {:ok, runtime} <- Config.runtime(stored, name) do
      runtime =
        runtime
        |> Map.put("model", model)
        |> Map.put("model_strategy", "manual")
        |> Map.put("team_mode", current["team_mode"] || "auto")

      {:ok, stored, Map.merge(current, runtime)}
    else
      false -> {:error, :provider_disabled}
      error -> error
    end
  end

  defp change(stored, current, %{"action" => "automatic"}) do
    next = Map.put(stored, "model_strategy", "auto")
    {:ok, next, Map.put(current, "model_strategy", "auto")}
  end

  defp change(stored, current, %{"action" => "toggle", "profile" => name}) do
    with {:ok, profile} <- fetch(stored, name),
         true <- not (current["model_strategy"] == "manual" and current["profile"] == name) do
      profile = Map.put(profile, "enabled", not Map.get(profile, "enabled", true))
      {:ok, next} = Config.put_profile(stored, name, profile, force: true)
      {:ok, runtime} = runtime_after_edit(next, current, name)
      {:ok, next, runtime}
    else
      false -> {:error, :release_model_lock_before_disabling_provider}
      error -> error
    end
  end

  defp change(stored, current, %{"action" => "select", "profile" => name} = request) do
    with {:ok, profile} <- fetch(stored, name),
         true <- Map.get(profile, "enabled", true),
         mode when mode in ["manual", "auto", "local_only"] <- request["strategy"] || "manual",
         team when team in ["auto", "solo"] <-
           request["team_mode"] || stored["team_mode"] || "solo",
         {:ok, next} <-
           Config.put_profile(stored, name, Map.put(profile, "model", nullable(request["model"])),
             force: true
           ),
         {:ok, next} <- Config.use_profile(next, name),
         next <- Map.put(next, "model_strategy", mode),
         next <- Map.put(next, "team_mode", team),
         {:ok, runtime} <- Config.runtime(next, name) do
      {:ok, next, Map.merge(current, runtime)}
    else
      {:error, _} = e -> e
      _ -> {:error, :invalid_model_strategy}
    end
  end

  defp change(
         stored,
         current,
         %{"action" => "save", "profile" => name, "fields" => fields} = request
       )
       when is_map(fields) do
    previous = get_in(stored, ["profiles", name])
    editing? = request["editing"] == true

    with true <- editing? == is_map(previous),
         {:ok, profile} <- build_profile(previous, fields),
         {:ok, next} <- Config.put_profile(stored, name, profile, force: editing?),
         {:ok, runtime} <- runtime_after_edit(next, current, name) do
      {:ok, next, runtime}
    else
      false -> {:error, :profile_conflict}
      {:error, _} = e -> e
    end
  end

  defp change(stored, current, %{"action" => "delete", "profile" => name, "confirmed" => true}) do
    with {:ok, _} <- fetch(stored, name),
         true <- name not in [current["profile"], stored["active_profile"]] do
      next = update_in(stored, ["profiles"], &Map.delete(&1, name))
      {:ok, next, current}
    else
      false -> {:error, :cannot_remove_active_provider}
      {:error, _} = e -> e
    end
  end

  defp change(_, _, _), do: {:error, :invalid_settings_action}

  defp runtime_after_edit(next, current, name) do
    if current["profile"] == name do
      with {:ok, runtime} <- Config.runtime(next, name), do: {:ok, Map.merge(current, runtime)}
    else
      {:ok, current}
    end
  end

  defp build_profile(previous, fields) do
    previous = previous || %{}
    mode = fields["auth_mode"] || "environment"

    preserve? =
      previous["provider"] == fields["provider"] and
        previous["base_url"] == nullable(fields["base_url"]) and mode == auth_mode(previous)

    profile =
      Map.new(@editable, &{&1, nullable(fields[&1])})
      |> Map.put("enabled", Map.get(previous, "enabled", true))
      |> Map.put("credential_ref", if(preserve?, do: previous["credential_ref"]))
      |> Map.put(
        "auth",
        cond do
          mode == "chatgpt" and fields["provider"] == "openai" ->
            %{"type" => "chatgpt", "transport" => "codex_app_server"}

          mode == "saved" and preserve? ->
            previous["auth"]

          mode == "environment" ->
            if(fields["provider"] == "openai", do: %{"type" => "api_key"})

          true ->
            :invalid
        end
      )

    with true <- Map.keys(fields) -- (@editable ++ ["auth_mode"]) == [],
         true <- profile["auth"] != :invalid,
         true <- valid_env?(profile["api_key_env"]),
         true <- safe_url?(profile["base_url"]) do
      {:ok, profile}
    else
      _ -> {:error, :invalid_provider_fields}
    end
  end

  defp validate_selection(runtime, request, codex) do
    if request["action"] in ["select", "lock"] do
      with {:ok, provider} <- Providers.fetch(runtime["provider"]) do
        case discover(runtime, codex) do
          {:ok, models} ->
            if Enum.any?(models, &(model_id(&1) == runtime["model"])),
              do: :ok,
              else: {:error, {:model_not_in_catalogue, runtime["model"]}}

          {:manual, _} ->
            case provider.module.healthcheck(Config.provider_options(runtime)) do
              :ok -> :ok
              {:ok, _} -> :ok
              {:error, _} = e -> e
            end

          {:error, _} = e ->
            e
        end
      end
    else
      :ok
    end
  end

  defp discover(profile, codex) do
    {:ok, provider} = Providers.fetch(profile["provider"])

    {:ok, endpoint} =
      BeamAgent.ModelEndpoint.new(%{
        id: profile["profile"] || "catalogue",
        provider: provider.id,
        model: profile["model"],
        base_url: profile["base_url"],
        api_key_env: profile["api_key_env"],
        credential_ref: profile["credential_ref"],
        auth: profile["auth"]
      })

    case BeamAgent.ModelCatalog.discover(endpoint, codex_app_server: codex) do
      {:manual, _} -> {:manual, "No discovery adapter. Enter a model ID to lock this connection."}
      result -> result
    end
  end

  defp model_id(model), do: model["model"] || model["id"]

  defp fetch(stored, name) do
    case get_in(stored, ["profiles", name]) do
      p when is_map(p) -> {:ok, p}
      _ -> {:error, :unknown_provider_profile}
    end
  end

  defp auth_mode(%{"auth" => %{"type" => "chatgpt"}}), do: "chatgpt"
  defp auth_mode(%{"credential_ref" => ref}) when is_binary(ref), do: "saved"
  defp auth_mode(_), do: "environment"

  defp nullable(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp nullable(_), do: nil
  defp valid_env?(nil), do: true
  defp valid_env?(value), do: Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, value)
  defp safe_url?(nil), do: true

  defp safe_url?(value) do
    uri = URI.parse(value)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and is_nil(uri.userinfo) and
      is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp current_revision(config, revision) do
    if revision(config) == revision,
      do: :ok,
      else: {:error, :settings_changed_reload_before_saving}
  end

  defp revision(config),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(config)) |> Base.encode16(case: :lower)

  defp idle(state) do
    with {:ok, %{current_stage: nil}} <- BeamAgent.Goal.status(state.goal_id),
         {:ok, :idle} <- BeamAgent.Agent.status(state.session_id) do
      :ok
    else
      _ -> {:error, :goal_busy}
    end
  end
end
