defmodule BeamAgent.CLI.Config do
  @moduledoc false

  @version 1
  @providers ~w(demo echo)

  def path do
    System.get_env("BEAM_AGENT_CONFIG") ||
      Path.join([config_home(), "beam_agent", "config.json"])
  end

  def defaults do
    %{
      "version" => @version,
      "provider" => "demo",
      "data_dir" => Path.join([data_home(), "beam_agent", "sessions"]),
      "max_steps" => 8,
      "timeout_ms" => 30_000
    }
  end

  def supported_providers, do: @providers

  def load(config_path \\ path()) do
    with {:ok, contents} <- File.read(config_path),
         {:ok, config} <- decode(contents),
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
         :ok <- require_provider(config["provider"]),
         :ok <- require_directory(config["data_dir"]),
         :ok <- require_integer(config["max_steps"], "max_steps", 1, 100),
         :ok <- require_integer(config["timeout_ms"], "timeout_ms", 100, 3_600_000) do
      :ok
    end
  end

  def validate(_config), do: {:error, :invalid_config}

  def merge_overrides(config, opts) do
    config
    |> maybe_put("provider", opts[:provider])
    |> maybe_put("data_dir", opts[:data_dir] && Path.expand(opts[:data_dir]))
    |> maybe_put("max_steps", opts[:max_steps])
    |> maybe_put("timeout_ms", opts[:timeout])
  end

  def provider_atom("demo"), do: {:ok, :demo}
  def provider_atom("echo"), do: {:ok, :echo}
  def provider_atom(other), do: {:error, {:unsupported_provider, other}}

  defp decode(contents) do
    case JSON.decode(contents) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _other} -> {:error, :invalid_config}
      {:error, reason} -> {:error, {:invalid_config_json, reason}}
    end
  end

  defp require_version(@version), do: :ok
  defp require_version(other), do: {:error, {:unsupported_config_version, other}}

  defp require_provider(provider) when provider in @providers, do: :ok
  defp require_provider(provider), do: {:error, {:unsupported_provider, provider}}

  defp require_directory(path) when is_binary(path) and path != "", do: :ok
  defp require_directory(_path), do: {:error, {:invalid_config_value, "data_dir"}}

  defp require_integer(value, _name, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: :ok

  defp require_integer(_value, name, _min, _max),
    do: {:error, {:invalid_config_value, name}}

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Map.put(config, key, value)

  defp config_home do
    System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
  end

  defp data_home do
    System.get_env("XDG_DATA_HOME") || Path.join([System.user_home!(), ".local", "share"])
  end
end
