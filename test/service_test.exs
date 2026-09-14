defmodule BeamAgent.ServiceTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias BeamAgent.CLI.Config
  alias BeamAgent.Service.Storage

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "loom-service-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    File.mkdir_p!(root)
    previous = System.get_env("LOOM_SERVICE_DIR")
    discovery = Application.get_env(:beam_agent, :discovery_dir)
    System.put_env("LOOM_SERVICE_DIR", Path.join(root, "service"))
    Application.put_env(:beam_agent, :discovery_dir, Path.join(root, "live"))

    stored =
      Config.defaults()
      |> put_in(["profiles", "demo", "provider"], "echo")
      |> Map.put("data_dir", Path.join(root, "sessions"))

    config_path = Path.join(root, "config.json")
    {:ok, _} = Config.write(stored, config_path)
    {:ok, config} = Config.runtime(stored)
    config = Map.put(config, "workspace_root", root)

    on_exit(fn ->
      if previous,
        do: System.put_env("LOOM_SERVICE_DIR", previous),
        else: System.delete_env("LOOM_SERVICE_DIR")

      if discovery,
        do: Application.put_env(:beam_agent, :discovery_dir, discovery),
        else: Application.delete_env(:beam_agent, :discovery_dir)

      File.rm_rf(root)
    end)

    %{root: root, config: config, config_path: config_path}
  end

  test "private discovery validates live identity and does not return credentials in status",
       ctx do
    start_supervised!(
      {BeamAgent.Service, config: ctx.config, config_path: ctx.config_path, desk: false}
    )

    assert {:ok, record} = Storage.lookup()
    assert {:ok, status} = Storage.request(record, :get, "/api/v1/service")
    refute Map.has_key?(status, "token")
    assert status["config_path"] == ctx.config_path

    assert {:error, _} =
             Storage.request(
               Map.put(record, "token", String.duplicate("x", 40)),
               :get,
               "/api/v1/service"
             )

    assert band(File.stat!(Storage.path("runtime.json")).mode, 0o077) == 0

    assert {:error, "desk_starting"} =
             Storage.request(record, :post, "/api/v1/service/launch", %{})

    File.chmod!(Storage.path("runtime.json"), 0o644)
    assert {:error, :service_unavailable} = Storage.lookup()
  end

  test "diagnostics CLI captures the service and its routes require authentication", ctx do
    start_supervised!(
      {BeamAgent.Service, config: ctx.config, config_path: ctx.config_path, desk: false}
    )

    assert {:ok, record} = Storage.lookup()

    assert {:error, _} =
             Storage.request(
               Map.put(record, "token", "wrong-token"),
               :post,
               "/api/v1/diagnostics/capture",
               %{}
             )

    assert [] == Path.wildcard(Storage.path("diagnostics/incident-*.json"))

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert 0 = BeamAgent.CLI.run(["diagnostics", "capture"])
      end)

    assert %{"path" => path, "bytes" => bytes} = JSON.decode!(String.trim(output))
    assert bytes == File.stat!(path).size
    assert JSON.decode!(File.read!(path))["samples"] != []

    for {command, enabled} <- [{"stop", false}, {"start", true}] do
      result =
        ExUnit.CaptureIO.capture_io(fn ->
          assert 0 = BeamAgent.CLI.run(["diagnostics", command])
        end)
        |> String.trim()
        |> JSON.decode!()

      assert result["enabled"] == enabled
      assert File.regular?(path)
    end
  end

  test "disconnecting a TUI leaves work owned by the service and recovery restores the observer paused",
       ctx do
    System.cmd("git", ["init", "-q"], cd: ctx.root)
    File.write!(Path.join(ctx.root, "README.md"), "fixture")
    System.cmd("git", ["add", "README.md"], cd: ctx.root)
    opts = [config: ctx.config, config_path: ctx.config_path, desk: false]
    start_supervised!({BeamAgent.Service, opts})
    assert {:ok, id, _endpoint} = BeamAgent.CLI.create_local_session(ctx.config, ctx.config_path)
    assert :ok = BeamAgent.Missions.Documentation.command(id, "start")
    {:ok, record} = BeamAgent.LocalDiscovery.lookup(id)

    {:ok, socket} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        record["tui_port"],
        [:binary, packet: 4, active: false],
        2000
      )

    :ok = :gen_tcp.send(socket, JSON.encode!(%{token: record["token"]}))
    assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 3000)
    assert %{"type" => "init", "session_id" => ^id} = JSON.decode!(bytes)
    :gen_tcp.close(socket)
    assert {:ok, _} = BeamAgent.agent_pid(id)

    assert {:ok, %{"status" => "observing"}} =
             BeamAgent.Missions.Documentation.command(id, "status")

    stop_supervised!(BeamAgent.Service)
    assert eventually(fn -> match?({:error, _}, BeamAgent.LocalDiscovery.lookup(id)) end)
    start_supervised!({BeamAgent.Service, opts})
    assert eventually(fn -> match?({:ok, _}, BeamAgent.LocalDiscovery.lookup(id)) end)

    assert {:ok, %{"status" => "paused", "attempts" => 0}} =
             BeamAgent.Missions.Documentation.command(id, "status")

    assert {:ok, %{phase: :idle}} = BeamAgent.Goal.snapshot(id)
    assert {:ok, %{"recovery" => recovery}} = BeamAgent.Service.status()
    assert recovery[id] == "restored_idle"
  end

  test "a deleted observer stays deleted after service recovery", ctx do
    System.cmd("git", ["init", "-q"], cd: ctx.root)
    opts = [config: ctx.config, config_path: ctx.config_path, desk: false]
    start_supervised!({BeamAgent.Service, opts})
    {:ok, id, _} = BeamAgent.CLI.create_local_session(ctx.config, ctx.config_path)
    :ok = BeamAgent.Missions.Documentation.command(id, "start")
    :ok = BeamAgent.Missions.Documentation.command(id, "delete")
    stop_supervised!(BeamAgent.Service)
    assert eventually(fn -> match?({:error, _}, BeamAgent.LocalDiscovery.lookup(id)) end)
    start_supervised!({BeamAgent.Service, opts})
    assert eventually(fn -> match?({:ok, _}, BeamAgent.LocalDiscovery.lookup(id)) end)

    assert {:ok, %{"status" => "disabled"}} =
             BeamAgent.Missions.Documentation.command(id, "status")
  end

  test "launch agent arguments escape paths and contain no bearer credentials", ctx do
    xml = BeamAgent.CLI.Service.plist(ctx.config_path <> "<&", "/test path/loom")
    assert xml =~ "<string>/test path/loom</string>"
    assert xml =~ "&lt;&amp;"
    assert xml =~ "<key>KeepAlive</key><true/>"
    refute xml =~ "RUNTIME_TOKEN"
    refute xml =~ "LAUNCH_TICKET"
  end

  defp eventually(fun, tries \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, tries) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(20)
          eventually(fun, tries - 1)
        )
  end
end
