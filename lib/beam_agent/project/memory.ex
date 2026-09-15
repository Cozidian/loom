defmodule BeamAgent.Project.Memory do
  @moduledoc """
  Project-owned durable memory: facts, feedback and preferences that outlive
  one session, written and read by the agent itself (not prompt history).

  Bounded by entry count and total content bytes so a runaway agent cannot
  turn this into an unbounded append log; entries are upserted by id and
  removed explicitly, never silently evicted.
  """
  use GenServer

  alias BeamAgent.Names

  @types ~w(user feedback project reference)
  @max_description_bytes 300
  @max_content_bytes 8_000
  @default_max_entries 200
  @default_max_bytes 500_000

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:project_memory, project_id))
  end

  def put(project_id, attributes), do: call(project_id, {:put, attributes})
  def forget(project_id, id), do: call(project_id, {:forget, id})
  def list(project_id), do: call(project_id, :list)
  def fetch(project_id, id), do: call(project_id, {:fetch, id})

  @impl true
  def init(opts) do
    data_dir =
      Keyword.get_lazy(opts, :data_dir, fn -> Application.fetch_env!(:beam_agent, :data_dir) end)

    project_id = Keyword.fetch!(opts, :project_id)
    path = Path.join([data_dir, "projects", project_id, "memory.jsonl"])

    with :ok <- File.mkdir_p(Path.dirname(path)), {:ok, entries} <- load(path) do
      _ = compact(path, entries)

      {:ok,
       %{
         project_id: project_id,
         path: path,
         entries: entries,
         enabled: Keyword.get(opts, :memory_enabled, true) != false,
         max_entries: positive(opts, :memory_max_entries, @default_max_entries),
         max_bytes: positive(opts, :memory_max_bytes, @default_max_bytes)
       }}
    end
  end

  @impl true
  def handle_call({:put, _attributes}, _from, %{enabled: false} = state),
    do: {:reply, {:error, :memory_disabled}, state}

  def handle_call({:put, attributes}, _from, state) do
    with {:ok, entry} <- normalize(attributes, state.entries[id_of(attributes)]),
         entries = Map.put(state.entries, entry.id, entry),
         :ok <- within_bounds(entries, state, new?: not Map.has_key?(state.entries, entry.id)),
         :ok <- compact(state.path, entries) do
      {:reply, {:ok, entry}, %{state | entries: entries}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:forget, id}, _from, state) when is_binary(id) do
    if Map.has_key?(state.entries, id) do
      entries = Map.delete(state.entries, id)

      case compact(state.path, entries) do
        :ok -> {:reply, :ok, %{state | entries: entries}}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :unknown_memory}, state}
    end
  end

  def handle_call({:fetch, id}, _from, state) do
    case state.entries[id] do
      nil -> {:reply, {:error, :unknown_memory}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  def handle_call(:list, _from, state) do
    index =
      state.entries
      |> Map.values()
      |> Enum.sort_by(& &1.updated_at, :desc)
      |> Enum.map(&Map.take(&1, [:id, :type, :description, :updated_at]))

    {:reply, {:ok, index}, state}
  end

  defp id_of(attributes), do: value(attributes, :id) || slug(value(attributes, :description))

  defp normalize(attributes, existing) do
    type = value(attributes, :type)
    description = value(attributes, :description)
    content = value(attributes, :content)
    id = id_of(attributes)
    links = value(attributes, :links) || []
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    cond do
      not (is_binary(id) and id != "") ->
        {:error, :memory_requires_a_description_or_id}

      type not in @types ->
        {:error, {:invalid_memory_type, type}}

      not valid_text?(description, @max_description_bytes) ->
        {:error, :invalid_memory_description}

      not valid_text?(content, @max_content_bytes) ->
        {:error, :invalid_memory_content}

      not (is_list(links) and Enum.all?(links, &is_binary/1)) ->
        {:error, :invalid_memory_links}

      true ->
        {:ok,
         %{
           id: id,
           type: type,
           description: description,
           content: content,
           links: links,
           created_at: (existing && existing.created_at) || now,
           updated_at: now
         }}
    end
  end

  defp valid_text?(value, max_bytes),
    do: is_binary(value) and value != "" and byte_size(value) <= max_bytes

  defp within_bounds(entries, state, new?: new?) do
    total_bytes = entries |> Map.values() |> Enum.map(&entry_bytes/1) |> Enum.sum()

    cond do
      new? and map_size(entries) > state.max_entries ->
        {:error, :memory_entry_limit_reached}

      total_bytes > state.max_bytes ->
        {:error, :memory_byte_limit_reached}

      true ->
        :ok
    end
  end

  defp entry_bytes(entry), do: byte_size(entry.description) + byte_size(entry.content)

  defp slug(description) when is_binary(description) and description != "" do
    description
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 64)
  end

  defp slug(_description), do: nil

  defp value(map, key), do: map[key] || map[to_string(key)]

  # Rewrites the file to hold exactly the current entries, one per line, so it
  # stays proportional to distinct memories instead of every put ever made.
  defp compact(path, entries) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      body =
        entries
        |> Map.values()
        |> Enum.map(&[JSON.encode!(stringify(&1)), "\n"])

      temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

      with :ok <- File.write(temporary, body, [:binary]),
           :ok <- File.chmod(temporary, 0o600) do
        File.rename(temporary, path)
      else
        error ->
          File.rm(temporary)
          error
      end
    end
  end

  defp load(path) do
    case File.read(path) do
      {:ok, contents} ->
        entries =
          contents
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            case JSON.decode(line) do
              {:ok, %{"id" => id} = entry} -> Map.put(acc, id, atomize(entry))
              _other -> acc
            end
          end)

        {:ok, entries}

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp positive(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp atomize(map),
    do:
      Map.new(map, fn
        {"id", value} -> {:id, value}
        {"type", value} -> {:type, value}
        {"description", value} -> {:description, value}
        {"content", value} -> {:content, value}
        {"links", value} -> {:links, value}
        {"created_at", value} -> {:created_at, value}
        {"updated_at", value} -> {:updated_at, value}
        {key, value} -> {key, value}
      end)

  defp call(project_id, message) do
    with {:ok, pid} <- Names.pid(:project_memory, project_id),
         do: GenServer.call(pid, message)
  end
end
