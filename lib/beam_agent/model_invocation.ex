defmodule BeamAgent.ModelInvocation do
  @moduledoc "Executes one model request with normalized success, failure, streaming, and timeout contracts."

  alias BeamAgent.{ModelError, ModelRequest, ModelResponse, ModelUsage}

  def invoke(%ModelRequest{} = request, emit \\ fn _event -> :ok end) when is_function(emit, 1) do
    operation = fn -> execute(request, normalize_emitter(emit)) end

    result =
      case request.timeout do
        :infinity -> operation.()
        timeout -> invoke_with_timeout(operation, timeout)
      end

    case result do
      {:ok, response} ->
        case ModelResponse.normalize(request.request_id, response) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, reason} -> {:error, ModelError.normalize(request, reason)}
        end

      {:error, reason} ->
        {:error, ModelError.normalize(request, reason)}

      other ->
        {:error, ModelError.normalize(request, {:invalid_provider_return, other})}
    end
  end

  defp execute(request, emit) do
    try do
      if request.stream do
        request.provider_module.stream(request.messages, request.tools, request.options, emit)
      else
        request.provider_module.complete(request.messages, request.tools, request.options)
      end
    rescue
      error -> {:error, {:provider_exception, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:provider_throw, kind, reason}}
    end
  end

  defp invoke_with_timeout(operation, timeout) do
    task = Task.async(operation)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :model_timeout}
      {:exit, reason} -> {:error, {:provider_exit, reason}}
    end
  end

  defp normalize_emitter(emit) do
    fn
      {:usage, usage} -> emit.({:usage, ModelUsage.normalize(usage)})
      event -> emit.(event)
    end
  end
end
