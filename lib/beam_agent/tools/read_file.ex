defmodule BeamAgent.Tools.ReadFile do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Tools.FileSupport

  @impl true
  def name, do: "read_file"

  @impl true
  def description,
    do:
      "Read a UTF-8 text file inside the workspace and return numbered-window metadata plus SHA-256."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "Workspace-relative file path"},
        start_line: %{type: "integer", minimum: 1},
        line_count: %{type: "integer", minimum: 1, maximum: 500}
      },
      required: ["path"]
    }
  end

  @impl true
  def access, do: :read

  @impl true
  def execute(%{"path" => path} = arguments, context) do
    start_line = Map.get(arguments, "start_line", 1)
    line_count = Map.get(arguments, "line_count", 200)

    with true <- is_integer(start_line) and start_line > 0,
         true <- is_integer(line_count) and line_count in 1..500,
         {:ok, resolved} <- FileSupport.resolve(context, path),
         {:ok, content} <- FileSupport.read_text(resolved) do
      lines = String.split(content, "\n")
      selected = Enum.slice(lines, start_line - 1, line_count)

      {:ok,
       JSON.encode!(%{
         path: path,
         content: Enum.join(selected, "\n"),
         start_line: start_line,
         end_line: start_line + max(length(selected) - 1, 0),
         total_lines: length(lines),
         sha256: FileSupport.sha256(content)
       })}
    else
      false -> {:error, :invalid_read_window}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_path}
end
