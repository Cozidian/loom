defmodule BeamAgent.Tools.FileDiagnosticsTest do
  use ExUnit.Case, async: true

  alias BeamAgent.Tools.FileDiagnostics

  test "formats parser tokens that are not iodata without crashing" do
    diagnostics = FileDiagnostics.diagnostics("broken.ex", "defmodule Broken do\n  %{a: }\nend\n")

    assert [%{severity: "error", message: message}] = diagnostics
    assert is_binary(message)
    assert message != ""
  end

  test "returns no diagnostics for valid Elixir and unsupported files" do
    assert FileDiagnostics.diagnostics("valid.ex", "defmodule Valid do\nend\n") == []
    assert FileDiagnostics.diagnostics("notes.md", "not Elixir") == []
  end
end
