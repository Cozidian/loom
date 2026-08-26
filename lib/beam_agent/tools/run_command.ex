defmodule BeamAgent.Tools.RunCommand do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.{Sandbox, Subprocess}
  alias BeamAgent.Tools.FileSupport

  @impl true
  def name, do: "run_command"

  @impl true
  def description,
    do:
      "Run a shell command with bounded output/time inside a workspace-write, network-denied sandbox."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        command: %{type: "string"},
        cwd: %{type: "string", description: "Workspace-relative directory; defaults to ."},
        timeout_ms: %{type: "integer", minimum: 100, maximum: 120_000}
      },
      required: ["command"]
    }
  end

  @impl true
  def access, do: :execute

  @impl true
  def execute(%{"command" => command} = arguments, context)
      when is_binary(command) and command != "" do
    timeout = Map.get(arguments, "timeout_ms", 30_000)
    cwd = Map.get(arguments, "cwd", ".")

    with true <- is_integer(timeout) and timeout in 100..120_000,
         {:ok, cwd} <- FileSupport.resolve(context, cwd),
         {:ok, %File.Stat{type: :directory}} <- File.stat(cwd),
         {:ok, executable, argv} <- Sandbox.command(context.workspace_root, command),
         {:ok, result} <-
           Subprocess.run(executable, argv,
             cwd: cwd,
             timeout_ms: timeout,
             max_output_bytes: 100_000
           ) do
      {:ok,
       JSON.encode!(%{
         status: result.status,
         output: result.output,
         truncated: result.truncated,
         sandbox: "workspace-write",
         network: "denied"
       })}
    else
      false -> {:error, :invalid_command_timeout}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_directory, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_non_empty_command}
end
