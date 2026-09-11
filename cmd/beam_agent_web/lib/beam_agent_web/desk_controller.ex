defmodule BeamAgentWeb.DeskController do
  use Phoenix.Controller, formats: [:html]
  alias BeamAgentWeb.{Page, RuntimeClient}

  def index(conn, _params) do
    if authenticated?(conn) do
      notice = get_session(conn, :notice)

      page =
        case RuntimeClient.sessions() do
          {:ok, directory} ->
            Page.overview(directory, csrf(), notice)

          {:error, {:runtime_http_error, 404}} ->
            Page.desk(RuntimeClient.snapshot(), csrf(), notice)

          _ ->
            Page.overview(
              %{"sessions" => [], "unavailable" => true},
              csrf(),
              "Runtime directory unavailable. No work has been restarted."
            )
        end

      conn |> delete_session(:notice) |> html(page)
    else
      html(conn, Page.login(csrf(), RuntimeClient.configured?()))
    end
  end

  def session(conn, %{"session_id" => id}) do
    if authenticated?(conn) do
      notice = get_session(conn, :notice)

      conn
      |> delete_session(:notice)
      |> html(Page.desk(RuntimeClient.snapshot(id), csrf(), notice, id))
    else
      html(conn, Page.login(csrf(), RuntimeClient.configured?()))
    end
  end

  def sessions_panel(conn, _) do
    if authenticated?(conn) do
      case RuntimeClient.sessions() do
        {:ok, directory} -> html(conn, Page.directory(directory))
        _ -> conn |> put_status(503) |> html("Runtime directory unavailable")
      end
    else
      conn |> send_resp(401, "Sign in first.")
    end
  end

  def create_session(conn, params) do
    args =
      params
      |> Map.take(["workspace", "request_id"])
      |> Map.put_new("request_id", Page.start_id())

    with true <- authenticated?(conn),
         {:ok, %{"request_id" => id}} <- RuntimeClient.create_session(args) do
      redirect(conn,
        to: "/session-starts/" <> id <> if(params["observer"] == "1", do: "?observer=1", else: "")
      )
    else
      false ->
        conn |> send_resp(401, "Sign in first.")

      {:ok, %{"session_id" => id}} when not is_map_key(args, "workspace") ->
        # Compatibility with a still-running older, synchronous catalog.
        redirect(conn, to: session_path(id))

      {:ok, _} ->
        conn
        |> put_session(
          :notice,
          "An older runtime could not confirm the chosen workspace. Restart Desk after rebuilding and check live sessions before retrying."
        )
        |> redirect(to: "/")

      {:error, reason} ->
        conn
        |> put_session(
          :notice,
          "Session startup not confirmed (#{inspect(reason)}). Check live sessions before retrying."
        )
        |> redirect(to: "/")
    end
  end

  def session_start(conn, params) do
    if authenticated?(conn) do
      case RuntimeClient.session_start(params["id"]) do
        {:ok, %{"status" => "ready", "session_id" => id}} ->
          redirect(conn,
            to: session_path(id) <> if(params["observer"] == "1", do: "/observer", else: "")
          )

        result ->
          html(conn, Page.session_start(result))
      end
    else
      send_resp(conn, 401, "Sign in first.")
    end
  end

  def session_start_status(conn, params) do
    if authenticated?(conn) do
      case RuntimeClient.session_start(params["id"]) do
        {:ok, job} ->
          json(conn, job)

        _ ->
          conn
          |> put_status(404)
          |> json(%{
            error: "Startup status unavailable. Check live sessions; no request was repeated."
          })
      end
    else
      send_resp(conn, 401, "Sign in first.")
    end
  end

  def workspaces(conn, params) do
    if authenticated?(conn) do
      html(conn, Page.workspaces(RuntimeClient.workspaces(), csrf(), params["observer"] == "1"))
    else
      send_resp(conn, 401, "Sign in first.")
    end
  end

  def workspace_paths(conn, params) do
    if authenticated?(conn) do
      case RuntimeClient.workspaces(params) do
        {:ok, listing} ->
          json(conn, listing)

        _ ->
          conn
          |> put_status(422)
          |> json(%{error: "Directory unavailable or not readable by the runtime."})
      end
    else
      send_resp(conn, 401, "Sign in first.")
    end
  end

  def login(conn, %{"token" => supplied}) when is_binary(supplied) do
    token = RuntimeClient.token()

    if RuntimeClient.configured?() and Plug.Crypto.secure_compare(supplied, token) do
      conn
      |> configure_session(renew: true)
      |> put_session(:authenticated, fingerprint(token))
      |> redirect(to: "/")
    else
      conn
      |> put_status(401)
      |> html(Page.login(csrf(), RuntimeClient.configured?(), "Token not accepted."))
    end
  end

  def login(conn, _), do: conn |> put_status(400) |> html("A token is required.")

  def launch(conn, %{"ticket" => ticket}) do
    if RuntimeClient.configured?() and BeamAgentWeb.LaunchTicket.consume(ticket) do
      conn
      |> configure_session(renew: true)
      |> put_session(:authenticated, fingerprint(RuntimeClient.token()))
      |> send_resp(204, "")
    else
      conn
      |> put_status(401)
      |> html(
        "Launch link expired or already used. Run ./loom desk for a fresh link. Your agents keep running."
      )
    end
  end

  def launch(conn, _), do: conn |> send_resp(400, "A launch ticket is required.")

  def logout(conn, _), do: conn |> configure_session(drop: true) |> redirect(to: "/")

  def panels(conn, params) do
    if authenticated?(conn) do
      case RuntimeClient.snapshot(params["session_id"]) do
        {:ok, snapshot} ->
          html(conn, Page.panels(snapshot, csrf(), params["session_id"]))

        {:error, _} ->
          conn
          |> put_status(503)
          |> html("Runtime unavailable. Reconnecting; your work remains runtime-owned.")
      end
    else
      conn
      |> put_status(401)
      |> html("Session expired. Run ./loom desk to reconnect; your agents keep running.")
    end
  end

  def command(conn, params) do
    with true <- authenticated?(conn),
         {:ok, name, arguments} <- arguments(params),
         {:ok, _} <- RuntimeClient.command(name, arguments, params["session_id"]) do
      notice =
        if name == "submit",
          do: "Prompt accepted by the runtime.",
          else: "Command accepted by the runtime."

      conn |> put_session(:notice, notice) |> redirect(to: session_path(params["session_id"]))
    else
      false ->
        conn |> put_status(401) |> html("Sign in first.")

      {:error, reason} ->
        conn
        |> put_status(422)
        |> html(
          Page.desk(
            RuntimeClient.snapshot(params["session_id"]),
            csrf(),
            "Command not confirmed: #{inspect(reason)}. Check activity before retrying.",
            params["session_id"]
          )
        )
    end
  end

  def observer(conn, params) do
    if authenticated?(conn) do
      id = params["session_id"]

      with {:ok, mission} <-
             RuntimeClient.command("documentation_mission", %{action: "status"}, id),
           {:ok, listing} <-
             RuntimeClient.command("documentation_mission", %{action: "browse"}, id) do
        html(conn, Page.observer(mission, listing, csrf(), id))
      else
        {:error, reason} ->
          conn
          |> put_status(422)
          |> html(
            Page.desk(
              RuntimeClient.snapshot(id),
              csrf(),
              "Folder browser unavailable: #{inspect(reason)}. The observer needs a readable Git workspace.",
              id
            )
          )
      end
    else
      send_resp(conn, 401, "Sign in first.")
    end
  end

  def observer_paths(conn, params) do
    if authenticated?(conn) do
      case RuntimeClient.command(
             "documentation_mission",
             %{action: "browse", path: params["path"] || "."},
             params["session_id"]
           ) do
        {:ok, listing} ->
          json(conn, listing)

        {:error, _} ->
          conn
          |> put_status(422)
          |> json(%{error: "Cannot browse that path within this session's Git workspace."})
      end
    else
      send_resp(conn, 401, "Sign in first.")
    end
  end

  def observer_followup(conn, params) do
    if authenticated?(conn) do
      case RuntimeClient.command(
             "documentation_mission",
             %{
               action: "preview_fix",
               report_id: params["report_id"],
               finding_id: params["finding_id"]
             },
             params["session_id"]
           ) do
        {:ok, finding} ->
          html(conn, Page.observer_followup(finding, params, csrf()))

        _ ->
          conn
          |> put_session(
            :notice,
            "This finding is no longer available. Reload the current report."
          )
          |> redirect(to: session_path(params["session_id"]))
      end
    else
      send_resp(conn, 401, "Sign in first.")
    end
  end

  defp session_path(nil), do: "/"
  defp session_path(id), do: "/sessions/" <> URI.encode(id, &URI.char_unreserved?/1)

  defp arguments(%{"command" => "submit", "prompt" => prompt}) when is_binary(prompt) do
    if String.trim(prompt) != "" and byte_size(prompt) <= 100_000,
      do: {:ok, "submit", %{prompt: prompt}},
      else: {:error, :invalid_prompt}
  end

  defp arguments(%{"command" => "cancel"}), do: {:ok, "cancel", %{}}

  defp arguments(%{
         "command" => "documentation_mission",
         "action" => "prepare_fix",
         "report_id" => report,
         "finding_id" => finding
       })
       when is_binary(report) and is_binary(finding),
       do:
         {:ok, "documentation_mission",
          %{action: "prepare_fix", report_id: report, finding_id: finding}}

  defp arguments(%{
         "command" => "documentation_mission",
         "action" => "cancel_fix",
         "followup_id" => id
       })
       when is_binary(id),
       do: {:ok, "documentation_mission", %{action: "cancel_fix", followup_id: id}}

  defp arguments(%{"command" => "documentation_mission", "action" => action, "paths" => paths})
       when action in ["start", "configure"] and is_binary(paths) and byte_size(paths) <= 4200 do
    selected = paths |> String.split(~r/\r?\n/, trim: true) |> Enum.uniq()

    if selected != [],
      do: {:ok, "documentation_mission", %{action: action, paths: selected}},
      else: {:error, :choose_at_least_one_path}
  end

  defp arguments(%{"command" => "documentation_mission", "paths" => _}),
    do: {:error, :invalid_mission_paths}

  defp arguments(%{"command" => "documentation_mission", "action" => action})
       when action in ["start", "pause", "resume", "dismiss", "stop", "delete"],
       do: {:ok, "documentation_mission", %{action: action}}

  defp arguments(%{"command" => "approval", "approval_id" => id, "decision" => decision})
       when is_binary(id) and decision in ["allow_once", "deny"],
       do: {:ok, "approval", %{approval_id: id, decision: decision}}

  defp arguments(_), do: {:error, :unsupported_command}

  defp authenticated?(conn) do
    RuntimeClient.configured?() and
      get_session(conn, :authenticated) == fingerprint(RuntimeClient.token())
  end

  defp fingerprint(token), do: :crypto.hash(:sha256, token) |> Base.encode16()
  defp csrf, do: Plug.CSRFProtection.get_csrf_token()
end
