defmodule BeamAgent.ToolRunner do
  @moduledoc "Guarded execution boundary shared by every model-callable tool."

  alias BeamAgent.Session.ToolPolicy

  def execute(module, arguments, context) do
    access = if function_exported?(module, :access, 0), do: module.access(), else: :execute

    with :ok <- ToolPolicy.authorize(context.session_id, module.name(), arguments, access) do
      invoke(module, arguments, context)
    end
  end

  defp invoke(module, arguments, context) do
    try do
      module.execute(arguments, context)
    rescue
      error -> {:error, {:tool_exception, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:tool_throw, kind, reason}}
    end
  end
end
