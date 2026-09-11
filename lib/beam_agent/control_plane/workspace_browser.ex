defmodule BeamAgent.ControlPlane.WorkspaceBrowser do
  @moduledoc "Directory names only, for explicit local-user workspace selection; never exposed to agent tools."

  def list(path, page \\ 0) do
    with true <-
           is_binary(path) and byte_size(path) in 1..4096 and Path.type(path) == :absolute and
             not String.contains?(path, <<0>>) and is_integer(page) and page in 0..1000,
         {:ok, root} <- BeamAgent.Workspace.canonical_root(path),
         {:ok, names} <- File.ls(root) do
      dirs =
        names
        |> Enum.filter(&String.valid?/1)
        |> Enum.filter(&File.dir?(Path.join(root, &1)))
        |> Enum.sort()

      {:ok,
       %{
         path: root,
         parent: if(root == "/", do: nil, else: Path.dirname(root)),
         home: System.user_home!(),
         repository: File.exists?(Path.join(root, ".git")),
         entries:
           dirs
           |> Enum.drop(page * 200)
           |> Enum.take(200)
           |> Enum.map(&%{name: &1, path: Path.join(root, &1)}),
         page: page,
         more: length(dirs) > (page + 1) * 200
       }}
    else
      _ -> {:error, :workspace_unavailable}
    end
  end
end
