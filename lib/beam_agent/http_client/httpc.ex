defmodule BeamAgent.HTTPClient.Httpc do
  @moduledoc false
  @behaviour BeamAgent.HTTPClient

  @impl true
  def post_json(url, headers, body, options) do
    request = {
      String.to_charlist(url),
      encode_headers(headers),
      ~c"application/json",
      JSON.encode!(body)
    }

    request(:post, request, url, options)
  rescue
    error -> {:error, {:request_encode_failed, Exception.message(error)}}
  end

  @impl true
  def get_json(url, headers, options) do
    request = {String.to_charlist(url), encode_headers(headers)}
    request(:get, request, url, options)
  end

  defp request(method, request, url, options) do
    timeout = Keyword.get(options, :timeout_ms, 30_000)

    http_options = [
      timeout: timeout,
      connect_timeout: min(timeout, 10_000),
      ssl: ssl_options(url)
    ]

    case :httpc.request(method, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} ->
        decode_response(status, body)

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp decode_response(status, ""), do: {:ok, status, %{}}

  defp decode_response(status, body) do
    case JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, status, decoded}
      {:ok, decoded} -> {:error, {:invalid_json_response, status, decoded}}
      {:error, _reason} -> {:error, {:invalid_json_response, status, truncate(body)}}
    end
  end

  defp encode_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp ssl_options("https://" <> _rest) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp ssl_options(_url), do: []

  defp truncate(body) when byte_size(body) > 1_000,
    do: binary_part(body, 0, 1_000) <> "..."

  defp truncate(body), do: body
end
