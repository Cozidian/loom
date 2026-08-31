defmodule BeamAgent.Runtime.JSONProtocol do
  @moduledoc """
  Versioned command protocol shared by CLI automation, editor adapters, and
  external transports. It owns no runtime state; a connected Runtime client is
  always authoritative.
  """

  @version 1

  def dispatch(client, request) when is_pid(client) and is_map(request) do
    request_id = value(request, :request_id)

    response =
      with @version <- value(request, :version),
           command when is_binary(command) <- value(request, :command) do
        execute(client, command, value(request, :arguments) || %{})
      else
        nil -> {:error, :missing_protocol_field}
        version when is_integer(version) -> {:error, {:unsupported_protocol_version, version}}
        _other -> {:error, :invalid_protocol_request}
      end

    envelope(request_id, response)
  end

  def dispatch(_client, _request), do: envelope(nil, {:error, :invalid_protocol_request})

  def encode_response(response), do: JSON.encode!(stringify(response))
  def normalize(value), do: stringify(value)

  def event(event) when is_map(event) do
    %{version: @version, type: "event", event: stringify(event)}
  end

  defp execute(client, "snapshot", _arguments), do: BeamAgent.Runtime.snapshot(client)
  defp execute(client, "status", _arguments), do: BeamAgent.Runtime.status(client)
  defp execute(client, "goal_tree", _arguments), do: BeamAgent.Runtime.goal_tree(client)
  defp execute(client, "budget", _arguments), do: BeamAgent.Runtime.budget(client)
  defp execute(client, "models", _arguments), do: BeamAgent.Runtime.models(client)
  defp execute(client, "repository", _arguments), do: BeamAgent.Runtime.repository(client)
  defp execute(client, "resource_pools", _arguments), do: BeamAgent.Runtime.resource_pools(client)
  defp execute(client, "path_leases", _arguments), do: BeamAgent.Runtime.path_leases(client)
  defp execute(client, "delegations", _arguments), do: BeamAgent.Runtime.delegations(client)
  defp execute(client, "organizations", _arguments), do: BeamAgent.Runtime.organizations(client)

  defp execute(client, "project_preferences", _arguments),
    do: BeamAgent.Runtime.project_preferences(client)

  defp execute(client, "set_project_preferences", arguments),
    do: BeamAgent.Runtime.set_project_preferences(client, arguments)

  defp execute(client, "capability_leases", _arguments),
    do: BeamAgent.Runtime.capability_leases(client)

  defp execute(client, "project_context", arguments),
    do: BeamAgent.Runtime.project_context(client, atomize_known(arguments))

  defp execute(client, "inspect_events", arguments) do
    query = value(arguments, :query) || ""
    limit = value(arguments, :limit) || 100
    BeamAgent.Runtime.inspect_events(client, query, limit: min(max(limit, 1), 1_000))
  end

  defp execute(client, "submit", arguments) do
    case value(arguments, :prompt) do
      prompt when is_binary(prompt) and prompt != "" -> BeamAgent.Runtime.submit(client, prompt)
      _other -> {:error, :invalid_prompt}
    end
  end

  defp execute(client, "cancel", _arguments), do: BeamAgent.Runtime.cancel(client)

  defp execute(client, "steer", arguments) do
    case value(arguments, :message) do
      message when is_binary(message) and message != "" ->
        BeamAgent.Runtime.steer(client, message)

      _other ->
        {:error, :invalid_steering_message}
    end
  end

  defp execute(client, "verify", _arguments), do: BeamAgent.Runtime.verify(client)

  defp execute(client, "approval", arguments) do
    decision = parse_decision(value(arguments, :decision))

    if decision,
      do: BeamAgent.Runtime.respond_approval(client, value(arguments, :approval_id), decision),
      else: {:error, :invalid_approval_decision}
  end

  defp execute(_client, command, _arguments), do: {:error, {:unknown_protocol_command, command}}

  defp envelope(request_id, {:ok, result}) do
    %{version: @version, type: "response", request_id: request_id, ok: true, result: result}
  end

  defp envelope(request_id, :ok) do
    %{version: @version, type: "response", request_id: request_id, ok: true, result: nil}
  end

  defp envelope(request_id, {:error, reason}) do
    %{
      version: @version,
      type: "response",
      request_id: request_id,
      ok: false,
      error: error_code(reason)
    }
  end

  defp parse_decision("allow_once"), do: :allow_once
  defp parse_decision("allow_always"), do: :allow_always
  defp parse_decision("deny"), do: :deny
  defp parse_decision(_decision), do: nil
  defp error_code(reason) when is_atom(reason), do: to_string(reason)
  defp error_code({reason, _detail}) when is_atom(reason), do: to_string(reason)
  defp error_code(_reason), do: "runtime_error"
  defp value(map, key), do: map[key] || map[to_string(key)]

  defp atomize_known(map) when is_map(map) do
    %{
      kinds: value(map, :kinds) || :all,
      maximum_bytes: value(map, :maximum_bytes) || 64_000
    }
  end

  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify(%MapSet{} = value), do: value |> MapSet.to_list() |> Enum.map(&stringify/1)
  defp stringify(struct) when is_struct(struct), do: struct |> Map.from_struct() |> stringify()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&stringify/1)

  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value) when is_pid(value) or is_reference(value), do: inspect(value)
  defp stringify(value), do: value
end
