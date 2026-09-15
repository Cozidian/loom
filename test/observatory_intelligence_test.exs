defmodule BeamAgent.Project.ObservatoryIntelligenceTest do
  use ExUnit.Case, async: false
  alias BeamAgent.Project.{Observatory, ObservatoryIntelligence}

  setup do
    root = Path.join(System.tmp_dir!(), "obs-intelligence-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)

    source = %{
      "src/ui/page.ts" => "import { login } from '../auth/login';\nexport const page = login;",
      "src/auth/login.ts" =>
        "import { store } from '../data/store';\nimport remote from '@app/remote';\nexport const login = store;",
      "src/data/store.ts" => "export const store = 1;",
      "src/data/store.test.ts" => "import { store } from './store';",
      "src/unrelated/util.ts" => "export const util = 1;",
      "lib/demo/service.ex" => "defmodule Demo.Service do\n alias Demo.Store\nend",
      "lib/demo/store.ex" => "defmodule Demo.Store do\nend",
      "README.md" => "System purpose"
    }

    for {path, content} <- source do
      full = Path.join(workspace, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    {:ok, id} =
      BeamAgent.start_session(
        workspace_root: workspace,
        data_dir: Path.join(root, "runtime"),
        provider: :echo,
        repository_scan_interval_ms: 60_000
      )

    {:ok, goal} = BeamAgent.goal(id)

    on_exit(fn ->
      BeamAgent.stop_session(id)
      File.rm_rf(root)
    end)

    %{workspace: workspace, project_id: goal.project_id}
  end

  test "no-history repository retains topology, typed references and uncertainty", ctx do
    assert {:ok, %{model: model}} = Observatory.snapshot(ctx.project_id)
    assert length(model.files) == 8
    assert model.timeline == []
    edge = Enum.find(model.edges, &(&1.source == "src/auth/login.ts"))
    assert edge.target == "src/data/store.ts"
    assert edge.evidence == "src/auth/login.ts:1"
    assert edge.confidence == "static"

    assert Enum.any?(
             model.edges,
             &(&1.source == "lib/demo/service.ex" and &1.target == "lib/demo/store.ex")
           )

    assert Enum.any?(model.unresolved, &(&1.reference == "@app/remote"))
    assert Enum.find(model.dimensions, &(&1.id == "tests")).state == "unknown"

    login = Enum.find(model.files, &(&1.path == "src/auth/login.ts"))
    touchpoint = Enum.find(login.external_touchpoints, &(&1.package == "@app/remote"))
    assert touchpoint.declared == false
    assert touchpoint.version == nil
  end

  test "impact follows reverse imports transitively, excludes unrelated code and returns candidate tests",
       ctx do
    assert {:ok, %{model: model}} = Observatory.snapshot(ctx.project_id)
    assert {:ok, impact} = ObservatoryIntelligence.impact(model, "src/data/store.ts")
    assert "src/auth/login.ts" in impact.downstream
    assert "src/ui/page.ts" in impact.downstream
    refute "src/unrelated/util.ts" in impact.affected
    assert "src/data/store.test.ts" in impact.tests
    assert "src/auth/login.ts" in impact.security_paths
    assert {:ok, reverse} = ObservatoryIntelligence.impact(model, "src/ui/page.ts")
    refute "src/data/store.ts" in reverse.affected

    assert {:error, :unknown_observatory_target} =
             ObservatoryIntelligence.impact(model, "missing")
  end

  test "trace finds an evidenced forward chain, without inventing reverse paths", ctx do
    assert {:ok, %{model: model}} = Observatory.snapshot(ctx.project_id)

    assert {:ok, %{found: true, evidence: [first, second]}} =
             ObservatoryIntelligence.trace(model, "src/ui", "src/data")

    assert first.source == "src/ui/page.ts"
    assert first.target == second.source
    assert second.target == "src/data/store.ts"
    assert {:ok, %{found: false}} = ObservatoryIntelligence.trace(model, "src/data", "src/ui")

    assert {:ok, json} =
             BeamAgent.Tools.RepositoryIntelligence.execute(
               %{"action" => "trace", "target" => "src/ui", "destination" => "src/data"},
               ctx
             )

    assert JSON.decode!(json)["result"]["found"]
  end

  test "agent query shares the model and rejects invalid queries", ctx do
    assert {:ok, json} =
             BeamAgent.Tools.RepositoryIntelligence.execute(
               %{"action" => "impact", "target" => "src/data"},
               ctx
             )

    assert {:ok, result} = JSON.decode(json)
    assert "src/ui/page.ts" in result["result"]["downstream"]

    assert {:error, :expected_observatory_target} =
             BeamAgent.Tools.RepositoryIntelligence.execute(%{"action" => "impact"}, ctx)

    assert {:error, :invalid_intelligence_query} =
             BeamAgent.Tools.RepositoryIntelligence.execute(%{"action" => "delete"}, ctx)
  end

  test "protocol heuristics, external touchpoints and co-change surface with clear caveats" do
    root = Path.join(System.tmp_dir!(), "obs-signals-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)

    files = %{
      "lib/demo_web/router.ex" =>
        "defmodule DemoWeb.Router do\n  get \"/health\", HealthController, :show\nend",
      "src/api/orders.js" =>
        "const stripe = require('stripe');\napp.get('/api/orders', ordersHandler);\napp.post('/api/orders', createOrder);",
      "package.json" => ~s({"dependencies":{"stripe":"^14.0.0"}})
    }

    for {path, content} <- files do
      full = Path.join(workspace, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    System.cmd("git", ["init", "-q"], cd: workspace)
    System.cmd("git", ["add", "."], cd: workspace)

    System.cmd(
      "git",
      [
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.invalid",
        "commit",
        "--no-gpg-sign",
        "-qm",
        "Add router and orders API"
      ],
      cd: workspace,
      env: [
        {"GIT_AUTHOR_DATE", "2026-01-01T12:00:00Z"},
        {"GIT_COMMITTER_DATE", "2026-01-01T12:00:00Z"}
      ]
    )

    {:ok, id} =
      BeamAgent.start_session(
        workspace_root: workspace,
        data_dir: Path.join(root, "runtime"),
        provider: :echo,
        repository_scan_interval_ms: 60_000
      )

    {:ok, goal} = BeamAgent.goal(id)

    on_exit(fn ->
      BeamAgent.stop_session(id)
      File.rm_rf(root)
    end)

    assert {:ok, %{model: model}} = Observatory.snapshot(goal.project_id)

    router = Enum.find(model.files, &(&1.path == "lib/demo_web/router.ex"))

    assert [%{method: "GET", path: "/health", framework: "phoenix/plug router"}] =
             router.protocols

    orders = Enum.find(model.files, &(&1.path == "src/api/orders.js"))
    methods = Enum.map(orders.protocols, & &1.method)
    assert "GET" in methods and "POST" in methods

    touchpoint = Enum.find(orders.external_touchpoints, &(&1.package == "stripe"))
    assert touchpoint.declared == true
    assert touchpoint.version == "^14.0.0"
    assert touchpoint.ecosystem == "npm"

    pair = Enum.sort(["lib/demo_web/router.ex", "src/api/orders.js"])

    assert Enum.any?(model.co_change, fn e -> Enum.sort([e.source, e.target]) == pair end)
    assert router.co_change != []
    assert orders.co_change != []

    assert Enum.any?(model.limits, &(&1 =~ "correlation"))
    assert Enum.any?(model.limits, &(&1 =~ "live route table"))
  end

  test "source reads reject escape symlinks and credential filenames", ctx do
    external = Path.join(Path.dirname(ctx.workspace), "outside.ts")
    File.write!(external, "import secret from './private';")
    File.ln_s!(external, Path.join(ctx.workspace, "escape.ts"))
    File.write!(Path.join(ctx.workspace, ".env.production"), "SECRET=do-not-export")
    assert {:ok, %{model: model}} = Observatory.snapshot(ctx.project_id)
    refute Enum.any?(model.files, &(&1.path == ".env.production"))
    refute Enum.any?(model.unresolved, &(&1.reference == "./private"))
    refute JSON.encode!(model) =~ "do-not-export"
  end
end
