defmodule BeamAgent.CLI.TurnRunner do
  @moduledoc false

  alias BeamAgent.Runtime

  def run(session_id, prompt, timeout, approval_fun) when is_function(approval_fun, 1) do
    with_runtime(session_id, fn runtime ->
      case Runtime.run(runtime, prompt, timeout, approval_fun) do
        {:ok, answer, _meta} -> {:ok, answer}
        {:error, reason, _meta} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def run_live(session_id, prompt, timeout, approval_fun, event_fun)
      when is_function(approval_fun, 1) and is_function(event_fun, 1) do
    with_runtime(session_id, fn runtime ->
      case Runtime.run(runtime, prompt, timeout, approval_fun, event_fun) do
        {:ok, answer, meta} -> {:ok, answer, meta}
        {:error, reason, meta} -> {:error, reason, meta}
        {:error, reason} -> {:error, reason, empty_meta()}
      end
    end)
  end

  defp with_runtime(session_id, fun) do
    case Runtime.connect(session_id, view: :internal, after: :latest) do
      {:ok, runtime} ->
        try do
          fun.(runtime)
        after
          Runtime.disconnect(runtime)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp empty_meta, do: %{streamed_text?: false, live_tool_events?: false}
end
