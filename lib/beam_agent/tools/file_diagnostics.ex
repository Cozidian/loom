defmodule BeamAgent.Tools.FileDiagnostics do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Tools.FileSupport

  @impl true
  def name, do: "file_diagnostics"

  @impl true
  def description,
    do: "Return deterministic syntax diagnostics for one workspace-relative source file."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{path: %{type: "string"}},
      required: ["path"]
    }
  end

  @impl true
  def access, do: :read

  @impl true
  def execute(%{"path" => path}, context) when is_binary(path) do
    with {:ok, resolved} <- FileSupport.resolve(context, path),
         {:ok, contents} <- File.read(resolved) do
      diagnostics = diagnostics(path, contents)
      {:ok, JSON.encode!(%{path: path, diagnostics: diagnostics, count: length(diagnostics)})}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_path}

  def diagnostics(path, contents) when is_binary(path) and is_binary(contents) do
    if Path.extname(path) in [".ex", ".exs"] do
      case Code.string_to_quoted(contents, file: path) do
        {:ok, _ast} ->
          []

        {:error, {location, message, token}} ->
          [
            %{
              severity: "error",
              line: location[:line],
              column: location[:column],
              message: IO.iodata_to_binary([message, token])
            }
          ]
      end
    else
      []
    end
  rescue
    error -> [%{severity: "error", line: nil, column: nil, message: Exception.message(error)}]
  end
end
