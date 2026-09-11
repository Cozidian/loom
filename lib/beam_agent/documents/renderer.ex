defmodule BeamAgent.Documents.Renderer do
  @moduledoc "Explicit desktop-document capability: render a private copy in Word, never the user's open original."
  alias BeamAgent.{Subprocess, Tools.FileSupport}
  alias BeamAgent.Documents.Docx

  @script """
  on run argv
    set inputPath to item 1 of argv
    set outputName to item 2 of argv
    set copyName to item 3 of argv
    set openedCopy to false
    tell application "Microsoft Word"
      with timeout of 90 seconds
        try
          repeat 100 times
            if exists document copyName then exit repeat
            delay 0.1
          end repeat
          set copyDocument to document copyName
          set openedCopy to true
          save as copyDocument file name outputName file format format PDF add to recent files false
          close copyDocument saving no
          set openedCopy to false
        on error messageText number errorNumber
          if openedCopy then
            try
              close copyDocument saving no
            end try
          end if
          error messageText number errorNumber
        end try
      end timeout
    end tell
  end run
  """

  def preflight do
    checks = %{
      macos: :os.type() == {:unix, :darwin},
      word: File.dir?("/Applications/Microsoft Word.app"),
      osascript: not is_nil(System.find_executable("osascript")),
      pdfinfo: not is_nil(System.find_executable("pdfinfo")),
      pdftoppm: not is_nil(System.find_executable("pdftoppm"))
    }

    %{
      ready: Enum.all?(checks, fn {_, ready} -> ready end),
      checks: checks,
      note:
        "macOS Word automation permission and Poppler are required. Rendering is not visual review."
    }
  end

  def render(source, destination) do
    with %{ready: true} <- preflight(),
         {:ok, document} <- Docx.read(source),
         false <- active_fields?(document),
         :ok <- File.mkdir(destination) do
      # Serialize desktop automation independently of model parallelism.
      :global.trans({__MODULE__, self()}, fn ->
        render_copy(source, destination, document.sha256)
      end)
    else
      %{ready: false} = status -> {:error, {:document_renderer_unavailable, status}}
      true -> {:error, :document_fields_require_specialist_renderer}
      error -> error
    end
  end

  defp active_fields?(document) do
    Enum.any?(document.entries, fn {_name, bytes} ->
      Regex.match?(~r/<w:(?:instrText|fldSimple|altChunk)\b|macroEnabled/i, bytes)
    end)
  end

  defp render_copy(source, destination, expected) do
    id = "beam-document-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    copy = Path.join(destination, id <> ".docx")
    pdf_name = id <> ".pdf"

    word_pdf =
      Path.join([
        System.user_home!(),
        "Library/Containers/com.microsoft.Word/Data/Documents",
        pdf_name
      ])

    pdf = Path.join(destination, "document.pdf")

    try do
      with {:ok, bytes} <- File.read(source),
           true <- FileSupport.sha256(bytes) == expected,
           :ok <- File.write(copy, bytes, [:exclusive, :binary]),
           {:ok, %{status: 0}} <-
             run("open", ["-a", "/Applications/Microsoft Word.app", copy], destination),
           {:ok, %{status: 0}} <-
             run(
               "osascript",
               ["-e", @script, copy, pdf_name, Path.basename(copy)],
               destination,
               100_000
             ),
           :ok <- File.rename(word_pdf, pdf),
           {:ok, %{status: 0, output: info}} <- run("pdfinfo", [pdf], destination),
           [_, count] <- Regex.run(~r/^Pages:\s+(\d+)/m, info),
           pages <- String.to_integer(count),
           true <- pages in 1..30,
           {:ok, %{status: 0}} <-
             run(
               "pdftoppm",
               ["-scale-to", "1500", "-png", pdf, Path.join(destination, "page")],
               destination
             ),
           images <- Path.wildcard(Path.join(destination, "page-*.png")) |> Enum.sort(),
           true <- length(images) == pages,
           {:ok, current} <- File.read(source),
           true <- FileSupport.sha256(current) == expected do
        {:ok,
         %{
           source_sha256: expected,
           original_preserved: true,
           renderer: "Microsoft Word",
           rendered: true,
           page_count: pages,
           pdf: pdf,
           pages: images,
           page_sha256: Map.new(images, &{Path.basename(&1), FileSupport.sha256(File.read!(&1))}),
           pdf_sha256: FileSupport.sha256(File.read!(pdf)),
           visually_reviewed: false,
           next_action:
             "Inspect EVERY page image. Rendering alone does not prove layout or factual correctness."
         }}
      else
        false ->
          {:error, :document_changed_or_render_limits_exceeded}

        {:ok, %{status: status, output: output}} ->
          {:error, {:document_render_failed, status, output}}

        error ->
          {:error, {:document_render_failed, error}}
      end
    after
      # Only these freshly generated, uniquely named artifacts belong to this call.
      File.rm(copy)
      File.rm(word_pdf)
    end
  end

  defp run(name, args, cwd, timeout \\ 60_000),
    do:
      Subprocess.run(System.find_executable(name), args,
        cwd: cwd,
        timeout_ms: timeout,
        max_output_bytes: 4_000
      )
end
