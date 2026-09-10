defmodule BeamAgent.Evaluation.FileEvidence do
  @moduledoc "Evaluator-owned content fingerprints, including binary artifacts and protected fixtures."

  alias BeamAgent.Workspace

  def capture(workspace, paths) do
    Map.new(paths, &{&1, fingerprint(workspace, &1)})
  end

  def compare(workspace, before, paths, kind) when kind in [:file_preserved, :file_changed] do
    Enum.map(paths, fn path ->
      previous = Map.fetch!(before, path)
      current = fingerprint(workspace, path)

      passed =
        case {kind, previous, current} do
          {:file_preserved, {:ok, hash}, {:ok, hash}} -> true
          {:file_changed, {:ok, old}, {:ok, new}} -> old != new
          {:file_changed, {:error, :enoent}, {:ok, _new}} -> true
          _other -> false
        end

      %{
        kind: kind,
        path: path,
        passed: passed,
        before_sha256: hash(previous),
        after_sha256: hash(current),
        before_error: error(previous),
        after_error: error(current)
      }
    end)
  end

  defp fingerprint(workspace, path) do
    with {:ok, resolved} <- Workspace.resolve(workspace, path),
         {:ok, %{type: :regular}} <- File.lstat(resolved) do
      digest =
        resolved
        |> File.stream!(64 * 1024)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:ok, digest}
    else
      {:ok, _stat} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in File.Error -> {:error, error.reason}
  end

  defp hash({:ok, hash}), do: hash
  defp hash(_result), do: nil
  defp error({:error, reason}), do: inspect(reason)
  defp error(_result), do: nil
end
