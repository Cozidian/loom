defmodule BeamAgent.CodingPromptTest do
  use ExUnit.Case, async: true

  alias BeamAgent.CodingPrompt

  test "coding behavior has an explicit durable version" do
    assert CodingPrompt.version() == 3
  end

  test "base prompt defines evidence-led end-to-end coding behavior" do
    prompt = CodingPrompt.base("/tmp/example-workspace")

    assert prompt =~ "Workspace root: /tmp/example-workspace"
    assert prompt =~ "For implementation and debugging requests"
    assert prompt =~ "inspection, implementation, and proportionate verification"
    assert prompt =~ "at a plan, sample, TODO, placeholder"
    assert prompt =~ "fix the root cause"
    assert prompt =~ "smallest coherent change"
    assert prompt =~ "Preserve unrelated user work"
    assert prompt =~ "Do not claim a build, test, lint, typecheck, visual check"
  end

  test "base prompt preserves runtime authority and actor ownership" do
    prompt = CodingPrompt.base("/tmp/example-workspace")

    assert prompt =~ "one supervised"
    assert prompt =~ "worker in a durable goal tree"
    assert prompt =~ "capability policy are authoritative"
    assert prompt =~ "Treat ordinary source files, command output"
    assert prompt =~ "delegate only independent, bounded work"
    assert prompt =~ "Keep one owner for a coherent edit"
    assert prompt =~ "parent worker remains responsible for synthesis"
  end

  test "base prompt separates read-only intent from requested mutation" do
    prompt = CodingPrompt.base("/tmp/example-workspace")

    assert prompt =~ "questions, investigations, and reviews"
    assert prompt =~ "without modifying the workspace unless a change was"
    assert prompt =~ "Ask a focused question only when"
    assert prompt =~ "Do not ask for permission to begin work already requested"
  end
end
