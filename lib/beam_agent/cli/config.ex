defmodule BeamAgent.CLI.Config do
  @moduledoc false

  alias BeamAgent.Providers

  @version 10
  @profile_keys ["provider", "model", "base_url", "api_key_env", "credential_ref", "auth"]
  @global_keys [
    "approval_policy",
    "model_strategy",
    "team_mode",
    "data_dir",
    "context_window_tokens",
    "compaction_threshold_percent"
  ]

  def path do
    System.get_env("BEAM_AGENT_CONFIG") ||
      Path.join([config_home(), "beam_agent", "config.json"])
  end

  def defaults do
    %{
      "version" => @version,
      "active_profile" => "demo",
      "profiles" => %{
        "demo" => %{
          "provider" => "demo",
          "model" => nil,
          "base_url" => nil,
          "api_key_env" => nil,
          "credential_ref" => nil,
          "auth" => nil
        }
      },
      "approval_policy" => "ask",
      "model_strategy" => "auto",
      "team_mode" => "auto",
      "data_dir" => Path.join([data_home(), "beam_agent", "sessions"]),
      "context_window_tokens" => 32_000,
      "compaction_threshold_percent" => 75
    }
  end

  def supported_providers, do: Providers.names()

  def load(config_path \\ path()) do
    with {:ok, contents} <- File.read(config_path),
         {:ok, config} <- decode(contents),
         {:ok, config} <- migrate(config),
         :ok <- validate(config) do
      {:ok, config}
    else
      {:error, :enoent} -> {:error, {:not_initialized, config_path}}
      {:error, reason} -> {:error, reason}
    end
  end

  def write(config, config_path \\ path()) do
    config = Map.put(config, "version", @version)
    suffix = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    temporary = config_path <> ".#{suffix}.tmp"

    with :ok <- validate(config),
         {:ok, encoded} <- encode_config(config),
         :ok <- File.mkdir_p(Path.dirname(config_path)),
         :ok <- File.mkdir_p(config["data_dir"]),
         :ok <- File.write(temporary, [encoded, "\n"], [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, config_path) do
      {:ok, config_path}
    else
      {:error, reason} = error ->
        _ = File.rm(temporary)
        if reason == :eexist, do: write(config, config_path), else: error
    end
  end

  def new(profile_name, profile, globals) do
    config =
      globals
      |> Map.take(@global_keys)
      |> Map.merge(%{
        "version" => @version,
        "active_profile" => profile_name,
        "profiles" => %{profile_name => profile}
      })

    with :ok <- validate(config), do: {:ok, config}
  end

  def runtime(config, selected_profile \\ nil) do
    profile_name = selected_profile || config["active_profile"]

    with :ok <- validate_profile_name(profile_name),
         {:ok, profile} <- fetch_profile(config, profile_name) do
      runtime =
        config
        |> Map.take(@global_keys)
        |> Map.merge(profile)
        |> Map.put("version", @version)
        |> Map.put("profile", profile_name)
        |> Map.put(
          "team_mode",
          config["team_mode"] || if(config["model_strategy"] == "auto", do: "auto", else: "solo")
        )

      with :ok <- validate_runtime(runtime), do: {:ok, runtime}
    end
  end

  def put_profile(config, name, profile, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    with :ok <- validate_profile_name(name),
         :ok <- validate_profile(profile),
         :ok <- ensure_profile_available(config, name, force?) do
      next = put_in(config, ["profiles", name], profile)

      next =
        if Keyword.get(opts, :activate, false),
          do: Map.put(next, "active_profile", name),
          else: next

      {:ok, next}
    end
  end

  def use_profile(config, name) do
    with :ok <- validate_profile_name(name),
         {:ok, _profile} <- fetch_profile(config, name) do
      {:ok, Map.put(config, "active_profile", name)}
    end
  end

  def put_profile_auth(config, name, credential_ref, auth) do
    with :ok <- validate_profile_name(name),
         {:ok, profile} <- fetch_profile(config, name),
         :ok <- validate_credential_ref(credential_ref),
         :ok <- validate_auth(auth) do
      profile =
        profile
        |> Map.put("credential_ref", credential_ref)
        |> Map.put("auth", auth)

      {:ok, put_in(config, ["profiles", name], profile)}
    end
  end

  def clear_profile_credential(config, name) do
    with :ok <- validate_profile_name(name),
         {:ok, profile} <- fetch_profile(config, name) do
      profile = Map.put(profile, "credential_ref", nil)
      {:ok, put_in(config, ["profiles", name], profile)}
    end
  end

  def clear_profile_auth(config, name) do
    with :ok <- validate_profile_name(name),
         {:ok, profile} <- fetch_profile(config, name) do
      profile =
        profile
        |> Map.put("credential_ref", nil)
        |> Map.put("auth", nil)

      {:ok, put_in(config, ["profiles", name], profile)}
    end
  end

  def profiles(config), do: config["profiles"] |> Enum.sort_by(fn {name, _profile} -> name end)

  def model_endpoints(config, runtime \\ nil) do
    endpoints =
      config
      |> profiles()
      |> Enum.map(fn {name, profile} -> endpoint_spec(name, profile) end)

    case runtime do
      %{"profile" => name} = runtime ->
        replacement = endpoint_spec(name, runtime)
        [replacement | Enum.reject(endpoints, &(&1.id == name))]

      _runtime ->
        endpoints
    end
  end

  def validate(config) when is_map(config) do
    with :ok <- require_version(config["version"]),
         :ok <- validate_profile_name(config["active_profile"]),
         :ok <- validate_profiles(config["profiles"]),
         {:ok, _active} <- fetch_profile(config, config["active_profile"]),
         :ok <- validate_globals(config) do
      :ok
    end
  end

  def validate(_config), do: {:error, :invalid_config}

  def validate_runtime(config) when is_map(config) do
    with :ok <- validate_profile(Map.take(config, @profile_keys)),
         :ok <- validate_globals(config) do
      :ok
    end
  end

  def validate_runtime(_config), do: {:error, :invalid_config}

  def merge_overrides(config, opts) do
    config = maybe_reset_provider_defaults(config, opts[:provider])

    config
    |> maybe_put("provider", opts[:provider])
    |> maybe_put("model", opts[:model])
    |> maybe_put("base_url", opts[:base_url])
    |> maybe_put("api_key_env", opts[:api_key_env])
    |> maybe_put("approval_policy", opts[:approval])
    |> maybe_put("model_strategy", opts[:model_strategy])
    |> maybe_put("team_mode", opts[:team_mode])
    |> maybe_put("data_dir", opts[:data_dir] && Path.expand(opts[:data_dir]))
    |> maybe_put("context_window_tokens", opts[:context_window])
    |> maybe_put("compaction_threshold_percent", opts[:compact_at])
  end

  def provider_atom(name) do
    with {:ok, provider} <- Providers.fetch(name), do: {:ok, provider.id}
  end

  def approval_policy_atom(policy) when policy in ["auto", "allow"], do: :auto
  def approval_policy_atom("ask"), do: :ask
  def approval_policy_atom("deny"), do: :deny

  def model_strategy_atom("auto"), do: :auto
  def model_strategy_atom("manual"), do: :manual
  def model_strategy_atom("local_only"), do: :local_only

  def team_mode_atom("auto"), do: :auto
  def team_mode_atom("solo"), do: :solo
  def team_mode_atom(_), do: nil

  def provider_options(config) do
    [
      model: config["model"],
      base_url: config["base_url"],
      api_key_env: config["api_key_env"],
      credential_ref: config["credential_ref"],
      auth: config["auth"],
      profile: config["profile"]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  def profile(provider_name, model, base_url, api_key_env) do
    profile = %{
      "provider" => provider_name,
      "model" => model,
      "base_url" => base_url,
      "api_key_env" => api_key_env,
      "credential_ref" => nil,
      "auth" => nil
    }

    with :ok <- validate_profile(profile), do: {:ok, profile}
  end

  defp decode(contents) do
    case JSON.decode(contents) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _other} -> {:error, :invalid_config}
      {:error, reason} -> {:error, {:invalid_config_json, reason}}
    end
  end

  defp encode_config(config) do
    {:ok, JSON.encode!(config)}
  rescue
    error -> {:error, {:config_write_failed, Exception.message(error)}}
  end

  defp migrate(%{"version" => version} = config) when version in [1, 2] do
    with {:ok, provider} <- Providers.fetch(config["provider"]) do
      config
      |> Map.put_new("model", provider[:default_model])
      |> Map.put_new("base_url", provider[:default_base_url])
      |> Map.put_new("api_key_env", provider[:default_api_key_env])
      |> Map.put_new("approval_policy", "ask")
      |> Map.put("version", 3)
      |> migrate()
    end
  end

  defp migrate(%{"version" => 3} = config) do
    profile_name = legacy_profile_name(config["provider"])

    config
    |> Map.take(@global_keys)
    |> Map.merge(%{
      "version" => 4,
      "active_profile" => profile_name,
      "profiles" => %{profile_name => Map.take(config, @profile_keys)}
    })
    |> migrate()
  end

  defp migrate(%{"version" => 4} = config) do
    defaults = defaults()

    config
    |> Map.put("version", 5)
    |> Map.put_new("context_window_tokens", defaults["context_window_tokens"])
    |> Map.put_new(
      "compaction_threshold_percent",
      defaults["compaction_threshold_percent"]
    )
    |> migrate()
  end

  defp migrate(%{"version" => 5} = config) do
    config |> Map.put("version", 6) |> Map.delete("max_steps") |> migrate()
  end

  defp migrate(%{"version" => 6} = config) do
    config |> Map.put("version", 7) |> Map.delete("timeout_ms") |> migrate()
  end

  defp migrate(%{"version" => 7} = config) do
    config |> Map.put("version", 8) |> Map.put_new("model_strategy", "auto") |> migrate()
  end

  defp migrate(%{"version" => 8} = config) do
    profiles =
      Map.new(config["profiles"] || %{}, fn {name, profile} ->
        {name,
         profile
         |> Map.put_new("credential_ref", nil)
         |> Map.put_new("auth", nil)}
      end)

    config |> Map.put("version", 9) |> Map.put("profiles", profiles) |> migrate()
  end

  defp migrate(%{"version" => 9} = config) do
    # Preserve legacy spending/parallelism until the user explicitly opts in.
    mode = if config["model_strategy"] == "auto", do: "auto", else: "solo"
    {:ok, config |> Map.put("version", @version) |> Map.put_new("team_mode", mode)}
  end

  defp migrate(config), do: {:ok, config}

  defp legacy_profile_name("grok"), do: "grok"
  defp legacy_profile_name(provider) when is_binary(provider) and provider != "", do: provider
  defp legacy_profile_name(_provider), do: "default"

  defp validate_profiles(profiles) when is_map(profiles) and map_size(profiles) > 0 do
    Enum.reduce_while(profiles, :ok, fn {name, profile}, :ok ->
      with :ok <- validate_profile_name(name),
           :ok <- validate_profile(profile) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_profiles(_profiles), do: {:error, {:invalid_config_value, "profiles"}}

  defp validate_profile(profile) when is_map(profile) do
    with {:ok, provider} <- Providers.fetch(profile["provider"]),
         :ok <- require_when(provider[:model_required], profile["model"], "model"),
         :ok <- require_when(provider[:default_base_url] != nil, profile["base_url"], "base_url"),
         :ok <- require_credential_when(provider[:default_api_key_env] != nil, profile),
         :ok <- validate_credential_ref(profile["credential_ref"]),
         :ok <- validate_auth(profile["auth"]),
         :ok <- validate_url(profile["base_url"]) do
      :ok
    end
  end

  defp validate_profile(_profile), do: {:error, {:invalid_config_value, "profile"}}

  defp validate_globals(config) do
    with :ok <- require_directory(config["data_dir"]),
         :ok <-
           require_integer(
             config["context_window_tokens"],
             "context_window_tokens",
             1_024,
             2_000_000
           ),
         :ok <-
           require_integer(
             config["compaction_threshold_percent"],
             "compaction_threshold_percent",
             50,
             95
           ),
         :ok <- validate_approval_policy(config["approval_policy"]),
         :ok <- validate_model_strategy(config["model_strategy"]),
         :ok <- validate_team_mode(config["team_mode"]) do
      :ok
    end
  end

  defp validate_profile_name(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/, name),
      do: :ok,
      else: {:error, {:invalid_profile_name, name}}
  end

  defp validate_profile_name(name), do: {:error, {:invalid_profile_name, name}}

  defp fetch_profile(config, name) do
    case get_in(config, ["profiles", name]) do
      profile when is_map(profile) -> {:ok, profile}
      _ -> {:error, {:unknown_profile, name}}
    end
  end

  defp ensure_profile_available(config, name, false) do
    if Map.has_key?(config["profiles"], name),
      do: {:error, {:profile_exists, name}},
      else: :ok
  end

  defp ensure_profile_available(_config, _name, true), do: :ok

  defp require_version(@version), do: :ok
  defp require_version(other), do: {:error, {:unsupported_config_version, other}}

  defp require_directory(path) when is_binary(path) and path != "", do: :ok
  defp require_directory(_path), do: {:error, {:invalid_config_value, "data_dir"}}

  defp require_integer(value, _name, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: :ok

  defp require_integer(_value, name, _min, _max),
    do: {:error, {:invalid_config_value, name}}

  defp require_when(true, value, name) when not is_binary(value) or value == "",
    do: {:error, {:invalid_config_value, name}}

  defp require_when(_required, _value, _name), do: :ok

  defp require_credential_when(false, _profile), do: :ok

  defp require_credential_when(true, profile) do
    if present?(profile["api_key_env"]) or present?(profile["credential_ref"]),
      do: :ok,
      else: {:error, {:invalid_config_value, "credential"}}
  end

  defp validate_credential_ref(nil), do: :ok

  defp validate_credential_ref(reference) when is_binary(reference) do
    if Regex.match?(~r/\Akeychain:\/\/beam-agent\/[a-zA-Z0-9._-]{1,64}\z/, reference),
      do: :ok,
      else: {:error, {:invalid_config_value, "credential_ref"}}
  end

  defp validate_credential_ref(_reference),
    do: {:error, {:invalid_config_value, "credential_ref"}}

  defp validate_auth(nil), do: :ok
  defp validate_auth(%{"type" => "api_key"}), do: :ok
  defp validate_auth(%{"type" => "chatgpt", "transport" => "codex_app_server"}), do: :ok

  defp validate_auth(%{"type" => "device_code"} = auth) do
    with :ok <- require_when(true, auth["device_endpoint"], "auth.device_endpoint"),
         :ok <- require_when(true, auth["token_endpoint"], "auth.token_endpoint"),
         :ok <- validate_auth_url(auth["device_endpoint"], "auth.device_endpoint"),
         :ok <- validate_auth_url(auth["token_endpoint"], "auth.token_endpoint"),
         :ok <- require_when(true, auth["client_id"], "auth.client_id") do
      :ok
    end
  end

  defp validate_auth(_auth), do: {:error, {:invalid_config_value, "auth"}}

  defp present?(value), do: is_binary(value) and value != ""

  defp validate_auth_url(url, name) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) -> :ok
      %URI{scheme: "http", host: host} when host in ["127.0.0.1", "localhost", "::1"] -> :ok
      _ -> {:error, {:invalid_config_value, name}}
    end
  end

  defp validate_auth_url(_url, name), do: {:error, {:invalid_config_value, name}}

  defp validate_url(nil), do: :ok

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> :ok
      _ -> {:error, {:invalid_config_value, "base_url"}}
    end
  end

  defp validate_url(_url), do: {:error, {:invalid_config_value, "base_url"}}

  defp validate_approval_policy(policy) when policy in ["auto", "ask", "allow", "deny"],
    do: :ok

  defp validate_approval_policy(_policy), do: {:error, {:invalid_config_value, "approval_policy"}}

  defp validate_model_strategy(strategy) when strategy in ["auto", "manual", "local_only"],
    do: :ok

  defp validate_model_strategy(_strategy),
    do: {:error, {:invalid_config_value, "model_strategy"}}

  defp validate_team_mode(mode) when mode in [nil, "auto", "solo"], do: :ok
  defp validate_team_mode(_), do: {:error, {:invalid_config_value, "team_mode"}}

  defp maybe_reset_provider_defaults(config, nil), do: config

  defp maybe_reset_provider_defaults(config, provider_name) do
    if provider_name == config["provider"] do
      config
    else
      case Providers.fetch(provider_name) do
        {:ok, provider} ->
          config
          |> Map.put("model", provider[:default_model])
          |> Map.put("base_url", provider[:default_base_url])
          |> Map.put("api_key_env", provider[:default_api_key_env])

        {:error, _reason} ->
          config
      end
    end
  end

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Map.put(config, key, value)

  defp endpoint_spec(name, profile) do
    {:ok, provider} = Providers.fetch(profile["provider"])

    %{
      id: name,
      provider: provider.id,
      provider_module: provider.module,
      model: profile["model"],
      base_url: profile["base_url"],
      api_key_env: profile["api_key_env"],
      credential_ref: profile["credential_ref"],
      auth: profile["auth"],
      claims: profile["claims"]
    }
  end

  defp config_home do
    System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
  end

  defp data_home do
    System.get_env("XDG_DATA_HOME") || Path.join([System.user_home!(), ".local", "share"])
  end
end
