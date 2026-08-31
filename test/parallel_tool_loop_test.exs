defmodule BeamAgent.ParallelToolLoopTest do
  use ExUnit.Case, async: false

  defmodule ReadA do
    @behaviour BeamAgent.Tool
    def name, do: "parallel_read_a"
    def description, do: "A blocking test read"
    def input_schema, do: %{type: "object", properties: %{}}
    def access, do: :read
    def execute(_arguments, _context), do: block(:a)

    defp block(id) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:parallel_read_started, id, self()})
      receive do: (:release -> {:ok, "read-a"})
    end
  end

  defmodule ReadB do
    @behaviour BeamAgent.Tool
    def name, do: "parallel_read_b"
    def description, do: "A second blocking test read"
    def input_schema, do: %{type: "object", properties: %{}}
    def access, do: :read
    def execute(_arguments, _context), do: block(:b)

    defp block(id) do
      owner = :persistent_term.get({ReadA, :owner})
      send(owner, {:parallel_read_started, id, self()})
      receive do: (:release -> {:ok, "read-b"})
    end
  end

  defmodule Provider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :parallel_tool_loop_test

    def complete(messages, _tools, _options) do
      if Enum.count(messages, &(&1.role == :tool)) == 0 do
        {:ok,
         %{
           content: nil,
           tool_calls: [
             %{id: "read-a", name: "parallel_read_a", arguments: %{}},
             %{id: "read-b", name: "parallel_read_b", arguments: %{}}
           ]
         }}
      else
        {:ok, %{content: "both reads completed", tool_calls: []}}
      end
    end
  end

  setup_all do
    for registration <- [
          BeamAgent.CapabilityCatalog.register_tool(ReadA),
          BeamAgent.CapabilityCatalog.register_tool(ReadB),
          BeamAgent.CapabilityCatalog.register_provider(Provider)
        ] do
      assert registration == :ok
    end

    :ok
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-parallel-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    :persistent_term.put({ReadA, :owner}, self())

    on_exit(fn ->
      :persistent_term.erase({ReadA, :owner})
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "independent read calls execute concurrently", context do
    assert {:ok, session_id} =
             BeamAgent.start_session(
               data_dir: Path.join(context.root, "sessions"),
               workspace_root: context.root,
               provider: :parallel_tool_loop_test,
               approval_policy: :auto,
               completion_review: :external
             )

    turn = Task.async(fn -> BeamAgent.ask(session_id, "inspect both sources") end)

    assert_receive {:parallel_read_started, :a, first}, 1_000
    assert_receive {:parallel_read_started, :b, second}, 1_000
    send(first, :release)
    send(second, :release)
    assert {:ok, "both reads completed"} = Task.await(turn, 2_000)
  end
end
