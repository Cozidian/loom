defmodule BeamAgent.DocumentVisualReviewTest do
  use ExUnit.Case, async: false
  alias BeamAgent.Documents.VisualReview
  alias BeamAgent.Tools.FileSupport

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  defmodule VisionProvider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :document_visual_review_test

    def configuration,
      do: %{
        name: "document_visual_review_test",
        label: "Deterministic visual review test provider",
        modalities: [:text, :image],
        capabilities: [:text_generation, :vision, :reasoning]
      }

    def complete(messages, tools, options) do
      send(options[:test_pid], {:vision_request, messages, tools})
      if options[:mutate], do: File.write!(options[:mutate], "changed after inspection")

      {:ok,
       %{
         content: JSON.encode!(%{pages: [%{page: 1, status: "passed", findings: []}]}),
         tool_calls: []
       }}
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(VisionProvider)
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-visual-review-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    source = Path.join(root, "source.docx")

    xml =
      ~s(<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Test</w:t></w:r></w:p></w:body></w:document>)

    {:ok, {_, bytes}} =
      :zip.create(
        ~c"fixture.docx",
        [
          {~c"[Content_Types].xml", "<Types/>"},
          {~c"_rels/.rels", "<Relationships/>"},
          {~c"word/document.xml", xml}
        ],
        [:memory]
      )

    File.write!(source, bytes)
    File.write!(Path.join(root, "document.pdf"), "test PDF fixture")
    File.write!(Path.join(root, "page-1.png"), @png)

    report = %{
      rendered: true,
      source_sha256: FileSupport.sha256(bytes),
      pdf_sha256: FileSupport.sha256("test PDF fixture"),
      page_count: 1,
      page_sha256: %{"page-1.png" => FileSupport.sha256(@png)}
    }

    File.write!(Path.join(root, "evidence.json"), JSON.encode!(report))
    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      source: source,
      report: report,
      options: [
        workspace_root: root,
        data_dir: Path.join(root, "runtime"),
        provider: VisionProvider.id(),
        provider_options: [test_pid: self()]
      ]
    }
  end

  test "review receives image bytes with no tools and records fingerprint-bound layout evidence",
       ctx do
    File.mkdir_p!(Path.join(ctx.root, ".beam_agent"))

    File.write!(
      Path.join(ctx.root, ".beam_agent/verification.json"),
      JSON.encode!(%{checks: [%{id: "must-not-run", command: "touch forbidden-verification"}]})
    )

    assert {:ok, result} = VisualReview.run(ctx.source, ctx.root, ctx.options)
    assert result.status == :passed
    assert result.method == "model_image_assessment"
    assert result.factual_review == false
    assert result.source_sha256 == ctx.report.source_sha256
    assert result.page_sha256 == ctx.report.page_sha256
    assert_receive {:vision_request, messages, []}
    attachments = Enum.flat_map(messages, &Map.get(&1, :attachments, []))
    assert [attachment] = attachments
    assert Base.decode64!(attachment.data) == @png
    assert {:error, _} = BeamAgent.Agent.construction_context(result.reviewer_session_id)
    refute File.exists?(Path.join(ctx.root, "forbidden-verification"))
  end

  test "stale pages are rejected before a provider is called", ctx do
    File.write!(Path.join(ctx.root, "page-1.png"), "substituted")

    assert {:error, :invalid_or_stale_render_evidence} =
             VisualReview.run(ctx.source, ctx.root, ctx.options)

    refute_receive {:vision_request, _, _}
  end

  test "changed source, PDF, missing pages and traversal cannot borrow a valid receipt", ctx do
    for report <- [
          %{ctx.report | source_sha256: "different"},
          %{ctx.report | pdf_sha256: "different"},
          %{ctx.report | page_count: 2},
          %{ctx.report | page_sha256: %{"../page-1.png" => FileSupport.sha256(@png)}},
          %{ctx.report | page_sha256: %{"page-2.png" => FileSupport.sha256(@png)}},
          %{ctx.report | page_count: 11}
        ] do
      File.write!(Path.join(ctx.root, "evidence.json"), JSON.encode!(report))

      assert {:error, :invalid_or_stale_render_evidence} =
               VisualReview.prepare(ctx.source, ctx.root)
    end
  end

  test "a page changed while the provider runs cannot be marked passed", ctx do
    opts =
      Keyword.put(ctx.options, :provider_options,
        test_pid: self(),
        mutate: Path.join(ctx.root, "page-1.png")
      )

    assert {:error, :invalid_or_stale_render_evidence} =
             VisualReview.run(ctx.source, ctx.root, opts)

    assert_receive {:vision_request, _, []}
  end

  test "every page needs an explicit assessment; concerns cannot be reported as success" do
    passed = %{page: 1, status: "passed", findings: []}
    uncertain = %{page: 2, status: "uncertain", findings: ["Text is too small to inspect."]}

    assert {:ok, %{status: :needs_attention}} =
             VisualReview.parse(JSON.encode!(%{pages: [passed, uncertain]}), 2)

    for pages <- [
          [passed],
          [passed, passed],
          [passed, %{uncertain | findings: []}],
          [passed, %{uncertain | status: "passed"}]
        ] do
      assert {:error, :incomplete_visual_assessment} =
               VisualReview.parse(JSON.encode!(%{pages: pages}), 2)
    end

    assert {:error, :incomplete_visual_assessment} = VisualReview.parse("Looks good", 1)
  end
end
