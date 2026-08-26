defmodule BeamAgent.CLI.Config do
  @moduledoc false

  alias BeamAgent.Providers

  @version 3

  def path do
    System.get_env("BEAM_AGENT_CONFIG") ||
      Path.join([config_home(), "beam_agent", "config.json"])
  end

  def defaults do
    %{
      "version" => @version,
      "provider" => "demo",
      "model" => nil,
      "base_url" => nil,
      "api_key_env" => nil,
      "approval_policy" => "ask",
      "data_dir" => Path.join([data_home(), "beam_agent", "sessions"]),
      "max_steps" => 8,
      "timeout_ms" => 30_000
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

    with :ok <- validate(config),
         :ok <- File.mkdir_p(Path.dirname(config_path)),
         :ok <- File.mkdir_p(config["data_dir"]),
         :ok <- File.write(config_path, [JSON.encode!(config), "\n"]),
         :ok <- File.chmod(config_path, 0o600) do
      {:ok, config_path}
    end
  rescue
    error -> {:error, {:config_write_failed, Exception.message(error)}}
  end

  def validate(config) when is_map(config) do
    with :ok <- require_version(config["version"]),
         {:ok, provider} <- Providers.fetch(config["provider"]),
         :ok <- require_directory(config["data_dir"]),
         :ok <- require_integer(config["max_steps"], "max_steps", 1, 100),
         :ok <- require_integer(config["timeout_ms"], "timeout_ms", 100, 3_600_000),
         :ok <- validate_provider_options(config, provider) do
      :ok
    end
  end

  def validate(_config), do: {:error, :invalid_config}

  def merge_overrides(config, opts) do
    config
    |> maybe_put("provider", opts[:provider])
    |> maybe_put("model", opts[:model])
    |> maybe_put("base_url", opts[:base_url])
    |> maybe_put("api_key_env", opts[:api_key_env])
    |> maybe_put("approval_policy", opts[:approval])
    |> maybe_put("data_dir", opts[:data_dir] && Path.expand(opts[:data_dir]))
    |> maybe_put("max_steps", opts[:max_steps])
    |> maybe_put("timeout_ms", opts[:timeout])
  end

  def provider_atom(name) do
    with {:ok, provider} <- Providers.fetch(name), do: {:ok, provider.id}
  end

  def provider_options(config) do
    [
      model: config["model"],
      base_url: config["base_url"],
      api_key_env: config["api_key_env"],
      timeout_ms: config["timeout_ms"]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp decode(contents) do
    case JSON.decode(contents) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _other} -> {:error, :invalid_config}
      {:error, reason} -> {:error, {:invalid_config_json, reason}}
    end
  end

  defp migrate(%{"version" => version} = config) when version in [1, 2] do
    with {:ok, provider} <- Providers.fetch(config["provider"]) do
      {:ok,
       config
       |> Map.put("version", @version)
       |> Map.put_new("model", provider[:default_model])
       |> Map.put_new("base_url", provider[:default_base_url])
       |> Map.put_new("api_key_env", provider[:default_api_key_env])
       |> Map.put_new("approval_policy", "ask")}
    end
  end

  defp migrate(config), do: {:ok, config}

  defp require_version(@version), do: :ok
  defp require_version(other), do: {:error, {:unsupported_config_version, other}}

  defp require_directory(path) when is_binary(path) and path != "", do: :ok
  defp require_directory(_path), do: {:error, {:invalid_config_value, "data_dir"}}

  defp require_integer(value, _name, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: :ok

  defp require_integer(_value, name, _min, _max),
    do: {:error, {:invalid_config_value, name}}

  defp validate_provider_options(config, provider) do
    with :ok <- require_when(provider[:model_required], config["model"], "model"),
         :ok <- require_when(provider[:default_base_url] != nil, config["base_url"], "base_url"),
         :ok <-
           require_when(
             provider[:default_api_key_env] != nil,
             config["api_key_env"],
             "api_key_env"
           ),
         :ok <- validate_url(config["base_url"]),
         :ok <- validate_approval_policy(config["approval_policy"]) do
      :ok
    end
  end

  defp require_when(true, value, name) when not is_binary(value) or value == "",
    do: {:error, {:invalid_config_value, name}}

  defp require_when(_required, _value, _name), do: :ok

  defp validate_url(nil), do: :ok

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> :ok
      _ -> {:error, {:invalid_config_value, "base_url"}}
    end
  end

  defp validate_url(_url), do: {:error, {:invalid_config_value, "base_url"}}

  defp validate_approval_policy(policy) when policy in ["ask", "allow", "deny"], do: :ok
  defp validate_approval_policy(_policy), do: {:error, {:invalid_config_value, "approval_policy"}}

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Map.put(config, key, value)

  defp config_home do
    System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
  end

  defp data_home do
    System.get_env("XDG_DATA_HOME") || Path.join([System.user_home!(), ".local", "share"])
  end
end
