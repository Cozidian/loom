defmodule BeamAgent.Auth.OAuthDevice do
  @moduledoc "RFC 8628 OAuth device authorization over OTP's built-in HTTP client."
  @behaviour BeamAgent.Auth.DeviceAdapter
  @behaviour BeamAgent.Auth.TokenRefresher

  @default_interval 5

  @impl true
  def authorize(options) do
    with :ok <- validate_options(options),
         {:ok, response} <-
           post_form(options.device_endpoint, %{
             "client_id" => options.client_id,
             "scope" => options[:scope]
           }),
         {:ok, device_code} <- required(response, "device_code"),
         {:ok, user_code} <- required(response, "user_code"),
         {:ok, verification_uri} <- required(response, "verification_uri") do
      interval = positive_integer(response["interval"], @default_interval)
      expires_in = positive_integer(response["expires_in"], 900)

      {:ok,
       %{
         public: %{
           verification_uri: verification_uri,
           verification_uri_complete: response["verification_uri_complete"],
           user_code: user_code,
           expires_in: expires_in
         },
         poll_after_ms: interval * 1_000,
         poll_state: %{
           token_endpoint: options.token_endpoint,
           client_id: options.client_id,
           device_code: device_code,
           interval_ms: interval * 1_000,
           deadline: System.monotonic_time(:millisecond) + expires_in * 1_000,
           provider: options[:provider]
         }
       }}
    end
  end

  @impl true
  def poll(state) do
    if System.monotonic_time(:millisecond) >= state.deadline do
      {:error, :authorization_expired}
    else
      case post_form(state.token_endpoint, %{
             "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
             "device_code" => state.device_code,
             "client_id" => state.client_id
           }) do
        {:ok, %{"access_token" => token} = response} when is_binary(token) and token != "" ->
          {:ok, credential(response, state)}

        {:error, {:oauth_error, "authorization_pending", _description}} ->
          {:pending, state, state.interval_ms}

        {:error, {:oauth_error, "slow_down", _description}} ->
          interval = state.interval_ms + 5_000
          {:pending, %{state | interval_ms: interval}, interval}

        {:error, {:oauth_error, error, description}} ->
          {:error, {:oauth_authorization_failed, error, description}}

        {:error, reason} ->
          {:error, reason}

        {:ok, response} ->
          {:error, {:invalid_oauth_token_response, safe_keys(response)}}
      end
    end
  end

  @impl BeamAgent.Auth.TokenRefresher
  def refresh(
        %{
          "token_endpoint" => token_endpoint,
          "client_id" => client_id,
          "refresh_token" => refresh_token
        } = credential
      )
      when is_binary(refresh_token) and refresh_token != "" do
    case post_form(token_endpoint, %{
           "grant_type" => "refresh_token",
           "refresh_token" => refresh_token,
           "client_id" => client_id,
           "scope" => credential["scope"]
         }) do
      {:ok, %{"access_token" => token} = response} when is_binary(token) and token != "" ->
        {:ok, refreshed_credential(response, credential)}

      {:ok, response} ->
        {:error, {:invalid_oauth_token_response, safe_keys(response)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refresh(_credential), do: {:error, :oauth_refresh_unavailable}

  defp credential(response, state) do
    expires_in = positive_integer(response["expires_in"], 0)

    %{
      "version" => 1,
      "type" => "oauth",
      "provider" => state.provider && to_string(state.provider),
      "access_token" => response["access_token"],
      "refresh_token" => response["refresh_token"],
      "token_type" => response["token_type"] || "Bearer",
      "scope" => response["scope"],
      "token_endpoint" => state.token_endpoint,
      "client_id" => state.client_id,
      "expires_at" => if(expires_in > 0, do: System.system_time(:second) + expires_in, else: nil)
    }
  end

  defp refreshed_credential(response, credential) do
    expires_in = positive_integer(response["expires_in"], 0)

    credential
    |> Map.put("access_token", response["access_token"])
    |> Map.put("refresh_token", response["refresh_token"] || credential["refresh_token"])
    |> Map.put("token_type", response["token_type"] || credential["token_type"] || "Bearer")
    |> Map.put("scope", response["scope"] || credential["scope"])
    |> Map.put(
      "expires_at",
      if(expires_in > 0, do: System.system_time(:second) + expires_in, else: nil)
    )
  end

  defp post_form(url, fields) do
    body =
      fields
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()
      |> URI.encode_query()

    request = {
      String.to_charlist(url),
      [{~c"accept", ~c"application/json"}],
      ~c"application/x-www-form-urlencoded",
      body
    }

    with {:ok, {{_version, status, _reason}, _headers, response}} <-
           :httpc.request(:post, request, [ssl: ssl_options(url)], body_format: :binary),
         {:ok, decoded} <- decode(response) do
      if status in 200..299 do
        {:ok, decoded}
      else
        {:error,
         {:oauth_error, decoded["error"] || "http_#{status}", decoded["error_description"]}}
      end
    else
      {:error, reason} -> {:error, {:oauth_transport_failed, reason}}
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_oauth_response}
    end
  end

  defp validate_options(options) do
    with :ok <- https_or_loopback(options[:device_endpoint], :device_endpoint),
         :ok <- https_or_loopback(options[:token_endpoint], :token_endpoint),
         true <- is_binary(options[:client_id]) and options.client_id != "" do
      :ok
    else
      false -> {:error, {:invalid_oauth_option, :client_id}}
      {:error, _reason} = error -> error
    end
  end

  defp https_or_loopback(url, field) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) -> :ok
      %URI{scheme: "http", host: host} when host in ["127.0.0.1", "localhost", "::1"] -> :ok
      _ -> {:error, {:invalid_oauth_option, field}}
    end
  end

  defp https_or_loopback(_url, field), do: {:error, {:invalid_oauth_option, field}}

  defp required(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_oauth_response, key}}
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default
  defp safe_keys(map), do: map |> Map.keys() |> Enum.sort()

  defp ssl_options("https://" <> _rest) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp ssl_options(_url), do: []
end
