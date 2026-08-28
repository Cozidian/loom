defmodule BeamAgent.Providers.Support do
  @moduledoc false

  def http_client(options), do: Keyword.get(options, :http_client, BeamAgent.HTTPClient.Httpc)

  def require_option(options, key) do
    case Keyword.get(options, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_provider_option, key}}
    end
  end

  def api_key(options, default_env) do
    cond do
      is_binary(options[:api_key]) and options[:api_key] != "" ->
        {:ok, options[:api_key]}

      true ->
        with {:error, :credential_not_found} <- stored_credential(options) do
          env = Keyword.get(options, :api_key_env, default_env)

          case System.get_env(env) do
            value when is_binary(value) and value != "" -> {:ok, value}
            _ -> {:error, {:missing_api_key, env}}
          end
        end
    end
  end

  defp stored_credential(options) do
    explicit? = is_binary(options[:credential_ref])

    reference =
      options[:credential_ref] ||
        with profile when is_binary(profile) <- options[:profile],
             {:ok, reference} <- BeamAgent.Auth.default_reference(profile) do
          reference
        else
          _ -> nil
        end

    case reference do
      reference when is_binary(reference) ->
        case BeamAgent.Auth.resolve(reference) do
          {:ok, secret} -> {:ok, secret}
          {:error, :credential_not_found} -> {:error, :credential_not_found}
          {:error, reason} when explicit? -> {:error, {:stored_credential_unavailable, reason}}
          {:error, _reason} -> {:error, :credential_not_found}
        end

      _ ->
        {:error, :credential_not_found}
    end
  catch
    :exit, _reason -> {:error, :credential_not_found}
  end

  def endpoint(base_url, path), do: String.trim_trailing(base_url, "/") <> path

  def accept(status, body) when status in 200..299, do: {:ok, body}

  def accept(status, body) do
    message = get_in(body, ["error", "message"]) || body["error"] || body["message"] || body
    {:error, {:provider_http_error, status, message}}
  end

  def tool_schema(tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => tool.input_schema
      }
    }
  end

  def call_id, do: "call-" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
