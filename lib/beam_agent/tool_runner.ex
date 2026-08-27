defmodule BeamAgent.ToolRunner do
  @moduledoc "Guarded execution boundary shared by every model-callable tool."

  alias BeamAgent.{CapabilityEnvelope, Session.ToolPolicy}

  def execute(module, arguments, context) do
    access = if function_exported?(module, :access, 0), do: module.access(), else: :execute

    resource = resource(module.name(), arguments)

    with :ok <- authorize_capability(context, resource),
         :ok <-
           ToolPolicy.authorize(context.session_id, module.name(), arguments, access, resource) do
      invoke(module, arguments, context)
    end
  end

  def execute_mcp(server, tool, arguments, context, invoke) when is_function(invoke, 0) do
    name = "mcp__#{server}__#{tool}"
    resource = %{tools: name, mcp_servers: server}

    with :ok <- authorize_capability(context, resource),
         :ok <- ToolPolicy.authorize(context.session_id, name, arguments, :execute, resource) do
      invoke.()
    end
  end

  defp authorize_capability(context, resource) do
    case CapabilityEnvelope.authorize(Map.get(context, :capability_envelope), resource) do
      :ok ->
        :ok

      {:error, reason} = error ->
        _ =
          BeamAgent.Session.EventLog.append(context.session_id, :capability_denied, %{
            "resource" => stringify(resource),
            "reason" => inspect(reason)
          })

        error
    end
  end

  defp resource(tool, arguments) do
    %{
      tools: tool,
      paths: arguments["path"] || arguments["cwd"],
      commands: command_family(arguments["command"]),
      hosts: host(arguments["url"])
    }
  end

  defp command_family(command) when is_binary(command),
    do: command |> String.trim() |> String.split(~r/\s+/, parts: 2) |> List.first()

  defp command_family(_), do: nil
  defp host(url) when is_binary(url), do: URI.parse(url).host
  defp host(_), do: nil
  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

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
