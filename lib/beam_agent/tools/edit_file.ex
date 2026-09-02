defmodule BeamAgent.Tools.EditFile do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Session.FileTracker
  alias BeamAgent.Tools.FileSupport

  @impl true
  def name, do: "edit_file"

  @impl true
  def description,
    do:
      "Replace one exact text occurrence in a previously read workspace file. The runtime owns the observed file version."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "Workspace-relative file path"},
        old_text: %{type: "string", description: "Exact text that must occur once"},
        new_text: %{type: "string"},
        expected_sha256: %{
          type: "string",
          description: "Optional legacy SHA-256; the runtime normally tracks this"
        }
      },
      required: ["path", "old_text", "new_text"]
    }
  end

  @impl true
  def access, do: :write

  @impl true
  def execute(
        %{"path" => path, "old_text" => old_text, "new_text" => new_text} = arguments,
        context
      )
      when is_binary(old_text) and old_text != "" and is_binary(new_text) do
    with {:ok, resolved} <- FileSupport.resolve(context, path),
         {:ok, content} <- FileSupport.read_text(resolved),
         {:ok, expected} <- expected_version(context, path, arguments),
         :ok <- verify_version(content, expected),
         :ok <- verify_unique(content, old_text),
         updated <- String.replace(content, old_text, new_text, global: false),
         :ok <- FileSupport.atomic_write(resolved, updated),
         sha256 <- FileSupport.sha256(updated),
         :ok <- FileTracker.observe(context, path, sha256) do
      {:ok,
       JSON.encode!(%{
         path: path,
         bytes: byte_size(updated),
         previous_sha256: expected,
         sha256: sha256,
         generation_owner: "runtime"
       })}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_versioned_exact_edit}

  defp expected_version(_context, _path, %{"expected_sha256" => expected})
       when is_binary(expected),
       do: {:ok, expected}

  defp expected_version(context, path, _arguments) do
    with {:ok, observation} <- FileTracker.expected(context, path), do: {:ok, observation.sha256}
  end

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
