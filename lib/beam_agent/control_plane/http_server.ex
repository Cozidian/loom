defmodule BeamAgent.ControlPlane.HTTPServer do
  @moduledoc """
  Dependency-free loopback web shell for `BeamAgent.ControlPlane`.

  It exposes a live polling view plus the versioned runtime command protocol.
  The web process is only a client: stopping it never stops the observed goal.
  A Phoenix LiveView host can use the same `ControlPlane` process directly.
  """
  use GenServer

  alias BeamAgent.ControlPlane
  alias BeamAgent.Runtime.JSONProtocol

  @maximum_request_bytes 1_048_576

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def url(server), do: GenServer.call(server, :url)

  @impl true
  def init(opts) do
    session_id = Keyword.get(opts, :session_id)
    token = Keyword.get_lazy(opts, :token, &new_token/0)
    port = Keyword.get(opts, :port, 0)

    with true <- is_binary(token) and byte_size(token) >= 16,
         {:ok, control_plane} <- start_control_plane(session_id, opts),
         {:ok, listener} <-
           :gen_tcp.listen(port,
             mode: :binary,
             packet: :raw,
             active: false,
             reuseaddr: true,
             ip: {127, 0, 0, 1}
           ),
         {:ok, {_ip, actual_port}} <- :inet.sockname(listener) do
      owner = self()

      acceptor =
        spawn_link(fn -> accept_loop(listener, owner, control_plane, token) end)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
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
  def handle_info({:acceptor_failed, reason}, state),
    do: {:stop, {:control_plane_acceptor_failed, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)

    if is_pid(state.control_plane) and Process.alive?(state.control_plane),
      do: GenServer.stop(state.control_plane)

    :ok
  end

  defp accept_loop(listener, owner, control_plane, token) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        handler = spawn(fn -> await_socket(control_plane, token) end)

        case :gen_tcp.controlling_process(socket, handler) do
          :ok -> send(handler, {:socket, socket})
          {:error, _reason} -> :gen_tcp.close(socket)
        end

        accept_loop(listener, owner, control_plane, token)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(owner, {:acceptor_failed, reason})
    end
  end

  defp await_socket(control_plane, token) do
    receive do
      {:socket, socket} -> serve(socket, control_plane, token)
    after
      5_000 -> :ok
    end
  end

  defp serve(socket, control_plane, token) do
    response =
      with {:ok, request} <- read_request(socket),
           true <- authorized?(token, request) do
        route(request, control_plane, token)
      else
        false ->
          response(401, "application/json", JSON.encode!(%{error: "unauthorized"}))

        {:error, :request_too_large} ->
          response(413, "text/plain", "request too large")

        {:error, _reason} ->
          response(400, "application/json", JSON.encode!(%{error: "bad_request"}))
      end

    :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
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

  defp read_request(socket), do: read_headers(socket, "")

  defp read_headers(_socket, buffer) when byte_size(buffer) > @maximum_request_bytes,
    do: {:error, :request_too_large}

  defp read_headers(socket, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {index, 4} ->
        header_bytes = binary_part(buffer, 0, index)
        rest = binary_part(buffer, index + 4, byte_size(buffer) - index - 4)
        parse_request(socket, header_bytes, rest)

      :nomatch ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, bytes} -> read_headers(socket, buffer <> bytes)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_request(socket, header_bytes, rest) do
    [request_line | header_lines] = String.split(header_bytes, "\r\n")

    with [method, target, _version] <- String.split(request_line, " ", parts: 3),
         headers <- parse_headers(header_lines),
         {:ok, content_length} <- content_length(headers),
         true <- content_length <= @maximum_request_bytes,
         {:ok, body} <- read_body(socket, rest, content_length) do
      uri = URI.parse(target)

      {:ok,
       %{
         method: method,
         path: uri.path || "/",
         query: URI.decode_query(uri.query || ""),
         headers: headers,
         body: body
       }}
    else
      false -> {:error, :request_too_large}
      _other -> {:error, :invalid_request}
    end
  rescue
    _error -> {:error, :invalid_request}
  end

  defp parse_headers(lines) do
    Map.new(lines, fn line ->
      [name, value] = String.split(line, ":", parts: 2)
      {String.downcase(String.trim(name)), String.trim(value)}
    end)
  end

  defp content_length(headers) do
    case Integer.parse(Map.get(headers, "content-length", "0")) do
      {length, ""} when length >= 0 -> {:ok, length}
      _other -> {:error, :invalid_content_length}
    end
  end

  defp read_body(_socket, rest, length) when byte_size(rest) >= length,
    do: {:ok, binary_part(rest, 0, length)}

  defp read_body(socket, rest, length) do
    case :gen_tcp.recv(socket, length - byte_size(rest), 5_000) do
      {:ok, bytes} -> read_body(socket, rest <> bytes, length)
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp response(status, content_type, body) do
    [
      "HTTP/1.1 #{status} #{reason(status)}\r\n",
      "content-type: #{content_type}\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "cache-control: no-store\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end

  defp reason(200), do: "OK"
  defp reason(400), do: "Bad Request"
  defp reason(401), do: "Unauthorized"
  defp reason(403), do: "Forbidden"
  defp reason(404), do: "Not Found"
  defp reason(413), do: "Payload Too Large"
  defp reason(_status), do: "Internal Server Error"

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
