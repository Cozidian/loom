defmodule BeamAgent.ControlPlane.HTTPServer.Router do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn

  alias BeamAgent.ControlPlane.HTTPServer

  @maximum_request_bytes 1_048_576

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    control_plane = Keyword.fetch!(opts, :control_plane)
    token = Keyword.fetch!(opts, :token)

    case read_body(conn, length: @maximum_request_bytes) do
      {:ok, body, conn} ->
        conn = fetch_query_params(conn)

        request = %{
          method: conn.method,
          path: conn.request_path,
          query: conn.query_params,
          headers: Map.new(conn.req_headers),
          body: body
        }

        respond(conn, HTTPServer.serve_request(request, control_plane, token))

      {:more, _partial, conn} ->
        respond(conn, {413, "text/plain", "request too large"})

      {:error, _reason} ->
        respond(conn, {400, "application/json", JSON.encode!(%{error: "bad_request"})})
    end
  end

  defp respond(conn, {status, content_type, body}) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type(content_type)
    |> send_resp(status, body)
  end
end
