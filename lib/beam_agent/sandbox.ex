defmodule BeamAgent.Sandbox do
  @moduledoc """
  Host-selected command confinement for one immutable workspace.

  The runtime picks an enforcing backend for the current OS. macOS uses
  Seatbelt when `sandbox-exec` is present. Other platforms fail closed until
  an enforcing backend exists. Nested shells inherit the installed policy
  and cannot widen it. Models and clients do not choose the backend.
  """

  alias BeamAgent.Sandbox.Seatbelt

  @confinement "workspace-write"
  @backends [Seatbelt]
  @networks ["loopback-only", "external"]

  def backends, do: @backends

  def selected do
    case Enum.find(@backends, & &1.available?()) do
      nil -> {:error, {:sandbox_unavailable, :os.type()}}
      module -> {:ok, module}
    end
  end

  def info do
    case selected() do
      {:ok, module} ->
        {:ok, %{backend: module.id(), confinement: @confinement, available: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def temporary_root(workspace_root) do
    digest =
      :crypto.hash(:sha256, workspace_root)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    Path.join([canonical_temp_root(), "beam_agent", digest])
  end

  def command(workspace_root, command, opts \\ []) do
    with {:ok, invocation} <- wrap(workspace_root, command, opts) do
      {:ok, invocation.executable, invocation.argv}
    end
  end

  def wrap(workspace_root, command, opts \\ []) do
    network = Keyword.get(opts, :network, "loopback-only")
    temporary = temporary_root(workspace_root)

    with :ok <- validate_network(network),
         {:ok, backend} <- selected(),
         :ok <- File.mkdir_p(temporary) do
      command = env_prefix(temporary, network) <> command

      case backend.wrap(workspace_root, command,
             network: network,
             temporary_root: temporary
           ) do
        {:ok, wrapped} ->
          {:ok,
           %{
             backend: backend.id(),
             confinement: @confinement,
             network: network,
             executable: wrapped.executable,
             argv: wrapped.argv
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_network(network) when network in @networks, do: :ok
  defp validate_network(_network), do: {:error, :invalid_command_network}

  defp env_prefix(temporary, network) do
    "export TMPDIR=#{shell_quote(temporary)} BEAM_AGENT_SANDBOX=1 " <>
      "BEAM_AGENT_SANDBOX_NETWORK=#{shell_quote(network)} " <>
      "HEX_HOME=#{shell_quote(Path.join(temporary, "hex"))} " <>
      "GOCACHE=#{shell_quote(Path.join(temporary, "go-build"))} " <>
      "npm_config_cache=#{shell_quote(Path.join(temporary, "npm"))}; "
  end

  defp canonical_temp_root do
    case BeamAgent.Workspace.canonical_root(System.tmp_dir!()) do
      {:ok, root} -> root
      {:error, _reason} -> Path.expand(System.tmp_dir!())
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
