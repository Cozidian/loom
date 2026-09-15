defmodule BeamAgent.ControlPlane.HTTPServer do
  @moduledoc """
  Authenticated loopback web shell for `BeamAgent.ControlPlane`, on Bandit/Plug.

  It exposes a live polling view plus the versioned runtime command protocol.
  The web process is only a client: stopping it never stops the observed goal.
  A Phoenix LiveView host can use the same `ControlPlane` process directly.
  """
  use GenServer

  alias BeamAgent.ControlPlane
  alias BeamAgent.Runtime.JSONProtocol

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def url(server), do: GenServer.call(server, :url)

  @impl true
  def init(opts) do
    session_id = Keyword.get(opts, :session_id)
    token = Keyword.get_lazy(opts, :token, &new_token/0)
    port = Keyword.get(opts, :port, 0)

    with true <- is_binary(token) and byte_size(token) >= 16,
         {:ok, control_plane} <- start_control_plane(session_id, opts),
         {:ok, bandit} <-
           Bandit.start_link(
             plug: {__MODULE__.Router, control_plane: control_plane, token: token},
             scheme: :http,
             ip: {127, 0, 0, 1},
             port: port,
             startup_log: false
           ),
         {:ok, {_address, actual_port}} <- ThousandIsland.listener_info(bandit) do
      {:ok,
       %{
         bandit: bandit,
         control_plane: control_plane,
         token: token,
         url: "http://127.0.0.1:#{actual_port}/?token=#{URI.encode_www_form(token)}"
       }}
    else
      false -> {:stop, :invalid_control_plane_token}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:url, _from, state), do: {:reply, {:ok, state.url}, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.bandit) and Process.alive?(state.bandit), do: Supervisor.stop(state.bandit)

    if is_pid(state.control_plane) and Process.alive?(state.control_plane),
      do: GenServer.stop(state.control_plane)

    :ok
  end

  @doc false
  def serve_request(request, control_plane, token) do
    if authorized?(token, request) do
      route(request, control_plane, token)
    else
      response(401, "application/json", JSON.encode!(%{error: "unauthorized"}))
    end
  end

  defp start_control_plane(nil, opts), do: {:ok, {:catalog, Keyword.fetch!(opts, :catalog)}}

  defp start_control_plane(session, opts),
    do:
      ControlPlane.start_link(
        session_id: session,
        conversation: Keyword.get(opts, :conversation, false)
      )

  defp route(request, {:catalog, opts}, token) do
    if authorized?(token, %{request | query: %{}}) do
      case BeamAgent.ControlPlane.Catalog.route(request, opts) do
        {:ok, result} -> json(200, %{ok: true, result: result})
        {:error, reason} -> json(200, %{ok: false, error: catalog_error(reason)})
      end
    else
      json(401, %{ok: false, error: "bearer_token_required"})
    end
  end

  defp route(%{method: "GET", path: "/api/v1/identity"}, control_plane, _token) do
    {:ok, identity} = ControlPlane.identity(control_plane)
    json(200, %{ok: true, result: identity})
  end

  defp route(%{method: "GET", path: "/api/v1/activity"}, control_plane, _token) do
    case ControlPlane.activity(control_plane) do
      {:ok, activity} -> json(200, %{ok: true, result: activity})
      {:error, reason} -> json(200, %{ok: false, error: catalog_error(reason)})
    end
  end

  defp route(%{method: "GET", path: "/"}, _control_plane, token),
    do: response(200, "text/html; charset=utf-8", page(token))

  defp route(%{method: "GET", path: "/api/v1/snapshot"}, control_plane, _token) do
    case ControlPlane.snapshot(control_plane) do
      {:ok, snapshot} -> json(200, %{ok: true, result: snapshot})
      {:error, reason} -> json(500, %{ok: false, error: inspect(reason)})
    end
  end

  defp route(%{method: "GET", path: "/api/v1/conversation"} = request, control_plane, token) do
    # Content is opt-in and requires an Authorization header, never a URL token.
    if authorized?(token, %{request | query: %{}}) do
      case ControlPlane.conversation(control_plane) do
        {:ok, conversation} -> json(200, %{ok: true, result: conversation})
        {:error, reason} -> json(403, %{ok: false, error: to_string(reason)})
      end
    else
      json(401, %{ok: false, error: "bearer_token_required"})
    end
  end

  defp route(%{method: "POST", path: "/api/v1/command", body: body}, control_plane, _token) do
    case JSON.decode(body) do
      {:ok, request} when is_map(request) ->
        json(200, ControlPlane.dispatch(control_plane, request))

      _other ->
        json(400, %{ok: false, error: "invalid_json"})
    end
  end

  defp route(_request, _control_plane, _token),
    do: response(404, "application/json", JSON.encode!(%{error: "not_found"}))

  defp catalog_error(reason) when is_atom(reason), do: to_string(reason)
  defp catalog_error({reason, _}) when is_atom(reason), do: to_string(reason)
  defp catalog_error(_), do: "catalog_request_failed"

  defp authorized?(token, request) do
    supplied =
      request.query["token"] || bearer(request.headers["authorization"])

    is_binary(supplied) and byte_size(supplied) == byte_size(token) and
      :crypto.hash(:sha256, supplied) == :crypto.hash(:sha256, token)
  end

  defp bearer("Bearer " <> token), do: token
  defp bearer(_header), do: nil

  defp json(status, value),
    do: response(status, "application/json", JSONProtocol.encode_response(value))

  defp response(status, content_type, body), do: {status, content_type, body}

  defp page(token) do
    safe_token = token |> String.replace("&", "&amp;") |> String.replace("\"", "&quot;")

    """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <title>BeamAgent Control Plane</title><style>
    body{font-family:ui-monospace,monospace;background:#202329;color:#cdd6f4;margin:2rem}header{display:flex;justify-content:space-between;color:#89dceb}
    button,input{font:inherit;background:#292c33;color:#cdd6f4;border:1px solid #585b70;padding:.6rem}button{cursor:pointer;color:#a6e3a1}
    .controls{display:flex;gap:.5rem;margin:1rem 0}#prompt{flex:1}pre{white-space:pre-wrap;border:1px solid #45475a;padding:1rem;max-height:72vh;overflow:auto}
    </style></head><body><header><strong>BEAM AGENT</strong><span id="state">connecting</span></header>
    <div class="controls"><input id="prompt" placeholder="Ask BeamAgent"><button onclick="submitPrompt()">Submit</button><button onclick="command('verify')">Verify</button><button onclick="command('cancel')">Cancel</button></div>
    <pre id="snapshot">Loading runtime snapshot...</pre><script>
    const token="#{safe_token}";let sequence=0;
    async function refresh(){const r=await fetch('/api/v1/snapshot?token='+encodeURIComponent(token));const d=await r.json();
      document.getElementById('state').textContent=d.result?.status?.agent_status||'unknown';document.getElementById('snapshot').textContent=JSON.stringify(d.result,null,2)}
    async function command(name,args={}){sequence++;await fetch('/api/v1/command',{method:'POST',headers:{'content-type':'application/json','authorization':'Bearer '+token},body:JSON.stringify({version:1,request_id:'web-'+sequence,command:name,arguments:args})});await refresh()}
    function submitPrompt(){const input=document.getElementById('prompt');if(input.value){command('submit',{prompt:input.value});input.value=''}}
    refresh();setInterval(refresh,1000);
    </script></body></html>
    """
  end

  defp new_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
