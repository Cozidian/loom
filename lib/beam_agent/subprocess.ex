defmodule BeamAgent.Subprocess do
  @moduledoc "Bounded foreground OS process execution with explicit argv and cwd."

  @default_max_output 100_000

  def run(executable, args, opts) when is_binary(executable) and is_list(args) do
    timeout = Keyword.get(opts, :timeout_ms, 30_000)
    max_output = Keyword.get(opts, :max_output_bytes, @default_max_output)
    cwd = Keyword.fetch!(opts, :cwd)

    port_options = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      :hide,
      {:args, Enum.map(args, &String.to_charlist/1)},
      {:cd, String.to_charlist(cwd)}
    ]

    port = Port.open({:spawn_executable, String.to_charlist(executable)}, port_options)
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, deadline, max_output, "", false)
  rescue
    error -> {:error, {:subprocess_start_failed, Exception.message(error)}}
  end

  defp collect(port, deadline, max_output, output, truncated?) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        {output, truncated?} = append_output(output, data, max_output, truncated?)
        collect(port, deadline, max_output, output, truncated?)

      {^port, {:exit_status, status}} ->
        {:ok, %{status: status, output: output, truncated: truncated?}}
    after
      remaining ->
        terminate(port)
        {:error, {:subprocess_timeout, output, truncated?}}
    end
  end

  defp append_output(output, _data, max, true) when byte_size(output) >= max,
    do: {output, true}

  defp append_output(output, data, max, truncated?) do
    remaining = max - byte_size(output)

    if byte_size(data) <= remaining do
      {output <> data, truncated?}
    else
      {output <> binary_part(data, 0, remaining), true}
    end
  end

  defp terminate(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        if kill = System.find_executable("kill") do
          _ = System.cmd(kill, ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
        end

      _ ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end
end
