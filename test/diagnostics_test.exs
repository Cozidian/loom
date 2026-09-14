defmodule BeamAgent.DiagnosticsTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias BeamAgent.Diagnostics
  alias BeamAgent.Diagnostics.{Snapshot, Store}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "loom-diagnostics-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    :ok = Diagnostics.configure(directory: root, owner: self(), enabled: false)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "manual capture observes a blocked process without copying its mailbox or dictionary",
       ctx do
    secret = "private-prompt-and-token-" <> Base.encode16(:crypto.strong_rand_bytes(20))
    test_pid = self()

    worker =
      spawn(fn ->
        Registry.register(BeamAgent.Registry, {:diagnostics_fixture, "blocked-session"}, nil)
        Process.put(:secret, secret)
        send(test_pid, :ready)
        receive do: (:release -> :ok)
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive :ready
    for _ <- 1..200, do: send(worker, {:private_message, secret})

    assert {:ok, %{path: path, bytes: bytes}} = Diagnostics.capture()
    assert bytes <= 2_097_152
    raw = File.read!(path)
    refute raw =~ secret
    report = JSON.decode!(raw)
    assert report["trigger"]["kind"] == "manual"
    sample = List.last(report["samples"])
    row = Enum.find(sample["processes"], &(&1["pid"] == inspect(worker)))
    assert row["message_queue_len"] == 200
    assert row["identity"] == %{"kind" => "diagnostics_fixture", "id" => "blocked-session"}
    assert row["stack"] != []
    assert sample["vm_memory"]["binary"] >= 0

    assert Enum.any?(
             sample["os_processes"],
             &(&1["pid"] == String.to_integer(System.pid()) and &1["rss_bytes"] > 0)
           )

    assert band(File.stat!(ctx.root).mode, 0o777) == 0o700
    assert band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "an automatic memory capture is saved independently of the observed process", ctx do
    :ok =
      Diagnostics.configure(
        directory: ctx.root,
        owner: self(),
        interval_ms: 20,
        memory_threshold: 1
      )

    assert eventually(fn ->
             {:ok, status} = Diagnostics.status()
             status.last_capture != nil
           end)

    {:ok, %{last_capture: %{path: path}}} = Diagnostics.status()

    assert JSON.decode!(File.read!(path))["trigger"]["kind"] in [
             "process_memory",
             "vm_memory",
             "os_memory"
           ]
  end

  test "limit evidence survives the emitting process exiting before the next sample", ctx do
    :ok = Diagnostics.configure(directory: ctx.root, owner: self(), interval_ms: 50)

    {worker, ref} =
      spawn_monitor(fn ->
        Registry.register(BeamAgent.Registry, {:provider_conversation, "dead-session"}, nil)

        Diagnostics.progress(%{
          source: :codex_conversation,
          phase: :active,
          elapsed_ms: 50,
          messages: 100,
          retained_text_bytes: 1_024,
          prompt: "never-store-this"
        })

        Diagnostics.incident({:codex_turn_limit, :bytes, 1_024})
      end)

    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}

    assert eventually(fn ->
             {:ok, status} = Diagnostics.status()
             status.last_capture != nil
           end)

    {:ok, %{last_capture: %{path: path}}} = Diagnostics.status()
    raw = File.read!(path)
    refute raw =~ "never-store-this"
    incident = JSON.decode!(raw)["trigger"]
    assert incident["kind"] == "codex_turn_limit"
    assert incident["progress"]["retained_text_bytes"] == 1_024
    assert incident["process"]["identity"]["id"] == "dead-session"
    assert Snapshot.progress(worker) == nil
  end

  test "a real Codex watchdog records the child PID and counters before killing it", ctx do
    :ok = Diagnostics.configure(directory: ctx.root, owner: self(), interval_ms: 50)

    client =
      start_supervised!(
        {BeamAgent.CodexAppServer.Client,
         owner: self(),
         executable: "/bin/sh",
         arguments: ["-c", "while IFS= read -r line; do :; done"]}
      )

    :ok = BeamAgent.CodexAppServer.Client.begin_turn(client, codex_turn_timeout_ms: 20)

    assert_receive {:codex_app_server, ^client, {:exit, {:codex_turn_limit, :duration_ms, 20}}},
                   1_000

    BeamAgent.CodexAppServer.Client.stop(client)

    assert eventually(fn ->
             {:ok, state} = Diagnostics.status()
             state.last_capture != nil
           end)

    {:ok, %{last_capture: %{path: path}}} = Diagnostics.status()
    incident = JSON.decode!(File.read!(path))["trigger"]
    assert incident["kind"] == "codex_turn_limit"
    assert incident["progress"]["source"] == "codex_client"
    assert incident["progress"]["os_pid"] > 0
    assert incident["progress"]["elapsed_ms"] >= 20
  end

  test "pause is reversible and manual capture still works", ctx do
    :ok =
      Diagnostics.configure(
        directory: ctx.root,
        owner: self(),
        interval_ms: 20,
        memory_threshold: 1
      )

    :ok = Diagnostics.enable(false)
    Process.sleep(60)
    assert {:ok, %{enabled: false, last_capture: nil}} = Diagnostics.status()
    assert {:ok, _} = Diagnostics.capture()
    :ok = Diagnostics.enable(true)
    assert {:ok, %{enabled: true}} = Diagnostics.status()
  end

  test "active client samples correlate OS RSS and channel counters with their session" do
    Registry.register(BeamAgent.Registry, {:provider_conversation, "rss-session"}, nil)

    client =
      start_supervised!(
        {BeamAgent.CodexAppServer.Client,
         owner: self(),
         executable: "/bin/sh",
         arguments: [
           "-c",
           "IFS= read -r line; printf '%s\\n' '{\"method\":\"item/reasoning/summaryTextDelta\",\"params\":{\"delta\":\"private-summary\"}}'; while IFS= read -r line; do :; done"
         ]}
      )

    :ok = BeamAgent.CodexAppServer.Client.begin_turn(client, codex_turn_timeout_ms: 5_000)
    :ok = BeamAgent.CodexAppServer.Client.notify(client, "go")
    assert_receive {:codex_app_server, ^client, {:notification, _}}, 1_000
    assert {:ok, %{path: path}} = Diagnostics.capture()
    raw = File.read!(path)
    refute raw =~ "private-summary"
    sample = JSON.decode!(raw)["samples"] |> List.last()
    provider = Enum.find(sample["providers"], &(&1["pid"] == inspect(client)))
    assert provider["identity"]["id"] == "rss-session"
    assert provider["data"]["summary"] == 1
    assert provider["data"]["messages"] == 1
    assert provider["data"]["received_bytes"] > 0

    assert Enum.any?(
             sample["os_processes"],
             &(&1["pid"] == provider["data"]["os_pid"] and &1["rss_bytes"] > 0)
           )
  end

  test "history and retained captures remain bounded", ctx do
    for _ <- 1..27, do: assert({:ok, _} = Diagnostics.capture())
    assert {:ok, %{samples: 24}} = Diagnostics.status()
    files = Path.wildcard(Path.join(ctx.root, "incident-*.json"))
    assert length(files) == 5
    assert Enum.all?(files, &(File.stat!(&1).size <= 2_097_152))
  end

  test "writer refuses an oversized report and a symlink directory", ctx do
    assert {:error, :capture_too_large} =
             Store.write(ctx.root, [String.duplicate("x", 2_097_152)], %{})

    link = ctx.root <> "-link"
    File.ln_s!(ctx.root, link)
    on_exit(fn -> File.rm(link) end)
    assert {:error, :unsafe_diagnostics_directory} = Store.prepare(link)
  end

  test "a recorder restart resumes configuration while its owning service is alive" do
    old = Process.whereis(Diagnostics)
    Process.exit(old, :kill)

    assert eventually(fn ->
             case Process.whereis(Diagnostics) do
               pid when is_pid(pid) and pid != old -> true
               _ -> false
             end
           end)

    assert {:ok, %{enabled: false, directory: directory}} = Diagnostics.status()
    assert is_binary(directory)
    assert {:ok, _} = Diagnostics.capture()
  end

  test "owner death disables recording and prevents writes to its old directory", ctx do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    :ok = Diagnostics.configure(directory: ctx.root, owner: owner, interval_ms: 20)
    Process.exit(owner, :kill)

    assert eventually(fn ->
             {:ok, state} = Diagnostics.status()
             state.enabled == false and state.directory == nil
           end)

    assert {:error, :diagnostics_not_configured} = Diagnostics.capture()
  end

  test "progress overwrites one bounded row and computes elapsed time during silence" do
    for n <- 1..10_000,
        do:
          Diagnostics.progress(%{
            source: :codex_client,
            messages: n,
            phase: :active,
            elapsed_ms: 1
          })

    Process.sleep(10)
    assert %{messages: 10_000, elapsed_ms: elapsed} = Snapshot.progress(self())
    assert elapsed >= 11

    assert Enum.count(
             Registry.keys(BeamAgent.Registry, self()),
             &match?({:diagnostic_progress, _}, &1)
           ) == 1
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, remaining) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(20)
          eventually(fun, remaining - 1)
        )
  end
end
