defmodule BeamAgent.CommandNetworkTest do
  use ExUnit.Case, async: false

  alias BeamAgent.{Agent, Sandbox, ToolRunner}
  alias BeamAgent.Tools.RunCommand

  setup do
    root = Path.join(System.tmp_dir!(), "command-network-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)

    {:ok, id} =
      BeamAgent.start_session(
        workspace_root: workspace,
        data_dir: Path.join(root, "runtime"),
        provider: :echo,
        approval_policy: :ask,
        approval_handler: self()
      )

    {:ok, context} = Agent.construction_context(id)

    on_exit(fn ->
      BeamAgent.stop_session(id)
      File.rm_rf(root)
    end)

    %{id: id, context: context, root: root}
  end

  test "offline always approvals do not grant external shell access", ctx do
    if :os.type() == {:unix, :darwin} do
      command = %{"command" => "printf approved", "timeout_ms" => 5_000}
      offline = Task.async(fn -> ToolRunner.execute(RunCommand, command, ctx.context) end)
      assert_receive {:beam_agent_approval, first}, 5_000
      assert first.resource.hosts == nil
      :ok = BeamAgent.respond_approval(ctx.id, first.approval_id, :allow_always)
      assert {:ok, output} = Task.await(offline, 10_000)
      assert JSON.decode!(output)["network"] == "loopback-only"

      external_command = Map.put(command, "network", "external")

      external =
        Task.async(fn -> ToolRunner.execute(RunCommand, external_command, ctx.context) end)

      assert_receive {:beam_agent_approval, second}, 5_000
      assert second.resource.hosts == "*"
      :ok = BeamAgent.respond_approval(ctx.id, second.approval_id, :deny)
      assert {:error, {:tool_denied, "run_command"}} = Task.await(external)

      approved =
        Task.async(fn -> ToolRunner.execute(RunCommand, external_command, ctx.context) end)

      assert_receive {:beam_agent_approval, third}, 5_000
      :ok = BeamAgent.respond_approval(ctx.id, third.approval_id, :allow_once)
      assert {:ok, output} = Task.await(approved, 10_000)
      assert JSON.decode!(output)["network"] == "external"
    end
  end

  test "a finite host capability cannot authorize an arbitrary networked shell", ctx do
    {:ok, envelope} =
      BeamAgent.CapabilityEnvelope.restrict(
        ctx.context.capability_envelope,
        %{hosts: ["hex.pm"]}
      )

    restricted = %{ctx.context | capability_envelope: envelope}

    assert {:error, {:capability_denied, :hosts, "*"}} =
             ToolRunner.execute(
               RunCommand,
               %{"command" => "printf forbidden", "network" => "external"},
               restricted
             )

    refute_receive {:beam_agent_approval, _}
  end

  test "external networking keeps filesystem confinement and rejects invalid modes", ctx do
    assert {:error, :invalid_command_network} =
             Sandbox.command(
               ctx.context.workspace_root,
               "true",
               network: "anything"
             )

    if :os.type() == {:unix, :darwin} and System.get_env("BEAM_AGENT_SANDBOX") != "1" do
      outside = Path.join(ctx.root, "outside.txt")

      assert {:error, {:command_failed, result}} =
               RunCommand.execute(
                 %{
                   "command" => "printf forbidden > " <> quote_shell(outside),
                   "network" => "external"
                 },
                 ctx.context
               )

      assert result.network == "external"
      refute File.exists?(outside)
    end
  end

  test "nested shells cannot change their inherited network policy", ctx do
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
               Sandbox.command(ctx.context.workspace_root, "true", network: "external")

      System.put_env("BEAM_AGENT_SANDBOX_NETWORK", "external")

      assert {:error, :nested_sandbox_network_denied} =
               Sandbox.command(ctx.context.workspace_root, "true")
    end
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
