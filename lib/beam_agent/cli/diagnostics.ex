defmodule BeamAgent.CLI.Diagnostics do
  @moduledoc false
  alias BeamAgent.Service.Storage

  def run(args) when args in [[], ["--help"], ["-h"]] do
    IO.puts(
      "loom diagnostics capture|status|stop|start\nCapture saves a bounded incident report from the running service.\nStop pauses automatic recording; retained captures remain on disk."
    )

    0
  end

  def run([action]) when action in ["capture", "status", "stop", "start"] do
    method = if action == "status", do: :get, else: :post

    path =
      if action == "status", do: "/api/v1/diagnostics", else: "/api/v1/diagnostics/" <> action

    case with {:ok, record} <- Storage.lookup(), do: Storage.request(record, method, path, %{}) do
      {:ok, result} ->
        IO.puts(JSON.encode!(result))
        0

      _ ->
        IO.puts(
          :stderr,
          "Diagnostics unavailable. Check loom service status; no service was started."
        )

        1
    end
  end

  def run(_args) do
    IO.puts(:stderr, "Use loom diagnostics capture|status|stop|start")
    1
  end
end
