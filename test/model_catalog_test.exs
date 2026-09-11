defmodule BeamAgent.ModelCatalogTest do
  use ExUnit.Case, async: false
  alias BeamAgent.{ModelCatalog, ModelEndpoint, ModelRegistry, ModelRouter, Agent}

  defmodule Provider do
    def configuration,
      do: %{
        capabilities: [:text_generation, :tool_use, :reasoning],
        locality: :local,
        privacy: :local,
        cost_hint: :free
      }

    def healthcheck(_), do: :ok

    def complete(_, _, opts),
      do: {:ok, %{content: "used:" <> (opts[:model] || "none"), tool_calls: []}}
  end

  defmodule Discovery do
    def discover(endpoint, opts) do
      agent = Keyword.fetch!(opts, :fixture)
      result = Elixir.Agent.get(agent, &Map.get(&1, endpoint.id, {:ok, []}))

      case result do
        {:wait, owner, response} ->
          send(owner, {:discovering, self(), endpoint.id})

          receive do
            :continue -> response
          end

        other ->
          other
      end
    end
  end

  defmodule HTTP do
    def get_json("http://catalog.test/api/tags", _, _),
      do: {:ok, 200, %{"models" => [%{"name" => "coder"}, %{"name" => "embed"}]}}

    def get_json("https://api.test/v1/models", _, _),
      do:
        {:ok, 200, %{"data" => [%{"id" => "claude-one"}], "has_more" => true, "last_id" => "one"}}

    def get_json("https://api.test/v1/models?after_id=one", _, _),
      do: {:ok, 200, %{"data" => [%{"id" => "claude-two"}]}}

    def get_json("https://api.test/v1/language-models", _, _),
      do:
        {:ok, 200,
         %{
           "models" => [
             %{
               "id" => "grok-test",
               "input_modalities" => ["text"],
               "output_modalities" => ["text"]
             }
           ]
         }}

    def post_json(_, _, %{"model" => "coder"}, _),
      do: {:ok, 200, %{"capabilities" => ["completion", "tools"], "parameters" => "num_ctx 8192"}}

    def post_json(_, _, %{"model" => "embed"}, _),
      do: {:ok, 200, %{"capabilities" => ["embedding"]}}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "loom-catalog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, fixture} = Elixir.Agent.start_link(fn -> %{} end)

    {:ok, session} =
      BeamAgent.start_session(
        workspace_root: root,
        data_dir: Path.join(root, "state"),
        provider: :echo,
        provider_profile: "local",
        provider_options: [model: "small"],
        model_strategy: :auto,
        model_endpoints: [connection("local"), connection("other")],
        model_discovery: Discovery,
        model_discovery_options: [fixture: fixture]
      )

    {:ok, identity} = Agent.runtime_identity(session)

    on_exit(fn ->
      BeamAgent.stop_project(identity.project_id)
      File.rm_rf!(root)
    end)

    %{project: identity.project_id, session: session, fixture: fixture, root: root}
  end

  defp connection(id), do: %{id: id, provider: :ollama, provider_module: Provider, model: "small"}

  defp model(id, caps \\ ["completion", "tools", "thinking"]),
    do: %{"model" => id, "capabilities" => caps, "parameters" => "num_ctx 8192"}

  defp refresh(c) do
    :ok = ModelRegistry.refresh_catalog(c.project)
    :ok = ModelRegistry.await_catalog(c.project)
  end

  defp input(c, opts \\ %{}) do
    Map.merge(
      %{
        prompt: "explain the architecture",
        workspace_root: c.root,
        strategy: :auto,
        preferred_endpoint_id: "local",
        preferred_provider: :ollama,
        tools: [%{name: "read_file"}],
        context_tokens: 100
      },
      opts
    )
  end

  test "discovery adds every model with stable account-specific identity and credential references",
       c do
    Elixir.Agent.update(c.fixture, fn _ ->
      %{"local" => {:ok, [model("small"), model("large")]}, "other" => {:ok, [model("large")]}}
    end)

    refresh(c)
    {:ok, endpoints} = ModelRegistry.list(c.project)
    assert length(endpoints) == 3
    assert length(Enum.uniq_by(endpoints, & &1.id)) == 3
    large = Enum.find(endpoints, &(&1.connection_id == "local" and &1.model == "large"))
    assert ModelEndpoint.invocation_options(large)[:profile] == "local"
    assert large.id == ModelCatalog.model_id("local", "large")
    {:ok, route} = ModelRouter.route(c.project, input(c))
    assert length(route.candidate_endpoint_ids) == 3
    refresh(c)
    assert {:ok, ^endpoints} = ModelRegistry.list(c.project)
  end

  test "embedding, unknown capabilities, no tools, and undersized contexts never bid for tool work",
       c do
    Elixir.Agent.update(c.fixture, fn _ ->
      %{
        "local" =>
          {:ok,
           [
             model("embed", ["embedding"]),
             model("plain", ["completion"]),
             %{"model" => "unknown"},
             Map.put(model("tiny"), "parameters", "num_ctx 10"),
             model("usable")
           ]}
      }
    end)

    refresh(c)
    {:ok, route} = ModelRouter.route(c.project, input(c))
    assert route.endpoint.model == "usable"
    assert route.candidate_endpoint_ids == [ModelCatalog.model_id("local", "usable")]
  end

  test "a manual lock is the exact connection and model and cannot fall back", c do
    Elixir.Agent.update(c.fixture, fn _ ->
      %{"local" => {:ok, [model("small"), model("large")]}, "other" => {:ok, [model("small")]}}
    end)

    refresh(c)

    locked =
      input(c, %{strategy: :manual, preferred_connection_id: "local", preferred_model: "small"})

    assert {:ok,
            %{endpoint: %{model: "small", connection_id: "local"}, candidate_endpoint_ids: [_]}} =
             ModelRouter.route(c.project, locked)

    {:ok, fallback} = ModelEndpoint.new(connection("local"))
    Elixir.Agent.update(c.fixture, &Map.put(&1, "local", {:ok, [model("large")]}))
    refresh(c)

    assert {:error, _} =
             ModelRouter.route(c.project, Map.put(locked, :fallback_endpoint, fallback))
  end

  test "one provider failure preserves its cache and other providers remain available", c do
    Elixir.Agent.update(c.fixture, fn _ ->
      %{"local" => {:ok, [model("small")]}, "other" => {:error, :offline}}
    end)

    refresh(c)
    assert {:ok, %{endpoint: %{connection_id: "local"}}} = ModelRouter.route(c.project, input(c))
    Elixir.Agent.update(c.fixture, &Map.put(&1, "local", {:error, :offline}))
    refresh(c)
    {:ok, catalog} = ModelRegistry.catalog(c.project)
    assert Enum.find(catalog.sources, &(&1.profile == "local")).status == :stale
    assert Enum.any?(catalog.models, &(&1.model == "small" and &1.connection_id == "local"))
  end

  test "an old discovery result cannot resurrect a removed connection", c do
    # The owner PID must be the test, not the fixture process.
    owner = self()
    Elixir.Agent.update(c.fixture, &Map.put(&1, "local", {:wait, owner, {:ok, [model("small")]}}))
    :ok = ModelRegistry.refresh_catalog(c.project)
    assert_receive {:discovering, worker, "local"}
    assert :ok = ModelRegistry.reconcile(c.project, [], ["local"])
    send(worker, :continue)
    :ok = ModelRegistry.await_catalog(c.project)
    {:ok, endpoints} = ModelRegistry.list(c.project)
    refute Enum.any?(endpoints, &(&1.connection_id == "local"))
  end

  test "disabled connections do not discover or route", c do
    assert :ok =
             ModelRegistry.reconcile(
               c.project,
               [Map.put(connection("local"), :enabled, false)],
               []
             )

    Elixir.Agent.update(c.fixture, fn _ ->
      %{"local" => {:ok, [model("small")]}, "other" => {:ok, [model("large")]}}
    end)

    refresh(c)
    {:ok, route} = ModelRouter.route(c.project, input(c))
    assert route.endpoint.connection_id == "other"
  end

  test "Ollama metadata is read without generation and supplies usable context" do
    {:ok, endpoint} =
      ModelEndpoint.new(%{id: "local", provider: :ollama, base_url: "http://catalog.test"})

    {:ok, rows} = ModelCatalog.discover(endpoint, http_client: HTTP)
    endpoints = ModelCatalog.endpoints(endpoint, rows)
    assert Enum.find(endpoints, &(&1.model == "coder")).claims.context_window_tokens == 8192
    assert Enum.find(endpoints, &(&1.model == "embed")).claims.capabilities == [:embedding]
  end

  test "Anthropic discovery follows pagination and xAI reads language-model metadata" do
    {:ok, anthropic} =
      ModelEndpoint.new(%{id: "claude", provider: :anthropic, base_url: "https://api.test"})

    assert {:ok, [%{"id" => "claude-one"}, %{"id" => "claude-two"}]} =
             ModelCatalog.discover(anthropic, http_client: HTTP, api_key: "fixture")

    {:ok, xai} = ModelEndpoint.new(%{id: "grok", provider: :xai, base_url: "https://api.test/v1"})

    assert {:ok, [%{"id" => "grok-test"} = row]} =
             ModelCatalog.discover(xai, http_client: HTTP, api_key: "fixture")

    assert [endpoint] = ModelCatalog.endpoints(xai, [row])
    assert :tool_use in endpoint.claims.capabilities
  end
end
