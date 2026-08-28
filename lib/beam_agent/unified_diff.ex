defmodule BeamAgent.UnifiedDiff do
  @moduledoc """
  Parses `git diff` output into per-file, per-hunk structures.

  Interfaces render diffs themselves, so the parser keeps every line's original
  text alongside the old/new line number it occupies.
  """

  @hunk_header ~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/
  @git_header ~r|^a/(.*?) b/(.*)$|

  @type line :: %{
          kind: :context | :add | :remove,
          old_line: pos_integer() | nil,
          new_line: pos_integer() | nil,
          text: String.t()
        }

  @type hunk :: %{
          header: String.t(),
          old_start: non_neg_integer(),
          old_count: non_neg_integer(),
          new_start: non_neg_integer(),
          new_count: non_neg_integer(),
          lines: [line()]
        }

  @type file_diff :: %{
          file: String.t(),
          old_path: String.t() | nil,
          new_path: String.t() | nil,
          status: String.t(),
          binary: boolean(),
          hunks: [hunk()]
        }

  @spec parse(String.t()) :: [file_diff()]
  def parse(text) when is_binary(text),
    do: text |> sections() |> Enum.map(&parse_section/1)

  @doc "Splits raw diff text into the verbatim text of each file section."
  @spec split(String.t()) :: [String.t()]
  def split(text) when is_binary(text),
    do: text |> sections() |> Enum.map(&Enum.join(&1, "\n"))

  defp sections(text) do
    text
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.reduce([], fn
      "diff --git " <> _rest = line, sections -> [[line] | sections]
      _line, [] -> []
      line, [current | rest] -> [[line | current] | rest]
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  defp parse_section([header | rest]) do
    {meta, body} = Enum.split_while(rest, &(not hunk_header?(&1)))
    {header_old, header_new} = header_paths(header)
    status = status(meta)

    old_path = if status == "added", do: nil, else: old_path(meta, header_old)
    new_path = if status == "deleted", do: nil, else: new_path(meta, header_new)

    %{
      file: new_path || old_path || header_new || header_old,
      old_path: old_path,
      new_path: new_path,
      status: status,
      binary: binary?(meta),
      hunks: hunks(body)
    }
  end

  defp header_paths("diff --git " <> rest) do
    case Regex.run(@git_header, rest) do
      [_match, old, new] -> {old, new}
      nil -> {nil, nil}
    end
  end

  defp status(meta) do
    cond do
      meta?(meta, "new file mode") -> "added"
      meta?(meta, "deleted file mode") -> "deleted"
      meta?(meta, "rename from ") -> "renamed"
      meta?(meta, "copy from ") -> "copied"
      true -> "modified"
    end
  end

  defp binary?(meta), do: meta?(meta, "Binary files ") or meta?(meta, "GIT binary patch")

  defp meta?(meta, prefix), do: Enum.any?(meta, &String.starts_with?(&1, prefix))

  defp old_path(meta, fallback) do
    case meta_value(meta, "--- ") do
      nil -> meta_value(meta, "rename from ") || meta_value(meta, "copy from ") || fallback
      "/dev/null" -> nil
      path -> strip_prefix(path, "a/")
    end
  end

  defp new_path(meta, fallback) do
    case meta_value(meta, "+++ ") do
      nil -> meta_value(meta, "rename to ") || meta_value(meta, "copy to ") || fallback
      "/dev/null" -> nil
      path -> strip_prefix(path, "b/")
    end
  end

  defp meta_value(meta, prefix) do
    Enum.find_value(meta, fn line ->
      if String.starts_with?(line, prefix),
        do: line |> String.replace_prefix(prefix, "") |> String.trim_trailing()
    end)
  end

  defp strip_prefix(path, prefix), do: String.replace_prefix(path, prefix, "")

  defp hunk_header?(line), do: String.starts_with?(line, "@@")

  defp hunks(body) do
    body
    |> Enum.reduce([], fn line, hunks ->
      cond do
        hunk_header?(line) -> [[line] | hunks]
        hunks == [] -> hunks
        true -> [[line | hd(hunks)] | tl(hunks)]
      end
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map(&parse_hunk/1)
  end

  defp parse_hunk([header | lines]) do
    [_match, old_start, old_count, new_start, new_count, _context] =
      Regex.run(@hunk_header, header)

    old_start = String.to_integer(old_start)
    new_start = String.to_integer(new_start)
    {parsed, _cursors} = Enum.map_reduce(lines, {old_start, new_start}, &hunk_line/2)

    %{
      header: header,
      old_start: old_start,
      old_count: count(old_count),
      new_start: new_start,
      new_count: count(new_count),
      lines: Enum.reject(parsed, &is_nil/1)
    }
  end

  defp count(""), do: 1
  defp count(value), do: String.to_integer(value)

  defp hunk_line("\\" <> _marker, cursors), do: {nil, cursors}

  defp hunk_line(" " <> text, {old, new}),
    do: {%{kind: :context, old_line: old, new_line: new, text: text}, {old + 1, new + 1}}

  defp hunk_line("+" <> text, {old, new}),
    do: {%{kind: :add, old_line: nil, new_line: new, text: text}, {old, new + 1}}

  defp hunk_line("-" <> text, {old, new}),
    do: {%{kind: :remove, old_line: old, new_line: nil, text: text}, {old + 1, new}}

  defp hunk_line("", {old, new}),
    do: {%{kind: :context, old_line: old, new_line: new, text: ""}, {old + 1, new + 1}}

  defp hunk_line(_other, cursors), do: {nil, cursors}
end
