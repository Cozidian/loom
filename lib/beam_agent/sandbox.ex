defmodule BeamAgent.Sandbox do
  @moduledoc "Platform command confinement resolved for one immutable workspace."

  def command(workspace_root, command) do
    shell = System.find_executable("zsh") || System.find_executable("sh")

    case {:os.type(), shell} do
      {{:unix, :darwin}, shell} when is_binary(shell) ->
        {:ok, "/usr/bin/sandbox-exec",
         ["-p", macos_profile(workspace_root), shell, "-lc", command]}

      {os, _shell} ->
        {:error, {:sandbox_unavailable, os}}
    end
  end

  defp macos_profile(workspace_root) do
    workspace = escape_profile(workspace_root)

    """
    (version 1)
    (deny default)
    (allow process*)
    (allow file-read*)
    (allow file-write*
      (subpath "#{workspace}")
      (subpath "/private/tmp")
      (subpath "/tmp")
      (literal "/dev/null"))
    (allow sysctl-read)
    (allow mach-lookup)
    """
  end

  defp escape_profile(path) do
    path |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end
end
