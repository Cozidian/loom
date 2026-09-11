defmodule BeamAgentWeb.RuntimeClient do
  @moduledoc "Bounded loopback-only HTTP client; no goal state, credentials in browser, or automatic command retries."

  def sessions, do: request(:get, "/api/v1/sessions", nil)
  def create_session, do: request(:post, "/api/v1/sessions", %{})
  def create_session(args), do: request(:post, "/api/v1/sessions", args)

  def session_start(id),
    do: request(:get, "/api/v1/session-starts/" <> URI.encode(id, &URI.char_unreserved?/1), nil)

  def workspaces(params \\ %{}),
    do:
      request(
        :get,
        "/api/v1/workspaces?" <> URI.encode_query(Map.take(params, ["path", "page"])),
        nil
      )

  def snapshot(session_id \\ nil) do
    prefix = session_prefix(session_id)

    with {:ok, snapshot} <- request(:get, prefix <> "/snapshot", nil) do
      snapshot =
        case command("documentation_mission", %{action: "status"}, session_id) do
          {:ok, mission} -> Map.put(snapshot, "documentation_mission", mission)
          {:error, _} -> Map.put(snapshot, "documentation_mission_unavailable", true)
        end

      case request(:get, prefix <> "/conversation", nil) do
        {:ok, conversation} -> {:ok, Map.put(snapshot, "conversation", conversation)}
        {:error, _} -> {:ok, Map.put(snapshot, "conversation_unavailable", true)}
      end
    end
  end

  def command(name, arguments, session_id \\ nil) do
    request(:post, session_prefix(session_id) <> "/command", %{
      version: 1,
      request_id: "desk-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      command: name,
      arguments: arguments
    })
  end

  defp session_prefix(nil), do: "/api/v1"
  defp session_prefix(id), do: "/api/v1/sessions/" <> URI.encode(id, &URI.char_unreserved?/1)

  def token, do: Application.get_env(:beam_agent_web, :runtime_token)

  def configured? do
    is_binary(token()) and byte_size(token()) >= 16 and match?({:ok, _}, base_url())
  end

  def base_url do
    uri = URI.parse(Application.get_env(:beam_agent_web, :runtime_url, ""))

    if uri.scheme == "http" and uri.host == "127.0.0.1" and is_integer(uri.port) and
         uri.port in 1..65535 and uri.path in [nil, "", "/"] and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      {:ok, "http://127.0.0.1:#{uri.port}"}
    else
      {:error, :invalid_runtime_url}
    end
  end

  defp request(method, path, body) do
    with true <- configured?(), {:ok, base} <- base_url() do
      headers = [{~c"authorization", String.to_charlist("Bearer " <> token())}]
      url = String.to_charlist(base <> path)

      request =
        if method == :get,
          do: {url, headers},
          else: {url, headers, ~c"application/json", Jason.encode!(body)}

      case :httpc.request(
             method,
             request,
             [timeout: 8_000, connect_timeout: 2_000, autoredirect: false],
             body_format: :binary
           ) do
        {:ok, {{_, 200, _}, _, encoded}} -> decode(encoded)
        {:ok, {{_, 401, _}, _, _}} -> {:error, :runtime_unauthorized}
        {:ok, {{_, status, _}, _, _}} -> {:error, {:runtime_http_error, status}}
        {:error, _} -> {:error, :runtime_unavailable}
      end
    else
      _ -> {:error, :runtime_not_configured}
    end
  end

  defp decode(encoded) do
    case Jason.decode(encoded) do
      {:ok, %{"ok" => true, "result" => result}} -> {:ok, result}
      {:ok, %{"ok" => false, "error" => error}} when is_binary(error) -> {:error, error}
      _ -> {:error, :invalid_runtime_response}
    end
  end
end
