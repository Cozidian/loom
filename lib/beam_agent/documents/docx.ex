defmodule BeamAgent.Documents.Docx do
  @moduledoc "Bounded DOCX inspection and insert-only template filling. Never rewrites unrelated package parts."
  alias BeamAgent.Tools.FileSupport
  @max_bytes 20_000_000
  @max_expanded 50_000_000
  @paragraph ~r/<w:p\b[^>]*\/>|<w:p\b[^>]*>.*?<\/w:p>/s

  def read(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, entries} <- unpack(bytes),
         {:ok, xml} <- fetch(entries, "word/document.xml"),
         :ok <- validate_xml(xml),
         true <- String.contains?(xml, "<w:document"),
         paragraphs <- paragraphs(xml),
         true <-
           length(paragraphs) <= 2_000 and
             Enum.sum(Enum.map(paragraphs, &byte_size(&1.text))) <= 64_000 do
      {:ok,
       %{sha256: FileSupport.sha256(bytes), entries: entries, xml: xml, paragraphs: paragraphs}}
    else
      false -> {:error, :unsupported_document_namespace_or_text_limits}
      {:ok, _} -> {:error, :document_too_large_or_not_regular}
      error -> error
    end
  end

  def fill(document, edits) when is_list(edits) and length(edits) in 1..100 do
    # This first editing surface deliberately excludes tables, text boxes and
    # tracked changes: their paragraph ownership needs a richer editor.
    with false <- Regex.match?(~r/<w:(?:tbl|txbxContent|ins|del)\b/, document.xml),
         {:ok, replacements} <- replacements(document.paragraphs, edits),
         true <- Enum.sum(Enum.map(replacements, fn {_, text} -> byte_size(text) end)) <= 64_000 do
      xml = replace_paragraphs(document.xml, replacements)

      entries =
        Enum.map(document.entries, fn {name, bytes} ->
          {name, if(name == ~c"word/document.xml", do: xml, else: bytes)}
        end)

      with :ok <- validate_xml(xml),
           {:ok, {_name, bytes}} <- :zip.create(~c"filled.docx", entries, [:memory]) do
        {:ok, bytes}
      end
    else
      true -> {:error, :complex_document_requires_specialist_editor}
      false -> {:error, :document_insertions_too_large}
      error -> error
    end
  end

  def fill(_, _), do: {:error, :expected_one_to_100_insertions}

  def public(document) do
    %{
      sha256: document.sha256,
      paragraphs: document.paragraphs,
      verification: %{structure: "parsed", rendered: false, visually_reviewed: false}
    }
  end

  defp unpack(bytes) do
    with {:ok, table} <- :zip.table(bytes),
         files <- Enum.filter(table, &(elem(&1, 0) == :zip_file)),
         true <- length(files) in 1..1_000,
         names <- Enum.map(files, &(elem(&1, 1) |> List.to_string())),
         true <- length(Enum.uniq(names)) == length(names),
         true <- Enum.all?(names, &safe_part?/1),
         true <- Enum.sum(Enum.map(files, &elem(elem(&1, 2), 1))) <= @max_expanded,
         {:ok, entries} <- :zip.extract(bytes, [:memory]),
         true <- Enum.sum(Enum.map(entries, fn {_, data} -> byte_size(data) end)) <= @max_expanded,
         true <-
           Enum.all?(["[Content_Types].xml", "_rels/.rels", "word/document.xml"], fn name ->
             List.keymember?(entries, String.to_charlist(name), 0)
           end),
         :ok <- validate_parts(entries) do
      {:ok, entries}
    else
      false -> {:error, :unsafe_or_unsupported_docx_package}
      error -> error
    end
  rescue
    _ -> {:error, :invalid_docx_package}
  end

  defp safe_part?(name) do
    not String.starts_with?(name, "/") and not String.contains?(name, ["..", "\\", ":", <<0>>]) and
      not Regex.match?(~r/(vbaproject|embeddings\/|activex\/)/i, name)
  end

  defp validate_parts(entries) do
    Enum.reduce_while(entries, :ok, fn {name, bytes}, :ok ->
      name = List.to_string(name)

      if String.ends_with?(name, [".xml", ".rels"]) do
        case validate_xml(bytes) do
          :ok ->
            if external_relationship?(bytes),
              do: {:halt, {:error, :external_document_relationship}},
              else: {:cont, :ok}

          error ->
            {:halt, error}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp external_relationship?(xml) do
    # SAX decodes character references: Extern&#97;l is still an external target.
    {:ok, external, _} =
      :xmerl_sax_parser.stream(xml,
        event_state: false,
        event_fun: fn
          {:startElement, _, _, _, attributes}, _, found ->
            found or
              Enum.any?(attributes, fn {_, _, name, value} ->
                name == ~c"TargetMode" and String.downcase(List.to_string(value)) == "external"
              end)

          _, _, found ->
            found
        end
      )

    external
  end

  defp validate_xml(xml) do
    if not String.valid?(xml) or Regex.match?(~r/<!\s*(?:DOCTYPE|ENTITY)/i, xml) do
      {:error, :unsafe_document_xml}
    else
      case :xmerl_sax_parser.stream(xml, event_fun: fn _, _, state -> state end, event_state: nil) do
        {:ok, nil, rest} when rest in ["", []] -> :ok
        _ -> {:error, :invalid_document_xml}
      end
    end
  end

  defp fetch(entries, name) do
    case List.keyfind(entries, String.to_charlist(name), 0) do
      {_, bytes} -> {:ok, bytes}
      nil -> {:error, :missing_document_part}
    end
  end

  defp paragraphs(xml) do
    Regex.scan(@paragraph, xml)
    |> Enum.with_index(1)
    |> Enum.map(fn {[paragraph], index} ->
      text =
        Regex.scan(~r/<w:t\b[^>]*>(.*?)<\/w:t>/s, paragraph)
        |> Enum.map_join(fn [_, text] -> decode(text) end)

      %{id: index, text: text}
    end)
  end

  defp replacements(paragraphs, edits) do
    Enum.reduce_while(edits, {:ok, %{}}, fn edit, {:ok, acc} ->
      with %{"after_paragraph" => id, "expected_text" => expected, "paragraphs" => texts} <- edit,
           true <- is_integer(id) and id > 0 and is_binary(expected),
           %{text: ^expected} <- Enum.find(paragraphs, &(&1.id == id)),
           true <- not Map.has_key?(acc, id),
           true <- is_list(texts) and length(texts) in 1..20,
           true <-
             Enum.all?(
               texts,
               &(is_binary(&1) and byte_size(&1) in 1..12_000 and String.valid?(&1))
             ),
           true <- Enum.all?(texts, &(not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, &1))) do
        {:cont, {:ok, Map.put(acc, id, Enum.map_join(texts, &body_paragraph/1))}}
      else
        _ -> {:halt, {:error, :invalid_or_stale_document_insertion}}
      end
    end)
  end

  defp replace_paragraphs(xml, replacements) do
    {pieces, cursor} =
      Regex.scan(@paragraph, xml, return: :index)
      |> Enum.with_index(1)
      |> Enum.reduce({[], 0}, fn {[{start, length}], id}, {pieces, cursor} ->
        stop = start + length
        {[pieces, binary_part(xml, cursor, stop - cursor), Map.get(replacements, id, "")], stop}
      end)

    IO.iodata_to_binary([pieces, binary_part(xml, cursor, byte_size(xml) - cursor)])
  end

  defp body_paragraph(text) do
    "<w:p><w:pPr><w:pStyle w:val=\"Normal\"/><w:widowControl/><w:spacing w:after=\"120\" w:line=\"264\" w:lineRule=\"auto\"/></w:pPr><w:r><w:t xml:space=\"preserve\">" <>
      escape(text) <> "</w:t></w:r></w:p>"
  end

  defp escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp decode(text) do
    {:ok, pieces, _} =
      :xmerl_sax_parser.stream("<text>" <> text <> "</text>",
        event_fun: fn
          {:characters, chars}, _, state -> [List.to_string(chars) | state]
          _, _, state -> state
        end,
        event_state: []
      )

    pieces |> Enum.reverse() |> Enum.join()
  end
end
