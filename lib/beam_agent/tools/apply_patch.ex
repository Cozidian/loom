defmodule BeamAgent.Tools.ApplyPatch do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Session.FileTracker
  alias BeamAgent.Tools.FileSupport

  @impl true
  def name, do: "apply_patch"

  @impl true
  def description do
    "Atomically apply multiple exact text hunks to one observed workspace file. The runtime owns its version."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string"},
        expected_sha256: %{
          type: "string",
          description: "Optional legacy SHA-256; the runtime normally tracks this"
        },
        hunks: %{
          type: "array",
          minItems: 1,
          maxItems: 64,
          items: %{
            type: "object",
            properties: %{
              old_text: %{type: "string"},
              new_text: %{type: "string"}
            },
            required: ["old_text", "new_text"]
          }
        }
      },
      required: ["path", "hunks"]
    }
  end

  @impl true
  def access, do: :write

  @impl true
  def execute(%{"path" => _path, "patch" => patch} = arguments, context)
      when is_binary(patch) and not is_map_key(arguments, "hunks") do
    case hunks_from_patch(patch) do
      {:ok, hunks} -> execute(Map.put(arguments, "hunks", hunks), context)
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%{"path" => path, "hunks" => hunks} = arguments, context)
      when is_list(hunks) and length(hunks) in 1..64 do
    with {:ok, resolved} <- FileSupport.resolve(context, path),
         {:ok, content} <- FileSupport.read_text(resolved),
         {:ok, expected} <- expected_version(context, path, arguments),
         :ok <- verify_version(content, expected),
         {:ok, updated} <- apply_hunks(content, hunks),
         :ok <- FileSupport.atomic_write(resolved, updated),
         sha256 <- FileSupport.sha256(updated),
         :ok <- FileTracker.observe(context, path, sha256) do
      {:ok,
       JSON.encode!(%{
         path: path,
         hunks_applied: length(hunks),
         bytes: byte_size(updated),
         previous_sha256: expected,
         sha256: sha256,
         generation_owner: "runtime"
       })}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_versioned_patch_hunks}

  defp hunks_from_patch(patch) do
    hunks =
      patch
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.reject(&patch_header?/1)
      |> collect_hunks([], [], [])
      |> Enum.reverse()

    if hunks == [], do: {:error, :expected_versioned_patch_hunks}, else: {:ok, hunks}
  end

  defp patch_header?(line) do
    String.starts_with?(line, "***") or String.starts_with?(line, "@@")
  end

  defp collect_hunks([], old, new, hunks), do: flush_hunk(old, new, hunks)

  defp collect_hunks(["-" <> rest | lines], old, new, hunks) when new != [] do
    collect_hunks(lines, [patch_line(rest)], [], flush_hunk(old, new, hunks))
  end

  defp collect_hunks(["-" <> rest | lines], old, new, hunks) do
    collect_hunks(lines, old ++ [patch_line(rest)], new, hunks)
  end

  defp collect_hunks(["+" <> rest | lines], old, new, hunks) do
    collect_hunks(lines, old, new ++ [patch_line(rest)], hunks)
  end

  defp collect_hunks([" " <> rest | lines], old, new, hunks) do
    line = patch_line(rest)
    collect_hunks(lines, old ++ [line], new ++ [line], hunks)
  end

  defp collect_hunks([_other | lines], old, new, hunks),
    do: collect_hunks(lines, old, new, hunks)

  defp flush_hunk([], [], hunks), do: hunks

  defp flush_hunk(old, new, hunks) do
    old_text = Enum.join(old, "\n")
    new_text = Enum.join(new, "\n")

    if old_text == "" do
      hunks
    else
      [%{"old_text" => old_text, "new_text" => new_text} | hunks]
    end
  end

  defp patch_line(text) do
    String.replace(text, ~r/\A\d+:\s/, "")
  end

  defp expected_version(_context, _path, %{"expected_sha256" => expected})
       when is_binary(expected),
       do: {:ok, expected}

  defp expected_version(context, path, _arguments) do
    with {:ok, observation} <- FileTracker.expected(context, path), do: {:ok, observation.sha256}
  end

  defp apply_hunks(content, hunks) do
    Enum.reduce_while(hunks, {:ok, content}, fn
      %{"old_text" => old_text, "new_text" => new_text}, {:ok, current}
      when is_binary(old_text) and old_text != "" and is_binary(new_text) ->
        case :binary.matches(current, old_text) do
          [_one] -> {:cont, {:ok, String.replace(current, old_text, new_text, global: false)}}
          [] -> {:halt, {:error, :patch_text_not_found}}
          matches -> {:halt, {:error, {:ambiguous_patch, length(matches)}}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_patch_hunk}}
    end)
  end

  defp verify_version(content, expected) do
    actual = FileSupport.sha256(content)
    if actual == expected, do: :ok, else: {:error, {:stale_file, expected, actual}}
  end
end
