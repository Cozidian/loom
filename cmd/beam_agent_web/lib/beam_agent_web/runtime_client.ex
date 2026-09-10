defmodule BeamAgentWeb.RuntimeClient do
  @moduledoc "Bounded loopback-only HTTP client; no goal state, credentials in browser, or automatic command retries."

  def snapshot, do: request(:get, "/api/v1/snapshot", nil)

  def command(name, arguments) do
    request(:post, "/api/v1/command", %{
      version: 1,
      request_id: "desk-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      command: name,
      arguments: arguments
    })
  end

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
