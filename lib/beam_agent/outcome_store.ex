defmodule BeamAgent.OutcomeStore do
  @moduledoc "Project-owned, append-only model/task outcome ledger without prompt content."
  use GenServer

  alias BeamAgent.{Names, RoutingEvidence}
  alias BeamAgent.Session.EventLog

  @record_keys ~w(version redaction id kind project_id goal_id session_id turn step task_type language endpoint_id provider model latency_ms usage estimated_cost retries status failure cancelled verification route_decision_id recorded_at)a

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:outcome_store, project_id))
  end

  def record(project_id, attributes), do: call(project_id, {:record, attributes})

  def attach_verification(project_id, outcome_id, result),
    do: call(project_id, {:verify, outcome_id, result})

  def list(project_id, opts \\ []), do: call(project_id, {:list, opts})
  def routing_evidence(project_id, opts \\ []), do: call(project_id, {:routing_evidence, opts})
  def export(project_id), do: call(project_id, :export)
  def path(project_id), do: call(project_id, :path)

  @impl true
  def init(opts) do
    data_dir =
      Keyword.get_lazy(opts, :data_dir, fn -> Application.fetch_env!(:beam_agent, :data_dir) end)

    project_id = Keyword.fetch!(opts, :project_id)
    path = Path.join([data_dir, "projects", project_id, "outcomes.jsonl"])

    with :ok <- File.mkdir_p(Path.dirname(path)), {:ok, records} <- load(path) do
      {:ok,
       %{
         project_id: project_id,
         path: path,
         enabled: Keyword.get(opts, :outcome_telemetry, true),
         retention: Keyword.get(opts, :outcome_retention, 10_000),
         records: records
       }}
    end
  end

  @impl true
  def handle_call({:record, _attributes}, _from, %{enabled: false} = state),
    do: {:reply, {:ok, :disabled}, state}

  def handle_call({:record, attributes}, _from, state) do
    record = normalize(attributes, state.project_id)

    case append(state.path, %{"type" => "outcome_recorded", "record" => stringify(record)}) do
      :ok ->
        state =
          %{state | records: Map.put(state.records, record.id, record)} |> enforce_retention()

        {:reply, {:ok, record}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:verify, outcome_id, result}, _from, state) do
    case state.records[outcome_id] do
      nil ->
        {:reply, {:error, :unknown_outcome}, state}

      record ->
        verification = verification(result)
        status = verified_status(record, verification)

        entry = %{
          "type" => "verification_attached",
          "outcome_id" => outcome_id,
          "verification" => stringify(verification),
          "status" => status
        }

        case append(state.path, entry) do
          :ok ->
            _ =
              EventLog.append(record.session_id, :verification_attached, %{
                "outcome_id" => outcome_id,
                "kind" => record.kind,
                "status" => status,
                "verification" => stringify(verification)
              })

            {:reply, :ok,
             put_in(
               state.records[outcome_id],
               %{record | verification: verification, status: status}
             )}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:list, opts}, _from, state) do
    records = state.records |> Map.values() |> Enum.sort_by(& &1.recorded_at, :desc)

    records =
      if kind = opts[:kind], do: Enum.filter(records, &(&1.kind == text(kind))), else: records

    records = if limit = opts[:limit], do: Enum.take(records, limit), else: records
    {:reply, {:ok, records}, state}
  end

  def handle_call({:routing_evidence, opts}, _from, state) do
    evidence = state.records |> Map.values() |> RoutingEvidence.summarize(opts)
    {:reply, {:ok, evidence}, state}
  end

  def handle_call(:export, _from, state) do
    encoded =
      state.records
      |> Map.values()
      |> Enum.sort_by(& &1.recorded_at)
      |> Enum.map_join("\n", &JSON.encode!(stringify(&1)))

    {:reply, {:ok, encoded <> if(encoded == "", do: "", else: "\n")}, state}
  end

  def handle_call(:path, _from, state), do: {:reply, {:ok, state.path}, state}

  defp normalize(attributes, project_id) do
    attributes = Map.new(attributes)

    Map.new(@record_keys, &{&1, nil})
    |> Map.merge(Map.take(attributes, @record_keys))
    |> Map.merge(%{
      id: attributes[:id] || new_id(),
      version: 1,
      redaction: "content_excluded_v1",
      project_id: project_id,
      kind: text(attributes[:kind] || :model),
      task_type: text(attributes[:task_type]),
      language: text(attributes[:language]),
      provider: text(attributes[:provider]),
      status: text(attributes[:status]),
      failure: failure_code(attributes[:failure]),
      retries: attributes[:retries] || 0,
      cancelled: attributes[:cancelled] || false,
      verification: stringify(attributes[:verification] || %{status: :unverified}),
      recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp verification(result) when is_map(result),
    do:
      result
      |> Map.take([
        :status,
        :source,
        :summary,
        :verification_id,
        "status",
        "source",
        "summary",
        "verification_id"
      ])
      |> stringify()

  defp verification(result) when result in [:passed, :failed, :unverified],
    do: %{"status" => to_string(result)}

  defp verification(_result), do: %{"status" => "unverified"}

  defp load(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents |> String.split("\n", trim: true) |> Enum.reduce(%{}, &replay/2)}

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay(line, records) do
    case JSON.decode(line) do
      {:ok, %{"type" => "outcome_recorded", "record" => record}} ->
        Map.put(records, record["id"], atomize_keys(record))

      {:ok,
       %{
         "type" => "verification_attached",
         "outcome_id" => id,
         "verification" => verification
       } = entry}
      when is_map_key(records, id) ->
        record = records[id]

        Map.put(records, id, %{
          record
          | verification: verification,
            status: entry["status"] || record.status
        })

      _ ->
        records
    end
  end

  defp append(path, entry) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, [JSON.encode!(entry), "\n"], [:append, :binary])
    end
  end

  defp enforce_retention(%{retention: retention, records: records} = state)
       when map_size(records) > retention do
    kept =
      records |> Map.values() |> Enum.sort_by(& &1.recorded_at, :desc) |> Enum.take(retention)

    lines =
      Enum.map(kept, fn record ->
        [JSON.encode!(%{"type" => "outcome_recorded", "record" => stringify(record)}), "\n"]
      end)

    :ok = File.mkdir_p(Path.dirname(state.path))
    :ok = File.write(state.path, lines, [:binary])
    %{state | records: Map.new(kept, &{&1.id, &1})}
  end

  defp enforce_retention(state), do: state

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value

  defp atomize_keys(map),
    do: Map.new(map, fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp text(nil), do: nil
  defp text(value) when is_atom(value), do: to_string(value)
  defp text(value), do: value

  defp failure_code(nil), do: nil
  defp failure_code(value) when is_atom(value), do: to_string(value)

  defp failure_code(value) when is_tuple(value) and tuple_size(value) > 0 do
    case elem(value, 0) do
      code when is_atom(code) -> to_string(code)
      _other -> "runtime_failure"
    end
  end

  defp failure_code(_value), do: "redacted_failure"

  defp verified_status(%{kind: "task"}, %{"status" => "passed"}), do: "succeeded"
  defp verified_status(%{kind: "task"}, %{"status" => "failed"}), do: "failed"
  defp verified_status(record, _verification), do: record.status

  defp new_id,
    do: "outcome-" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))

  defp call(project_id, message) do
    with {:ok, pid} <- Names.pid(:outcome_store, project_id), do: GenServer.call(pid, message)
  end
end
