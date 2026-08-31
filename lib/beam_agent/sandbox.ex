defmodule BeamAgent.Sandbox do
  @moduledoc "Platform command confinement resolved for one immutable workspace."

  @doc false
  def temporary_root(workspace_root) do
    digest =
      :crypto.hash(:sha256, workspace_root)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    Path.join([canonical_temp_root(), "beam_agent", digest])
  end

  def command(workspace_root, command) do
    shell = System.find_executable("zsh") || System.find_executable("sh")
    temporary = temporary_root(workspace_root)

    with :ok <- File.mkdir_p(temporary) do
      command = "export TMPDIR=#{shell_quote(temporary)} BEAM_AGENT_SANDBOX=1; #{command}"

      case {System.get_env("BEAM_AGENT_SANDBOX"), :os.type(), shell} do
        {"1", {:unix, :darwin}, shell} when is_binary(shell) ->
          {:ok, shell, ["-o", "pipefail", "-lc", command]}

        {_nested, {:unix, :darwin}, shell} when is_binary(shell) ->
          {:ok, "/usr/bin/sandbox-exec",
           [
             "-p",
             macos_profile(workspace_root, temporary),
             shell,
             "-o",
             "pipefail",
             "-lc",
             command
           ]}

        {_nested, os, _shell} ->
          {:error, {:sandbox_unavailable, os}}
      end
    end
  end

  defp macos_profile(workspace_root, temporary_root) do
    workspace = escape_profile(workspace_root)
    temporary = escape_profile(temporary_root)

    """
    (version 1)
    (deny default)
    (allow process*)
    (allow file-read*)
    (allow file-write*
      (subpath "#{workspace}")
      (subpath "#{temporary}")
      (literal "/dev/null"))
    (allow sysctl-read)
    (allow mach-lookup)
    (allow network-bind (local ip "localhost:*"))
    (allow network-inbound (local ip "localhost:*"))
    (allow network-outbound (remote ip "localhost:*"))
    """
  end

  defp escape_profile(path) do
    path |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end

  defp canonical_temp_root do
    case BeamAgent.Workspace.canonical_root(System.tmp_dir!()) do
      {:ok, root} -> root
      {:error, _reason} -> Path.expand(System.tmp_dir!())
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
