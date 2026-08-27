defmodule BeamAgent.RuntimeCommand do
  @moduledoc "Versioned identity for an interface request entering the runtime."

  @version 1

  def new(name, scope, opts \\ []) when is_atom(name) and is_map(scope) do
    command_id = Keyword.get_lazy(opts, :command_id, &new_id/0)
    inherited_correlation = Keyword.get(opts, :correlation_id)

    %{
      type: :runtime_command,
      version: @version,
      command_id: command_id,
      name: name,
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      correlation_id: inherited_correlation || command_id,
      causation_id: Keyword.get(opts, :causation_id),
      scope: Map.take(scope, [:project_id, :goal_id, :session_id, :worker_id])
    }
  end

  defp new_id do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    "command-#{suffix}"
  end
end
