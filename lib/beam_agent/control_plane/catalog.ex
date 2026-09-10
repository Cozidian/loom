defmodule BeamAgent.ControlPlane.Catalog do
  @moduledoc "Authenticated local session directory and routing facade. Selection is explicit in every request, never global mutable state."

  def route(%{method: "GET", path: "/api/v1/sessions"}, opts),
    do:
      BeamAgent.LocalDiscovery.list(
        Keyword.get(opts, :directory, BeamAgent.LocalDiscovery.directory())
      )

  def route(%{method: "POST", path: "/api/v1/sessions"}, opts) do
    with {:ok, id, _endpoint} <-
           BeamAgent.CLI.create_local_session(opts[:config], opts[:config_path]) do
      {:ok, %{session_id: id}}
    end
  end

  def route(%{path: path, method: method} = request, opts) do
    with ["api", "v1", "sessions", id, operation] <- String.split(path, "/", trim: true),
         true <-
           {method, operation} in [
             {"GET", "snapshot"},
             {"GET", "conversation"},
             {"POST", "command"}
           ],
         {:ok, record} <-
           BeamAgent.LocalDiscovery.lookup(
             id,
             Keyword.get(opts, :directory, BeamAgent.LocalDiscovery.directory())
           ) do
      if method == "GET" do
        BeamAgent.LocalDiscovery.request(record, :get, "/api/v1/" <> operation)
      else
        with {:ok, body} when is_map(body) <- JSON.decode(request.body) do
          BeamAgent.LocalDiscovery.request(record, :post, "/api/v1/command", body)
        else
          _ -> {:error, :invalid_request}
        end
      end
    else
      _ -> {:error, :session_unavailable}
    end
  end
end
