defmodule BeamAgent.ControlPlane.Catalog do
  @moduledoc "Authenticated local session directory and routing facade. Selection is explicit in every request, never global mutable state."

  def route(%{method: "GET", path: "/api/v1/service"}, opts) do
    if opts[:service], do: BeamAgent.Service.status(), else: {:error, :not_a_service}
  end

  def route(%{method: "GET", path: "/api/v1/diagnostics"}, opts) do
    if opts[:service], do: BeamAgent.Diagnostics.status(), else: {:error, :not_a_service}
  end

  def route(%{method: "POST", path: "/api/v1/diagnostics/" <> action}, opts) do
    if opts[:service] do
      case action do
        "capture" ->
          BeamAgent.Diagnostics.capture()

        "start" ->
          with :ok <- BeamAgent.Diagnostics.enable(true), do: BeamAgent.Diagnostics.status()

        "stop" ->
          with :ok <- BeamAgent.Diagnostics.enable(false), do: BeamAgent.Diagnostics.status()

        _ ->
          {:error, :invalid_diagnostics_action}
      end
    else
      {:error, :not_a_service}
    end
  end

  def route(%{method: "POST", path: "/api/v1/service/launch", body: body}, opts) do
    with true <- opts[:service] == true,
         {:ok, args} when is_map(args) <- JSON.decode(body),
         do: BeamAgent.Service.launch(args["session_id"]),
         else: (_ -> {:error, :invalid_service_request})
  end

  def route(%{method: "GET", path: "/api/v1/sessions"}, opts),
    do:
      BeamAgent.LocalDiscovery.list(
        Keyword.get(opts, :directory, BeamAgent.LocalDiscovery.directory())
      )

  def route(%{method: "GET", path: "/api/v1/workspaces", query: query}, opts) do
    page =
      case Integer.parse(query["page"] || "0") do
        {number, ""} -> number
        _ -> -1
      end

    BeamAgent.ControlPlane.WorkspaceBrowser.list(
      query["path"] || opts[:config]["workspace_root"],
      page
    )
  end

  def route(%{method: "POST", path: "/api/v1/sessions", body: body}, opts) do
    with {:ok, args} when is_map(args) <- JSON.decode(body),
         {:ok, config} <- workspace_config(opts[:config], args) do
      if args["request_id"] do
        BeamAgent.LocalSessionStarts.begin(args["request_id"], config, opts[:config_path])
      else
        with {:ok, id, _} <- BeamAgent.CLI.create_local_session(config, opts[:config_path]),
             do: {:ok, %{session_id: id}}
      end
    else
      _ -> {:error, :invalid_workspace_request}
    end
  end

  def route(%{method: "GET", path: "/api/v1/session-starts/" <> id}, _),
    do: BeamAgent.LocalSessionStarts.status(id)

  def route(%{path: path, method: method, query: query} = request, opts) do
    with {id, forward_path} <- session_forward(method, path, query),
         {:ok, record} <-
           BeamAgent.LocalDiscovery.lookup(
             id,
             Keyword.get(opts, :directory, BeamAgent.LocalDiscovery.directory())
           ) do
      if method == "GET" do
        BeamAgent.LocalDiscovery.request(record, :get, forward_path)
      else
        with {:ok, body} when is_map(body) <- JSON.decode(request.body) do
          BeamAgent.LocalDiscovery.request(record, :post, forward_path, body)
        else
          _ -> {:error, :invalid_request}
        end
      end
    else
      _ -> {:error, :session_unavailable}
    end
  end

  defp session_forward(method, path, query) do
    case String.split(path, "/", trim: true) do
      ["api", "v1", "sessions", id, "observatory", "file"] when method == "GET" ->
        {id, "/api/v1/observatory/file?" <> URI.encode_query(%{"path" => query["path"] || ""})}

      ["api", "v1", "sessions", id, operation] ->
        if {method, operation} in [
             {"GET", "snapshot"},
             {"GET", "conversation"},
             {"GET", "observatory"},
             {"POST", "command"}
           ],
           do: {id, "/api/v1/" <> operation},
           else: :error

      _ ->
        :error
    end
  end

  defp workspace_config(config, args) do
    path = Map.get(args, "workspace", config["workspace_root"])

    with true <- is_binary(path) and byte_size(path) in 1..4096 and Path.type(path) == :absolute,
         {:ok, root} <- BeamAgent.Workspace.canonical_root(path),
         do: {:ok, Map.put(config, "workspace_root", root)},
         else: (_ -> {:error, :invalid_workspace})
  end
end
