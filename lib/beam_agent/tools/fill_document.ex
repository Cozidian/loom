defmodule BeamAgent.Tools.FillDocument do
  @behaviour BeamAgent.Tool
  alias BeamAgent.Documents.Docx
  alias BeamAgent.Session.FileTracker
  alias BeamAgent.Tools.FileSupport
  def name, do: "fill_document"

  def description,
    do:
      "Fill an observed DOCX template by inserting body paragraphs after exact numbered paragraphs. Creates a NEW output path; never overwrites. Preserves original package parts and formatting. First call read_document on source. Tables, tracked changes and external relationships require a specialist editor. Output still needs rendering and visual review."

  def access, do: :write

  def input_schema do
    %{
      type: "object",
      properties: %{
        source: %{type: "string"},
        path: %{type: "string", description: "New workspace-relative .docx output"},
        insertions: %{
          type: "array",
          items: %{
            type: "object",
            properties: %{
              after_paragraph: %{type: "integer"},
              expected_text: %{type: "string"},
              paragraphs: %{type: "array", items: %{type: "string"}}
            },
            required: ["after_paragraph", "expected_text", "paragraphs"]
          }
        }
      },
      required: ["source", "path", "insertions"]
    }
  end

  def execute(%{"source" => source, "path" => path, "insertions" => edits}, context)
      when is_binary(source) and is_binary(path) do
    with true <- String.ends_with?(String.downcase(path), ".docx"),
         {:ok, input} <- FileSupport.resolve(context, source),
         {:ok, output} <- FileSupport.resolve(context, path),
         false <- File.exists?(output),
         {:ok, %{sha256: expected}} <- FileTracker.expected(context, source),
         {:ok, document} <- Docx.read(input),
         true <- document.sha256 == expected,
         {:ok, bytes} <- Docx.fill(document, edits),
         {:ok, current} <- File.read(input),
         true <- FileSupport.sha256(current) == expected,
         :ok <- File.mkdir_p(Path.dirname(output)),
         :ok <- File.write(output, bytes, [:binary, :exclusive]),
         :ok <- FileTracker.observe(context, path, FileSupport.sha256(bytes)) do
      {:ok,
       JSON.encode!(%{
         path: path,
         source: source,
         source_sha256: expected,
         sha256: FileSupport.sha256(bytes),
         original_preserved: true,
         unchanged_parts_preserved: true,
         rendered: false,
         visually_reviewed: false
       })}
    else
      true -> {:error, :document_output_exists}
      false -> {:error, :invalid_output_or_stale_source}
      error -> error
    end
  end

  def execute(_, _), do: {:error, :expected_source_output_and_insertions}
end
