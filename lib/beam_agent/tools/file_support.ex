defmodule BeamAgent.Tools.FileSupport do
  @moduledoc false

  alias BeamAgent.Workspace

  @max_file_bytes 1_000_000

  def resolve(context, path), do: Workspace.resolve(context.workspace_root, path)

  def read_text(path, max_bytes \\ @max_file_bytes) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes <-
           File.stat(path),
         {:ok, content} <- File.read(path),
         true <- String.valid?(content) do
      {:ok, content}
    else
      {:ok, %File.Stat{type: :regular, size: size}} -> {:error, {:file_too_large, size}}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular_file, type}}
      false -> {:error, :not_utf8_text}
      {:error, reason} -> {:error, reason}
    end
  end

  def sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  def atomic_write(path, content) do
    suffix = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    temporary = Path.join(Path.dirname(path), ".beam-agent-#{suffix}.tmp")

    with {:ok, stat} <- File.stat(path),
         :ok <- File.write(temporary, content, [:binary, :exclusive]),
         :ok <- File.chmod(temporary, Bitwise.band(stat.mode, 0o7777)),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} = error ->
        _ = File.rm(temporary)
        if reason == :eexist, do: atomic_write(path, content), else: error
    end
  end
end
