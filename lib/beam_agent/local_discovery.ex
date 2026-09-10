defmodule BeamAgent.LocalDiscovery do
  @moduledoc "Owner-private discovery of authenticated loopback runtimes. Descriptors are hints; identity is checked live before use."
  import Bitwise

  def directory,
    do:
      Application.get_env(
        :beam_agent,
        :discovery_dir,
        Path.join(System.user_home!(), ".local/share/beam_agent/live")
      )

  def valid_id?(id), do: is_binary(id) and Regex.match?(~r/\Asession-[A-Za-z0-9_-]{1,100}\z/, id)

  def publish(record, dir \\ directory()) do
    with true <- valid_id?(record["session_id"]),
         :ok <- private_directory(dir),
         path = Path.join(dir, record["session_id"] <> ".json"),
         false <- File.exists?(path),
         {:ok, file} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600),
             :ok <- IO.binwrite(file, JSON.encode!(record)),
             :ok <- :file.sync(file),
             do: {:ok, path}
      after
        File.close(file)
      end
    else
      true -> {:error, :runtime_already_registered}
      false -> {:error, :invalid_session_id}
      error -> error
    end
  end

  def lookup(id, dir \\ directory()) do
    with true <- valid_id?(id),
         :ok <- check_directory(dir),
         path = Path.join(dir, id <> ".json"),
         {:ok, %{type: :regular, size: size, mode: mode, uid: uid}} <- File.lstat(path),
         true <- size <= 8192 and band(mode, 0o077) == 0 and uid == owner_uid(),
         {:ok, bytes} <- File.read(path),
         {:ok,
          %{"session_id" => ^id, "token" => token, "http_port" => port, "tui_port" => tui} =
            record} <- JSON.decode(bytes),
         true <-
           is_binary(token) and byte_size(token) >= 32 and port in 1..65535 and tui in 1..65535,
         {:ok, %{"session_id" => ^id}} <- request(record, :get, "/api/v1/identity") do
      {:ok, record}
    else
      _ -> {:error, :runtime_unavailable}
    end
  end

  def list(dir \\ directory()) do
    with :ok <- check_directory(dir), {:ok, names} <- File.ls(dir) do
      entries =
        names |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort() |> Enum.take(200)

      sessions =
        entries
        |> Task.async_stream(fn name -> lookup(String.trim_trailing(name, ".json"), dir) end,
          max_concurrency: 8,
          timeout: 3000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, {:ok, record}} ->
            [Map.take(record, ["session_id", "workspace", "started_at", "owner_pid"])]

          _ ->
            []
        end)

      {:ok, %{sessions: sessions, limit: 200}}
    else
      {:error, :enoent} -> {:ok, %{sessions: [], limit: 200}}
      _ -> {:error, :discovery_unavailable}
    end
  end

  def request(record, method, path, body \\ nil) do
    :inets.start()
    url = String.to_charlist("http://127.0.0.1:#{record["http_port"]}#{path}")
    headers = [{~c"authorization", String.to_charlist("Bearer " <> record["token"])}]

    req =
      if method == :get,
        do: {url, headers},
        else: {url, headers, ~c"application/json", JSON.encode!(body)}

    timeout = if path == "/api/v1/identity", do: 700, else: 8_000

    case :httpc.request(
           method,
           req,
           [timeout: timeout, connect_timeout: 500, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, bytes}} ->
        case JSON.decode(bytes) do
          {:ok, %{"ok" => true, "result" => result}} -> {:ok, result}
          {:ok, %{"ok" => false, "error" => error}} -> {:error, error}
          _ -> {:error, :invalid_runtime_response}
        end

      _ ->
        {:error, :runtime_unavailable}
    end
  end

  def remove(path, token) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"token" => ^token}} <- JSON.decode(bytes),
         do: File.rm(path)
  end

  defp private_directory(dir) do
    case File.lstat(dir) do
      {:error, :enoent} ->
        with :ok <- File.mkdir_p(dir), :ok <- File.chmod(dir, 0o700), do: check_directory(dir)

      _ ->
        check_directory(dir)
    end
  end

  defp check_directory(dir) do
    with {:ok, %{type: :directory, mode: mode, uid: uid}} <- File.lstat(dir),
         true <- band(mode, 0o077) == 0 and uid == owner_uid(),
         do: :ok
  end

  defp owner_uid do
    {:ok, stat} = File.stat(System.user_home!())
    stat.uid
  end
end
