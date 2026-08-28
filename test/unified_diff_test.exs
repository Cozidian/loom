defmodule BeamAgent.UnifiedDiffTest do
  use ExUnit.Case, async: true

  alias BeamAgent.UnifiedDiff

  test "empty diff text yields no file entries" do
    assert UnifiedDiff.parse("") == []
    assert UnifiedDiff.parse("\n") == []
    assert UnifiedDiff.split("") == []
  end

  test "parses an added file" do
    diff = """
    diff --git a/lib/new.ex b/lib/new.ex
    new file mode 100644
    index 0000000..8d1c8b6
    --- /dev/null
    +++ b/lib/new.ex
    @@ -0,0 +1,3 @@
    +defmodule New do
    +end
    +
    """

    assert [file] = UnifiedDiff.parse(diff)
    assert file.file == "lib/new.ex"
    assert file.old_path == nil
    assert file.new_path == "lib/new.ex"
    assert file.status == "added"
    refute file.binary

    assert [hunk] = file.hunks
    assert hunk.header == "@@ -0,0 +1,3 @@"
    assert hunk.old_start == 0
    assert hunk.old_count == 0
    assert hunk.new_start == 1
    assert hunk.new_count == 3

    assert hunk.lines == [
             %{kind: :add, old_line: nil, new_line: 1, text: "defmodule New do"},
             %{kind: :add, old_line: nil, new_line: 2, text: "end"},
             %{kind: :add, old_line: nil, new_line: 3, text: ""}
           ]
  end

  test "parses a modified file with multiple hunks and tracks line numbers" do
    diff = """
    diff --git a/lib/app.ex b/lib/app.ex
    index 1111111..2222222 100644
    --- a/lib/app.ex
    +++ b/lib/app.ex
    @@ -1,5 +1,6 @@
     defmodule App do
    -  def run, do: :old
    +  def run, do: :new
    +  def extra, do: :ok
       def other, do: :ok
     end
    @@ -20,3 +21,2 @@ defmodule App do
     tail one
    -tail two
     tail three
    """

    assert [file] = UnifiedDiff.parse(diff)
    assert file.status == "modified"
    assert file.old_path == "lib/app.ex"
    assert file.new_path == "lib/app.ex"
    assert length(file.hunks) == 2

    [first, second] = file.hunks

    assert first.old_start == 1
    assert first.old_count == 5
    assert first.new_start == 1
    assert first.new_count == 6

    assert first.lines == [
             %{kind: :context, old_line: 1, new_line: 1, text: "defmodule App do"},
             %{kind: :remove, old_line: 2, new_line: nil, text: "  def run, do: :old"},
             %{kind: :add, old_line: nil, new_line: 2, text: "  def run, do: :new"},
             %{kind: :add, old_line: nil, new_line: 3, text: "  def extra, do: :ok"},
             %{kind: :context, old_line: 3, new_line: 4, text: "  def other, do: :ok"},
             %{kind: :context, old_line: 4, new_line: 5, text: "end"}
           ]

    assert second.header == "@@ -20,3 +21,2 @@ defmodule App do"
    assert second.old_start == 20
    assert second.new_start == 21

    assert second.lines == [
             %{kind: :context, old_line: 20, new_line: 21, text: "tail one"},
             %{kind: :remove, old_line: 21, new_line: nil, text: "tail two"},
             %{kind: :context, old_line: 22, new_line: 22, text: "tail three"}
           ]
  end

  test "parses a deleted file" do
    diff = """
    diff --git a/lib/gone.ex b/lib/gone.ex
    deleted file mode 100644
    index 8d1c8b6..0000000
    --- a/lib/gone.ex
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -defmodule Gone do
    -end
    """

    assert [file] = UnifiedDiff.parse(diff)
    assert file.file == "lib/gone.ex"
    assert file.old_path == "lib/gone.ex"
    assert file.new_path == nil
    assert file.status == "deleted"

    assert [%{lines: lines, new_start: 0, new_count: 0}] = file.hunks

    assert lines == [
             %{kind: :remove, old_line: 1, new_line: nil, text: "defmodule Gone do"},
             %{kind: :remove, old_line: 2, new_line: nil, text: "end"}
           ]
  end

  test "parses a pure rename with no content change" do
    diff = """
    diff --git a/lib/old.ex b/lib/new.ex
    similarity index 100%
    rename from lib/old.ex
    rename to lib/new.ex
    """

    assert [file] = UnifiedDiff.parse(diff)
    assert file.status == "renamed"
    assert file.old_path == "lib/old.ex"
    assert file.new_path == "lib/new.ex"
    assert file.file == "lib/new.ex"
    assert file.hunks == []
    refute file.binary
  end

  test "parses a rename that also changes content" do
    diff = """
    diff --git a/lib/old.ex b/lib/new.ex
    similarity index 80%
    rename from lib/old.ex
    rename to lib/new.ex
    index 1111111..2222222 100644
    --- a/lib/old.ex
    +++ b/lib/new.ex
    @@ -1,2 +1,2 @@
    -defmodule Old do
    +defmodule New do
     end
    """

    assert [file] = UnifiedDiff.parse(diff)
    assert file.status == "renamed"
    assert file.old_path == "lib/old.ex"
    assert file.new_path == "lib/new.ex"

    assert [%{lines: lines}] = file.hunks

    assert lines == [
             %{kind: :remove, old_line: 1, new_line: nil, text: "defmodule Old do"},
             %{kind: :add, old_line: nil, new_line: 1, text: "defmodule New do"},
             %{kind: :context, old_line: 2, new_line: 2, text: "end"}
           ]
  end

  test "parses a binary file without hunks" do
    diff = """
    diff --git a/assets/logo.png b/assets/logo.png
    index 1111111..2222222 100644
    Binary files a/assets/logo.png and b/assets/logo.png differ
    """

    assert [file] = UnifiedDiff.parse(diff)
    assert file.file == "assets/logo.png"
    assert file.status == "modified"
    assert file.binary
    assert file.hunks == []
  end

  test "ignores no-newline-at-eof markers" do
    diff = """
    diff --git a/a.txt b/a.txt
    index 1111111..2222222 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -1 +1 @@
    -one
    \\ No newline at end of file
    +two
    \\ No newline at end of file
    """

    assert [%{hunks: [hunk]}] = UnifiedDiff.parse(diff)
    assert hunk.old_count == 1
    assert hunk.new_count == 1

    assert hunk.lines == [
             %{kind: :remove, old_line: 1, new_line: nil, text: "one"},
             %{kind: :add, old_line: nil, new_line: 1, text: "two"}
           ]
  end

  test "parses a multi-file diff and splits it into verbatim sections" do
    diff = """
    diff --git a/a.txt b/a.txt
    index 1111111..2222222 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -1 +1 @@
    -a
    +A
    diff --git a/b.txt b/b.txt
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/b.txt
    @@ -0,0 +1 @@
    +b
    diff --git a/c.png b/c.png
    deleted file mode 100644
    index 4444444..0000000
    Binary files a/c.png and /dev/null differ
    """

    files = UnifiedDiff.parse(diff)
    assert Enum.map(files, & &1.file) == ["a.txt", "b.txt", "c.png"]
    assert Enum.map(files, & &1.status) == ["modified", "added", "deleted"]
    assert Enum.map(files, & &1.binary) == [false, false, true]

    sections = UnifiedDiff.split(diff)
    assert length(sections) == 3
    assert Enum.at(sections, 1) =~ "+++ b/b.txt"
    refute Enum.at(sections, 1) =~ "a.txt"
    assert Enum.join(sections, "\n") == String.trim_trailing(diff, "\n")
  end

  test "handles paths containing spaces" do
    diff = """
    diff --git a/my dir/my file.txt b/my dir/my file.txt
    index 1111111..2222222 100644
    --- a/my dir/my file.txt
    +++ b/my dir/my file.txt
    @@ -1 +1 @@
    -x
    +y
    """

    assert [file] = UnifiedDiff.parse(diff)
    assert file.file == "my dir/my file.txt"
  end
end
