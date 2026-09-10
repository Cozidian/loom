defmodule BeamAgent.DocumentToolsTest do
  use ExUnit.Case, async: false
  alias BeamAgent.Documents.Docx
  alias BeamAgent.Tools.{ReadDocument, FillDocument, RenderDocument}
  alias BeamAgent.ToolRunner

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-document-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    original = fixture(root)

    {:ok, id} =
      BeamAgent.start_session(
        workspace_root: root,
        data_dir: Path.join(root, ".runtime"),
        provider: :echo,
        approval_policy: :auto
      )

    {:ok, context} = BeamAgent.Agent.construction_context(id)

    on_exit(fn ->
      BeamAgent.stop_session(id)
      File.rm_rf(root)
    end)

    %{root: root, original: original, context: context}
  end

  test "guarded template filling preserves binary originals and every unrelated ZIP part", ctx do
    assert {:ok, encoded} =
             ToolRunner.execute(ReadDocument, %{"path" => "original.docx"}, ctx.context)

    assert %{"paragraphs" => [%{"id" => 1, "text" => "Dagens tilstand"}]} = JSON.decode!(encoded)
    assert {:ok, result} = ToolRunner.execute(FillDocument, insertion(), ctx.context)

    assert %{"original_preserved" => true, "rendered" => false, "visually_reviewed" => false} =
             JSON.decode!(result)

    assert File.read!(ctx.original) == fixture_bytes()
    assert {:ok, before} = Docx.read(ctx.original)
    assert {:ok, after_doc} = Docx.read(Path.join(ctx.root, "result.docx"))
    assert Enum.at(after_doc.paragraphs, 1).text == "Kodegrunnlag <usikkert> & tiltak æøå"

    assert Enum.reject(before.entries, &(elem(&1, 0) == ~c"word/document.xml")) ==
             Enum.reject(after_doc.entries, &(elem(&1, 0) == ~c"word/document.xml"))

    assert after_doc.xml =~ "<w:b/>"

    assert {:error, :document_output_exists} =
             ToolRunner.execute(FillDocument, insertion(), ctx.context)
  end

  test "requires an observed generation and rejects edits after the source changes", ctx do
    assert {:error, :file_not_observed} =
             ToolRunner.execute(FillDocument, insertion(), ctx.context)

    assert {:ok, _} = ToolRunner.execute(ReadDocument, %{"path" => "original.docx"}, ctx.context)
    File.write!(ctx.original, fixture_bytes("Changed"))

    assert {:error, :invalid_output_or_stale_source} =
             ToolRunner.execute(FillDocument, insertion(), ctx.context)

    refute File.exists?(Path.join(ctx.root, "result.docx"))
  end

  test "source and output BOTH require path authority and desktop rendering has its own scope",
       ctx do
    narrow =
      BeamAgent.CapabilityEnvelope.root(%{
        tools: ["fill_document", "render_document"],
        paths: ["result.docx"]
      })

    context = %{ctx.context | capability_envelope: narrow}

    assert {:error, {:capability_denied, :paths, "original.docx"}} =
             ToolRunner.execute(FillDocument, insertion(), context)

    assert {:error, {:capability_denied, :browser_scopes, "desktop-document"}} =
             ToolRunner.execute(
               RenderDocument,
               %{"source" => "original.docx", "path" => "result.docx"},
               context
             )
  end

  test "deny policy prevents writes even when paths are allowed", ctx do
    :ok = BeamAgent.set_approval_policy(ctx.context.session_id, :deny)
    assert {:ok, _} = ToolRunner.execute(ReadDocument, %{"path" => "original.docx"}, ctx.context)
    assert {:error, _} = ToolRunner.execute(FillDocument, insertion(), ctx.context)
    refute File.exists?(Path.join(ctx.root, "result.docx"))
  end

  test "rejects stale anchors, duplicate anchors, traversal and unsupported active XML", ctx do
    {:ok, document} = Docx.read(ctx.original)
    edits = insertion()["insertions"]
    assert {:error, _} = Docx.fill(document, edits ++ edits)

    assert {:error, _} =
             Docx.fill(document, [
               %{"after_paragraph" => 1, "expected_text" => "wrong", "paragraphs" => ["text"]}
             ])

    assert {:error, _} =
             ToolRunner.execute(ReadDocument, %{"path" => "../outside.docx"}, ctx.context)

    for xml <- [
          "<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><x>&a;</x>",
          "<x>",
          "<Relationships><Relationship TargetMode='External'/></Relationships>"
        ] do
      path = Path.join(ctx.root, "unsafe.docx")
      File.write!(path, fixture_bytes("Dagens tilstand", xml))
      assert {:error, _} = Docx.read(path)
    end
  end

  test "plain-text requests to fill a document retain mutation intent" do
    assert BeamAgent.TaskClassifier.classify("Fill in the ROS analysis in test.docx").change_intent
  end

  test "document missions cannot redirect their output even within an allowed workspace", ctx do
    bound = %{
      ctx.context.agent_spec
      | restrictions: %{document: %{source: "original.docx", path: "approved.docx"}}
    }

    context = %{ctx.context | agent_spec: bound}

    assert {:error, :document_binding_denied} =
             ToolRunner.execute(FillDocument, insertion(), context)

    refute File.exists?(Path.join(ctx.root, "result.docx"))
  end

  test "numeric XML entities are decoded without enabling document-defined entities", ctx do
    File.write!(ctx.original, fixture_bytes("Bl&#229;b&#xE6;r &amp; frukt"))
    assert {:ok, document} = Docx.read(ctx.original)
    assert [%{text: "Blåbær & frukt"}] = document.paragraphs
  end

  test "completion reviewer inherits finite path authority and cannot add unavailable tools" do
    parent =
      BeamAgent.CapabilityEnvelope.root(%{
        tools: ["read_document", "fill_document"],
        paths: ["."]
      })

    requested = BeamAgent.Goal.Reviewer.read_capabilities(%{capability_envelope: parent})
    assert requested == %{tools: ["read_document"]}
    assert {:ok, child} = BeamAgent.CapabilityEnvelope.restrict(parent, requested)
    assert child.scopes.paths == ["."]
  end

  test "encoded external relationship attributes cannot bypass package checks", %{root: root} do
    path = Path.join(root, "encoded-external.docx")

    File.write!(
      path,
      fixture_bytes(
        "Dagens tilstand",
        "<Relationships><Relationship TargetMode=\"Extern&#97;l\" Target=\"https://example.invalid\"/></Relationships>"
      )
    )

    assert {:error, :external_document_relationship} = Docx.read(path)
  end

  defp insertion,
    do: %{
      "source" => "original.docx",
      "path" => "result.docx",
      "insertions" => [
        %{
          "after_paragraph" => 1,
          "expected_text" => "Dagens tilstand",
          "paragraphs" => ["Kodegrunnlag <usikkert> & tiltak æøå"]
        }
      ]
    }

  defp fixture(root) do
    path = Path.join(root, "original.docx")
    File.write!(path, fixture_bytes())
    path
  end

  defp fixture_bytes(text \\ "Dagens tilstand", relationships \\ "<Relationships/>") do
    xml =
      "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>#{text}</w:t></w:r></w:p><w:sectPr/></w:body></w:document>"

    {:ok, {_, bytes}} =
      :zip.create(
        ~c"fixture.docx",
        [
          {~c"[Content_Types].xml", "<Types/>"},
          {~c"_rels/.rels", relationships},
          {~c"word/document.xml", xml},
          {~c"word/media/test.bin", <<0, 255, 17>>}
        ],
        [:memory]
      )

    bytes
  end
end
