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
              line: location_value(location, :line),
              column: location_value(location, :column),
              message: diagnostic_message(message, token)
            }
          ]
      end
    else
      []
    end
  rescue
    error -> [%{severity: "error", line: nil, column: nil, message: Exception.message(error)}]
  end

  defp location_value(location, key) when is_list(location), do: location[key]
  defp location_value(location, :line) when is_integer(location), do: location
  defp location_value(_location, _key), do: nil

  defp diagnostic_message(message, token) do
    [safe_text(message), safe_text(token)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("")
  end

  defp safe_text(value) when is_binary(value), do: value

  defp safe_text(value) when is_list(value) do
    try do
      IO.chardata_to_string(value)
    rescue
      _error -> inspect(value)
    end
  end

  defp safe_text(nil), do: ""
  defp safe_text(value), do: inspect(value)
end
