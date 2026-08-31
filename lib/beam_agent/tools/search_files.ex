defmodule BeamAgent.Tools.SearchFiles do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Subprocess
  alias BeamAgent.Tools.FileSupport

  @impl true
  def name, do: "search_files"

  @impl true
  def description, do: "Search workspace text with ripgrep and return bounded path/line matches."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Regular expression to search for"},
        path: %{type: "string", description: "Workspace-relative search root; defaults to ."},
        glob: %{type: "string", description: "Optional ripgrep glob such as *.ex"},
        limit: %{type: "integer", minimum: 1, maximum: 500}
      },
      required: ["query"]
    }
  end

  @impl true
  def access, do: :read

  @impl true
  def execute(%{"query" => query} = arguments, context) when is_binary(query) and query != "" do
    path = Map.get(arguments, "path", ".")
    limit = Map.get(arguments, "limit", 100)

    with :ok <- validate_limit(limit),
         {:ok, target} <- FileSupport.resolve(context, path),
         rg when is_binary(rg) <- System.find_executable("rg"),
         args <- rg_args(query, target, arguments["glob"]),
         {:ok, result} <-
           Subprocess.run(rg, args,
             cwd: context.workspace_root,
             timeout_ms: 15_000,
             max_output_bytes: 200_000
           ),
         :ok <- accept_status(result) do
      matches =
        result.output
        |> String.split("\n", trim: true)
        |> Enum.take(limit)
        |> Enum.map(&relativize(&1, context.workspace_root))

      {:ok,
       JSON.encode!(%{
         query: query,
         matches: matches,
         truncated: result.truncated or length(matches) == limit
       })}
    else
      nil -> {:error, :ripgrep_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_non_empty_query}

  defp validate_limit(limit) when is_integer(limit) and limit in 1..500, do: :ok
  defp validate_limit(_limit), do: {:error, :invalid_search_options}

  defp accept_status(%{status: status}) when status in [0, 1], do: :ok

  defp accept_status(%{status: status, output: output}),
    do: {:error, {:ripgrep_failed, status, output}}

  defp rg_args(query, target, glob) do
    base = ["--line-number", "--no-heading", "--color", "never"]
    base = if is_binary(glob) and glob != "", do: base ++ ["--glob", glob], else: base
    base ++ ["--", query, target]
  end

  defp relativize(line, workspace) do
    String.replace_prefix(line, workspace <> "/", "")
  end
end
