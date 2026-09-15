defmodule BeamAgent.Project.ObservatoryTest do
  use ExUnit.Case, async: false

  alias BeamAgent.Project.Observatory

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-observatory-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  defp git!(workspace, args), do: {_, 0} = System.cmd("git", args, cd: workspace)

  defp commit!(workspace, files, message) do
    for {path, content} <- files do
      full = Path.join(workspace, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    git!(workspace, ["add" | Map.keys(files)])
    git!(workspace, ["commit", "-m", message])
  end

  defp init_repo!(workspace) do
    git!(workspace, ["init", "-q"])
    git!(workspace, ["config", "user.email", "observatory@test.local"])
    git!(workspace, ["config", "user.name", "Observatory Test"])
  end

  defp project_id!(workspace, data_dir) do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: data_dir,
               workspace_root: workspace,
               provider: :echo,
               repository_scan_interval_ms: 60_000
             )

    {:ok, goal} = BeamAgent.goal(root_id)
    goal.project_id
  end

  test "hotspots and co-change edges reflect actual commit history", ctx do
    init_repo!(ctx.workspace)

    # route.ts and its i18n messages change together every time; helper.ts is
    # untouched after its first commit and must not show up as a hotspot.
    for n <- 1..6 do
      commit!(
        ctx.workspace,
        %{
          "route.ts" => "export const n = #{n};",
          "messages/en.json" => ~s({"n": #{n}}),
          "messages/nb.json" => ~s({"n": #{n}})
        },
        "update route ##{n}"
      )
    end

    commit!(ctx.workspace, %{"helper.ts" => "export const id = 1;"}, "add helper")

    project_id = project_id!(ctx.workspace, ctx.data_dir)
    assert {:ok, snapshot} = Observatory.snapshot(project_id)

    assert snapshot.commits_sampled == 7
    assert snapshot.file_count == 4

    paths = Enum.map(snapshot.constellation.nodes, & &1.path)
    assert "route.ts" in paths
    assert "messages/en.json" in paths
    assert "helper.ts" in paths

    route = Enum.find(snapshot.constellation.nodes, &(&1.path == "route.ts"))
    assert route.commits == 6
    assert route.language == "typescript"
    assert route.has_test == false

    helper = Enum.find(snapshot.constellation.nodes, &(&1.path == "helper.ts"))
    assert helper.commits == 1

    coupled_pair =
      Enum.find(snapshot.constellation.edges, fn edge ->
        Enum.sort([edge.source, edge.target]) == Enum.sort(["route.ts", "messages/en.json"])
      end)

    assert coupled_pair.weight == 6

    refute Enum.any?(snapshot.constellation.edges, fn edge ->
             "helper.ts" in [edge.source, edge.target]
           end)
  end

  test "risk scoring favors high-churn files without a matching test", ctx do
    init_repo!(ctx.workspace)

    for n <- 1..10 do
      commit!(ctx.workspace, %{"lib/risky.ex" => "defmodule Risky, do: :v#{n}"}, "touch ##{n}")
    end

    commit!(
      ctx.workspace,
      %{
        "lib/safe.ex" => "defmodule Safe, do: :v1",
        "test/safe_test.exs" => "defmodule SafeTest, do: nil"
      },
      "add safe with test"
    )

    project_id = project_id!(ctx.workspace, ctx.data_dir)
    assert {:ok, snapshot} = Observatory.snapshot(project_id)

    [top | _] = snapshot.risk
    assert top.path == "lib/risky.ex"
    assert top.score > 0
    assert Enum.any?(top.reasons, &String.contains?(&1, "no matching test file"))

    safe = Enum.find(snapshot.risk, &(&1.path == "lib/safe.ex"))
    assert safe.score < top.score
  end

  test "a mass-rename commit is excluded as noise from hotspots and edges", ctx do
    init_repo!(ctx.workspace)
    commit!(ctx.workspace, %{"a.ex" => "1", "b.ex" => "1"}, "seed")

    mass_files = for n <- 1..60, into: %{}, do: {"generated/file_#{n}.txt", "x"}
    commit!(ctx.workspace, mass_files, "bulk generated files")

    project_id = project_id!(ctx.workspace, ctx.data_dir)
    assert {:ok, snapshot} = Observatory.snapshot(project_id)

    refute Enum.any?(snapshot.constellation.nodes, &String.starts_with?(&1.path, "generated/"))
  end

  test "dependency inventory reads mix.lock, package-lock.json and Cargo.lock", ctx do
    init_repo!(ctx.workspace)

    File.write!(Path.join(ctx.workspace, "mix.lock"), ~s"""
    %{
      "jason": {:hex, :jason, "1.4.5", "abc", [:mix], [], "hexpm", "def"},
      "bandit": {:hex, :bandit, "1.5.7", "abc", [:mix], [], "hexpm", "def"},
    }
    """)

    File.write!(
      Path.join(ctx.workspace, "package-lock.json"),
      JSON.encode!(%{
        "packages" => %{
          "" => %{"name" => "app"},
          "node_modules/react" => %{"version" => "18.3.1"},
          "node_modules/eslint" => %{"version" => "9.9.0", "dev" => true}
        }
      })
    )

    File.write!(Path.join(ctx.workspace, "Cargo.lock"), ~s"""
    [[package]]
    name = "serde"
    version = "1.0.210"

    [[package]]
    name = "ratatui"
    version = "0.30.2"
    """)

    commit!(ctx.workspace, %{"a.ex" => "1"}, "seed")
    project_id = project_id!(ctx.workspace, ctx.data_dir)
    assert {:ok, snapshot} = Observatory.snapshot(project_id)

    names = Enum.map(snapshot.libraries, & &1.name)
    assert "jason" in names
    assert "bandit" in names
    assert "react" in names
    assert "eslint" in names
    assert "serde" in names
    assert "ratatui" in names

    react = Enum.find(snapshot.libraries, &(&1.name == "react"))
    assert react.version == "18.3.1"
    assert react.ecosystem == "npm"
    assert react.kind == "prod"

    eslint = Enum.find(snapshot.libraries, &(&1.name == "eslint"))
    assert eslint.kind == "dev"
  end

  test "CI workflows are discovered from .github/workflows", ctx do
    init_repo!(ctx.workspace)

    File.mkdir_p!(Path.join([ctx.workspace, ".github", "workflows"]))

    File.write!(Path.join([ctx.workspace, ".github", "workflows", "ci.yml"]), ~s"""
    name: Checks
    on: [push, pull_request]
    jobs:
      macos:
        runs-on: macos-15
      linux:
        runs-on: ubuntu-latest
    """)

    commit!(ctx.workspace, %{"a.ex" => "1"}, "seed")
    project_id = project_id!(ctx.workspace, ctx.data_dir)
    assert {:ok, snapshot} = Observatory.snapshot(project_id)

    assert [workflow] = snapshot.ci
    assert workflow.name == "Checks"
    assert workflow.file == "ci.yml"
    assert "macos" in workflow.jobs
    assert "linux" in workflow.jobs
    assert "push" in workflow.triggers
    assert "pull_request" in workflow.triggers
  end

  test "a workspace with no git history still returns a usable, empty report", ctx do
    File.write!(Path.join(ctx.workspace, "a.txt"), "hello")
    project_id = project_id!(ctx.workspace, ctx.data_dir)

    assert {:ok, snapshot} = Observatory.snapshot(project_id)
    assert snapshot.commits_sampled == 0
    assert snapshot.constellation.nodes == []
    assert snapshot.constellation.edges == []
    assert snapshot.risk == []
  end
end
