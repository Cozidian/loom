defmodule BeamAgent.Tools.CreateFile do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Tools.FileSupport

  @impl true
  def name, do: "create_file"

  @impl true
  def description,
    do: "Create a new UTF-8 file inside the workspace. Refuses to overwrite an existing path."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "Workspace-relative path"},
        content: %{type: "string"}
      },
      required: ["path", "content"]
    }
  end

  @impl true
  def access, do: :write

  @impl true
  def execute(%{"path" => path, "content" => content}, context)
      when is_binary(content) do
    with {:ok, resolved} <- FileSupport.resolve(context, path),
         false <- File.exists?(resolved),
         :ok <- File.mkdir_p(Path.dirname(resolved)),
         :ok <- write_exclusively(resolved, content) do
      {:ok,
       JSON.encode!(%{path: path, bytes: byte_size(content), sha256: FileSupport.sha256(content)})}
    else
      true -> {:error, {:file_exists, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_path_and_content}

  defp write_exclusively(path, content) do
    case File.open(path, [:write, :exclusive, :binary], &IO.binwrite(&1, content)) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        _ = File.rm(path)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
