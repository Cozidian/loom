defmodule BeamAgent.CapabilityEnvelope do
  @moduledoc "Immutable, delegable authority attached to a goal or worker."

  @scopes [
    :tools,
    :paths,
    :commands,
    :hosts,
    :git_operations,
    :browser_scopes,
    :mcp_servers,
    :model_classes,
    :secret_kinds,
    :approval_scopes
  ]
  @enforce_keys [:id, :scopes]
  defstruct [:id, :parent_id, :scopes]

  @type scope_value :: :all | [String.t()]
  @type t :: %__MODULE__{id: String.t(), parent_id: String.t() | nil, scopes: map()}

  def root(spec \\ :all)
  def root(:all), do: new(nil, Map.new(@scopes, &{&1, :all}))
  def root(spec) when is_map(spec), do: new(nil, normalize_scopes(spec))

  def restrict(%__MODULE__{} = parent, requested \\ %{}) when is_map(requested) do
    Enum.reduce_while(@scopes, {:ok, %{}}, fn scope, {:ok, scopes} ->
      inherited = Map.fetch!(parent.scopes, scope)

      requested_scope =
        requested
        |> Map.get(scope, Map.get(requested, to_string(scope), inherited))
        |> normalize_value()

      case narrow(inherited, requested_scope, scope) do
        {:ok, value} -> {:cont, {:ok, Map.put(scopes, scope, value)}}
        :escalation -> {:halt, {:error, {:capability_escalation, scope, requested_scope}}}
      end
    end)
    |> case do
      {:ok, scopes} -> {:ok, new(parent.id, scopes)}
      error -> error
    end
  end

  def authorize(%__MODULE__{} = envelope, resource) when is_map(resource) do
    Enum.reduce_while(resource, :ok, fn
      {_scope, nil}, :ok ->
        {:cont, :ok}

      {scope, value}, :ok when scope in @scopes ->
        if allowed?(Map.fetch!(envelope.scopes, scope), to_string(value), scope),
          do: {:cont, :ok},
          else: {:halt, {:error, {:capability_denied, scope, value}}}

      {_unknown, _value}, :ok ->
        {:cont, :ok}
    end)
  end

  def authorize(nil, _resource), do: :ok

  def to_map(%__MODULE__{} = envelope) do
    %{id: envelope.id, parent_id: envelope.parent_id, scopes: envelope.scopes}
  end

  defp new(parent_id, scopes) do
    fingerprint =
      :crypto.hash(:sha256, :erlang.term_to_binary({parent_id, scopes, System.unique_integer()}))

    %__MODULE__{
      id: "cap-" <> Base.url_encode64(binary_part(fingerprint, 0, 9), padding: false),
      parent_id: parent_id,
      scopes: scopes
    }
  end

  defp normalize_scopes(spec) do
    Map.new(@scopes, fn scope ->
      value = Map.get(spec, scope, Map.get(spec, to_string(scope), []))
      {scope, normalize_value(value)}
    end)
  end

  defp normalize_value(:all), do: :all
  defp normalize_value("all"), do: :all

  defp normalize_value(values) when is_list(values),
    do: values |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()

  defp normalize_value(value) when is_binary(value), do: [value]
  defp normalize_value(_value), do: []

  defp narrow(:all, requested, _scope), do: {:ok, requested}
  defp narrow(_parent, :all, _scope), do: :escalation

  defp narrow(parent, requested, :paths) do
    if Enum.all?(requested, fn value -> Enum.any?(parent, &path_match?(&1, value)) end),
      do: {:ok, requested},
      else: :escalation
  end

  defp narrow(parent, requested, _scope) do
    if Enum.all?(requested, &Enum.member?(parent, &1)), do: {:ok, requested}, else: :escalation
  end

  defp allowed?(:all, _value, _scope), do: true
  defp allowed?(allowed, value, :paths), do: Enum.any?(allowed, &path_match?(&1, value))
  defp allowed?(allowed, value, _scope), do: value in allowed

  defp path_match?(prefix, value) do
    (prefix == "." and workspace_relative?(value)) or prefix == value or
      String.starts_with?(value, String.trim_trailing(prefix, "/") <> "/")
  end

  defp workspace_relative?(value) do
    if Path.type(value) == :absolute do
      false
    else
      root = Path.join(System.tmp_dir!(), "beam-agent-capability-root")
      relative = value |> Path.expand(root) |> Path.relative_to(root)

      relative != ".." and not String.starts_with?(relative, "../") and
        not String.starts_with?(relative, "..\\") and Path.type(relative) != :absolute
    end
  end
end
