defmodule BeamAgent.Tools.GitInspect do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @maximum_output_bytes 100_000

  @impl true
  def name, do: "git_inspect"

  @impl true
  def description,
    do: "Inspect Git status, diff, or recent history through fixed read-only Git operations."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        operation: %{type: "string", enum: ["status", "diff", "log"]},
        path: %{type: "string", description: "Optional workspace-relative path for diff"},
        limit: %{type: "integer", minimum: 1, maximum: 50}
      },
      required: ["operation"]
    }
  end

  @impl true
  def access, do: :read

  @impl true
  def execute(%{"operation" => operation} = arguments, context) do
    with {:ok, argv} <- arguments(operation, arguments),
         {output, 0} <-
           System.cmd("git", argv, cd: context.workspace_root, stderr_to_stdout: true) do
      truncated = byte_size(output) > @maximum_output_bytes
      output = binary_part(output, 0, min(byte_size(output), @maximum_output_bytes))
      {:ok, JSON.encode!(%{operation: operation, output: output, truncated: truncated})}
    else
      {:error, reason} -> {:error, reason}
      {_output, _status} -> {:error, :git_inspection_failed}
    end
  rescue
    error -> {:error, {:git_inspection_failed, Exception.message(error)}}
  end

  def execute(_arguments, _context), do: {:error, :expected_git_inspection_operation}

  defp arguments("status", _arguments), do: {:ok, ["status", "--porcelain=v1", "--branch"]}

  defp arguments("diff", arguments) do
    case arguments["path"] do
      nil ->
        {:ok, ["diff", "--no-ext-diff", "--"]}

      path when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute or ".." in Path.split(path),
          do: {:error, :path_escapes_workspace},
          else: {:ok, ["diff", "--no-ext-diff", "--", path]}

      _other ->
        {:error, :invalid_git_path}
    end
  end

  defp arguments("log", arguments) do
    limit = arguments["limit"] || 10

    if is_integer(limit) and limit in 1..50,
      do: {:ok, ["log", "-n", Integer.to_string(limit), "--format=%H%x09%aI%x09%s"]},
      else: {:error, :invalid_git_log_limit}
  end

  defp arguments(_operation, _arguments), do: {:error, :invalid_git_operation}
end
