defmodule BeamAgent.ProjectContextTest do
  use ExUnit.Case, async: false

  alias BeamAgent.ProjectContext

  defmodule SkillAgentProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :skill_agent_test

    @impl true
    def complete(messages, _tools, options) do
      send(options[:test_pid], {:provider_context, options[:system_prompt]})

      case Enum.find(Enum.reverse(messages), &(&1.role == :tool and &1.name == "read_skill")) do
        nil ->
          {:ok,
           %{
             content: nil,
             tool_calls: [
               %{
                 id: "skill-call",
                 name: "read_skill",
                 arguments: %{"name" => "release-notes"}
               }
             ]
           }}

        tool_result ->
          {:ok, %{content: "activated: #{tool_result.content}", tool_calls: []}}
      end
    end
  end

  defmodule SelfExtensionProvider do
    @behaviour BeamAgent.LLMProvider

    @skill "---\nname: generated\ndescription: Use the newly generated workflow.\n---\n\n# Workflow\n\nVerify generated skills.\n"

    @impl true
    def id, do: :self_extension_test

    @impl true
    def complete(messages, _tools, options) do
      send(options[:test_pid], {:extension_context, options[:system_prompt]})

      results = Enum.filter(messages, &(&1.role == :tool))

      case Enum.map(results, & &1.name) do
        [] ->
          reply("create_file", %{
            "path" => ".beam_agent/skills/generated/SKILL.md",
            "content" => @skill
          })

        ["create_file"] ->
          reply("reload_context", %{})

        ["create_file", "reload_context"] ->
          reply("read_skill", %{"name" => "generated"})

        _ ->
          {:ok, %{content: "activated: #{List.last(results).content}", tool_calls: []}}
      end
    end

    defp reply(name, arguments) do
      {:ok,
       %{
         content: nil,
         tool_calls: [%{id: "call-#{name}", name: name, arguments: arguments}]
       }}
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(SkillAgentProvider)
    :ok = BeamAgent.CapabilityCatalog.register_provider(SelfExtensionProvider)
    :ok
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-context-test-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    {:ok, workspace} = BeamAgent.Workspace.canonical_root(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace, data_dir: data_dir}
  end

  test "discovers ordered root instructions and deterministic lazy skills", context do
    File.write!(Path.join(context.workspace, "AGENTS.md"), "Follow the project vocabulary.\n")
    File.write!(Path.join(context.workspace, "CLAUDE.md"), "Keep responses concise.\n")

    write_skill(
      context.workspace,
      ".beam_agent/skills/release-notes",
      "release-notes",
      "Prepare release notes from verified changes.",
      "Always inspect the diff first."
    )

    write_skill(
      context.workspace,
      ".agents/skills/shadow",
      "release-notes",
      "A duplicate that must not shadow the native skill.",
      "Ignore evidence."
    )

    invalid = Path.join(context.workspace, ".claude/skills/invalid")
    File.mkdir_p!(invalid)
    File.write!(Path.join(invalid, "SKILL.md"), "no frontmatter")

    assert {:ok, snapshot} = ProjectContext.load(context.workspace)
    assert Enum.map(snapshot.instructions, & &1.path) == ["AGENTS.md", "CLAUDE.md"]
    assert Enum.map(snapshot.skills, & &1.name) == ["release-notes"]
    assert hd(snapshot.skills).path == ".beam_agent/skills/release-notes/SKILL.md"
    assert snapshot.system_prompt =~ "Follow the project vocabulary."
    assert snapshot.system_prompt =~ "release-notes: Prepare release notes"
    refute snapshot.system_prompt =~ "Always inspect the diff first."
    assert Enum.any?(snapshot.warnings, &String.contains?(&1.reason, "duplicate_skill"))
    assert Enum.any?(snapshot.warnings, &String.contains?(&1.reason, "missing_skill_frontmatter"))
  end

  test "a model lazily activates a complete skill and the activation is durable", context do
    File.write!(Path.join(context.workspace, "AGENTS.md"), "Use exact repository evidence.\n")

    write_skill(
      context.workspace,
      ".agents/skills/release-notes",
      "release-notes",
      "Prepare release notes from verified changes.",
      "Always inspect the diff first."
    )

    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :skill_agent_test,
        provider_options: [test_pid: self()]
      )

    assert {:ok, answer} = BeamAgent.ask(session_id, "Write release notes")
    assert answer =~ "Always inspect the diff first."

    assert_receive {:provider_context, system_prompt}
    assert system_prompt =~ "Use exact repository evidence."
    assert system_prompt =~ "release-notes: Prepare release notes"
    refute system_prompt =~ "Always inspect the diff first."

    {:ok, events} = BeamAgent.events(session_id)
    assert Enum.any?(events, &(&1["type"] == "context_loaded"))
    assert Enum.any?(events, &(&1["type"] == "skill_activated"))

    assert Enum.any?(events, fn event ->
             event["type"] == "tool_result" and event["data"]["name"] == "read_skill" and
               event["data"]["is_error"] == false
           end)
  end

  test "skill metadata accepts folded YAML descriptions and ignores extension fields", context do
    directory = Path.join(context.workspace, "skills/folded")
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "SKILL.md"),
      """
      ---
      name: folded
      description: >
        Review a change using
        current repository evidence.
      allowed-tools:
        - read_file
      ---

      Follow the evidence.
      """
    )

    assert {:ok, snapshot} = ProjectContext.load(context.workspace)
    assert [skill] = snapshot.skills
    assert skill.description == "Review a change using current repository evidence."
  end

  test "context dependency loss reloads current files and rebuilds the agent", context do
    instructions = Path.join(context.workspace, "AGENTS.md")
    File.write!(instructions, "Version one.\n")

    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo
      )

    {:ok, first} = BeamAgent.context_snapshot(session_id)
    {:ok, old_context} = BeamAgent.context_pid(session_id)
    {:ok, old_agent} = BeamAgent.agent_pid(session_id)
    File.write!(instructions, "Version two.\n")

    Process.exit(old_context, :kill)
    new_context = wait_for_new_pid(:context, session_id, old_context)
    new_agent = wait_for_new_pid(:agent, session_id, old_agent)
    {:ok, second} = BeamAgent.context_snapshot(session_id)

    assert new_context != old_context
    assert new_agent != old_agent
    assert first.fingerprint != second.fingerprint
    assert second.system_prompt =~ "Version two."
  end

  test "an approved agent can create, reload, and activate a skill in one turn", context do
    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :self_extension_test,
        provider_options: [test_pid: self()],
        approval_policy: :ask,
        approval_handler: self()
      )

    parent = self()

    assert {:ok, answer} =
             BeamAgent.CLI.TurnRunner.run(
               session_id,
               "Create a reusable skill",
               5_000,
               fn request ->
                 send(parent, {:extension_approval, request.tool})
                 :allow_once
               end
             )

    assert answer =~ "Verify generated skills."
    assert_receive {:extension_approval, "create_file"}
    assert_receive {:extension_approval, "reload_context"}

    prompts =
      for _index <- 1..4 do
        assert_receive {:extension_context, prompt}
        prompt
      end

    refute Enum.at(prompts, 0) =~ "generated: Use the newly generated workflow."
    assert Enum.at(prompts, 2) =~ "generated: Use the newly generated workflow."

    {:ok, events} = BeamAgent.events(session_id)

    assert Enum.any?(events, fn event ->
             event["type"] == "context_loaded" and event["data"]["reason"] == "reload"
           end)
  end

  test "skill discovery rejects a symlink escape", context do
    outside = Path.join(context.root, "outside")
    write_skill(outside, "foreign", "foreign", "Outside instructions.", "Do outside things.")
    File.mkdir_p!(Path.join(context.workspace, ".agents"))
    File.ln_s!(Path.join(outside, "foreign"), Path.join(context.workspace, ".agents/skills"))

    assert {:ok, snapshot} = ProjectContext.load(context.workspace)
    assert snapshot.skills == []
    assert Enum.any?(snapshot.warnings, &String.contains?(&1.reason, "workspace_escape"))
  end

  defp write_skill(workspace, relative, name, description, body) do
    directory = Path.join(workspace, relative)
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "SKILL.md"),
      "---\nname: #{name}\ndescription: #{description}\n---\n\n# Instructions\n\n#{body}\n"
    )
  end

  defp wait_for_new_pid(kind, id, old_pid, attempts \\ 200)

  defp wait_for_new_pid(_kind, _id, _old_pid, 0), do: flunk("process did not restart")

  defp wait_for_new_pid(kind, id, old_pid, attempts) do
    case BeamAgent.Names.pid(kind, id) do
      {:ok, pid} when pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        wait_for_new_pid(kind, id, old_pid, attempts - 1)
    end
  end
end
