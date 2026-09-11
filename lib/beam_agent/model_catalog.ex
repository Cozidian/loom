defmodule BeamAgent.ModelCatalog do
  @moduledoc "Read-only provider discovery and conservative, model-specific capability mapping."
  alias BeamAgent.{ModelEndpoint, Providers.Support}

  def discover(endpoint, opts \\ []) do
    options = Keyword.merge(ModelEndpoint.invocation_options(endpoint), opts)

    case discover_provider(endpoint, options) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn row ->
           if is_map(row), do: Map.put_new(row, "model", row["id"]), else: row
         end)}

      result ->
        result
    end
  rescue
    _ -> {:error, :catalogue_failed}
  catch
    _, _ -> {:error, :catalogue_failed}
  end

  defp discover_provider(%{provider: :openai, auth: %{"type" => "chatgpt"}}, opts) do
    codex = Keyword.get(opts, :codex_app_server, BeamAgent.CodexAppServer)

    with {:ok, %{"account" => %{"type" => "chatgpt"}}} <- codex.account(),
         {:ok, models} <- codex.models() do
      {:ok, Enum.reject(models, &(&1["hidden"] == true))}
    else
      _ -> {:error, :chatgpt_login_required}
    end
  end

  defp discover_provider(%{provider: :ollama}, opts) do
    client = Support.http_client(opts)

    with {:ok, 200, %{"models" => models}} <-
           client.get_json(Support.endpoint(opts[:base_url], "/api/tags"), [], timeout: 5_000) do
      # /show reads metadata only; it never loads or generates with a model.
      rows =
        Task.async_stream(
          models,
          fn row ->
            id = row["name"]

            details =
              case client.post_json(
                     Support.endpoint(opts[:base_url], "/api/show"),
                     [],
                     %{"model" => id},
                     timeout: 3_000
                   ) do
                {:ok, 200, body} -> Map.take(body, ["capabilities", "model_info", "parameters"])
                _ -> %{}
              end

            Map.merge(details, %{"model" => id})
          end,
          max_concurrency: 4,
          timeout: 4_000,
          on_timeout: :kill_task
        )
        |> Enum.zip(models)
        |> Enum.map(fn
          {{:ok, row}, _} -> row
          {_, row} -> %{"model" => row["name"]}
        end)

      {:ok, rows}
    else
      _ -> {:error, :ollama_catalogue_unavailable}
    end
  end

  defp discover_provider(%{provider: provider} = endpoint, opts)
       when provider in [:openai, :xai, :anthropic] do
    configuration = endpoint.provider_module.configuration()

    with {:ok, key} <- Support.api_key(opts, configuration.default_api_key_env) do
      headers =
        if provider == :anthropic,
          do: [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}],
          else: [{"authorization", "Bearer " <> key}]

      path =
        case provider do
          :xai -> "/language-models"
          :anthropic -> "/v1/models"
          _ -> "/models"
        end

      pages(
        Support.http_client(opts),
        Support.endpoint(opts[:base_url], path),
        headers,
        nil,
        [],
        MapSet.new()
      )
    else
      _ -> {:error, :catalogue_credentials_unavailable}
    end
  end

  defp discover_provider(_, _), do: {:manual, :no_discovery_adapter}

  defp pages(client, url, headers, cursor, rows, seen) do
    target = if cursor, do: url <> "?after_id=" <> URI.encode_www_form(cursor), else: url

    case client.get_json(target, headers, timeout: 5_000) do
      {:ok, 200, %{"data" => models} = body} when is_list(models) ->
        next = body["last_id"]

        cond do
          body["has_more"] != true ->
            {:ok, rows ++ models}

          not is_binary(next) or MapSet.member?(seen, next) or MapSet.size(seen) >= 50 ->
            {:error, :invalid_catalogue_cursor}

          true ->
            pages(client, url, headers, next, rows ++ models, MapSet.put(seen, next))
        end

      {:ok, 200, %{"models" => models}} when is_list(models) ->
        {:ok, models}

      {:ok, status, _} ->
        {:error, {:catalogue_http_status, status}}

      _ ->
        {:error, :catalogue_unavailable}
    end
  end

  def endpoints(connection, rows) do
    rows
    |> Enum.filter(&(is_map(&1) and &1["hidden"] != true))
    |> Enum.flat_map(fn row ->
      id = row["model"] || row["id"]

      if is_binary(id) and String.trim(id) != "" do
        claims = Map.merge(connection.claims, model_claims(connection, row, id))

        [
          %{
            connection
            | id: model_id(connection.id, id),
              connection_id: connection.id,
              model: id,
              claims: claims,
              health: %{status: :unknown, checked_at: nil},
              measurements: %{}
          }
        ]
      else
        []
      end
    end)
    |> Enum.uniq_by(& &1.id)
  end

  def model_id(connection, model) do
    "model-" <>
      (:crypto.hash(:sha256, connection <> "\0" <> model)
       |> Base.encode16(case: :lower)
       |> binary_part(0, 48))
  end

  defp model_claims(%{provider: :ollama}, row, _) do
    caps = row["capabilities"] || []

    capabilities =
      Enum.flat_map(
        [
          {"completion", :text_generation},
          {"tools", :tool_use},
          {"thinking", :reasoning},
          {"embedding", :embedding}
        ],
        fn {name, cap} -> if name in caps, do: [cap], else: [] end
      )

    # The advertised maximum is not necessarily the configured usable window.
    context =
      case Regex.run(~r/(?:^|\n)\s*num_ctx\s+(\d+)/, row["parameters"] || "") do
        [_, n] -> String.to_integer(n)
        _ -> nil
      end

    %{
      capabilities: capabilities,
      modalities: if("vision" in caps, do: [:text, :image], else: [:text]),
      context_window_tokens: context,
      source: if(row["capabilities"], do: :catalogue, else: :unknown)
    }
  end

  defp model_claims(%{provider: :openai, auth: %{"type" => "chatgpt"}}, row, _) do
    modalities = if "image" in (row["inputModalities"] || []), do: [:text, :image], else: [:text]

    %{
      capabilities: [:text_generation, :tool_use, :reasoning],
      modalities: modalities,
      context_window_tokens: nil,
      source: :codex_catalogue
    }
  end

  defp model_claims(%{provider: :xai}, row, _) do
    inputs = row["input_modalities"] || []
    outputs = row["output_modalities"] || []
    text? = "text" in outputs

    %{
      capabilities: if(text?, do: [:text_generation, :tool_use, :reasoning], else: []),
      modalities: if("image" in inputs, do: [:text, :image], else: [:text]),
      context_window_tokens: positive(row["context_length"]),
      source: :catalogue
    }
  end

  defp model_claims(%{provider: :anthropic}, row, _) do
    caps = row["capabilities"] || %{}

    %{
      capabilities:
        [:text_generation, :tool_use] ++
          if(get_in(caps, ["thinking", "supported"]) == true, do: [:reasoning], else: []),
      modalities:
        if(get_in(caps, ["image_input", "supported"]) == true, do: [:text, :image], else: [:text]),
      context_window_tokens: positive(row["max_input_tokens"]),
      source: :catalogue
    }
  end

  defp model_claims(%{provider: :openai}, _row, id) do
    # The API list supplies IDs, not capabilities. This small transport mapping is
    # an assessment, not measured quality; unsupported families remain unknown.
    chat? =
      Regex.match?(~r/^(?:gpt-(?:4o|4\.1|5(?:\.\d+)?)(?:-|$)|o[34](?:-|$))/, id) and
        not String.contains?(id, ["audio", "realtime", "search", "deep-research", "codex", "-pro"])

    %{
      capabilities: if(chat?, do: [:text_generation, :tool_use, :reasoning], else: []),
      modalities: if(chat?, do: [:text, :image], else: [:text]),
      context_window_tokens: nil,
      source: if(chat?, do: :transport_mapping, else: :unknown)
    }
  end

  defp model_claims(connection, _, _), do: connection.claims
  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil
end
