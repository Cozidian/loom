defmodule BeamAgent.Session.FileReference do
  @moduledoc """
  Parses workspace `@path` mentions and creates bounded, replayable snapshots.

  Event payloads carry metadata and an internal snapshot path, never the file
  contents themselves. Model context hydrates the immutable snapshot lazily.
  """

  alias BeamAgent.{CapabilityEnvelope, Workspace}
  alias BeamAgent.Project.RepositoryIndex

  @candidate_pattern ~r/(?:^|(?<=[\s\(\[\{<"']))@(?:"([^"\n]+)"|([^\s\)\]\}\>,;:!?]+))/u
  @max_file_bytes 64_000
  @max_total_bytes 128_000
  @secret_names MapSet.new(
                  ~w(.env .env.local .env.production credentials credentials.json secrets secrets.json id_rsa id_ed25519)
                )
  @secret_extensions ~w(.pem .key .p12 .pfx)

  def resolve(prompt, workspace_root) when is_binary(workspace_root) do
    case Workspace.canonical_root(workspace_root) do
      {:ok, canonical_root} -> resolve(prompt, %{workspace_root: canonical_root})
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve(prompt, context) when is_binary(prompt) and is_map(context) do
    candidates = candidates(prompt)

    if candidates == [] do
      {:ok, %{prompt: prompt, resolved: [], rejected: []}}
    else
      do_resolve(candidates, prompt, context)
    end
  end

  def resolve(_prompt, _context), do: {:error, :invalid_reference_input}

  defp do_resolve(candidates, prompt, context) do
    with input_root when is_binary(input_root) <- value(context, :workspace_root),
         {:ok, workspace_root} <- Workspace.canonical_root(input_root),
         context <- Map.put(context, :workspace_root, workspace_root),
         :ok <- maybe_refresh_index(context) do
      {resolved, rejected, _seen, _used} =
        candidates
        |> Enum.reduce({[], [], MapSet.new(), 0}, fn candidate,
                                                     {resolved, rejected, seen, used} ->
          remaining = max(0, @max_total_bytes - used)

          case resolve_candidate(candidate, context, remaining) do
            {:ok, reference} ->
              identity = reference.path

              if MapSet.member?(seen, identity) do
                {resolved, rejected, seen, used}
              else
                {[reference | resolved], rejected, MapSet.put(seen, identity),
                 used + reference.size_bytes}
              end

            {:error, reference} ->
              {resolved, [reference | rejected], seen, used}
          end
        end)

      {:ok, %{prompt: prompt, resolved: Enum.reverse(resolved), rejected: Enum.reverse(rejected)}}
    else
      nil -> {:error, :invalid_reference_input}
      {:error, reason} -> {:error, reason}
    end
  end

  def render_prompt(prompt, resolved_references)
      when is_binary(prompt) and is_list(resolved_references) do
    references = Enum.map(resolved_references, &hydrate_reference/1)

    case references do
      [] ->
        prompt

      references ->
        prompt <>
          "\n\n<workspace_file_references untrusted=\"true\">\n" <>
          Enum.map_join(references, "\n\n", &render_reference/1) <>
          "\n</workspace_file_references>"
    end
  end

  def public_list(references) when is_list(references), do: Enum.map(references, &public/1)

  def public(reference) when is_map(reference) do
    Map.take(reference, [
      :artifact_id,
      :raw,
      :path,
      :size_bytes,
      :source_size_bytes,
      :line_count,
      :sha256,
      :status,
      :reason,
      :truncated,
      :provenance
    ])
  end

  defp candidates(prompt) do
    Regex.scan(@candidate_pattern, prompt)
    |> Enum.map(&extract_candidate/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_unquoted(path), do: String.replace(path, ~r/\.+$/u, "")

  defp resolve_candidate(%{raw: raw, path: path}, context, remaining) do
    workspace_root = value(context, :workspace_root)

    with :ok <- validate_reference_path(path),
         :ok <- authorize(context, path),
         :ok <- indexed(context, path),
         {:ok, absolute_path} <- Workspace.resolve(workspace_root, path),
         {:ok, %File.Stat{type: :regular, size: source_size}} <- File.stat(absolute_path),
         :ok <- validate_remaining(remaining),
         {:ok, content, truncated} <-
           read_snapshot(absolute_path, min(@max_file_bytes, remaining)),
         true <- text_content?(content),
         sha256 <- file_sha256(absolute_path),
         artifact_id <- artifact_id(path, sha256),
         {:ok, snapshot_path} <- persist_snapshot(context, artifact_id, content) do
      reference = %{
        artifact_id: artifact_id,
        raw: raw,
        path: Workspace.relative(workspace_root, absolute_path),
        snapshot_path: snapshot_path,
        source_path: absolute_path,
        size_bytes: byte_size(content),
        source_size_bytes: source_size,
        line_count: line_count(content),
        sha256: sha256,
        status: "resolved",
        truncated: truncated,
        provenance: "workspace_reference"
      }

      reference = if snapshot_path, do: reference, else: Map.put(reference, :content, content)
      {:ok, reference}
    else
      false ->
        {:error, rejected(raw, path, :binary_file)}

      {:ok, %File.Stat{type: type}} ->
        {:error, rejected(raw, path, {:not_regular_file, type})}

      {:error, :enoent} ->
        {:error, rejected(raw, path, :file_not_found)}

      {:error, {:workspace_escape, _}} ->
        {:error, rejected(raw, path, :workspace_escape)}

      {:error, {:workspace_path_must_be_relative, _}} ->
        {:error, rejected(raw, path, :workspace_path_must_be_relative)}

      {:error, {:invalid_workspace_path, _}} ->
        {:error, rejected(raw, path, :invalid_workspace_path)}

      {:error, reason} ->
        {:error, rejected(raw, path, reason)}
    end
  end

  defp validate_reference_path(""), do: {:error, :invalid_workspace_path}

  defp validate_reference_path(path) do
    basename = Path.basename(path) |> String.downcase()
    extension = Path.extname(basename)

    if MapSet.member?(@secret_names, basename) or extension in @secret_extensions or
         String.contains?(String.downcase(path), ["/.ssh/", "/secrets/"]) do
      {:error, :secret_file}
    else
      :ok
    end
  end

  defp authorize(context, path) do
    CapabilityEnvelope.authorize(value(context, :capability_envelope), %{paths: path})
  end

  defp indexed(context, path) do
    case value(context, :project_id) do
      project_id when is_binary(project_id) ->
        case RepositoryIndex.file(project_id, path) do
          {:ok, _file} -> :ok
          {:error, :unknown_repository_file} -> {:error, :ignored_or_unindexed_file}
          {:error, reason} -> {:error, reason}
        end

      _none ->
        :ok
    end
  end

  defp maybe_refresh_index(context) do
    case value(context, :project_id) do
      project_id when is_binary(project_id) ->
        case RepositoryIndex.refresh(project_id) do
          {:ok, _snapshot} -> :ok
          {:error, :not_found} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _none ->
        :ok
    end
  end

  defp validate_remaining(remaining) when remaining > 0, do: :ok
  defp validate_remaining(_remaining), do: {:error, :reference_context_limit_exceeded}

  defp read_snapshot(path, maximum_bytes) when maximum_bytes > 0 do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, maximum_bytes + 4) do
          :eof ->
            {:ok, "", false}

          {:error, reason} ->
            {:error, reason}

          data ->
            truncated = byte_size(data) > maximum_bytes
            prefix = binary_part(data, 0, min(byte_size(data), maximum_bytes))

            case valid_text_prefix(prefix, truncated) do
              {:ok, content} ->
                {:ok, content, truncated or byte_size(content) < byte_size(data)}

              {:error, reason} ->
                {:error, reason}
            end
        end
      after
        File.close(io)
      end
    end
  end

  defp valid_prefix(""), do: ""

  defp valid_prefix(content) do
    if String.valid?(content),
      do: content,
      else: valid_prefix(binary_part(content, 0, byte_size(content) - 1))
  end

  # A text file can be truncated in the middle of a UTF-8 codepoint. Only
  # permit trimming the at-most-three incomplete trailing bytes in that case;
  # invalid bytes elsewhere indicate a binary file and must not be silently
  # converted into an empty snapshot.
  defp valid_text_prefix(prefix, _truncated) when prefix == "", do: {:ok, ""}

  defp valid_text_prefix(prefix, truncated) do
    cond do
      String.valid?(prefix) ->
        {:ok, prefix}

      truncated ->
        content = valid_prefix(prefix)
        removed = byte_size(prefix) - byte_size(content)

        if removed in 1..3 and content != "",
          do: {:ok, content},
          else: {:error, :binary_file}

      true ->
        {:error, :binary_file}
    end
  end

  defp persist_snapshot(context, artifact_id, content) do
    with data_dir when is_binary(data_dir) <- value(context, :data_dir),
         session_id when is_binary(session_id) <- value(context, :session_id) do
      directory = Path.join([data_dir, session_id, "file_references"])
      path = Path.join(directory, artifact_id <> ".txt")

      with :ok <- File.mkdir_p(directory),
           :ok <- write_once(path, content),
           :ok <- File.chmod(path, 0o600) do
        {:ok, path}
      end
    else
      _missing -> {:ok, nil}
    end
  end

  defp write_once(path, content) do
    case File.write(path, content, [:binary, :exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp hydrate_reference(reference) do
    content =
      case value(reference, :content) do
        content when is_binary(content) -> content
        _other -> read_persisted(value(reference, :snapshot_path))
      end

    reference
    |> Map.put(:content, content)
    |> Map.put(:status, source_status(reference))
  end

  defp source_status(reference) do
    source_path = value(reference, :source_path)
    expected = value(reference, :sha256)

    cond do
      not is_binary(source_path) -> value(reference, :status) || "resolved"
      not File.exists?(source_path) -> "deleted"
      file_sha256(source_path) == expected -> "resolved"
      true -> "changed"
    end
  rescue
    _error -> "unreadable"
  end

  defp read_persisted(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _reason} -> "[referenced file snapshot unavailable]"
    end
  end

  defp read_persisted(_path), do: "[referenced file snapshot unavailable]"

  defp rejected(raw, path, reason) do
    %{
      raw: raw,
      path: path,
      reason: reason_code(reason),
      status: "rejected",
      provenance: "workspace_reference"
    }
  end

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      code when is_atom(code) -> Atom.to_string(code)
      _other -> inspect(reason)
    end
  end

  defp reason_code(reason), do: inspect(reason)

  defp text_content?(content), do: String.valid?(content) and not String.contains?(content, <<0>>)
  defp line_count(""), do: 0

  defp line_count(content) do
    count = content |> String.split("\n", trim: false) |> length()
    if String.ends_with?(content, "\n"), do: count - 1, else: count
  end

  defp file_sha256(path) do
    path
    |> File.stream!([], 64_000)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp artifact_id(path, sha256) do
    digest = :crypto.hash(:sha256, path <> ":" <> sha256) |> Base.url_encode64(padding: false)
    "file-" <> binary_part(digest, 0, 20)
  end

  defp extract_candidate([raw, quoted_path, unquoted_path]) do
    path =
      case quoted_path do
        value when is_binary(value) and value != "" -> value
        _other -> normalize_unquoted(unquoted_path || "")
      end

    %{raw: raw, path: path}
  end

  defp extract_candidate([raw, quoted_path]) when is_binary(quoted_path) and quoted_path != "" do
    %{raw: raw, path: quoted_path}
  end

  defp extract_candidate(_match), do: nil

  defp render_reference(reference) do
    """
    <workspace_file artifact_id="#{xml_escape(value(reference, :artifact_id))}" path="#{xml_escape(value(reference, :path))}" sha256="#{xml_escape(value(reference, :sha256))}" status="#{xml_escape(value(reference, :status))}" truncated="#{value(reference, :truncated) || false}" source_size_bytes="#{value(reference, :source_size_bytes)}">
    #{value(reference, :content) || ""}
    </workspace_file>
    """
    |> String.trim()
  end

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
