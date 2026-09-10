defmodule BeamAgentWeb.DeskController do
  use Phoenix.Controller, formats: [:html]
  alias BeamAgentWeb.{Page, RuntimeClient}

  def index(conn, _params) do
    if authenticated?(conn) do
      notice = get_session(conn, :notice)
      conn |> delete_session(:notice) |> html(Page.desk(RuntimeClient.snapshot(), csrf(), notice))
    else
      html(conn, Page.login(csrf(), RuntimeClient.configured?()))
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

  def logout(conn, _), do: conn |> configure_session(drop: true) |> redirect(to: "/")

  def panels(conn, _) do
    if authenticated?(conn) do
      case RuntimeClient.snapshot() do
        {:ok, snapshot} ->
          html(conn, Page.panels(snapshot, csrf()))

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
         {:ok, _} <- RuntimeClient.command(name, arguments) do
      notice =
        if name == "submit",
          do: "Prompt accepted by the runtime.",
          else: "Command accepted by the runtime."

      conn |> put_session(:notice, notice) |> redirect(to: "/")
    else
      false ->
        conn |> put_status(401) |> html("Sign in first.")

      {:error, reason} ->
        conn
        |> put_status(422)
        |> html(
          Page.desk(
            RuntimeClient.snapshot(),
            csrf(),
            "Command not confirmed: #{inspect(reason)}. Check activity before retrying."
          )
        )
    end
  end

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
