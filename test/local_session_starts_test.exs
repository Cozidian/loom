defmodule BeamAgent.LocalSessionStartsTest do
  use ExUnit.Case, async: false
  alias BeamAgent.LocalSessionStarts

  test "startup is nonblocking and duplicate requests share one supervised operation" do
    owner = self()

    starter =
      start_supervised!(
        {LocalSessionStarts,
         [
           name: nil,
           create: fn config, _ ->
             send(owner, {:creating, self(), config})

             receive do
               :finish -> {:ok, "new-session", self()}
             end
           end
         ]}
      )

    id = "same-start-request-1234"

    assert {:ok, %{status: "starting"}} =
             LocalSessionStarts.begin(id, %{root: "one"}, "config", starter)

    assert_receive {:creating, worker, %{root: "one"}}

    assert {:ok, %{status: "starting"}} =
             LocalSessionStarts.begin(id, %{root: "one"}, "config", starter)

    assert {:error, :start_id_conflict} =
             LocalSessionStarts.begin(id, %{root: "two"}, "config", starter)

    refute_receive {:creating, _, _}
    send(worker, :finish)
    wait_ready(starter, id)

    assert {:ok, %{status: "ready", session_id: "new-session"}} =
             LocalSessionStarts.begin(id, %{root: "one"}, "config", starter)

    refute_receive {:creating, _, _}
  end

  test "startup failures have a stable status instead of dropping the HTTP response" do
    starter =
      start_supervised!(
        {LocalSessionStarts,
         [name: nil, create: fn _, _ -> {:error, {:endpoint_start_failed, :details}} end]}
      )

    id = "failed-start-request-1234"
    assert {:ok, _} = LocalSessionStarts.begin(id, %{}, "config", starter)
    Process.sleep(20)

    assert {:ok, %{status: "failed", error: "endpoint_start_failed"}} =
             LocalSessionStarts.status(id, starter)

    assert {:error, :invalid_start_id} =
             LocalSessionStarts.begin("../bad", %{}, "config", starter)
  end

  test "computer browser lists directories, canonicalizes roots and paginates without reading files" do
    root = Path.join(System.tmp_dir!(), "beam-computer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    for i <- 1..202, do: File.mkdir!(Path.join(root, "folder #{i}"))
    File.write!(Path.join(root, "not-a-directory"), "private content")
    assert {:ok, listing} = BeamAgent.ControlPlane.WorkspaceBrowser.list(root)
    assert length(listing.entries) == 200
    assert listing.more

    assert {:ok, %{entries: entries, more: false}} =
             BeamAgent.ControlPlane.WorkspaceBrowser.list(root, 1)

    assert length(entries) == 2

    assert {:error, :workspace_unavailable} =
             BeamAgent.ControlPlane.WorkspaceBrowser.list("relative")

    assert {:error, :workspace_unavailable} =
             BeamAgent.ControlPlane.WorkspaceBrowser.list(Path.join(root, "not-a-directory"))
  end

  defp wait_ready(server, id, n \\ 100)
  defp wait_ready(_, _, 0), do: flunk("startup did not finish")

  defp wait_ready(server, id, n) do
    case LocalSessionStarts.status(id, server) do
      {:ok, %{status: "ready"}} ->
        :ok

      _ ->
        Process.sleep(10)
        wait_ready(server, id, n - 1)
    end
  end
end
