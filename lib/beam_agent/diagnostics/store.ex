defmodule BeamAgent.Diagnostics.Store do
  @moduledoc false
  @max_bytes 2 * 1_024 * 1_024
  @retained 5

  def prepare(directory) do
    with :ok <- File.mkdir_p(directory),
         {:ok, %{type: :directory, uid: uid}} <- File.lstat(directory),
         {:ok, %{uid: ^uid}} <- File.stat(System.user_home!()),
         :ok <- File.chmod(directory, 0o700),
         :ok <- remove_stale_temps(directory),
         do: :ok,
         else: (_ -> {:error, :unsafe_diagnostics_directory})
  end

  def write(directory, history, trigger) do
    data = [
      "{\"version\":1,\"trigger\":",
      JSON.encode!(trigger),
      ",\"samples\":[",
      Enum.intersperse(Enum.reverse(history), ","),
      "]}"
    ]

    if IO.iodata_length(data) > @max_bytes do
      {:error, :capture_too_large}
    else
      with :ok <- prepare(directory) do
        name =
          "incident-#{System.system_time(:millisecond)}-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}.json"

        path = Path.join(directory, name)
        temp = path <> ".tmp"

        try do
          with {:ok, file} <- File.open(temp, [:write, :exclusive, :binary]) do
            result =
              with :ok <- File.chmod(temp, 0o600),
                   :ok <- IO.binwrite(file, data),
                   do: :file.sync(file)

            File.close(file)

            with :ok <- result,
                 :ok <- File.rename(temp, path),
                 :ok <- prune(directory),
                 do: {:ok, %{path: path, bytes: IO.iodata_length(data)}}
          end
        after
          File.rm(temp)
        end
      end
    end
  end

  # Only this recorder's generated filenames are retention candidates. A
  # killed writer can leave an empty/partial temporary file behind.
  defp owned_name?(path),
    do: Regex.match?(~r/^incident-[0-9]+-[A-Za-z0-9_-]{8}\.json$/, Path.basename(path))

  defp remove_stale_temps(directory) do
    Path.wildcard(Path.join(directory, "incident-*.json.tmp"))
    |> Enum.filter(&owned_name?(String.trim_trailing(&1, ".tmp")))
    |> Enum.reduce_while(:ok, fn path, _ ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp prune(directory) do
    Path.wildcard(Path.join(directory, "incident-*.json"))
    |> Enum.filter(&owned_name?/1)
    |> Enum.sort(:desc)
    |> Enum.drop(@retained)
    |> Enum.reduce_while(:ok, fn path, _ ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
