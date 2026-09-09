defmodule BeamAgent.AutomaticSpecializationTest do
  use ExUnit.Case, async: false

  alias BeamAgent.{AutomaticSpecialization, ModelEndpoint, WorkPlanningPolicy}

  defmodule Provider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :automatic_specialization_test

    def complete(messages, tools, opts) do
      observer = Process.whereis(:specialization_observer)
      results = Enum.filter(messages, &(&1.role == :tool))

      review? =
        Enum.any?(
          messages,
          &(&1.role == :user and String.starts_with?(&1.content, "Review the current uncommitted"))
        )

      cond do
        opts[:parent_session_id] && review? ->
          send(observer, {:review_model, opts[:model]})

          {:ok, _} =
            opts[:dynamic_tool_executor].(%{
              id: "review-read",
              name: "read_file",
              arguments: %{"path" => "frontend.txt"}
            })

          {:ok, %{content: "REVIEW_PASS", tool_calls: []}}

        opts[:parent_session_id] ->
          send(
            observer,
            {:helper_started, self(), opts[:session_id], opts[:model], Enum.map(tools, & &1.name)}
          )

          receive do
            :finish ->
              {:ok,
               %{content: "README.md: fixture convention confirmed from file", tool_calls: []}}

            :fail ->
              {:error, :helper_unavailable}
          after
            10_000 -> {:error, :test_timeout}
          end

        results == [] ->
          send(
            observer,
            {:owner_started, self(), opts[:model], Enum.map(tools, & &1.name),
             opts[:system_prompt]}
          )

          receive do
            :finish ->
              call("write", "create_file", %{"path" => "frontend.txt", "content" => "implemented"})

            {:native, delegation_id} ->
              executor = opts[:dynamic_tool_executor]

              {:ok, findings} =
                executor.(%{
                  id: "collect",
                  name: "await_subagent",
                  arguments: %{"delegation_id" => delegation_id, "timeout_ms" => 0}
                })

              send(observer, {:native_findings, findings})

              {:ok, _} =
                executor.(%{
                  id: "write",
                  name: "create_file",
                  arguments: %{"path" => "frontend.txt", "content" => "implemented"}
                })

              {:ok, %{content: "Implemented frontend.txt", tool_calls: []}}
          after
            10_000 -> {:error, :test_timeout}
          end

        true ->
          send(observer, {:owner_context, opts[:system_prompt]})
          {:ok, %{content: "Implemented frontend.txt", tool_calls: []}}
      end
    end

    defp call(id, name, args),
      do: {:ok, %{content: nil, tool_calls: [%{id: id, name: name, arguments: args}]}}
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(Provider)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "specialization-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(workspace, ".beam_agent"))
    File.write!(Path.join(workspace, "README.md"), "fixture convention")

    File.write!(
      Path.join(workspace, ".beam_agent/verification.json"),
      JSON.encode!(%{
        version: 1,
        checks: [%{id: "artifact", command: "test -f frontend.txt"}]
      })
    )

    Process.register(self(), :specialization_observer)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: Path.join(root, "runtime")}
  end

  test "complex automatic work runs cheap helpers concurrently while retaining one capable writer",
       ctx do
    id = start_session(ctx, 2)
    task = Task.async(fn -> BeamAgent.ask(id, "Implement a Phoenix frontend") end)
    assert_receive {:owner_started, owner, "capable", owner_tools, initial}, 5_000
    assert "create_file" in owner_tools
    assert initial =~ "single implementation owner"
    assert_receive {:helper_started, first, first_id, "cheap-1", first_tools}, 5_000
    assert_receive {:helper_started, second, second_id, "cheap-2", second_tools}, 5_000
    # All three invocations are alive before any is allowed to finish.
    for {pid, child_id, tools} <- [
          {first, first_id, first_tools},
          {second, second_id, second_tools}
        ] do
      assert Process.alive?(pid)
      assert "read_file" in tools

      refute Enum.any?(
               ~w(create_file edit_file apply_patch run_command spawn_subagent delegate_tasks),
               &(&1 in tools)
             )

      {:ok, spec} = BeamAgent.agent_spec(child_id)
      assert spec.resources.limits.wall_time_ms == 90_000
      assert spec.resources.limits.model_tokens == 16_000
      assert spec.resources.context_window_tokens == 8_192

      assert {:error, _} =
               BeamAgent.CapabilityEnvelope.authorize(spec.effective_capabilities, %{
                 tools: "create_file"
               })

      send(pid, :finish)
    end

    {:ok, delegations} = BeamAgent.worker_delegations(id)

    for delegation <- delegations do
      assert {:ok, _} = BeamAgent.await_delegation(id, delegation.id, 5_000)
    end

    send(owner, :finish)
    assert {:ok, _} = Task.await(task, 10_000)
    assert_receive {:owner_context, with_findings}
    assert with_findings =~ "fixture convention confirmed"
    assert File.read!(Path.join(ctx.workspace, "frontend.txt")) == "implemented"
    {:ok, blocks} = BeamAgent.work_blocks(id)
    assert Enum.any?(blocks, &(&1.role == "Implementation owner" and &1.model == "capable"))
    assert Enum.count(blocks, &(&1.owner_worker_id == id and &1.worker_id != id)) == 2
    assert Enum.any?(blocks, &is_binary(&1.assignment_reason))
    {:ok, status} = BeamAgent.Goal.status(id)
    assert status.last_work.artifact.verification.status == :passed
  end

  test "native tool conversations can collect the preassigned helper by handle", ctx do
    id = start_session(ctx, 1)
    task = Task.async(fn -> BeamAgent.ask(id, "Implement a Phoenix frontend") end)
    assert_receive {:owner_started, owner, _, _, _}, 5_000
    assert_receive {:helper_started, helper, _, _, _}, 5_000
    send(helper, :finish)
    {:ok, [delegation]} = BeamAgent.worker_delegations(id)
    assert {:ok, _} = BeamAgent.await_delegation(id, delegation.id, 5_000)
    send(owner, {:native, delegation.id})
    assert {:ok, _} = Task.await(task, 10_000)
    assert_receive {:native_findings, %{is_error: false, content: findings}}
    assert findings =~ "fixture convention confirmed"
  end

  test "a pinned owner still gets bounded helpers in automatic team mode", ctx do
    id =
      start_session(ctx, 1,
        model_strategy: :manual,
        team_mode: :auto,
        provider_options: [model: "capable"]
      )

    task = Task.async(fn -> BeamAgent.ask(id, "Implement a Phoenix frontend") end)
    assert_receive {:owner_started, owner, "capable", owner_tools, _}, 5_000
    assert "create_file" in owner_tools
    assert_receive {:helper_started, helper, _, "cheap-1", helper_tools}, 5_000
    refute "create_file" in helper_tools
    send(helper, :finish)
    send(owner, :finish)
    assert {:ok, _} = Task.await(task, 10_000)
  end

  test "automatic model routing can run solo", ctx do
    id = start_session(ctx, 1, model_strategy: :auto, team_mode: :solo)
    task = Task.async(fn -> BeamAgent.ask(id, "Implement a Phoenix frontend") end)
    assert_receive {:owner_started, owner, "capable", _, _}, 5_000
    refute_receive {:helper_started, _, _, _, _}, 100
    send(owner, :finish)
    assert {:ok, _} = Task.await(task, 10_000)
  end

  test "optional helper failure does not fail the implementation", ctx do
    id = start_session(ctx, 1)
    task = Task.async(fn -> BeamAgent.ask(id, "Implement a Phoenix frontend") end)
    assert_receive {:owner_started, owner, _, _, _}, 5_000
    assert_receive {:helper_started, helper, _, _, _}, 5_000
    send(helper, :fail)
    {:ok, [delegation]} = BeamAgent.worker_delegations(id)
    assert {:error, _} = BeamAgent.await_delegation(id, delegation.id, 5_000)
    send(owner, :finish)
    assert {:ok, _} = Task.await(task, 10_000)
  end

  test "automatic assistance respects a session-level delegation denial", ctx do
    id = start_session(ctx, 1, tool_permissions: %{"spawn_subagent" => :deny})
    task = Task.async(fn -> BeamAgent.ask(id, "Implement a Phoenix frontend") end)
    assert_receive {:owner_started, owner, _, _, _}, 5_000
    refute_receive {:helper_started, _, _, _, _}
    assert {:ok, []} = BeamAgent.worker_delegations(id)
    send(owner, :finish)
    assert {:ok, _} = Task.await(task, 10_000)
  end

  test "mandatory review stays capable when the only alternate is a cheap investigator", ctx do
    id = start_session(ctx, 1, completion_review: :required)
    task = Task.async(fn -> BeamAgent.ask(id, "Implement a Phoenix frontend") end)
    assert_receive {:owner_started, owner, _, _, _}, 5_000
    assert_receive {:helper_started, helper, child_id, _, _}, 5_000
    {:ok, events} = BeamAgent.events(child_id)
    assert Enum.count(events, &(&1["type"] == "tool_result" and &1["data"]["step"] == 0)) == 2
    send(helper, :finish)
    send(owner, :finish)
    assert {:ok, _} = Task.await(task, 10_000)
    assert_receive {:review_model, "capable"}
  end

  test "owner monitor and resource deadline reclaim actors even without wrapper cleanup", ctx do
    id = start_session(ctx, 1)

    for stop <- [:owner_crash, :deadline] do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> Process.exit(owner, :kill) end)
      opts = if stop == :deadline, do: [resource_limits: %{wall_time_ms: 500}], else: []

      {:ok, handle} =
        BeamAgent.spawn_worker(
          id,
          %{
            goal: "Inspect README.md",
            template: "researcher",
            model_requirements: %{preferred_endpoint_id: "cheap-1"}
          },
          opts
        )

      {:ok, child} = BeamAgent.Names.pid(:session_supervisor, handle.worker_id)
      monitor = Process.monitor(child)

      assert {:error, :invalid_delegation_owner} =
               BeamAgent.start_worker(handle, "Inspect README.md", owner: :invalid)

      assert :ok = BeamAgent.start_worker(handle, "Inspect README.md", owner: owner)
      assert_receive {:helper_started, _, _, _, _}, 5_000
      if stop == :owner_crash, do: Process.exit(owner, :kill)
      assert {:error, _} = BeamAgent.await_worker(handle, 5_000)
      assert_receive {:DOWN, ^monitor, :process, ^child, _}, 5_000
      send(owner, :stop)
    end
  end

  test "finishing or cancelling the owner reclaims pending helpers", ctx do
    for action <- [:finish, :cancel] do
      id = start_session(ctx, 1)
      task = Task.async(fn -> BeamAgent.ask(id, "Implement a Phoenix frontend") end)
      assert_receive {:owner_started, owner, _, _, _}, 5_000
      assert_receive {:helper_started, _helper, child_id, _, _}, 5_000
      {:ok, child} = BeamAgent.Names.pid(:session_supervisor, child_id)
      monitor = Process.monitor(child)
      if action == :finish, do: send(owner, :finish), else: BeamAgent.Agent.cancel(id)
      Task.await(task, 10_000)
      assert_receive {:DOWN, ^monitor, :process, ^child, _}, 5_000
      {:ok, [delegation]} = BeamAgent.worker_delegations(id)
      assert delegation.status == :cancelled
      BeamAgent.stop_session(id)
    end
  end

  test "small work, manual mode, explicit teams, and child workers are not automatically expanded" do
    context = %{
      model_strategy: :auto,
      parent_session_id: nil,
      capability_envelope: BeamAgent.CapabilityEnvelope.root()
    }

    for {prompt, changes} <- [
          {"Fix a typo", %{}},
          {"Implement a Phoenix frontend", %{model_strategy: :manual}},
          {"Implement a Phoenix frontend", %{parent_session_id: "parent"}},
          {"Use multiple providers to implement a Phoenix frontend", %{}}
        ] do
      ctx = Map.merge(context, changes)

      planning =
        WorkPlanningPolicy.decide(prompt, endpoints(2), model_strategy: ctx.model_strategy)

      refute AutomaticSpecialization.applicable?(ctx, planning)
    end
  end

  test "candidate selection excludes the owner, unhealthy and unknown-cost endpoints" do
    [owner, cheap] = endpoints(1)
    unhealthy = %{cheap | id: "unhealthy", health: %{status: :unavailable}}
    unknown = %{cheap | id: "unknown", claims: %{cheap.claims | cost_hint: :unknown}}

    assert [^cheap] =
             AutomaticSpecialization.candidates([owner, cheap, unhealthy, unknown], owner.id)

    assert [] = AutomaticSpecialization.candidates([cheap], cheap.id)
  end

  defp start_session(ctx, count, opts \\ []) do
    {:ok, id} =
      BeamAgent.start_session(
        Keyword.merge(
          [
            workspace_root: ctx.workspace,
            data_dir: ctx.data_dir,
            provider: :automatic_specialization_test,
            provider_profile: "owner",
            model_strategy: :auto,
            model_endpoints: Enum.map(endpoints(count), &Map.from_struct/1),
            approval_policy: :auto,
            completion_review: :external
          ],
          opts
        )
      )

    on_exit(fn -> BeamAgent.stop_session(id) end)
    id
  end

  defp endpoints(count) do
    Enum.map(["owner" | Enum.map(1..count, &"cheap-#{&1}")], fn id ->
      {:ok, endpoint} =
        ModelEndpoint.new(%{
          id: id,
          provider: :automatic_specialization_test,
          provider_module: Provider,
          model: if(id == "owner", do: "capable", else: id),
          claims: %{
            cost_hint: if(id == "owner", do: :high, else: :free),
            locality: if(id == "owner", do: :remote, else: :local),
            capabilities:
              if(id == "owner",
                do: [:text_generation, :tool_use, :reasoning],
                else: [:text_generation, :tool_use]
              )
          }
        })

      endpoint
    end)
  end
end
