defmodule BeamAgent.Project.ContextStore do
  @moduledoc """
  Project-owned, provenance-bearing working context.

  Artifacts are versioned observations, not prompt history. Newer source
  versions supersede older observations and callers request bounded projections
  by kind instead of receiving the entire project state.
  """
  use GenServer

  alias BeamAgent.Names

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:project_context_store, project_id))
  end

  def put(project_id, attributes), do: call(project_id, {:put, attributes})
  def fetch(project_id, artifact_id), do: call(project_id, {:fetch, artifact_id})
  def invalidate(project_id, selector), do: call(project_id, {:invalidate, selector})
  def assemble(project_id, request \\ %{}), do: call(project_id, {:assemble, request})
  def list(project_id), do: call(project_id, :list)

  def put_preferences(project_id, preferences) when is_map(preferences) do
    put(project_id, %{
      id: "project:preferences",
      kind: "preference",
      source: "user_runtime_configuration",
      source_version: System.system_time(:millisecond),
      content: JSON.encode!(stringify(preferences)),
      confidence: 1.0,
      metadata: %{authority: "user"}
    })
  end

  def preferences(project_id) do
    case fetch(project_id, "project:preferences") do
      {:ok, %{status: :current, content: content}} ->
        case JSON.decode(content) do
          {:ok, preferences} when is_map(preferences) -> {:ok, preferences}
          _other -> {:error, :invalid_project_preferences}
        end

      {:ok, %{status: :invalidated}} ->
        {:ok, %{}}

      {:error, :unknown_context_artifact} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    data_dir =
      Keyword.get_lazy(opts, :data_dir, fn -> Application.fetch_env!(:beam_agent, :data_dir) end)

    project_id = Keyword.fetch!(opts, :project_id)
    path = Path.join([data_dir, "projects", project_id, "context_artifacts.jsonl"])

    with :ok <- File.mkdir_p(Path.dirname(path)), {:ok, artifacts} <- load(path) do
      # A prior process may have left a long append-only history behind (every
      # put ever made, not just the current versions); shrink it back down to
      # what `artifacts` already represents before it grows further.
      _ = compact(path, artifacts)
      {:ok, %{project_id: project_id, path: path, artifacts: artifacts}}
    end
  end

  @impl true
  def handle_call({:put, attributes}, _from, state) do
    with {:ok, artifact} <- normalize(attributes),
         :ok <- accept_version(state.artifacts[artifact.id], artifact) do
      artifacts = Map.put(state.artifacts, artifact.id, artifact)

      case compact(state.path, artifacts) do
        :ok -> {:reply, {:ok, artifact}, %{state | artifacts: artifacts}}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fetch, artifact_id}, _from, state) do
    case state.artifacts[artifact_id] do
      nil -> {:reply, {:error, :unknown_context_artifact}, state}
      artifact -> {:reply, {:ok, artifact}, state}
    end
  end

  def handle_call({:invalidate, selector}, _from, state) do
    {matched, artifacts} =
      Map.new(state.artifacts, fn {id, artifact} ->
        if matches?(artifact, selector) do
          {id, Map.put(artifact, :status, :invalidated)}
        else
          {id, artifact}
        end
      end)
      |> then(fn artifacts ->
        {Enum.count(artifacts, fn {_id, artifact} -> artifact.status == :invalidated end),
         artifacts}
      end)

    case compact(state.path, artifacts) do
      :ok -> {:reply, {:ok, matched}, %{state | artifacts: artifacts}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:assemble, request}, _from, state) do
    kinds = request[:kinds] || request["kinds"] || :all
    maximum_bytes = request[:maximum_bytes] || request["maximum_bytes"] || 64_000
    normalized_kinds = if kinds == :all, do: :all, else: Enum.map(kinds, &to_string/1)

    artifacts =
      state.artifacts
      |> Map.values()
      |> Enum.filter(&(&1.status == :current))
      |> Enum.filter(&(normalized_kinds == :all or &1.kind in normalized_kinds))
      |> Enum.sort_by(&{&1.kind, &1.id})
      |> take_within(maximum_bytes)

    view = %{
      version: 1,
      project_id: state.project_id,
      generated_at: DateTime.utc_now(),
      artifacts: artifacts,
      total_bytes: Enum.sum(Enum.map(artifacts, & &1.size_bytes)),
      provenance: Enum.map(artifacts, &Map.take(&1, [:id, :kind, :source, :observed_at, :hash]))
    }

    {:reply, {:ok, view}, state}
  end

  def handle_call(:list, _from, state),
    do: {:reply, {:ok, state.artifacts |> Map.values() |> Enum.sort_by(& &1.id)}, state}

  defp normalize(attributes) when is_map(attributes) do
    kind = value(attributes, :kind)
    source = value(attributes, :source)
    content = value(attributes, :content)
    source_version = value(attributes, :source_version) || 0
    id = value(attributes, :id) || default_id(kind, source)

    if is_binary(id) and id != "" and is_binary(kind) and kind != "" and
         is_binary(source) and source != "" and is_binary(content) and
         is_integer(source_version) and source_version >= 0 do
      {:ok,
       %{
         id: id,
         kind: kind,
         source: source,
         source_version: source_version,
         content: content,
         hash: hash(content),
         size_bytes: byte_size(content),
         confidence: value(attributes, :confidence) || 1.0,
         metadata: value(attributes, :metadata) || %{},
         observed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         status: :current
       }}
    else
      {:error, :invalid_context_artifact}
    end
  end

  defp normalize(_attributes), do: {:error, :invalid_context_artifact}
  defp accept_version(nil, _artifact), do: :ok

  defp accept_version(existing, artifact) do
    if artifact.source_version >= existing.source_version,
      do: :ok,
      else: {:error, :stale_context_artifact}
  end

  defp matches?(artifact, selector) when is_map(selector) do
    Enum.all?(selector, fn {key, expected} -> Map.get(artifact, atom_key(key)) == expected end)
  end

  defp matches?(artifact, id) when is_binary(id), do: artifact.id == id
  defp matches?(_artifact, _selector), do: false

  defp take_within(artifacts, maximum_bytes) do
    artifacts
    |> Enum.reduce_while({[], 0}, fn artifact, {selected, used} ->
      if used + artifact.size_bytes <= maximum_bytes,
        do: {:cont, {[artifact | selected], used + artifact.size_bytes}},
        else: {:halt, {selected, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp load(path) do
    case File.read(path) do
      {:ok, contents} ->
        artifacts =
          contents
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            case JSON.decode(line) do
              {:ok, %{"type" => "artifact_put", "artifact" => artifact}} ->
                artifact = atomize(artifact)
                Map.put(acc, artifact.id, artifact)

              {:ok, %{"type" => "artifacts_invalidated", "selector" => selector}} ->
                Map.new(acc, fn {id, artifact} ->
                  if matches?(artifact, selector),
                    do: {id, Map.put(artifact, :status, :invalidated)},
                    else: {id, artifact}
                end)

              _other ->
                acc
            end
          end)

        {:ok, artifacts}

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Rewrites the file to hold exactly the current artifacts, one per line, so
  # it stays proportional to distinct artifacts instead of every put ever
  # made. A temp-file rename keeps a crash mid-write from truncating history.
  defp compact(path, artifacts) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      body =
        artifacts
        |> Map.values()
        |> Enum.map(
          &[JSON.encode!(%{"type" => "artifact_put", "artifact" => stringify(&1)}), "\n"]
        )

      temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

      with :ok <- File.write(temporary, body, [:binary]) do
        File.rename(temporary, path)
      else
        error ->
          File.rm(temporary)
          error
      end
    end
  end

  defp default_id(kind, source), do: "#{kind}:#{source}"
  defp hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  defp value(map, key), do: map[key] || map[to_string(key)]
  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key), do: String.to_existing_atom(key)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify(value), do: value

  defp atomize(map) do
    map
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
    |> Map.update(:status, :current, &String.to_existing_atom/1)
  end

  defp call(project_id, message) do
    with {:ok, pid} <- Names.pid(:project_context_store, project_id),
         do: GenServer.call(pid, message)
  end
end
