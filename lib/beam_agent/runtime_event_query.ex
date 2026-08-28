defmodule BeamAgent.RuntimeEventQuery do
  @moduledoc "Validated filters for inspecting a goal's public runtime-event projection."

  @categories ~w(lifecycle command tool model context policy resource routing outcome mcp verification runtime)a
  @default_limit 24
  @max_limit 100

  @spec categories :: [atom()]
  def categories, do: @categories

  defstruct categories: [],
            types: [],
            worker: :all,
            session: nil,
            correlation: nil,
            causation: nil,
            after_cursor: nil,
            before_cursor: nil,
            redacted: nil,
            order: :asc,
            limit: @default_limit

  @type t :: %__MODULE__{}

  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(query) when is_binary(query) do
    query
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce_while({:ok, %__MODULE__{}}, &parse_token/2)
  end

  @spec run([map()], t()) :: map()
  def run(events, %__MODULE__{} = query) when is_list(events) do
    filtered = Enum.filter(events, &matches?(&1, query))
    matched = length(filtered)

    selected =
      case query.order do
        :asc -> Enum.take(filtered, -query.limit)
        :desc -> filtered |> Enum.reverse() |> Enum.take(query.limit)
      end

    %{
      events: selected,
      total: length(events),
      matched: matched,
      returned: length(selected),
      filters: describe(query)
    }
  end

  @spec describe(t()) :: [String.t()]
  def describe(%__MODULE__{} = query) do
    []
    |> add_description(query.categories != [], "category=#{join_atoms(query.categories)}")
    |> add_description(query.types != [], "type=#{Enum.join(query.types, ",")}")
    |> add_description(query.worker != :all, "worker=#{query.worker}")
    |> add_description(not is_nil(query.session), "session=#{query.session}")
    |> add_description(not is_nil(query.correlation), "correlation=#{query.correlation}")
    |> add_description(not is_nil(query.causation), "causation=#{query.causation}")
    |> add_description(not is_nil(query.after_cursor), "after=#{query.after_cursor}")
    |> add_description(not is_nil(query.before_cursor), "before=#{query.before_cursor}")
    |> add_description(not is_nil(query.redacted), "redacted=#{query.redacted}")
    |> add_description(query.order != :asc, "order=#{query.order}")
    |> Kernel.++(["limit=#{query.limit}"])
  end

  def usage do
    [
      "/events [category=tool,model,routing,resource,outcome,mcp,verification] [type=tool_called,tool_result]",
      "        [worker=root|children] [session=SESSION_PREFIX]",
      "        [correlation=PREFIX] [causation=PREFIX]",
      "        [after=N] [before=N] [redacted=true|false]",
      "        [order=asc|desc] [limit=1..#{@max_limit}]"
    ]
  end

  defp parse_token("help", {:ok, _query}), do: {:halt, {:error, :event_filter_help}}

  defp parse_token(token, {:ok, query}) do
    case String.split(token, "=", parts: 2) do
      [key, value] when value != "" ->
        case put_filter(query, String.downcase(key), value) do
          {:ok, query} -> {:cont, {:ok, query}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _other ->
        {:halt, {:error, {:invalid_event_filter, token}}}
    end
  end

  defp put_filter(query, key, value) when key in ["category", "cat"] do
    with {:ok, categories} <- categories(value) do
      {:ok, %{query | categories: categories}}
    end
  end

  defp put_filter(query, "type", value),
    do: {:ok, %{query | types: comma_values(value)}}

  defp put_filter(query, "worker", "all"), do: {:ok, %{query | worker: :all}}
  defp put_filter(query, "worker", "root"), do: {:ok, %{query | worker: :root}}
  defp put_filter(query, "worker", "children"), do: {:ok, %{query | worker: :children}}

  defp put_filter(_query, "worker", value),
    do: {:error, {:invalid_event_filter_value, "worker", value}}

  defp put_filter(query, "session", value), do: {:ok, %{query | session: value}}

  defp put_filter(query, key, value) when key in ["correlation", "corr"],
    do: {:ok, %{query | correlation: value}}

  defp put_filter(query, key, value) when key in ["causation", "cause"],
    do: {:ok, %{query | causation: value}}

  defp put_filter(query, "after", value), do: put_cursor(query, :after_cursor, value)
  defp put_filter(query, "before", value), do: put_cursor(query, :before_cursor, value)

  defp put_filter(query, "redacted", value) do
    case boolean(value) do
      {:ok, redacted} -> {:ok, %{query | redacted: redacted}}
      :error -> {:error, {:invalid_event_filter_value, "redacted", value}}
    end
  end

  defp put_filter(query, "order", "asc"), do: {:ok, %{query | order: :asc}}
  defp put_filter(query, "order", "desc"), do: {:ok, %{query | order: :desc}}

  defp put_filter(_query, "order", value),
    do: {:error, {:invalid_event_filter_value, "order", value}}

  defp put_filter(query, "limit", value) do
    with {:ok, limit} <- integer(value),
         true <- limit in 1..@max_limit do
      {:ok, %{query | limit: limit}}
    else
      _invalid -> {:error, {:invalid_event_filter_value, "limit", value}}
    end
  end

  defp put_filter(_query, key, _value), do: {:error, {:unknown_event_filter, key}}

  defp put_cursor(query, field, value) do
    case integer(value) do
      {:ok, cursor} -> {:ok, Map.put(query, field, cursor)}
      _invalid -> {:error, {:invalid_event_filter_value, Atom.to_string(field), value}}
    end
  end

  defp categories(value) do
    categories = comma_values(value)

    Enum.reduce_while(categories, {:ok, []}, fn category, {:ok, parsed} ->
      case Enum.find(@categories, &(Atom.to_string(&1) == category)) do
        nil -> {:halt, {:error, {:invalid_event_filter_value, "category", category}}}
        category -> {:cont, {:ok, parsed ++ [category]}}
      end
    end)
  end

  defp comma_values(value),
    do: value |> String.split(",", trim: true) |> Enum.map(&String.downcase/1) |> Enum.uniq()

  defp integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> :error
    end
  end

  defp boolean("true"), do: {:ok, true}
  defp boolean("false"), do: {:ok, false}
  defp boolean(_value), do: :error

  defp matches?(event, query) do
    category_matches?(event, query.categories) and
      type_matches?(event, query.types) and
      worker_matches?(event, query.worker) and
      prefix_matches?(event.scope.session_id, query.session) and
      identity_matches?(event.correlation_id, query.correlation, "none") and
      identity_matches?(event.causation_id, query.causation, "root") and
      cursor_matches?(event.goal_seq, query.after_cursor, query.before_cursor) and
      redaction_matches?(event, query.redacted)
  end

  defp category_matches?(_event, []), do: true
  defp category_matches?(event, categories), do: event.category in categories

  defp type_matches?(_event, []), do: true
  defp type_matches?(event, types), do: String.downcase(to_string(event.payload.type)) in types

  defp worker_matches?(_event, :all), do: true
  defp worker_matches?(event, :root), do: event.scope.root?
  defp worker_matches?(event, :children), do: not event.scope.root?

  defp prefix_matches?(_value, nil), do: true
  defp prefix_matches?(nil, _prefix), do: false

  defp prefix_matches?(value, prefix) do
    value = to_string(value)
    String.starts_with?(value, prefix) or String.starts_with?(short_id(value), prefix)
  end

  defp identity_matches?(_value, nil, _nil_label), do: true
  defp identity_matches?(nil, prefix, nil_label), do: prefix == nil_label
  defp identity_matches?(value, prefix, _nil_label), do: prefix_matches?(value, prefix)

  defp cursor_matches?(goal_seq, after_cursor, before_cursor) do
    (is_nil(after_cursor) or goal_seq > after_cursor) and
      (is_nil(before_cursor) or goal_seq < before_cursor)
  end

  defp redaction_matches?(_event, nil), do: true
  defp redaction_matches?(event, redacted), do: Map.get(event, :redacted?, false) == redacted

  defp short_id(value) do
    suffix =
      case String.split(value, "-", parts: 2) do
        [_prefix, suffix] -> suffix
        [value] -> value
      end

    String.slice(suffix, 0, 8)
  end

  defp join_atoms(values), do: values |> Enum.map(&Atom.to_string/1) |> Enum.join(",")

  defp add_description(descriptions, true, description), do: descriptions ++ [description]
  defp add_description(descriptions, false, _description), do: descriptions
end
