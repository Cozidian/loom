defmodule BeamAgent.Diagnostics.Snapshot do
  @moduledoc false
  @keys [:memory, :total_heap_size, :message_queue_len, :reductions, :status, :current_function]

  def collect(previous \\ %{}, offset \\ 0) do
    pids = Process.list()
    selected = pids |> Enum.drop(offset) |> Enum.take(4_096)
    selected = if selected == [], do: Enum.take(pids, 4_096), else: selected

    rows =
      Enum.flat_map(selected, fn pid ->
        case process(pid) do
          nil ->
            []

          row ->
            [
              Map.put(
                row,
                :reductions_since_sample,
                case Map.fetch(previous, row.pid) do
                  {:ok, before} -> max(row.reductions - before, 0)
                  :error -> nil
                end
              )
            ]
        end
      end)

    top =
      [:memory, :message_queue_len, :reductions_since_sample]
      |> Enum.flat_map(fn metric ->
        rows |> Enum.sort_by(&(Map.get(&1, metric) || 0), :desc) |> Enum.take(16)
      end)
      |> Enum.uniq_by(& &1.pid)

    providers =
      Enum.flat_map(selected, fn pid ->
        case progress(pid) do
          nil -> []
          data -> [%{pid: inspect(pid), data: data, identity: provider_identity(pid, data)}]
        end
      end)
      |> Enum.take(64)

    os_pids =
      [
        String.to_integer(System.pid())
        | Enum.flat_map(providers, fn p ->
            case p.data[:os_pid] do
              n when is_integer(n) and n > 0 -> [n]
              _ -> []
            end
          end)
      ]
      |> Enum.uniq()

    sample = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      monotonic_ms: System.monotonic_time(:millisecond),
      vm_memory: Map.new(:erlang.memory()),
      word_size_bytes: :erlang.system_info(:wordsize),
      process_count: length(pids),
      sampled_process_count: length(selected),
      truncated: length(selected) < length(pids),
      processes: Enum.map(top, &Map.put(&1, :stack, stack(pid_from_row(&1)))),
      providers: providers,
      os_processes: os_processes(os_pids)
    }

    {sample, Map.new(rows, &{&1.pid, &1.reductions}),
     if(length(pids) <= 4_096, do: 0, else: rem(offset + 4_096, length(pids)))}
  end

  def process(pid) do
    case Process.info(pid, @keys) do
      nil ->
        nil

      fields ->
        fields
        |> Map.new()
        |> Map.update!(:current_function, &mfa/1)
        |> Map.put(:pid, inspect(pid))
        |> Map.put(:identity, identity(pid))
    end
  end

  def stack(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, frames} ->
        Enum.take(frames, 12) |> Enum.map(fn {m, f, a, _} -> mfa({m, f, a}) end)

      _ ->
        []
    end
  end

  def identity(pid) do
    case Registry.keys(BeamAgent.Registry, pid)
         |> Enum.find(fn
           {kind, _} -> kind != :diagnostic_progress
           _ -> false
         end) do
      {kind, id} -> %{kind: to_string(kind), id: safe_id(id)}
      _ -> nil
    end
  end

  def progress(pid) do
    case Registry.lookup(BeamAgent.Registry, {:diagnostic_progress, pid}) do
      [{_, %{phase: :active, updated_at_ms: time, elapsed_ms: elapsed} = data}] ->
        %{data | elapsed_ms: elapsed + max(System.monotonic_time(:millisecond) - time, 0)}

      [{_, data}] ->
        data

      _ ->
        nil
    end
  end

  defp provider_identity(pid, data) do
    identity(pid) ||
      case data[:owner_pid] do
        owner when is_binary(owner) -> identity(pid_from_row(%{pid: owner}))
        _ -> nil
      end
  rescue
    ArgumentError -> nil
  end

  defp safe_id(value) when is_binary(value), do: String.slice(value, 0, 128)
  defp safe_id(value) when is_pid(value), do: inspect(value)
  defp safe_id(_), do: nil
  defp mfa({m, f, a}), do: "#{m}.#{f}/#{if is_integer(a), do: a, else: length(a)}"

  defp pid_from_row(row),
    do: row.pid |> String.trim_leading("#PID") |> String.to_charlist() |> :erlang.list_to_pid()

  # Numeric columns only: command lines and environments can contain secrets.
  defp os_processes(pids) do
    case System.cmd("ps", ["-o", "pid=,rss=,pcpu=", "-p", Enum.join(pids, ",")],
           stderr_to_stdout: true
         ) do
      {text, 0} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line) do
            [pid, rss, cpu] ->
              with {pid, ""} <- Integer.parse(pid),
                   {rss, ""} <- Integer.parse(rss),
                   {cpu, ""} <- Float.parse(cpu) do
                [%{pid: pid, rss_bytes: rss * 1_024, cpu_percent_lifetime: cpu}]
              else
                _ -> []
              end

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end
end
