defmodule BeamAgent.Tools.EditFile do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Tools.FileSupport

  @impl true
  def name, do: "edit_file"

  @impl true
  def description,
    do:
      "Replace one exact text occurrence in a previously read workspace file using its SHA-256 version."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "Workspace-relative file path"},
        old_text: %{type: "string", description: "Exact text that must occur once"},
        new_text: %{type: "string"},
        expected_sha256: %{type: "string", description: "SHA-256 returned by read_file"}
      },
      required: ["path", "old_text", "new_text", "expected_sha256"]
    }
  end

  @impl true
  def access, do: :write

  @impl true
  def execute(
        %{
          "path" => path,
          "old_text" => old_text,
          "new_text" => new_text,
          "expected_sha256" => expected
        },
        context
      )
      when is_binary(old_text) and old_text != "" and is_binary(new_text) and
             is_binary(expected) do
    with {:ok, resolved} <- FileSupport.resolve(context, path),
         {:ok, content} <- FileSupport.read_text(resolved),
         :ok <- verify_version(content, expected),
         :ok <- verify_unique(content, old_text),
         updated <- String.replace(content, old_text, new_text, global: false),
         :ok <- FileSupport.atomic_write(resolved, updated) do
      {:ok,
       JSON.encode!(%{
         path: path,
         bytes: byte_size(updated),
         sha256: FileSupport.sha256(updated)
       })}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_versioned_exact_edit}

  defp verify_version(content, expected) do
    actual = FileSupport.sha256(content)
    if actual == expected, do: :ok, else: {:error, {:stale_file, expected, actual}}
  end

  defp verify_unique(content, old_text) do
    case :binary.matches(content, old_text) do
      [_one] -> :ok
      [] -> {:error, :edit_text_not_found}
      matches -> {:error, {:ambiguous_edit, length(matches)}}
    end
  end
end
