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
  def post_json_stream(url, headers, body, _options, initial_state, chunk_fun) do
    request = {
      String.to_charlist(url),
      encode_headers(headers),
      ~c"application/json",
      JSON.encode!(body)
    }

    http_options = [ssl: ssl_options(url)]

    case :httpc.request(:post, request, http_options, sync: false, stream: :self) do
      {:ok, request_id} -> await_stream(request_id, initial_state, chunk_fun)
      {:error, reason} -> {:error, {:transport_error, reason}}
    end
  rescue
    error -> {:error, {:request_encode_failed, Exception.message(error)}}
  end

  @impl true
  def get_json(url, headers, options) do
    request = {String.to_charlist(url), encode_headers(headers)}
    request(:get, request, url, options)
  end

  defp request(method, request, url, _options) do
    http_options = [ssl: ssl_options(url)]

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

  defp await_stream(request_id, state, chunk_fun) do
    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        receive_stream(request_id, state, chunk_fun)

      {:http, {^request_id, {{_version, status, _reason}, _headers, body}}} ->
        decode_response(status, body)

      {:http, {^request_id, {:error, reason}}} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp receive_stream(request_id, state, chunk_fun) do
    receive do
      {:http, {^request_id, :stream, body_part}} ->
        case safely_emit(chunk_fun, body_part, state) do
          {:ok, next_state} ->
            receive_stream(request_id, next_state, chunk_fun)

          {:error, reason} ->
            :httpc.cancel_request(request_id)
            {:error, reason}
        end

      {:http, {^request_id, :stream_end, _headers}} ->
        {:ok, 200, :streamed, state}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp safely_emit(chunk_fun, body_part, state) do
    case chunk_fun.(body_part, state) do
      {:ok, next_state} -> {:ok, next_state}
      other -> {:error, {:invalid_stream_callback_return, other}}
    end
  rescue
    error -> {:error, {:stream_callback_failed, Exception.message(error)}}
  end
end
