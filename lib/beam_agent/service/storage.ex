defmodule BeamAgent.Service.Storage do
  @moduledoc "Owner-private service discovery and recovery metadata. Never migrates old session storage."
  import Bitwise

  def directory,
    do:
      System.get_env("LOOM_SERVICE_DIR") ||
        Path.join(System.user_home!(), ".local/share/loom/service")

  def path(name), do: Path.join(directory(), name)

  # A stable listener also prevents concurrent owners of this service directory.
  def port, do: 49152 + :erlang.phash2(Path.expand(directory()), 16384)

  def prepare do
    with :ok <- File.mkdir_p(directory()),
         {:ok, %{type: :directory, uid: uid}} <- File.lstat(directory()),
         {:ok, %{uid: ^uid}} <- File.stat(System.user_home!()),
         do: File.chmod(directory(), 0o700),
         else: (_ -> {:error, :unsafe_service_directory})
  end

  def read(name) do
    with {:ok, %{type: :directory, mode: mode, uid: uid}} <- File.lstat(directory()),
         true <- band(mode, 0o077) == 0,
         {:ok, %{uid: ^uid}} <- File.stat(System.user_home!()),
         {:ok, %{type: :regular, mode: mode, uid: ^uid, size: size}} <- File.lstat(path(name)),
         true <- band(mode, 0o077) == 0 and size <= 1_048_576,
         {:ok, bytes} <- File.read(path(name)),
         do: JSON.decode(bytes),
         else: (_ -> {:error, :service_record_unavailable})
  end

  def write(name, data) do
    with :ok <- prepare() do
      temp = path(name <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false))

      try do
        with {:ok, fd} <- File.open(temp, [:write, :exclusive, :binary]) do
          result =
            with :ok <- File.chmod(temp, 0o600),
                 :ok <- IO.binwrite(fd, JSON.encode!(data)),
                 do: :file.sync(fd)

          File.close(fd)
          with :ok <- result, do: File.rename(temp, path(name))
        end
      after
        File.rm(temp)
      end
    end
  end

  def lookup do
    with {:ok, %{"http_port" => port, "token" => token, "instance" => instance} = record} <-
           read("runtime.json"),
         true <-
           is_integer(port) and port in 1..65535 and is_binary(token) and byte_size(token) >= 32,
         {:ok, %{"instance" => ^instance} = status} <- request(record, :get, "/api/v1/service"),
         do: {:ok, Map.merge(record, status)},
         else: (_ -> {:error, :service_unavailable})
  end

  def request(record, method, path, body \\ nil),
    do: BeamAgent.LocalDiscovery.request(record, method, path, body)
end
