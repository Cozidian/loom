defmodule BeamAgent.LocalEndpoint do
  @moduledoc "Publishes one live session without creating or resuming another owner."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with {:ok, http} <- BeamAgent.start_web_control_plane(id, token: token, conversation: true),
         {:ok, tui} <-
           BeamAgent.CLI.TUI.Server.start_link(
             session_id: id,
             config: config,
             config_path: Keyword.fetch!(opts, :config_path),
             token: token
           ),
         {:ok, url} <- BeamAgent.ControlPlane.HTTPServer.url(http),
         {:ok, port} <- BeamAgent.CLI.TUI.Server.port(tui) do
      record = %{
        "session_id" => id,
        "workspace" => config["workspace_root"],
        "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "owner_pid" => System.pid(),
        "http_port" => URI.parse(url).port,
        "tui_port" => port,
        "token" => token
      }

      case BeamAgent.LocalDiscovery.publish(
             record,
             Keyword.get(opts, :directory, BeamAgent.LocalDiscovery.directory())
           ) do
        {:ok, path} ->
          {:ok, %{http: http, tui: tui, path: path, token: token}}

        error ->
          GenServer.stop(tui)
          GenServer.stop(http)
          {:stop, error}
      end
    else
      {:error, reason} -> {:stop, reason}
      unexpected -> {:stop, {:endpoint_start_failed, unexpected}}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) when pid == state.http or pid == state.tui,
    do: {:stop, {:interface_stopped, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, state) do
    BeamAgent.LocalDiscovery.remove(state.path, state.token)
    for pid <- [state.tui, state.http], Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end
end
