defmodule BeamAgent.HarnessCapabilitiesTest do
  use ExUnit.Case, async: false

  alias BeamAgent.CLI.TurnRunner

  alias BeamAgent.Tools.{
    ApplyPatch,
    CreateFile,
    EditFile,
    FileDiagnostics,
    ReadFile,
    RunCommand,
    SearchFiles
  }

  defmodule FileAgentProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :file_agent_test

    @impl true
    def complete(messages, _tools, _options) do
      case Enum.find(Enum.reverse(messages), &(&1.role == :tool and &1.name == "create_file")) do
        nil ->
          {:ok,
           %{
             content: nil,
             tool_calls: [
               %{
                 id: "create-call",
                 name: "create_file",
                 arguments: %{"path" => "created-by-agent.txt", "content" => "from the agent\n"}
               }
             ]
           }}

        tool_result ->
          {:ok, %{content: "create_file returned: #{tool_result.content}", tool_calls: []}}
      end
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(FileAgentProvider)
    :ok
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-harness-test-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    {:ok, workspace} = BeamAgent.Workspace.canonical_root(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace, data_dir: data_dir}
  end

  test "workspace resolution rejects lexical and symlink escapes", context do
    outside = Path.join(context.root, "outside")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(context.workspace, "escape"))

    assert {:error, {:workspace_escape, _path}} =
             BeamAgent.Workspace.resolve(context.workspace, "../outside/secret.txt")

    assert {:error, {:workspace_escape, _path}} =
             BeamAgent.Workspace.resolve(context.workspace, "escape/secret.txt")

    assert {:error, {:workspace_path_must_be_relative, _path}} =
             BeamAgent.Workspace.resolve(context.workspace, "/tmp/secret.txt")
  end

  test "language-aware diagnostics report syntax failures without a model", context do
    File.write!(Path.join(context.workspace, "broken.ex"), "defmodule Broken do\n  def x(\nend\n")

    assert {:ok, encoded} =
             FileDiagnostics.execute(%{"path" => "broken.ex"}, %{
               workspace_root: context.workspace
             })

    result = JSON.decode!(encoded)
    assert result["count"] == 1
    assert hd(result["diagnostics"])["severity"] == "error"
  end

  test "durable sessions cannot be resumed against a different workspace", context do
    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo
      )

    :ok = BeamAgent.stop_session(session_id)
    other_workspace = Path.join(context.root, "other-workspace")
    File.mkdir_p!(other_workspace)

    assert {:error, reason} =
             BeamAgent.resume_session(session_id,
               data_dir: context.data_dir,
               workspace_root: other_workspace,
               provider: :echo
             )

    assert inspect(reason) =~ "workspace_mismatch"
    assert inspect(reason) =~ context.workspace
  end

  test "read and edit tools enforce an observed file version", context do
    path = Path.join(context.workspace, "sample.txt")
    File.write!(path, "alpha\nbeta\n")
    File.chmod!(path, 0o755)
    tool_context = %{workspace_root: context.workspace}

    assert {:ok, read_result} = ReadFile.execute(%{"path" => "sample.txt"}, tool_context)
    {:ok, read_data} = JSON.decode(read_result)
    assert read_data["content"] == "alpha\nbeta\n"

    assert {:error, {:stale_file, "wrong", _actual}} =
             EditFile.execute(
               %{
                 "path" => "sample.txt",
                 "old_text" => "beta",
                 "new_text" => "gamma",
                 "expected_sha256" => "wrong"
               },
               tool_context
             )

    assert {:ok, _result} =
             EditFile.execute(
               %{
                 "path" => "sample.txt",
                 "old_text" => "beta",
                 "new_text" => "gamma",
                 "expected_sha256" => read_data["sha256"]
               },
               tool_context
             )

    assert File.read!(path) == "alpha\ngamma\n"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o755
  end

  test "the session actor owns file versions so the model does not pass hashes", context do
    path = Path.join(context.workspace, "runtime-versioned.txt")
    File.write!(path, "before\n")

    assert {:ok, session_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    tool_context = %{workspace_root: context.workspace, session_id: session_id}
    assert {:ok, encoded} = ReadFile.execute(%{"path" => "runtime-versioned.txt"}, tool_context)
    assert JSON.decode!(encoded)["numbered_content"] == "1: before\n2: "

    assert {:ok, _result} =
             EditFile.execute(
               %{
                 "path" => "runtime-versioned.txt",
                 "old_text" => "before",
                 "new_text" => "after"
               },
               tool_context
             )

    assert File.read!(path) == "after\n"
  end

  test "create and search tools stay within the workspace", context do
    tool_context = %{workspace_root: context.workspace}

    assert {:ok, _result} =
             CreateFile.execute(
               %{"path" => "lib/new.ex", "content" => "defmodule NewModule do\nend\n"},
               tool_context
             )

    assert {:error, {:file_exists, "lib/new.ex"}} =
             CreateFile.execute(
               %{"path" => "lib/new.ex", "content" => "overwrite"},
               tool_context
             )

    assert {:ok, search_result} =
             SearchFiles.execute(%{"query" => "NewModule"}, tool_context)

    {:ok, search_data} = JSON.decode(search_result)
    assert Enum.any?(search_data["matches"], &String.contains?(&1, "lib/new.ex:1"))
  end

  test "search reports malformed regular expressions as ripgrep failures", context do
    assert {:error, {:ripgrep_failed, 2, output}} =
             SearchFiles.execute(%{"query" => "[", "path" => "."}, %{
               workspace_root: context.workspace
             })

    assert is_binary(output)
    assert output != ""
  end

  test "patch-native edits apply all hunks atomically against one observed version", context do
    path = Path.join(context.workspace, "multi.txt")
    File.write!(path, "alpha\nbeta\ngamma\n")
    content = File.read!(path)

    assert {:ok, encoded} =
             ApplyPatch.execute(
               %{
                 "path" => "multi.txt",
                 "expected_sha256" => BeamAgent.Tools.FileSupport.sha256(content),
                 "hunks" => [
                   %{"old_text" => "alpha", "new_text" => "one"},
                   %{"old_text" => "gamma", "new_text" => "three"}
                 ]
               },
               %{workspace_root: context.workspace}
             )

    assert JSON.decode!(encoded)["hunks_applied"] == 2
    assert File.read!(path) == "one\nbeta\nthree\n"

    assert {:error, :patch_text_not_found} =
             ApplyPatch.execute(
               %{
                 "path" => "multi.txt",
                 "expected_sha256" => BeamAgent.Tools.FileSupport.sha256(File.read!(path)),
                 "hunks" => [
                   %{"old_text" => "one", "new_text" => "changed"},
                   %{"old_text" => "missing", "new_text" => "never-written"}
                 ]
               },
               %{workspace_root: context.workspace}
             )

    assert File.read!(path) == "one\nbeta\nthree\n"
  end

  test "a risky tool waits for a session-owned approval before executing", context do
    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :file_agent_test,
        approval_policy: :ask,
        approval_handler: self()
      )

    parent = self()

    result =
      TurnRunner.run(session_id, "create the file", 5_000, fn request ->
        send(parent, {:approval_seen, request})
        refute File.exists?(Path.join(context.workspace, "created-by-agent.txt"))
        :allow_once
      end)

    assert {:ok, answer} = result
    assert answer =~ "create_file returned"
    assert_receive {:approval_seen, %{tool: "create_file", access: :write}}
    assert File.read!(Path.join(context.workspace, "created-by-agent.txt")) == "from the agent\n"

    {:ok, events} = BeamAgent.events(session_id)
    assert Enum.any?(events, &(&1["type"] == "tool_approval_requested"))
    assert Enum.any?(events, &(&1["type"] == "tool_approval_granted"))
  end

  test "denied approval becomes a model-visible tool error without executing", context do
    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :file_agent_test,
        approval_policy: :ask,
        approval_handler: self()
      )

    assert {:ok, answer} = TurnRunner.run(session_id, "create the file", 5_000, fn _ -> :deny end)
    assert answer =~ "tool_denied"
    refute File.exists?(Path.join(context.workspace, "created-by-agent.txt"))

    {:ok, events} = BeamAgent.events(session_id)
    assert Enum.any?(events, &(&1["type"] == "tool_denied"))

    assert Enum.any?(events, fn event ->
             event["type"] == "tool_result" and event["data"]["is_error"] == true and
               event["data"]["error"]["code"] == "tool_denied"
           end)
  end

  test "a pending approval follows a newly attached interface", context do
    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo,
        approval_policy: :ask,
        approval_handler: self()
      )

    authorization =
      Task.async(fn ->
        BeamAgent.Session.ToolPolicy.authorize(
          session_id,
          "create_file",
          %{"path" => "pending.txt"},
          :write
        )
      end)

    assert_receive {:beam_agent_approval, first_request}
    owner = self()

    replacement =
      spawn(fn ->
        receive do
          message ->
            send(owner, {:replacement_handler, message})

            receive do
              :stop -> :ok
            end
        end
      end)

    assert :ok = BeamAgent.set_approval_handler(session_id, replacement)

    assert_receive {:replacement_handler, {:beam_agent_approval, repeated_request}}
    assert repeated_request.approval_id == first_request.approval_id
    assert :ok = BeamAgent.respond_approval(session_id, repeated_request.approval_id, :deny)
    assert Task.await(authorization) == {:error, {:tool_denied, "create_file"}}
    send(replacement, :stop)
  end

  test "an approval requested without an interface waits until one attaches", context do
    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo,
        approval_policy: :ask
      )

    authorization =
      Task.async(fn ->
        BeamAgent.Session.ToolPolicy.authorize(
          session_id,
          "create_file",
          %{"path" => "patient.txt"},
          :write
        )
      end)

    assert Task.yield(authorization, 50) == nil
    assert :ok = BeamAgent.set_approval_handler(session_id, self())
    assert_receive {:beam_agent_approval, request}
    assert :ok = BeamAgent.respond_approval(session_id, request.approval_id, :deny)
    assert Task.await(authorization) == {:error, {:tool_denied, "create_file"}}
  end

  test "a pending approval survives interface loss and waits for reconnection", context do
    owner = self()

    first_handler =
      spawn(fn ->
        receive do
          message ->
            send(owner, {:first_handler, message})

            receive do
              :stop -> :ok
            end
        end
      end)

    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo,
        approval_policy: :ask,
        approval_handler: first_handler
      )

    authorization =
      Task.async(fn ->
        BeamAgent.Session.ToolPolicy.authorize(
          session_id,
          "create_file",
          %{"path" => "patient.txt"},
          :write
        )
      end)

    assert_receive {:first_handler, {:beam_agent_approval, first_request}}
    send(first_handler, :stop)
    monitor = Process.monitor(first_handler)
    assert_receive {:DOWN, ^monitor, :process, ^first_handler, _reason}
    assert Task.yield(authorization, 50) == nil

    replacement =
      spawn(fn ->
        receive do
          message -> send(owner, {:replacement_handler, message})
        end
      end)

    assert :ok = BeamAgent.set_approval_handler(session_id, replacement)
    assert_receive {:replacement_handler, {:beam_agent_approval, repeated_request}}
    assert repeated_request.approval_id == first_request.approval_id
    assert :ok = BeamAgent.respond_approval(session_id, repeated_request.approval_id, :allow_once)
    assert Task.await(authorization) == :ok
  end

  test "auto mode releases pending approval and approves future risky tools", context do
    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo,
        approval_policy: :ask,
        approval_handler: self()
      )

    pending =
      Task.async(fn ->
        BeamAgent.Session.ToolPolicy.authorize(
          session_id,
          "create_file",
          %{"path" => "pending.txt"},
          :write
        )
      end)

    assert_receive {:beam_agent_approval, request}
    assert request.tool == "create_file"
    assert :ok = BeamAgent.set_approval_policy(session_id, :auto)
    assert Task.await(pending) == :ok
    assert {:ok, :auto} = BeamAgent.approval_policy(session_id)

    assert :ok =
             BeamAgent.Session.ToolPolicy.authorize(
               session_id,
               "run_command",
               %{"command" => "mix test"},
               :execute
             )

    refute_receive {:beam_agent_approval, _request}

    {:ok, events} = BeamAgent.events(session_id)

    assert Enum.any?(events, fn event ->
             event["type"] == "approval_policy_changed" and event["data"]["to"] == "auto"
           end)

    assert Enum.any?(events, fn event ->
             event["type"] == "tool_approval_granted" and
               event["data"]["reason"] == "auto_mode_enabled"
           end)

    assert :ok = BeamAgent.stop_session(session_id)

    assert {:ok, ^session_id} =
             BeamAgent.resume_session(session_id,
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               approval_policy: :ask,
               approval_handler: self()
             )

    assert {:ok, :auto} = BeamAgent.approval_policy(session_id)
  end

  test "sandboxed commands can write inside but not outside the workspace", context do
    tool_context = %{workspace_root: context.workspace}

    if :os.type() != {:unix, :darwin} do
      assert {:error, {:sandbox_unavailable, _os}} =
               RunCommand.execute(%{"command" => "pwd"}, tool_context)
    else
      assert {:ok, command_result} =
               RunCommand.execute(
                 %{"command" => "printf inside > command.txt", "timeout_ms" => 5_000},
                 tool_context
               )

      {:ok, command_data} = JSON.decode(command_result)
      assert command_data["status"] == 0
      assert File.read!(Path.join(context.workspace, "command.txt")) == "inside"

      if System.get_env("BEAM_AGENT_SANDBOX") != "1" do
        outside = Path.join(context.root, "outside-command.txt")

        assert {:ok, denied_result} =
                 RunCommand.execute(
                   %{"command" => "printf outside > #{outside}", "timeout_ms" => 5_000},
                   tool_context
                 )

        denied_data = JSON.decode!(denied_result)
        assert denied_data["ok"] == false
        assert denied_data["status"] != 0
        refute File.exists?(outside)
      end

      assert {:ok, piped_result} =
               RunCommand.execute(
                 %{"command" => "false | cat", "timeout_ms" => 5_000},
                 tool_context
               )

      piped_data = JSON.decode!(piped_result)
      assert piped_data["ok"] == false
      assert piped_data["status"] != 0

      assert {:ok, mix_result} =
               RunCommand.execute(
                 %{"command" => "mix compile --warnings-as-errors", "timeout_ms" => 120_000},
                 %{workspace_root: File.cwd!()}
               )

      assert JSON.decode!(mix_result)["status"] == 0

      assert {:ok, temp_result} =
               RunCommand.execute(
                 %{"command" => "printf %s \"$TMPDIR\"", "timeout_ms" => 5_000},
                 tool_context
               )

      assert JSON.decode!(temp_result)["output"] ==
               BeamAgent.Sandbox.temporary_root(context.workspace)
    end
  end
end
