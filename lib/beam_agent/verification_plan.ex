defmodule BeamAgent.VerificationPlan do
  @moduledoc """
  A validated, interface-neutral set of deterministic completion checks.

  Projects may define `.beam_agent/verification.json`. When it is absent, the
  runtime discovers conservative checks from files at the workspace root.
  """

  @config_path ".beam_agent/verification.json"
  @maximum_timeout_ms 120_000

  @enforce_keys [:source, :checks]
  defstruct version: 1, source: nil, checks: []

  @type check :: %{
          id: String.t(),
          command: String.t(),
          cwd: String.t(),
          timeout_ms: pos_integer(),
          required: boolean()
        }

  @type t :: %__MODULE__{version: 1, source: String.t(), checks: [check()]}

  def load(workspace_root) when is_binary(workspace_root) do
    path = Path.join(workspace_root, @config_path)

    case File.read(path) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> discover(workspace_root)
      {:error, reason} -> {:error, {:verification_plan_read_failed, reason}}
    end
  end

  def new(%{} = attributes) do
    version = value(attributes, :version) || 1
    source = value(attributes, :source) || "runtime"
    checks = value(attributes, :checks)

    with true <- version == 1,
         true <- is_binary(source) and source != "",
         true <- is_list(checks) and checks != [],
         {:ok, checks} <- normalize_checks(checks) do
      {:ok, %__MODULE__{source: source, checks: checks}}
    else
      false -> {:error, :invalid_verification_plan}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(_attributes), do: {:error, :invalid_verification_plan}

  def timeout(%__MODULE__{checks: checks}) do
    Enum.reduce(checks, 5_000, &(&1.timeout_ms + &2))
  end

  defp decode(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} when is_map(decoded) ->
        case new(Map.put_new(decoded, "source", @config_path)) do
          {:ok, plan} -> {:ok, plan}
          {:error, reason} -> {:error, {:invalid_verification_plan, reason}}
        end

      {:ok, _decoded} ->
        {:error, {:invalid_verification_plan, :expected_object}}

      {:error, reason} ->
        {:error, {:invalid_verification_plan, reason}}
    end
  end

  defp discover(workspace_root) do
    checks =
      []
      |> maybe_add(git_repository?(workspace_root), "git-diff", "git diff --check", 30_000)
      |> maybe_add(
        File.regular?(Path.join(workspace_root, "mix.exs")),
        "elixir-compile",
        "mix compile --warnings-as-errors",
        @maximum_timeout_ms
      )
      |> maybe_add(
        File.regular?(Path.join(workspace_root, "mix.exs")),
        "elixir-test",
        "mix test",
        @maximum_timeout_ms
      )
      |> maybe_add(
        File.regular?(Path.join(workspace_root, "go.mod")),
        "go-test",
        "go test ./...",
        @maximum_timeout_ms
      )

    case checks do
      [] -> {:error, :no_verification_checks}
      checks -> {:ok, %__MODULE__{source: "workspace-discovery", checks: checks}}
    end
  end

  defp normalize_checks(checks) do
    checks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {check, index}, {:ok, normalized} ->
      case normalize_check(check, index) do
        {:ok, check} -> {:cont, {:ok, normalized ++ [check]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reject_duplicate_ids()
  end

  defp normalize_check(%{} = check, index) do
    id = value(check, :id) || "check-#{index}"
    command = value(check, :command)
    cwd = value(check, :cwd) || "."
    timeout_ms = value(check, :timeout_ms) || 30_000
    required = value(check, :required)
    required = if is_nil(required), do: true, else: required

    if valid_id?(id) and is_binary(command) and command != "" and valid_cwd?(cwd) and
         is_integer(timeout_ms) and timeout_ms in 100..@maximum_timeout_ms and
         is_boolean(required) do
      {:ok,
       %{
         id: id,
         command: command,
         cwd: cwd,
         timeout_ms: timeout_ms,
         required: required
       }}
    else
      {:error, {:invalid_verification_check, index}}
    end
  end

  defp normalize_check(_check, index), do: {:error, {:invalid_verification_check, index}}

  defp reject_duplicate_ids({:ok, checks}) do
    ids = Enum.map(checks, & &1.id)

    if length(ids) == MapSet.size(MapSet.new(ids)),
      do: {:ok, checks},
      else: {:error, :duplicate_verification_check}
  end

  defp reject_duplicate_ids(error), do: error

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/, id)

  defp valid_cwd?(cwd) do
    is_binary(cwd) and cwd != "" and Path.type(cwd) != :absolute and
      not Enum.member?(Path.split(cwd), "..")
  end

  defp git_repository?(workspace_root) do
    path = Path.join(workspace_root, ".git")
    File.dir?(path) or File.regular?(path)
  end

  defp maybe_add(checks, false, _id, _command, _timeout), do: checks

  defp maybe_add(checks, true, id, command, timeout_ms) do
    checks ++
      [%{id: id, command: command, cwd: ".", timeout_ms: timeout_ms, required: true}]
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end
end
