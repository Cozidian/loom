defmodule BeamAgent.Tools.RenderDocument do
  @behaviour BeamAgent.Tool
  alias BeamAgent.Documents.Renderer
  alias BeamAgent.Tools.FileSupport
  def name, do: "render_document"

  def description,
    do:
      "Render a DOCX COPY using desktop Microsoft Word on macOS and Poppler. Explicit desktop automation, not shell sandbox execution. Original is never opened or saved. path is a NEW output directory with an existing parent. Returns PDF/page PNG paths; every page still needs visual inspection. Fails honestly when tools or automation permission are unavailable."

  def access, do: :execute

  def input_schema,
    do: %{
      type: "object",
      properties: %{source: %{type: "string"}, path: %{type: "string"}},
      required: ["source", "path"]
    }

  def execute(%{"source" => source, "path" => path}, context)
      when is_binary(source) and is_binary(path) do
    with {:ok, input} <- FileSupport.resolve(context, source),
         {:ok, output} <- FileSupport.resolve(context, path),
         {:ok, result} <- Renderer.render(input, output) do
      {:ok, JSON.encode!(result)}
    end
  end

  def execute(_, _), do: {:error, :expected_source_and_render_directory}
end
