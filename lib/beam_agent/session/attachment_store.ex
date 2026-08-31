defmodule BeamAgent.Session.AttachmentStore do
  @moduledoc """
  Session-owned storage for validated model input attachments.

  Binary payloads live beside the durable session log, never inside events or
  prompts. Events and clients receive only the safe metadata returned by
  `public/1`.
  """
  use GenServer

  alias BeamAgent.Names
  alias BeamAgent.Session.EventLog

  @max_bytes 10 * 1024 * 1024
  @max_pixels 40_000_000
  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @png_metadata_chunks ["eXIf", "iTXt", "tEXt", "tIME", "zTXt"]

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:attachment_store, session_id))
  end

  def import(session_id, attrs) when is_map(attrs) do
    call(session_id, {:import, attrs})
  end

  def list(session_id), do: call(session_id, :list)
  def drafts(session_id), do: call(session_id, :drafts)
  def references(session_id, ids) when is_list(ids), do: call(session_id, {:references, ids})
  def resolve(session_id, ids) when is_list(ids), do: call(session_id, {:resolve, ids})
  def delete(session_id, id) when is_binary(id), do: call(session_id, {:delete, id})

  def hydrate_messages(session_id, messages) when is_list(messages) do
    ids =
      messages
      |> Enum.flat_map(&Map.get(&1, :attachments, []))
      |> Enum.map(&value(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    with {:ok, attachments} <- resolve(session_id, ids) do
      by_id = Map.new(attachments, &{&1.id, &1})

      {:ok,
       Enum.map(messages, fn message ->
         hydrated =
           message
           |> Map.get(:attachments, [])
           |> Enum.map(&Map.get(by_id, value(&1, :id)))
           |> Enum.reject(&is_nil/1)

         if hydrated == [], do: message, else: Map.put(message, :attachments, hydrated)
       end)}
    end
  end

  def public(attachment) when is_map(attachment) do
    Map.take(attachment, [
      :id,
      :kind,
      :name,
      :mime_type,
      :size_bytes,
      :width,
      :height,
      :sha256,
      :provenance,
      :created_at,
      :status,
      :summary
    ])
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    directory =
      opts
      |> Keyword.fetch!(:data_dir)
      |> Path.join(session_id)
      |> Path.join("attachments")

    with :ok <- File.mkdir_p(directory), {:ok, attachments} <- load(directory) do
      {:ok, %{session_id: session_id, directory: directory, attachments: attachments}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:import, attrs}, _from, state) do
    with {:ok, content} <- content(attrs),
         :ok <- validate_size(content),
         {:ok, image} <- inspect_png(content),
         sanitized <- strip_png_metadata(content),
         hash <- :crypto.hash(:sha256, sanitized) |> Base.encode16(case: :lower),
         id <- "attachment-" <> hash,
         {:ok, attachment} <- persist(state, id, hash, sanitized, image, attrs),
         {:ok, _event} <-
           EventLog.append(state.session_id, :attachment_imported, public(attachment)) do
      attachments = Map.put(state.attachments, id, attachment)
      {:reply, {:ok, public(attachment)}, %{state | attachments: attachments}}
    else
      {:error, reason} ->
        _ =
          EventLog.append(state.session_id, :attachment_import_failed, %{
            "kind" => "image",
            "reason" => error_code(reason),
            "provenance" => value(attrs, :provenance) || "unknown"
          })

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list, _from, state) do
    attachments =
      state.attachments |> Map.values() |> Enum.map(&public/1) |> Enum.sort_by(& &1.id)

    {:reply, {:ok, attachments}, state}
  end

  def handle_call(:drafts, _from, state) do
    attachments =
      state.attachments
      |> Map.values()
      |> Enum.reject(&referenced?(state.session_id, &1.id))
      |> Enum.map(&public/1)
      |> Enum.sort_by(& &1.id)

    {:reply, {:ok, attachments}, state}
  end

  def handle_call({:resolve, ids}, _from, state) do
    case resolve_all(state, ids) do
      {:ok, attachments} -> {:reply, {:ok, attachments}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:references, ids}, _from, state) do
    case fetch_all(state, ids) do
      {:ok, attachments} -> {:reply, {:ok, Enum.map(attachments, &public/1)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    case Map.fetch(state.attachments, id) do
      :error ->
        {:reply, {:error, :attachment_not_found}, state}

      {:ok, attachment} ->
        if referenced?(state.session_id, id) do
          {:reply, {:error, :attachment_in_use}, state}
        else
          with :ok <- remove_file(attachment.path),
               :ok <- remove_file(metadata_path(state.directory, id)),
               {:ok, _event} <-
                 EventLog.append(state.session_id, :attachment_deleted, public(attachment)) do
            {:reply, :ok, %{state | attachments: Map.delete(state.attachments, id)}}
          else
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
        end
    end
  end

  defp persist(state, id, hash, content, image, attrs) do
    path = Path.join(state.directory, id <> ".png")
    metadata_path = metadata_path(state.directory, id)

    attachment = %{
      id: id,
      kind: "image",
      name: safe_name(value(attrs, :name)),
      mime_type: "image/png",
      size_bytes: byte_size(content),
      width: image.width,
      height: image.height,
      sha256: hash,
      provenance: safe_provenance(value(attrs, :provenance)),
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "ready",
      summary: "PNG #{image.width}x#{image.height}",
      path: path
    }

    if Map.has_key?(state.attachments, id) do
      {:ok, Map.fetch!(state.attachments, id)}
    else
      with :ok <- atomic_write(path, content),
           :ok <- File.chmod(path, 0o600),
           :ok <- atomic_write(metadata_path, JSON.encode!(public(attachment))),
           :ok <- File.chmod(metadata_path, 0o600) do
        {:ok, attachment}
      end
    end
  end

  defp resolve_all(state, ids) do
    with {:ok, attachments} <- fetch_all(state, ids) do
      Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, acc} ->
        case File.read(attachment.path) do
          {:ok, data} ->
            resolved = attachment |> Map.put(:data, Base.encode64(data))
            {:cont, {:ok, acc ++ [resolved]}}

          {:error, reason} ->
            {:halt, {:error, {:attachment_read_failed, attachment.id, reason}}}
        end
      end)
    end
  end

  defp fetch_all(state, ids) do
    ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case Map.fetch(state.attachments, id) do
        {:ok, attachment} -> {:cont, {:ok, acc ++ [attachment]}}
        :error -> {:halt, {:error, {:attachment_not_found, id}}}
      end
    end)
  end

  defp load(directory) do
    directory
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
      with {:ok, encoded} <- File.read(path),
           {:ok, metadata} when is_map(metadata) <- JSON.decode(encoded),
           id when is_binary(id) <- metadata["id"],
           data_path <- Path.join(directory, id <> ".png"),
           true <- File.regular?(data_path) do
        attachment = metadata |> atomize_metadata() |> Map.put(:path, data_path)
        {:cont, {:ok, Map.put(acc, id, attachment)}}
      else
        _invalid -> {:halt, {:error, {:invalid_attachment_metadata, path}}}
      end
    end)
  end

  defp inspect_png(
         <<@png_signature, 13::unsigned-big-32, "IHDR", width::unsigned-big-32,
           height::unsigned-big-32, bit_depth, color_type, compression, filter, interlace,
           crc::unsigned-big-32, rest::binary>> = content
       ) do
    header =
      <<width::unsigned-big-32, height::unsigned-big-32, bit_depth, color_type, compression,
        filter, interlace>>

    cond do
      :erlang.crc32(<<"IHDR", header::binary>>) != crc ->
        {:error, :invalid_png_crc}

      width == 0 or height == 0 ->
        {:error, :invalid_image_dimensions}

      width * height > @max_pixels ->
        {:error, :image_pixel_limit_exceeded}

      compression != 0 or filter != 0 or interlace not in [0, 1] ->
        {:error, :invalid_png_header}

      bit_depth not in [1, 2, 4, 8, 16] ->
        {:error, :invalid_png_header}

      color_type not in [0, 2, 3, 4, 6] ->
        {:error, :invalid_png_header}

      true ->
        with :ok <- validate_png_chunks(rest, false),
             true <- byte_size(content) >= 45 do
          {:ok, %{width: width, height: height}}
        else
          false -> {:error, :invalid_png}
          {:error, _reason} = error -> error
        end
    end
  end

  defp inspect_png(_content), do: {:error, :unsupported_image_format}

  defp strip_png_metadata(<<@png_signature, chunks::binary>>) do
    [@png_signature | strip_png_chunks(chunks, [])]
    |> IO.iodata_to_binary()
  end

  defp strip_png_chunks(
         <<length::unsigned-big-32, type::binary-size(4), rest::binary>>,
         acc
       ) do
    <<data::binary-size(length), crc::unsigned-big-32, tail::binary>> = rest
    chunk = <<length::unsigned-big-32, type::binary, data::binary, crc::unsigned-big-32>>
    acc = if type in @png_metadata_chunks, do: acc, else: [chunk | acc]

    if type == "IEND", do: Enum.reverse(acc), else: strip_png_chunks(tail, acc)
  end

  defp validate_png_chunks(<<>>, _saw_idat), do: {:error, :missing_png_end}

  defp validate_png_chunks(
         <<length::unsigned-big-32, type::binary-size(4), rest::binary>>,
         saw_idat
       )
       when byte_size(rest) >= length + 4 do
    <<data::binary-size(length), crc::unsigned-big-32, tail::binary>> = rest

    cond do
      length > @max_bytes -> {:error, :invalid_png_chunk}
      :erlang.crc32(<<type::binary, data::binary>>) != crc -> {:error, :invalid_png_crc}
      type == "IEND" and length == 0 and tail == <<>> and saw_idat -> :ok
      type == "IEND" -> {:error, :invalid_png_end}
      true -> validate_png_chunks(tail, saw_idat or type == "IDAT")
    end
  end

  defp validate_png_chunks(_rest, _saw_idat), do: {:error, :invalid_png_chunk}

  defp referenced?(session_id, id) do
    case EventLog.events(session_id) do
      {:ok, events} ->
        Enum.any?(events, fn event ->
          event["type"] == "user_message" and
            Enum.any?(event["data"]["attachments"] || [], &(&1["id"] == id))
        end)

      {:error, _reason} ->
        true
    end
  end

  defp atomic_write(path, content) do
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(temporary, content, [:binary, :exclusive]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} = error ->
        _ = File.rm(temporary)
        if reason == :eexist and File.regular?(path), do: :ok, else: error
    end
  end

  defp content(attrs) do
    case value(attrs, :content) do
      content when is_binary(content) and content != <<>> -> {:ok, content}
      _other -> {:error, :empty_attachment}
    end
  end

  defp validate_size(content) when byte_size(content) <= @max_bytes, do: :ok
  defp validate_size(_content), do: {:error, :attachment_too_large}

  defp safe_name(name) when is_binary(name) and name != "" do
    name |> Path.basename() |> String.replace(~r/[^a-zA-Z0-9._-]/u, "-") |> String.slice(0, 96)
  end

  defp safe_name(_name), do: "pasted-image.png"

  defp safe_provenance(value) when value in ["clipboard", "upload", "api"], do: value
  defp safe_provenance(_value), do: "api"

  defp metadata_path(directory, id), do: Path.join(directory, id <> ".json")

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomize_metadata(metadata) do
    Map.new(metadata, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "attachment_error"

  defp call(session_id, message) do
    with {:ok, pid} <- Names.pid(:attachment_store, session_id) do
      GenServer.call(pid, message, 30_000)
    end
  catch
    :exit, {:noproc, _details} -> {:error, :not_found}
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
