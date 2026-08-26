defmodule BeamAgent.CLI.TUI do
  @moduledoc false

  alias BeamAgent.CLI.TUI.{App, Controller}

  def available?(override \\ nil)

  def available?(false), do: false

  def available?(_override) do
    dimensions_available? =
      match?({_columns, _rows}, terminal_dimensions()) or
        (match?({:ok, _columns}, :io.columns(:standard_io)) and
           match?({:ok, _rows}, :io.rows(:standard_io)))

    System.get_env("BEAM_AGENT_NO_TUI") not in ["1", "true"] and
      System.get_env("TERM") not in [nil, "", "dumb"] and IO.ANSI.enabled?() and
      dimensions_available?
  end

  def run(session_id, config) do
    terminal_state = terminal_state()
    dimensions = terminal_dimensions()

    try do
      case TermUI.Runtime.start_link(
             root: App,
             session_id: session_id,
             config: config,
             width: dimension(dimensions, 0),
             height: dimension(dimensions, 1),
             render_interval: 33
           ) do
        {:ok, runtime} ->
          :ok = apply_terminal_raw_mode(terminal_state)
          sync_runtime_dimensions(runtime, dimensions)
          start_controller(runtime, session_id, config, dimensions)

        {:error, _reason} = error ->
          error
      end
    after
      restore_terminal(terminal_state)
    end
  end

  defp start_controller(runtime, session_id, config, dimensions) do
    resize_monitor = start_resize_monitor(runtime, dimensions)

    case Controller.start_link(runtime: runtime, session_id: session_id, config: config) do
      {:ok, controller} ->
        wait_for_runtime(runtime, controller, resize_monitor)

      {:error, _reason} = error ->
        stop_resize_monitor(resize_monitor)
        if Process.alive?(runtime), do: TermUI.Runtime.shutdown(runtime)
        error
    end
  end

  defp wait_for_runtime(runtime, controller, resize_monitor) do
    monitor = Process.monitor(runtime)

    try do
      receive do
        {:DOWN, ^monitor, :process, ^runtime, :normal} -> :ok
        {:DOWN, ^monitor, :process, ^runtime, reason} -> {:error, {:tui_runtime_exit, reason}}
      end
    after
      Process.demonitor(monitor, [:flush])
      stop_resize_monitor(resize_monitor)

      if Process.alive?(controller) do
        GenServer.stop(controller, :normal)
      end

      if Process.alive?(runtime) do
        TermUI.Runtime.shutdown(runtime)
      end
    end
  end

  defp sync_runtime_dimensions(_runtime, nil), do: :ok

  defp sync_runtime_dimensions(runtime, {columns, rows}) do
    send(runtime, {:terminal_resize, {rows, columns}})
    TermUI.Runtime.sync(runtime)
  end

  defp start_resize_monitor(_runtime, nil), do: nil

  defp start_resize_monitor(runtime, dimensions) do
    spawn_link(fn -> monitor_dimensions(runtime, dimensions) end)
  end

  defp monitor_dimensions(runtime, previous) do
    receive do
      :stop ->
        :ok
    after
      500 ->
        current = terminal_dimensions()

        if current && current != previous do
          {columns, rows} = current
          send(runtime, {:terminal_resize, {rows, columns}})
        end

        if Process.alive?(runtime), do: monitor_dimensions(runtime, current || previous)
    end
  end

  defp stop_resize_monitor(nil), do: :ok

  defp stop_resize_monitor(pid) do
    send(pid, :stop)
    :ok
  end

  # TermUI switches the terminal to raw mode, but its stty subprocess does not
  # necessarily inherit the controlling terminal. Apply the same settings to
  # /dev/tty explicitly so control keys reach the Elm loop instead of being
  # interpreted by the line discipline. The exact pre-TUI state is restored
  # even when startup or rendering fails.
  defp terminal_state do
    with shell when is_binary(shell) <- System.find_executable("sh"),
         {state, 0} <-
           System.cmd(shell, ["-c", "stty -g < /dev/tty"], stderr_to_stdout: true) do
      String.trim(state)
    else
      _ -> nil
    end
  end

  defp terminal_dimensions do
    with shell when is_binary(shell) <- System.find_executable("sh"),
         {size, 0} <-
           System.cmd(shell, ["-c", "stty size < /dev/tty"], stderr_to_stdout: true),
         [rows_text, columns_text] <- String.split(String.trim(size)),
         {rows, ""} when rows > 0 <- Integer.parse(rows_text),
         {columns, ""} when columns > 0 <- Integer.parse(columns_text) do
      {columns, rows}
    else
      _ -> nil
    end
  end

  defp dimension(nil, _index), do: nil
  defp dimension(dimensions, index), do: elem(dimensions, index)

  defp apply_terminal_raw_mode(nil), do: :ok

  defp apply_terminal_raw_mode(_terminal_state) do
    run_stty("stty raw -echo -isig -ixon min 1 time 0 < /dev/tty")
    :ok
  end

  defp restore_terminal(nil), do: :ok

  defp restore_terminal(state) do
    with shell when is_binary(shell) <- System.find_executable("sh") do
      System.cmd(shell, ["-c", "stty \"$1\" < /dev/tty", "beam-agent-stty", state],
        stderr_to_stdout: true
      )
    end

    :ok
  end

  defp run_stty(command) do
    with shell when is_binary(shell) <- System.find_executable("sh") do
      System.cmd(shell, ["-c", command], stderr_to_stdout: true)
    end
  end
end
