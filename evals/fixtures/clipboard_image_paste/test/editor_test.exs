defmodule ClipboardFixture.EditorTest do
  use ExUnit.Case, async: true

  alias ClipboardFixture.Editor

  test "pastes a PNG as an attachment and inserts its Markdown reference" do
    state = Editor.new("Before\n")
    image = <<137, 80, 78, 71, 1, 2, 3>>

    assert {:ok, updated} =
             Editor.paste(state, %{
               "mime_type" => "image/png",
               "filename" => "screen.png",
               "data" => image
             })

    assert [attachment] = updated.attachments
    assert attachment.mime_type == "image/png"
    assert attachment.filename == "screen.png"
    assert attachment.byte_size == byte_size(image)
    assert attachment.data == image
    assert is_binary(attachment.id) and attachment.id != ""
    assert updated.document == "Before\n![screen.png](attachment://#{attachment.id})"
  end

  test "preserves attachments and generates defaults for JPEG images" do
    existing = %{
      id: "old",
      mime_type: "image/png",
      filename: "old.png",
      byte_size: 1,
      data: <<1>>
    }

    state = %{document: "", attachments: [existing]}

    assert {:ok, updated} =
             Editor.paste(state, %{"mime_type" => "image/jpeg", "data" => <<255, 216, 255>>})

    assert [^existing, attachment] = updated.attachments
    assert attachment.filename == "pasted-image.jpg"
    assert updated.document == "![pasted-image.jpg](attachment://#{attachment.id})"
  end

  test "rejects unsupported or empty clipboard items without mutating state" do
    state = Editor.new("unchanged")

    assert {:error, :unsupported_clipboard_item} =
             Editor.paste(state, %{"mime_type" => "text/plain", "data" => "hello"})

    assert {:error, :empty_image} =
             Editor.paste(state, %{"mime_type" => "image/png", "data" => <<>>})

    assert state == Editor.new("unchanged")
  end
end
