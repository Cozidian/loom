defmodule BeamAgent.Tools.RunCommand do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.{Sandbox, Subprocess}
  alias BeamAgent.Goal.WorkspaceSnapshot
  alias BeamAgent.Tools.FileSupport

  @impl true
  def name, do: "run_command"

  @impl true
  def description,
    do:
      "Run a shell command with bounded output/time inside a workspace-write, external-network-denied sandbox. Exit status and output are always returned as diagnostic data."

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

    baseline = workspace_snapshot(context)

    with true <- is_integer(timeout) and timeout in 100..120_000,
         {:ok, cwd} <- FileSupport.resolve(context, cwd),
         {:ok, %File.Stat{type: :directory}} <- File.stat(cwd),
         {:ok, executable, argv} <- Sandbox.command(context.workspace_root, command),
         {:ok, result} <-
           Subprocess.run(executable, argv,
             cwd: cwd,
             timeout_ms: timeout,
             max_output_bytes: 100_000,
             on_output: output_handler(context)
           ) do
      workspace_delta = workspace_delta(context, baseline)

      command_result = %{
        ok: result.status == 0,
        status: result.status,
        output: result.output,
        truncated: result.truncated,
        sandbox: "workspace-write",
        network: "loopback-only",
        changed_files: workspace_delta.changed_files,
        patch_fingerprint: workspace_delta.patch_fingerprint
      }

      {:ok, JSON.encode!(command_result)}
    else
      false -> {:error, :invalid_command_timeout}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_directory, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_non_empty_command}

  defp workspace_snapshot(%{
         project_id: project_id,
         workspace_root: workspace_root,
         data_dir: data_dir
       }),
       do:
         WorkspaceSnapshot.capture(project_id,
           workspace_root: workspace_root,
           data_dir: data_dir
         )

  defp workspace_snapshot(_context), do: {:error, :project_unavailable}

  defp workspace_delta(%{project_id: project_id}, {:ok, baseline}) do
    case WorkspaceSnapshot.capture(project_id,
           workspace_root: baseline.workspace_root,
           exclude: baseline.excluded_roots,
           data_dir: baseline.runtime_data_root
         ) do
      {:ok, current} -> WorkspaceSnapshot.delta(baseline, current)
      {:error, _reason} -> WorkspaceSnapshot.empty_delta()
    end
  end

  defp workspace_delta(_context, _baseline), do: WorkspaceSnapshot.empty_delta()

  defp output_handler(%{goal_id: goal_id, session_id: session_id}) do
    fn chunk ->
      BeamAgent.Goal.EventHub.publish(goal_id, session_id, %{
        type: :command_output_delta,
        delta: binary_part(chunk, 0, min(byte_size(chunk), 8_192)),
        truncated: byte_size(chunk) > 8_192
      })
    end
  end

  defp output_handler(_context), do: fn _chunk -> :ok end
end
