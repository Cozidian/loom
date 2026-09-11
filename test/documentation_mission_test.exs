defmodule BeamAgent.DocumentationMissionTest do
  use ExUnit.Case, async: false
  alias BeamAgent.Missions.{Documentation, Snapshot}

  defmodule Provider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :documentation_mission_test

    def complete(messages, tools, options) do
      send(options[:test_pid], {:mission_inference, self(), messages, tools})

      if options[:hold] do
        receive do
          :finish -> :ok
        end
      end

      {:ok,
       %{
         content:
           "Possible README gap: lib/example.ex changed. Confirm that the other editor has finished before acting.",
         tool_calls: []
       }}
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(Provider)

    :ok =
      BeamAgent.CapabilityCatalog.register_provider(
        BeamAgent.DocumentationMissionTest.FixProvider
      )
  end

  defmodule FixProvider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :documentation_fix_test

    def complete(messages, tools, options) do
      send(options[:test_pid], {:fix_tools, Enum.map(tools, & &1.name)})

      if options[:hold] do
        send(options[:test_pid], {:fix_waiting, self()})

        receive do
          :finish -> :ok
        end
      end

      case {Enum.any?(tools, &(&1.name == "edit_file")),
            Enum.count(messages, &(&1.role == :tool))} do
        {false, 0} ->
          call("review-read", "read_file", %{path: "README.md"})

        {false, _} ->
          {:ok,
           %{
             content: "REVIEW_PASS: bounded fixture documentation patch; shell tests not run.",
             tool_calls: []
           }}

        {_, 0} ->
          call("read", "read_file", %{path: "README.md"})

        {_, 1} ->
          call("edit", "edit_file", %{
            path: "README.md",
            old_text: "Existing documentation",
            new_text: "Verified proposed documentation"
          })

        _ ->
          {:ok, %{content: "Proposed README update. Shell tests were not run.", tool_calls: []}}
      end
    end

    defp call(id, name, args),
      do:
        {:ok,
         %{
           content: nil,
           tool_calls: [
             %{id: id, name: name, arguments: Map.new(args, fn {k, v} -> {to_string(k), v} end)}
           ]
         }}
  end

  setup tags do
    root = Path.join(System.tmp_dir!(), "beam-mission-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "README.md"), "Existing documentation")
    File.write!(Path.join(root, "lib/example.ex"), "initial")
    {_, 0} = System.cmd("git", ["init", "-q"], cd: root)
    {_, 0} = System.cmd("git", ["add", "."], cd: root)

    {:ok, id} =
      BeamAgent.start_session(
        workspace_root: root,
        data_dir: Path.join(root, ".runtime"),
        provider: if(tags[:fix], do: FixProvider.id(), else: Provider.id()),
        approval_policy: if(tags[:fix], do: :auto, else: :ask),
        provider_options: [test_pid: self(), hold: tags[:hold] || false]
      )

    {:ok, pid} = BeamAgent.Names.pid(:documentation_mission, id)

    on_exit(fn ->
      BeamAgent.stop_session(id)
      File.rm_rf(root)
    end)

    %{root: root, id: id, pid: pid}
  end

  test "disabled by default; stable changes report once, have no tools, and never edit", ctx do
    assert {:ok, %{"status" => "disabled"}} = Documentation.command(ctx.id, "status")
    tick(ctx.pid)
    refute_receive {:mission_inference, _, _, _}

    assert :ok =
             Documentation.command(ctx.id, "start", %{
               "quiet_seconds" => 10,
               "cooldown_seconds" => 10
             })

    File.write!(Path.join(ctx.root, "lib/example.ex"), "new behavior")
    tick(ctx.pid)
    refute_receive {:mission_inference, _, _, _}
    age_candidate(ctx.pid)
    tick(ctx.pid)
    assert_receive {:mission_inference, _, messages, []}, 2_000
    assert inspect(messages) =~ "new behavior"

    assert eventually(fn ->
             tick(ctx.pid)

             match?(
               {:ok, %{"report" => %{"status" => "advisory"}}},
               Documentation.command(ctx.id, "status")
             )
           end)

    for _ <- 1..3, do: tick(ctx.pid)
    assert {:ok, %{"attempts" => 1}} = Documentation.command(ctx.id, "status")
    refute_receive {:mission_inference, _, _, _}
    assert File.read!(Path.join(ctx.root, "lib/example.ex")) == "new behavior"
    assert File.read!(Path.join(ctx.root, "README.md")) == "Existing documentation"
    {:ok, events} = BeamAgent.events(ctx.id)
    assert Enum.any?(events, &(&1["type"] == "documentation_mission_report"))
    assert :ok = Documentation.command(ctx.id, "dismiss")
    assert {:ok, %{"report" => nil, "attempts" => 1}} = Documentation.command(ctx.id, "status")
  end

  @tag fix: true
  test "a confirmed finding spawns one file-only agent in a snapshot-seeded worktree", ctx do
    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Fixture",
          "-c",
          "user.email=fixture@example.invalid",
          "-c",
          "core.hooksPath=/dev/null",
          "commit",
          "--no-gpg-sign",
          "-qm",
          "Fixture"
        ],
        cd: ctx.root
      )

    File.write!(Path.join(ctx.root, "lib/example.ex"), "uncommitted work from another editor")
    :ok = Documentation.command(ctx.id, "start")
    {:ok, context} = BeamAgent.Agent.construction_context(ctx.id)
    {:ok, snapshot} = Snapshot.capture(context, ["lib", "README.md"])

    report = %{
      "worker_id" => "observer-fixture",
      "fingerprint" => snapshot.fingerprint,
      "status" => "advisory",
      "content" =>
        "REVIEW_WARN\n\n1. **README update**\n- **Evidence:** lib/example.ex changed.\n- **Uncertainty:** Re-read full source.\n- **Next action:** Correct the README."
    }

    :sys.replace_state(ctx.pid, fn state ->
      %{state | data: Map.put(state.data, "report", report)}
    end)

    shown = BeamAgent.Missions.Report.present(report)
    [finding] = shown["findings"]
    opts = %{"report_id" => shown["id"], "finding_id" => finding["id"]}
    assert {:ok, _} = Documentation.command(ctx.id, "preview_fix", opts)
    assert {:ok, _} = Documentation.command(ctx.id, "prepare_fix", opts)
    assert {:ok, _} = Documentation.command(ctx.id, "prepare_fix", opts)

    assert eventually(fn ->
             {:ok, status} = Documentation.command(ctx.id, "status")
             Enum.any?(status["followups"], &(&1["status"] in ["completed", "failed"]))
           end)

    {:ok, status} = Documentation.command(ctx.id, "status")
    assert [followup] = status["followups"]
    assert followup["status"] == "completed", inspect(followup)
    assert status["status"] == "paused"
    assert status["attempts"] == 0
    assert_receive {:fix_tools, tools}
    refute "run_command" in tools
    refute "spawn_subagent" in tools
    assert File.read!(Path.join(ctx.root, "README.md")) == "Existing documentation"

    assert File.read!(Path.join(followup["worktree"], "README.md")) ==
             "Verified proposed documentation"

    assert File.read!(Path.join(followup["worktree"], "lib/example.ex")) ==
             "uncommitted work from another editor"

    assert followup["output"] =~ "not run"
    assert :ok = Documentation.command(ctx.id, "cancel_fix", %{"followup_id" => followup["id"]})
    assert {:ok, %{"followups" => [retained]}} = Documentation.command(ctx.id, "status")
    assert retained["status"] == "completed"
    assert retained["output"] == followup["output"]
    assert {:error, :not_found} = BeamAgent.Names.pid(:agent, followup["worker_id"])
    assert {:ok, _} = Documentation.command(ctx.id, "prepare_fix", opts)
    assert {:ok, delegations} = BeamAgent.worker_delegations(ctx.id)
    assert Enum.count(delegations, &(&1.worker_id == followup["worker_id"])) == 1
  end

  test "stale reports cannot launch follow-up inference", ctx do
    :ok = Documentation.command(ctx.id, "start")

    report = %{
      "status" => "advisory",
      "fingerprint" => "outdated",
      "content" => "A finding",
      "worker_id" => "old"
    }

    :sys.replace_state(ctx.pid, fn state ->
      %{state | data: Map.put(state.data, "report", report)}
    end)

    shown = BeamAgent.Missions.Report.present(report)
    opts = %{"report_id" => shown["id"], "finding_id" => hd(shown["findings"])["id"]}
    assert {:ok, _} = Documentation.command(ctx.id, "prepare_fix", opts)

    assert eventually(fn ->
             {:ok, status} = Documentation.command(ctx.id, "status")
             Enum.any?(status["followups"], &(&1["status"] == "failed"))
           end)

    assert {:ok, []} = BeamAgent.worker_delegations(ctx.id)
    refute_receive {:mission_inference, _, _, _}

    assert {:error, :report_replaced_or_stale} =
             Documentation.command(ctx.id, "prepare_fix", Map.put(opts, "report_id", "different"))
  end

  for action <- ["cancel_fix", "stop", "delete"] do
    @tag fix: true, hold: true
    test "#{action} stops an explicit follow-up and keeps the original intact", ctx do
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Fixture",
          "-c",
          "user.email=fixture@example.invalid",
          "-c",
          "core.hooksPath=/dev/null",
          "commit",
          "--no-gpg-sign",
          "-qm",
          "Fixture"
        ],
        cd: ctx.root
      )

      :ok = Documentation.command(ctx.id, "start")
      {:ok, context} = BeamAgent.Agent.construction_context(ctx.id)
      {:ok, snapshot} = Snapshot.capture(context, ["."])

      report = %{
        "status" => "advisory",
        "worker_id" => "fixture",
        "fingerprint" => snapshot.fingerprint,
        "content" => "Investigate a possible README gap"
      }

      :sys.replace_state(ctx.pid, fn state ->
        %{state | data: Map.put(state.data, "report", report)}
      end)

      shown = BeamAgent.Missions.Report.present(report)
      opts = %{"report_id" => shown["id"], "finding_id" => hd(shown["findings"])["id"]}
      {:ok, followup} = Documentation.command(ctx.id, "prepare_fix", opts)
      assert_receive {:fix_waiting, worker}, 5000

      assert :ok =
               Documentation.command(ctx.id, unquote(action), %{"followup_id" => followup["id"]})

      assert eventually(fn -> not Process.alive?(worker) end)

      assert {:ok, %{"followups" => [%{"status" => "cancelled"}]}} =
               Documentation.command(ctx.id, "status")

      assert File.read!(Path.join(ctx.root, "README.md")) == "Existing documentation"

      assert {:ok, %{"status" => "cancelled"}} =
               Documentation.command(ctx.id, "prepare_fix", opts)

      refute_receive {:fix_waiting, _}
    end
  end

  test "stop and delete cancel preparation, reject late activation and preserve artifacts", ctx do
    :ok = Documentation.command(ctx.id, "start")

    {:ok, task} =
      Task.Supervisor.start_child(BeamAgent.LocalStartupTasks, fn ->
        receive do
          :finish -> :ok
        end
      end)

    :sys.replace_state(ctx.pid, fn state ->
      item = %{"id" => "pending", "status" => "preparing", "worktree" => "/retained-fixture"}

      %{
        state
        | preparations: %{"pending" => {task, Process.monitor(task)}},
          data: Map.merge(state.data, %{"attempts" => 1, "followups" => %{"pending" => item}})
      }
    end)

    assert :ok = Documentation.command(ctx.id, "stop")
    refute Process.alive?(task)
    assert :sys.get_state(ctx.pid).timer == nil
    assert :sys.get_state(ctx.pid).preparations == %{}

    assert {:error, :followup_cancelled} =
             GenServer.call(
               ctx.pid,
               {:activate_fix, "pending", fn -> flunk("late activation") end}
             )

    assert :ok = Documentation.command(ctx.id, "delete")
    assert :ok = Documentation.command(ctx.id, "delete")
    assert {:ok, status} = Documentation.command(ctx.id, "status")
    assert status["status"] == "disabled"
    refute status["paths"]
    assert [%{"status" => "cancelled", "worktree" => "/retained-fixture"}] = status["followups"]
    Process.exit(ctx.pid, :kill)

    assert eventually(fn ->
             case BeamAgent.Names.pid(:documentation_mission, ctx.id) do
               {:ok, replacement} when replacement != ctx.pid -> true
               _ -> false
             end
           end)

    assert {:ok, recovered} = Documentation.command(ctx.id, "status")
    assert recovered["status"] == "disabled"
    assert recovered["followups"] == status["followups"]
    assert :ok = Documentation.command(ctx.id, "start")
    assert {:ok, %{"attempts" => 1}} = Documentation.command(ctx.id, "status")
    assert File.read!(Path.join(ctx.root, "README.md")) == "Existing documentation"
  end

  @tag hold: true
  test "stop cancels assessment and survives process recovery without polling", ctx do
    :ok = Documentation.command(ctx.id, "start", %{"quiet_seconds" => 10})
    File.write!(Path.join(ctx.root, "lib/example.ex"), "changed")
    tick(ctx.pid)
    age_candidate(ctx.pid)
    tick(ctx.pid)
    assert_receive {:mission_inference, worker, _, []}, 2000
    assert :ok = Documentation.command(ctx.id, "stop")
    assert eventually(fn -> not Process.alive?(worker) end)
    Process.exit(ctx.pid, :kill)

    assert eventually(fn ->
             case BeamAgent.Names.pid(:documentation_mission, ctx.id) do
               {:ok, replacement} when replacement != ctx.pid -> true
               _ -> false
             end
           end)

    assert {:ok, %{"status" => "stopped", "attempts" => 1}} =
             Documentation.command(ctx.id, "status")

    {:ok, replacement} = BeamAgent.Names.pid(:documentation_mission, ctx.id)
    assert :sys.get_state(replacement).timer == nil
    tick(replacement)
    refute_receive {:mission_inference, _, _, _}
    assert :ok = Documentation.command(ctx.id, "resume")
    assert :sys.get_state(replacement).timer != nil
  end

  @tag hold: true
  test "new edits reset the quiet period and results from changing work are withheld", ctx do
    :ok =
      Documentation.command(ctx.id, "start", %{"quiet_seconds" => 10, "cooldown_seconds" => 10})

    File.write!(Path.join(ctx.root, "lib/example.ex"), "first")
    tick(ctx.pid)
    age_candidate(ctx.pid)
    File.write!(Path.join(ctx.root, "lib/example.ex"), "second")
    tick(ctx.pid)
    refute_receive {:mission_inference, _, _, _}
    age_candidate(ctx.pid)
    tick(ctx.pid)
    assert_receive {:mission_inference, provider, _, []}, 2_000
    File.write!(Path.join(ctx.root, "README.md"), "Documentation being updated")
    send(provider, :finish)

    assert eventually(fn ->
             tick(ctx.pid)

             match?(
               {:ok, %{"report" => %{"status" => "stale"}}},
               Documentation.command(ctx.id, "status")
             )
           end)

    assert {:ok, %{"report" => %{"content" => content}}} = Documentation.command(ctx.id, "status")
    refute content =~ "Possible README gap"
  end

  @tag hold: true
  test "pause cancels inference and restart stays paused without replaying paid work", ctx do
    :ok = Documentation.command(ctx.id, "start", %{"quiet_seconds" => 10})
    File.write!(Path.join(ctx.root, "lib/example.ex"), "changed")
    tick(ctx.pid)
    age_candidate(ctx.pid)
    tick(ctx.pid)
    assert_receive {:mission_inference, provider, _, []}, 2_000
    assert :ok = Documentation.command(ctx.id, "pause")
    assert eventually(fn -> not Process.alive?(provider) end)
    Process.exit(ctx.pid, :kill)

    assert eventually(fn ->
             case BeamAgent.Names.pid(:documentation_mission, ctx.id) do
               {:ok, replacement} when replacement != ctx.pid -> true
               _ -> false
             end
           end)

    assert {:ok, %{"status" => "paused", "attempts" => 1, "reason" => "runtime_restarted"}} =
             Documentation.command(ctx.id, "status")

    {:ok, replacement} = BeamAgent.Names.pid(:documentation_mission, ctx.id)
    tick(replacement)
    refute_receive {:mission_inference, _, _, _}
  end

  test "finite allowance pauses after one result and runtime protocol exposes the mission", ctx do
    {:ok, client} = BeamAgent.Runtime.connect(ctx.id)
    on_exit(fn -> BeamAgent.Runtime.disconnect(client) end)

    response =
      BeamAgent.Runtime.JSONProtocol.dispatch(client, %{
        version: 1,
        command: "documentation_mission",
        arguments: %{"action" => "start", "max_assessments" => 1, "quiet_seconds" => 10}
      })

    assert response.ok
    File.write!(Path.join(ctx.root, "lib/example.ex"), "changed")
    tick(ctx.pid)
    age_candidate(ctx.pid)
    tick(ctx.pid)
    assert_receive {:mission_inference, _, _, []}, 2_000

    assert eventually(fn ->
             tick(ctx.pid)

             match?(
               {:ok, %{"status" => "paused", "reason" => "assessment_limit_reached"}},
               Documentation.command(ctx.id, "status")
             )
           end)

    assert {:error, :mission_unconfigured_or_limit_reached} =
             Documentation.command(ctx.id, "resume")
  end

  test "pending delegated work defers assessment even when the coordinating goal is idle", ctx do
    :ok = Documentation.command(ctx.id, "start", %{"quiet_seconds" => 10})
    File.write!(Path.join(ctx.root, "lib/example.ex"), "changed")
    tick(ctx.pid)
    age_candidate(ctx.pid)
    {:ok, handle} = BeamAgent.spawn_worker(ctx.id, %{goal: "Another worker is preparing work"})
    tick(ctx.pid)
    refute_receive {:mission_inference, _, _, _}
    assert :sys.get_state(ctx.pid).candidate == nil
    :ok = BeamAgent.cancel_delegation(ctx.id, handle.delegation_id)
    tick(ctx.pid)
    assert :sys.get_state(ctx.pid).candidate != nil
    refute_receive {:mission_inference, _, _, _}
  end

  test "invalid scope and escaping symlinks fail closed before inference", ctx do
    assert {:error, :invalid_mission_options} =
             Documentation.command(ctx.id, "start", %{"paths" => ["../outside"]})

    assert {:error, :invalid_mission_options} =
             Documentation.command(ctx.id, "start", %{"quiet_seconds" => 0})

    File.rm!(Path.join(ctx.root, "lib/example.ex"))
    File.ln_s!("/etc/hosts", Path.join(ctx.root, "lib/example.ex"))
    assert {:error, :mission_snapshot_unavailable} = Documentation.command(ctx.id, "start")
    {:ok, context} = BeamAgent.Agent.construction_context(ctx.id)

    context = %{
      context
      | capability_envelope: BeamAgent.CapabilityEnvelope.root(%{tools: [], paths: []})
    }

    assert {:error, _} = Snapshot.capture(context, ["README.md"])
    refute_receive {:mission_inference, _, _, _}
  end

  test "scope browser lists only readable tracked paths and never escapes the workspace", ctx do
    File.mkdir_p!(Path.join(ctx.root, "docs with spaces/nested"))
    File.write!(Path.join(ctx.root, "docs with spaces/nested/guide.md"), "guide")
    File.write!(Path.join(ctx.root, "untracked.md"), "not in the index")
    File.ln_s!("/etc/hosts", Path.join(ctx.root, "outside-link"))
    System.cmd("git", ["add", "docs with spaces", "outside-link"], cd: ctx.root)
    {:ok, client} = BeamAgent.Runtime.connect(ctx.id)
    on_exit(fn -> BeamAgent.Runtime.disconnect(client) end)

    response =
      BeamAgent.Runtime.JSONProtocol.dispatch(client, %{
        version: 1,
        command: "documentation_mission",
        arguments: %{"action" => "browse"}
      })

    assert response.ok
    {:ok, context} = BeamAgent.Agent.construction_context(ctx.id)
    assert response.result.workspace == context.workspace_root

    assert Enum.map(response.result.entries, & &1.path) == [
             "docs with spaces",
             "lib",
             "README.md"
           ]

    assert {:ok, %{parent: "docs with spaces", entries: [%{name: "guide.md", directory: false}]}} =
             Documentation.command(ctx.id, "browse", %{"path" => "docs with spaces/nested"})

    for path <- ["../", "/etc", ".git", "lib/../docs", "bad\npath", 42] do
      assert {:error, :invalid_mission_path} =
               Documentation.command(ctx.id, "browse", %{"path" => path})
    end

    {:ok, context} = BeamAgent.Agent.construction_context(ctx.id)

    restricted = %{
      context
      | capability_envelope:
          BeamAgent.CapabilityEnvelope.root(%{
            tools: ["git_inspect", "read_file"],
            git_operations: ["status"],
            paths: ["README.md"]
          })
    }

    assert {:ok, %{entries: [%{path: "README.md"}]}} = Snapshot.browse(restricted, ".")
    refute_receive {:mission_inference, _, _, _}
    assert {:ok, %{"status" => "disabled"}} = Documentation.command(ctx.id, "status")
  end

  test "changing paused scope records a baseline without resetting allowance or resuming", ctx do
    assert :ok = Documentation.command(ctx.id, "start", %{"paths" => ["."]})

    assert {:error, :pause_mission_before_changing_scope} =
             Documentation.command(ctx.id, "configure", %{"paths" => ["lib"]})

    assert :ok = Documentation.command(ctx.id, "pause")

    :sys.replace_state(ctx.pid, fn state ->
      %{
        state
        | data:
            Map.merge(state.data, %{
              "attempts" => 3,
              "last_attempt_at" => 123,
              "report" => %{"content" => "old scope"}
            })
      }
    end)

    assert {:error, :invalid_mission_options} =
             Documentation.command(ctx.id, "configure", %{"paths" => ["../outside"]})

    assert :ok = Documentation.command(ctx.id, "configure", %{"paths" => ["README.md"]})

    assert {:ok,
            %{
              "status" => "paused",
              "attempts" => 3,
              "last_attempt_at" => 123,
              "paths" => ["README.md"],
              "report" => nil
            }} = Documentation.command(ctx.id, "status")

    assert Map.keys(:sys.get_state(ctx.pid).data["baseline"]) == ["README.md"]

    assert {:error, :mission_unconfigured_or_limit_reached} =
             Documentation.command(ctx.id, "resume")

    tick(ctx.pid)
    refute_receive {:mission_inference, _, _, _}
  end

  test "CLI controls the existing owner through authenticated discovery without creating a session",
       ctx do
    previous = Application.get_env(:beam_agent, :discovery_dir)
    directory = Path.join(ctx.root, "live")
    Application.put_env(:beam_agent, :discovery_dir, directory)
    {:ok, profile} = BeamAgent.CLI.Config.profile("echo", nil, nil, nil)

    stored =
      BeamAgent.CLI.Config.defaults()
      |> Map.put("active_profile", "echo")
      |> Map.put("profiles", %{"echo" => profile})

    {:ok, config} = BeamAgent.CLI.Config.runtime(stored)
    config = Map.put(config, "workspace_root", ctx.root)

    start_supervised!(
      {BeamAgent.LocalEndpoint,
       [
         session_id: ctx.id,
         config: config,
         config_path: Path.join(ctx.root, "unused.json"),
         directory: directory
       ]}
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:beam_agent, :discovery_dir, previous),
        else: Application.delete_env(:beam_agent, :discovery_dir)
    end)

    for action <- ["start", "status", "pause", "resume", "dismiss"] do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert BeamAgent.CLI.run(["mission", ctx.id, action]) == 0
        end)

      if action == "status", do: assert(output =~ "observing")
    end

    {:ok, client} = BeamAgent.Runtime.connect(ctx.id)
    BeamAgent.Runtime.disconnect(client)
    assert {:ok, %{"status" => "observing"}} = Documentation.command(ctx.id, "status")
    assert {:ok, %{sessions: [%{"session_id" => id}]}} = BeamAgent.LocalDiscovery.list(directory)
    assert id == ctx.id
  end

  @tag hold: true
  test "an observer crash cancels its in-flight worker and does not replay it", ctx do
    :ok = Documentation.command(ctx.id, "start", %{"quiet_seconds" => 10})
    File.write!(Path.join(ctx.root, "lib/example.ex"), "changed")
    tick(ctx.pid)
    age_candidate(ctx.pid)
    tick(ctx.pid)
    assert_receive {:mission_inference, provider, _, []}, 2_000
    Process.exit(ctx.pid, :kill)
    assert eventually(fn -> not Process.alive?(provider) end)

    assert eventually(fn ->
             match?(
               {:ok, %{"status" => "paused", "attempts" => 1}},
               Documentation.command(ctx.id, "status")
             )
           end)

    refute_receive {:mission_inference, _, _, _}
  end

  test "one-command launcher publishes an idle echo owner and cleans up on normal stop", ctx do
    previous = Application.get_env(:beam_agent, :discovery_dir)
    directory = Path.join(ctx.root, "launcher-live")
    Application.put_env(:beam_agent, :discovery_dir, directory)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:beam_agent, :discovery_dir, previous),
        else: Application.delete_env(:beam_agent, :discovery_dir)
    end)

    {:ok, profile} = BeamAgent.CLI.Config.profile("echo", nil, nil, nil)

    stored =
      BeamAgent.CLI.Config.defaults()
      |> Map.put("active_profile", "echo")
      |> Map.put("profiles", %{"echo" => profile})
      |> Map.put("data_dir", Path.join(ctx.root, "launcher-runtime"))

    path = Path.join(ctx.root, "launcher-config.json")
    File.write!(path, JSON.encode!(stored))

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        task =
          Task.async(fn ->
            BeamAgent.CLI.run(["mission", "docs", "--workspace", ctx.root, "--config", path])
          end)

        assert eventually(fn ->
                 match?({:ok, %{sessions: [_]}}, BeamAgent.LocalDiscovery.list(directory))
               end)

        {:ok, %{sessions: [%{"session_id" => id}]}} = BeamAgent.LocalDiscovery.list(directory)

        assert {:ok, %{"status" => "observing", "attempts" => 0}} =
                 Documentation.command(id, "status")

        send(task.pid, :stop)
        assert Task.await(task, 5_000) == 0
        assert {:ok, %{sessions: []}} = BeamAgent.LocalDiscovery.list(directory)
        assert {:error, :not_found} = BeamAgent.agent_pid(id)
      end)

    assert output =~ "Documentation mission session-"
    assert output =~ "Read-only"
    refute_receive {:mission_inference, _, _, _}
  end

  defp tick(pid) do
    send(pid, :tick)
    :sys.get_state(pid)
  end

  defp age_candidate(pid),
    do: :sys.replace_state(pid, &%{&1 | since: System.system_time(:second) - 20})

  defp eventually(fun, remaining \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, remaining) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, remaining - 1)
        )
  end
end
