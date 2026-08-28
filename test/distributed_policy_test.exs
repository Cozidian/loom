defmodule BeamAgent.DistributedPolicyTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-distribution-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "local execution is compatible and distributed jobs are idempotent", context do
    assert {:ok, project_id} =
             BeamAgent.start_project(
               workspace_root: context.workspace,
               data_dir: context.data_dir
             )

    assert {:ok, [local]} = BeamAgent.execution_nodes(project_id)
    assert local.id == "local"
    assert local.trust == :local

    assert {:ok, {:claimed, job}} =
             BeamAgent.claim_distributed_job(project_id, "job-1", %{data_locality: :project})

    assert job.node_id == "local"

    assert {:error, :duplicate_job_running} =
             BeamAgent.claim_distributed_job(project_id, "job-1")

    assert {:ok, completed} =
             BeamAgent.complete_distributed_job(project_id, "job-1", "result-hash")

    assert completed.status == :completed

    assert {:ok, {:duplicate_completed, duplicate}} =
             BeamAgent.claim_distributed_job(project_id, "job-1")

    assert duplicate.result_fingerprint == "result-hash"

    assert {:error, :distributed_job_result_conflict} =
             BeamAgent.complete_distributed_job(project_id, "job-1", "different-hash")
  end

  test "remote nodes require an explicit project policy", context do
    assert {:ok, project_id} =
             BeamAgent.start_project(
               workspace_root: context.workspace,
               data_dir: context.data_dir
             )

    version = to_string(Application.spec(:beam_agent, :vsn))

    assert {:error, :distributed_execution_disabled} =
             BeamAgent.Project.ExecutionNodeRegistry.register(project_id, %{
               id: "remote-1",
               node: :remote@host,
               trusted: true,
               code_version: version
             })
  end
end
