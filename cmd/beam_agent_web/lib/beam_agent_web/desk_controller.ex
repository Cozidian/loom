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

  def create_session(conn, _) do
    with true <- authenticated?(conn),
         {:ok, %{"session_id" => id}} <- RuntimeClient.create_session() do
      redirect(conn, to: "/sessions/" <> id)
    else
      false ->
        conn |> send_resp(401, "Sign in first.")

      _ ->
        conn
        |> put_status(422)
        |> html("Session creation not confirmed. Check the overview before retrying.")
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
      |> html("Launch link expired or already used. Restart Desk to get a new link.")
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
      conn |> put_status(401) |> html("Session expired. Reload to sign in.")
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

  defp session_path(nil), do: "/"
  defp session_path(id), do: "/sessions/" <> URI.encode(id, &URI.char_unreserved?/1)

  defp arguments(%{"command" => "submit", "prompt" => prompt}) when is_binary(prompt) do
    if String.trim(prompt) != "" and byte_size(prompt) <= 100_000,
      do: {:ok, "submit", %{prompt: prompt}},
      else: {:error, :invalid_prompt}
  end

  defp arguments(%{"command" => "cancel"}), do: {:ok, "cancel", %{}}

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
