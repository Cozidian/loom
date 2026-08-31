defmodule BeamAgent.AttachmentStoreTest do
  use ExUnit.Case, async: false

  alias BeamAgent.Session.AttachmentStore

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-attachment-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)

    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: data_dir,
        workspace_root: workspace,
        provider: :echo
      )

    on_exit(fn -> File.rm_rf(root) end)
    %{data_dir: data_dir, session_id: session_id, workspace: workspace}
  end

  test "validated images are stored privately while events contain metadata only", context do
    assert {:ok, attachment} =
             BeamAgent.import_attachment(context.session_id, %{
               content: @png,
               name: "clipboard image.png",
               provenance: "clipboard"
             })

    assert attachment.id == "attachment-" <> attachment.sha256
    assert attachment.mime_type == "image/png"
    assert attachment.width == 1
    assert attachment.height == 1
    assert attachment.size_bytes == byte_size(@png)
    refute Map.has_key?(attachment, :data)
    refute Map.has_key?(attachment, :path)

    assert {:ok, [resolved]} = AttachmentStore.resolve(context.session_id, [attachment.id])
    assert Base.decode64!(resolved.data) == @png
    assert File.stat!(resolved.path).mode |> Bitwise.band(0o777) == 0o600

    event_log = Path.join([context.data_dir, context.session_id, "events.jsonl"])
    persisted_events = File.read!(event_log)
    assert persisted_events =~ "attachment_imported"
    refute persisted_events =~ Base.encode64(@png)
  end

  test "attachment references persist in messages and require a vision endpoint", context do
    endpoints = [
      %{
        id: "text",
        provider: :echo,
        provider_module: BeamAgent.Providers.Echo,
        claims: %{modalities: [:text], locality: :local, cost_hint: :free}
      },
      %{
        id: "vision",
        provider: :echo,
        provider_module: BeamAgent.Providers.Echo,
        claims: %{modalities: [:text, :image]}
      }
    ]

    :ok = BeamAgent.stop_session(context.session_id)

    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: context.workspace,
        provider: :echo,
        provider_profile: "vision",
        model_strategy: :auto,
        model_endpoints: endpoints
      )

    assert {:ok, attachment} =
             BeamAgent.import_attachment(session_id, %{
               content: @png,
               provenance: "clipboard"
             })

    assert {:ok, _answer} = BeamAgent.ask(session_id, "describe this", [attachment.id])
    assert {:ok, _answer} = BeamAgent.ask(session_id, "tell me about your capabilities")

    assert {:ok, events} = BeamAgent.events(session_id)

    routes =
      events
      |> Enum.filter(&(&1["type"] == "model_route_selected"))
      |> Enum.map(& &1["data"])

    assert length(routes) == 2
    assert Enum.all?(routes, &(&1["selected_endpoint_id"] == "vision"))
    assert Enum.all?(routes, &(&1["inputs"]["modalities_required"] == ["text", "image"]))

    [user_message | _] =
      events
      |> Enum.filter(&(&1["type"] == "user_message"))
      |> Enum.reverse()

    assert user_message["data"]["attachments"] == []

    first_user = Enum.find(events, &(&1["type"] == "user_message"))
    assert get_in(first_user, ["data", "attachments", Access.at(0), "id"]) == attachment.id
    refute Map.has_key?(get_in(first_user, ["data", "attachments", Access.at(0)]), "data")
  end

  test "invalid formats are rejected and can be safely removed before submission", context do
    assert {:error, :unsupported_image_format} =
             BeamAgent.import_attachment(context.session_id, %{
               content: "not an image",
               provenance: "clipboard"
             })

    assert {:ok, attachment} =
             BeamAgent.import_attachment(context.session_id, %{
               content: @png,
               provenance: "clipboard"
             })

    assert :ok = BeamAgent.delete_attachment(context.session_id, attachment.id)
    assert {:ok, []} = BeamAgent.attachments(context.session_id)
  end

  test "embedded PNG text metadata is removed before persistence", context do
    text = "Comment\0private clipboard metadata"
    crc = :erlang.crc32(<<"tEXt", text::binary>>)

    metadata_chunk =
      <<byte_size(text)::unsigned-big-32, "tEXt", text::binary, crc::unsigned-big-32>>

    <<header::binary-size(33), rest::binary>> = @png
    png_with_metadata = <<header::binary, metadata_chunk::binary, rest::binary>>

    assert {:ok, attachment} =
             BeamAgent.import_attachment(context.session_id, %{
               content: png_with_metadata,
               provenance: "clipboard"
             })

    assert {:ok, [resolved]} = AttachmentStore.resolve(context.session_id, [attachment.id])
    persisted = Base.decode64!(resolved.data)
    refute persisted =~ "private clipboard metadata"
    assert persisted == @png
    assert attachment.size_bytes == byte_size(@png)
  end

  test "attachment metadata and bytes survive supervised session recovery", context do
    assert {:ok, attachment} =
             BeamAgent.import_attachment(context.session_id, %{
               content: @png,
               provenance: "clipboard"
             })

    assert :ok = BeamAgent.stop_session(context.session_id)

    assert {:ok, resumed_id} =
             BeamAgent.resume_session(context.session_id,
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert resumed_id == context.session_id
    assert {:ok, [recovered]} = BeamAgent.attachments(resumed_id)
    assert recovered.id == attachment.id
    assert {:ok, [resolved]} = AttachmentStore.resolve(resumed_id, [attachment.id])
    assert Base.decode64!(resolved.data) == @png
  end
end
