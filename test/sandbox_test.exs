defmodule BeamAgent.SandboxTest do
  use ExUnit.Case, async: false

  alias BeamAgent.Sandbox
  alias BeamAgent.Sandbox.Seatbelt
  alias BeamAgent.Tools.RunCommand

  setup do
    root = Path.join(System.tmp_dir!(), "sandbox-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    {:ok, workspace} = BeamAgent.Workspace.canonical_root(workspace)
    {:ok, root} = BeamAgent.Workspace.canonical_root(root)

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, workspace: workspace}
  end

  test "selects Seatbelt on macOS and fails closed elsewhere" do
    case :os.type() do
      {:unix, :darwin} ->
        assert Seatbelt.available?()
        assert {:ok, Seatbelt} = Sandbox.selected()

        assert {:ok, %{backend: "macos-seatbelt", confinement: "workspace-write"}} =
                 Sandbox.info()

      os ->
        refute Seatbelt.available?()
        assert {:error, {:sandbox_unavailable, ^os}} = Sandbox.selected()
        assert {:error, {:sandbox_unavailable, ^os}} = Sandbox.info()
    end
  end

  test "wraps a macOS command with sandbox-exec and the workspace-write profile", %{
    workspace: workspace
  } do
    if :os.type() == {:unix, :darwin} and System.get_env("BEAM_AGENT_SANDBOX") != "1" do
      assert {:ok, invocation} = Sandbox.wrap(workspace, "true")
      assert invocation.backend == "macos-seatbelt"
      assert invocation.confinement == "workspace-write"
      assert invocation.network == "loopback-only"
      assert invocation.executable == "/usr/bin/sandbox-exec"
      assert ["-p", profile, _shell, "-o", "pipefail", "-lc", wrapped] = invocation.argv
      assert profile =~ "(deny default)"
      assert profile =~ ~s(subpath "#{workspace}")
      refute profile =~ "(allow network-outbound)\n"
      assert wrapped =~ "BEAM_AGENT_SANDBOX=1"
      assert wrapped =~ "true"
    end
  end

  test "rejects invalid network modes", %{workspace: workspace} do
    assert {:error, :invalid_command_network} =
             Sandbox.wrap(workspace, "true", network: "anything")
  end

  test "nested shells cannot change their inherited network policy", %{workspace: workspace} do
    if :os.type() == {:unix, :darwin} do
      old =
        Map.new(["BEAM_AGENT_SANDBOX", "BEAM_AGENT_SANDBOX_NETWORK"], &{&1, System.get_env(&1)})

      on_exit(fn ->
        for key <- ["BEAM_AGENT_SANDBOX", "BEAM_AGENT_SANDBOX_NETWORK"] do
          if old[key], do: System.put_env(key, old[key]), else: System.delete_env(key)
        end
      end)

      System.put_env("BEAM_AGENT_SANDBOX", "1")
      System.put_env("BEAM_AGENT_SANDBOX_NETWORK", "loopback-only")

      assert {:error, :nested_sandbox_network_denied} =
               Sandbox.wrap(workspace, "true", network: "external")

      assert {:ok, invocation} = Sandbox.wrap(workspace, "true")
      assert invocation.backend == "macos-seatbelt"
      refute invocation.executable == "/usr/bin/sandbox-exec"
    end
  end

  test "run_command names the Seatbelt backend and confines writes to the workspace", %{
    root: root,
    workspace: workspace
  } do
    if :os.type() != {:unix, :darwin} do
      assert {:error, {:sandbox_unavailable, _os}} =
               RunCommand.execute(%{"command" => "pwd"}, %{workspace_root: workspace})
    else
      assert {:ok, encoded} =
               RunCommand.execute(
                 %{"command" => "printf inside > command.txt", "timeout_ms" => 5_000},
                 %{workspace_root: workspace}
               )

      result = JSON.decode!(encoded)
      assert result["status"] == 0
      assert result["sandbox"] == "workspace-write"
      assert result["sandbox_backend"] == "macos-seatbelt"
      assert result["network"] == "loopback-only"
      assert File.read!(Path.join(workspace, "command.txt")) == "inside"

      assert {:ok, tmp} =
               RunCommand.execute(
                 %{"command" => "printf %s \"$TMPDIR\"", "timeout_ms" => 5_000},
                 %{workspace_root: workspace}
               )

      assert JSON.decode!(tmp)["output"] == Sandbox.temporary_root(workspace)

      if System.get_env("BEAM_AGENT_SANDBOX") != "1" do
        outside = Path.join(root, "outside.txt")

        assert {:error, {:command_failed, denied}} =
                 RunCommand.execute(
                   %{
                     "command" => "printf outside > " <> shell_quote(outside),
                     "timeout_ms" => 5_000
                   },
                   %{workspace_root: workspace}
                 )

        assert denied.sandbox_backend == "macos-seatbelt"
        assert denied.ok == false
        assert denied.status != 0
        refute File.exists?(outside)
      end
    end
  end

  test "Seatbelt allows loopback bind and denies external outbound by default", %{
    workspace: workspace
  } do
    if :os.type() == {:unix, :darwin} and System.get_env("BEAM_AGENT_SANDBOX") != "1" do
      python = System.find_executable("python3") || System.find_executable("python")

      if is_binary(python) do
        loopback =
          python <>
            " -c \"import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])\""

        assert {:ok, encoded} =
                 RunCommand.execute(%{"command" => loopback, "timeout_ms" => 5_000}, %{
                   workspace_root: workspace
                 })

        bound = JSON.decode!(encoded)
        assert bound["sandbox_backend"] == "macos-seatbelt"
        assert bound["status"] == 0
        assert bound["output"] =~ ~r/^\d+$/

        outbound =
          python <>
            " -c \"import socket; s=socket.socket(); s.settimeout(2); s.connect(('1.1.1.1', 443))\""

        assert {:error, {:command_failed, denied}} =
                 RunCommand.execute(%{"command" => outbound, "timeout_ms" => 5_000}, %{
                   workspace_root: workspace
                 })

        assert denied.sandbox_backend == "macos-seatbelt"
        assert denied.status != 0
        assert denied.output =~ "Operation not permitted" or denied.status == 1
      end
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
