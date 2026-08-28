defmodule BeamAgent.Tools.ApplyPatch do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Tools.FileSupport

  @impl true
  def name, do: "apply_patch"

  @impl true
  def description do
    "Atomically apply multiple exact, version-checked text hunks to one workspace file."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string"},
        expected_sha256: %{type: "string", description: "SHA-256 returned by read_file"},
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
      required: ["path", "expected_sha256", "hunks"]
    }
  end

  @impl true
  def access, do: :write

  @impl true
  def execute(
        %{"path" => path, "expected_sha256" => expected, "hunks" => hunks},
        context
      )
      when is_binary(expected) and is_list(hunks) and length(hunks) in 1..64 do
    with {:ok, resolved} <- FileSupport.resolve(context, path),
         {:ok, content} <- FileSupport.read_text(resolved),
         :ok <- verify_version(content, expected),
         {:ok, updated} <- apply_hunks(content, hunks),
         :ok <- FileSupport.atomic_write(resolved, updated) do
      {:ok,
       JSON.encode!(%{
         path: path,
         hunks_applied: length(hunks),
         bytes: byte_size(updated),
         previous_sha256: expected,
         sha256: FileSupport.sha256(updated)
       })}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_versioned_patch_hunks}

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
