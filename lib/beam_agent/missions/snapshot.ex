defmodule BeamAgent.Missions.Snapshot do
  @moduledoc "Bounded tracked-file observation for the opt-in documentation mission."
  alias BeamAgent.{CapabilityEnvelope, Subprocess, Workspace}

  def capture(context, paths) do
    with {:ok, tracked} <- tracked_files(context) do
      files = tracked |> Enum.filter(&in_scope?(&1, paths)) |> Enum.sort()

      if length(files) <= 2_000,
        do: read_files(context, files),
        else: {:error, :mission_snapshot_too_large}
    end
  end

  # Only disclose tracked, readable paths from the owning runtime's workspace.
  # Browsing names never reads file contents or invokes a model.
  def browse(context, path) do
    with true <- valid_paths?([path]),
         {:ok, tracked} <- tracked_files(context) do
      prefix = if path == ".", do: "", else: path <> "/"

      entries =
        tracked
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.filter(&browsable?(context, &1))
        |> Enum.map(fn file ->
          remainder = String.replace_prefix(file, prefix, "")
          name = remainder |> String.split("/") |> hd()
          %{path: prefix <> name, name: name, directory: String.contains?(remainder, "/")}
        end)
        |> Enum.uniq()
        |> Enum.sort_by(&{not &1.directory, &1.name})

      {:ok,
       %{
         workspace: context.workspace_root,
         path: path,
         parent: if(path == ".", do: nil, else: Path.dirname(path)),
         entries: Enum.take(entries, 200),
         truncated: length(entries) > 200
       }}
    else
      false -> {:error, :invalid_mission_path}
      error -> error
    end
  end

  defp browsable?(context, path) do
    with true <- valid_paths?([path]),
         :ok <-
           CapabilityEnvelope.authorize(context.capability_envelope, %{
             tools: "read_file",
             paths: path
           }),
         {:ok, resolved} <- Workspace.resolve(context.workspace_root, path),
         true <- resolved == Path.expand(path, context.workspace_root),
         {:ok, %{type: :regular}} <- File.lstat(resolved),
         do: true,
         else: (_ -> false)
  end

  defp tracked_files(context) do
    with :ok <-
           CapabilityEnvelope.authorize(context.capability_envelope, %{
             tools: "git_inspect",
             git_operations: "status"
           }),
         git when is_binary(git) <- System.find_executable("git"),
         {:ok, %{status: 0, output: output, truncated: false}} <-
           Subprocess.run(git, ["ls-files", "-z", "--cached"],
             cwd: context.workspace_root,
             timeout_ms: 5_000,
             max_output_bytes: 500_000
           ) do
      {:ok, output |> String.split(<<0>>, trim: true) |> Enum.uniq()}
    else
      _ -> {:error, :mission_git_observation_unavailable}
    end
  end

  def valid_paths?(paths) do
    is_list(paths) and length(paths) in 1..20 and
      Enum.all?(paths, fn path ->
        is_binary(path) and byte_size(path) in 1..200 and Path.type(path) == :relative and
          (path == "." or not Enum.any?(Path.split(path), &(&1 in [".", "..", ".git"]))) and
          not String.contains?(path, ["\n", "\r", <<0>>])
      end)
  end

  def changed(before, after_files),
    do:
      (Map.keys(before) ++ Map.keys(after_files))
      |> Enum.uniq()
      |> Enum.filter(&(before[&1] != after_files[&1]))
      |> Enum.sort()

  def packet(snapshot, changed) do
    docs =
      snapshot.contents
      |> Map.keys()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.sort()
      |> Enum.take(8)

    selected = Enum.uniq(Enum.take(changed, 12) ++ docs)

    %{
      changed_paths: Enum.take(changed, 100),
      changed_count: length(changed),
      excerpts:
        Map.new(
          selected,
          &{&1, String.slice(snapshot.contents[&1] || "[deleted or unavailable]", 0, 2_000)}
        ),
      truncated: true
    }
  end

  defp in_scope?(path, scopes),
    do: Enum.any?(scopes, &(&1 == "." or path == &1 or String.starts_with?(path, &1 <> "/")))

  defp read_files(context, files) do
    Enum.reduce_while(files, {:ok, %{}, %{}, 0}, fn path, {:ok, hashes, contents, total} ->
      with :ok <-
             CapabilityEnvelope.authorize(context.capability_envelope, %{
               tools: "read_file",
               paths: path
             }),
           {:ok, resolved} <- Workspace.resolve(context.workspace_root, path),
           true <- resolved == Path.expand(path, context.workspace_root),
           {:ok, bytes} <- read_regular(resolved),
           true <- total + byte_size(bytes || "") <= 20_000_000 do
        hash = if bytes, do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower), else: nil

        text =
          if bytes && String.valid?(bytes),
            do: String.slice(bytes, 0, 2_000),
            else: "[binary or deleted]"

        {:cont,
         {:ok, Map.put(hashes, path, hash), Map.put(contents, path, text),
          total + byte_size(bytes || "")}}
      else
        _ -> {:halt, {:error, :mission_snapshot_unavailable}}
      end
    end)
    |> case do
      {:ok, hashes, contents, _} ->
        fingerprint =
          hashes
          |> Enum.sort()
          |> :erlang.term_to_binary()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        {:ok, %{files: hashes, contents: contents, fingerprint: fingerprint}}

      error ->
        error
    end
  end

  defp read_regular(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size <= 2_000_000 ->
        with {:ok, bytes} <- File.read(path),
             true <- byte_size(bytes) <= 2_000_000,
             do: {:ok, bytes}

      {:error, :enoent} ->
        {:ok, nil}

      _ ->
        {:error, :unsupported_observed_file}
    end
  end
end
