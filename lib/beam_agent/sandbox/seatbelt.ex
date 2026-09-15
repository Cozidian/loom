defmodule BeamAgent.Sandbox.Seatbelt do
  @moduledoc """
  macOS Seatbelt backend using `/usr/bin/sandbox-exec`.

  Nested shells inherit the installed profile. They cannot install a second
  profile or change the network mode the parent already applied.
  """
  @behaviour BeamAgent.Sandbox.Backend

  @id "macos-seatbelt"
  @sandbox_exec "/usr/bin/sandbox-exec"

  @impl true
  def id, do: @id

  @impl true
  def available? do
    :os.type() == {:unix, :darwin} and File.regular?(@sandbox_exec)
  end

  @impl true
  def wrap(workspace_root, command, opts) do
    network = Keyword.fetch!(opts, :network)
    temporary_root = Keyword.fetch!(opts, :temporary_root)
    shell = System.find_executable("zsh") || System.find_executable("sh")

    cond do
      not is_binary(shell) ->
        {:error, {:sandbox_unavailable, :os.type()}}

      nested?() ->
        inherit(shell, command, network)

      true ->
        {:ok,
         %{
           executable: @sandbox_exec,
           argv: [
             "-p",
             profile(workspace_root, temporary_root, network),
             shell,
             "-o",
             "pipefail",
             "-lc",
             command
           ]
         }}
    end
  end

  defp nested?, do: System.get_env("BEAM_AGENT_SANDBOX") == "1"

  defp inherit(shell, command, network) do
    inherited = System.get_env("BEAM_AGENT_SANDBOX_NETWORK") || "loopback-only"

    # A nested shell inherits its parent's Seatbelt policy. It cannot
    # widen it or promise a narrower policy that was never installed.
    if network != inherited do
      {:error, :nested_sandbox_network_denied}
    else
      {:ok, %{executable: shell, argv: ["-o", "pipefail", "-lc", command]}}
    end
  end

  defp profile(workspace_root, temporary_root, network) do
    workspace = escape(workspace_root)
    temporary = escape(temporary_root)

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
    #{if network == "external", do: "(allow network-outbound)", else: ""}
    """
  end

  defp escape(path) do
    path |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end
end
