defmodule BeamAgent.DecompositionPlan do
  @moduledoc """
  Validated, deterministic dependency graph for bounded delegated work.

  The plan contains semantic worker proposals, but it does not carry effective
  authority. Every task is still passed through `AgentConstructor` and runtime
  policy when it is started.
  """

  @enforce_keys [:id, :tasks]
  defstruct version: 1, id: nil, tasks: %{}, created_at: nil

  @type task :: %{
          required(:id) => String.t(),
          required(:goal) => String.t(),
          required(:depends_on) => [String.t()],
          optional(atom()) => term()
        }

  @type t :: %__MODULE__{
          version: pos_integer(),
          id: String.t(),
          tasks: %{String.t() => task()},
          created_at: DateTime.t()
        }

  def new(attributes) when is_map(attributes) do
    raw_tasks = value(attributes, :tasks) || []

    with {:ok, tasks} <- normalize_tasks(raw_tasks),
         :ok <- validate_single_implementation_owner(tasks),
         :ok <- validate_dependencies(tasks),
         :ok <- validate_acyclic(tasks) do
      {:ok,
       %__MODULE__{
         id: value(attributes, :id) || new_id(),
         tasks: Map.new(tasks, &{&1.id, &1}),
         created_at: DateTime.utc_now()
       }}
    end
  end

  def new(_attributes), do: {:error, :invalid_decomposition_plan}

  def ready(%__MODULE__{} = plan, statuses) when is_map(statuses) do
    plan.tasks
    |> Map.values()
    |> Enum.filter(fn task ->
      Map.get(statuses, task.id, :pending) == :pending and
        Enum.all?(task.depends_on, &(Map.get(statuses, &1) == :completed))
    end)
    |> Enum.sort_by(& &1.id)
  end

  def blocked(%__MODULE__{} = plan, statuses) when is_map(statuses) do
    plan.tasks
    |> Map.values()
    |> Enum.filter(fn task ->
      Map.get(statuses, task.id, :pending) == :pending and
        Enum.any?(task.depends_on, &(Map.get(statuses, &1) in [:failed, :cancelled, :blocked]))
    end)
    |> Enum.sort_by(& &1.id)
  end

  def terminal?(%__MODULE__{} = plan, statuses) do
    Enum.all?(Map.keys(plan.tasks), fn id ->
      Map.get(statuses, id, :pending) in [:completed, :failed, :cancelled, :blocked]
    end)
  end

  def to_map(%__MODULE__{} = plan) do
    %{
      "version" => plan.version,
      "id" => plan.id,
      "created_at" => plan.created_at && DateTime.to_iso8601(plan.created_at),
      "tasks" =>
        plan.tasks
        |> Map.values()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(&stringify/1)
    }
  end

  defp normalize_tasks(tasks) when is_list(tasks) and tasks != [] do
    tasks
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn raw, {:ok, acc, ids} ->
      with {:ok, task} <- normalize_task(raw),
           false <- MapSet.member?(ids, task.id) do
        {:cont, {:ok, [task | acc], MapSet.put(ids, task.id)}}
      else
        true -> {:halt, {:error, {:duplicate_task_id, value(raw, :id)}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized, _ids} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_tasks(_tasks), do: {:error, :decomposition_requires_tasks}

  defp normalize_task(raw) when is_map(raw) do
    id = value(raw, :id)
    goal = value(raw, :goal)
    dependencies = value(raw, :depends_on) || []

    if is_binary(id) and id != "" and is_binary(goal) and goal != "" and
         is_list(dependencies) and Enum.all?(dependencies, &is_binary/1) do
      {:ok,
       %{
         id: id,
         goal: goal,
         depends_on: Enum.uniq(dependencies),
         role: value(raw, :role),
         template: value(raw, :template),
         instructions: value(raw, :instructions) || [],
         capabilities: value(raw, :capabilities),
         model_requirements: value(raw, :model_requirements),
         verification_requirements: value(raw, :verification_requirements),
         maximum_attempts: normalize_maximum_attempts(value(raw, :maximum_attempts)),
         completion_criteria:
           value(raw, :completion_criteria) || "Return a result that satisfies the task goal"
       }}
    else
      {:error, {:invalid_decomposition_task, id}}
    end
  end

  defp normalize_task(_raw), do: {:error, :invalid_decomposition_task}

  defp validate_dependencies(tasks) do
    ids = MapSet.new(tasks, & &1.id)

    case Enum.find(tasks, fn task ->
           task.id in task.depends_on or
             Enum.any?(task.depends_on, &(not MapSet.member?(ids, &1)))
         end) do
      nil -> :ok
      task -> {:error, {:invalid_task_dependencies, task.id}}
    end
  end

  defp validate_single_implementation_owner(tasks) do
    implementers =
      Enum.filter(tasks, fn task ->
        task.template == "implementer" or
          BeamAgent.TaskClassifier.classify(task.goal).task_type == :implementation
      end)

    case implementers do
      [] ->
        :ok

      [_one] ->
        :ok

      many ->
        if noncompeting_implementers?(many, tasks),
          do: :ok,
          else: {:error, {:multiple_implementation_owners, Enum.map(many, & &1.id)}}
    end
  end

  defp noncompeting_implementers?(implementers, tasks) do
    tasks_by_id = Map.new(tasks, &{&1.id, &1})

    implementers
    |> Enum.with_index()
    |> Enum.all?(fn {task, index} ->
      implementers
      |> Enum.drop(index + 1)
      |> Enum.all?(fn other ->
        disjoint_implementation_paths?(task, other) or
          depends_transitively?(task.id, other.id, tasks_by_id) or
          depends_transitively?(other.id, task.id, tasks_by_id)
      end)
    end)
  end

  defp disjoint_implementation_paths?(left, right) do
    with [_ | _] = left_paths <- implementation_paths(left),
         [_ | _] = right_paths <- implementation_paths(right) do
      Enum.all?(left_paths, fn path ->
        Enum.all?(right_paths, &(not overlapping_path?(path, &1)))
      end)
    else
      _other -> false
    end
  end

  defp depends_transitively?(task_id, dependency_id, tasks, visited \\ MapSet.new()) do
    if MapSet.member?(visited, task_id) do
      false
    else
      case tasks[task_id] do
        nil ->
          false

        task ->
          dependency_id in task.depends_on or
            Enum.any?(task.depends_on, fn parent_id ->
              depends_transitively?(
                parent_id,
                dependency_id,
                tasks,
                MapSet.put(visited, task_id)
              )
            end)
      end
    end
  end

  defp implementation_paths(task) do
    capabilities = task.capabilities || %{}

    case value(capabilities, :paths) do
      paths when is_list(paths) ->
        paths
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim_trailing(&1, "/"))
        |> Enum.reject(&(&1 == ""))

      _other ->
        nil
    end
  end

  defp overlapping_path?(left, right) do
    left == right or String.starts_with?(left, right <> "/") or
      String.starts_with?(right, left <> "/")
  end

  defp validate_acyclic(tasks) do
    remaining = Map.new(tasks, &{&1.id, MapSet.new(&1.depends_on)})
    eliminate_dependencies(remaining)
  end

  defp eliminate_dependencies(remaining) when map_size(remaining) == 0, do: :ok

  defp eliminate_dependencies(remaining) do
    ready = for {id, dependencies} <- remaining, MapSet.size(dependencies) == 0, do: id

    if ready == [] do
      {:error, :cyclic_task_dependencies}
    else
      ready = MapSet.new(ready)

      next =
        remaining
        |> Map.drop(MapSet.to_list(ready))
        |> Map.new(fn {id, dependencies} -> {id, MapSet.difference(dependencies, ready)} end)

      eliminate_dependencies(next)
    end
  end

  defp value(map, key), do: map[key] || map[to_string(key)]

  defp normalize_maximum_attempts(value) when is_integer(value), do: value |> max(1) |> min(4)
  defp normalize_maximum_attempts(_value), do: nil

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(values) when is_list(values), do: Enum.map(values, &stringify/1)
  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value

  defp new_id do
    "plan-" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end
end
