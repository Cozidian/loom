defmodule BeamAgent.CodexAppServer.Client do
  @moduledoc """
  OTP-owned JSON-RPC client for the local `codex app-server` stdio transport.

  The client owns the external process, correlates requests without blocking its
  mailbox, and forwards server notifications and requests to one owner process.
  """
  use GenServer, restart: :temporary

  alias BeamAgent.CodexAppServer.TurnBudget

  @default_timeout 30_000
  @max_line_bytes 4 * 1_024 * 1_024

  @doc false
  def begin_turn(client, options) do
    GenServer.call(client, {:begin_turn, options}, @default_timeout)
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def request(client, method, params \\ %{}, timeout \\ @default_timeout) do
    GenServer.call(client, {:request, method, params}, timeout)
  end

  def notify(client, method, params \\ %{}) do
    GenServer.call(client, {:notify, method, params}, @default_timeout)
  end

  def respond(client, id, result) do
    GenServer.call(client, {:respond, id, result}, @default_timeout)
  end

  def stop(client) when is_pid(client) do
    if Process.alive?(client), do: GenServer.stop(client, :normal, @default_timeout)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    # The owner can be killed by cancellation. Trap its linked exit so terminate
    # can also kill a subprocess that ignores stdin closing.
    Process.flag(:trap_exit, true)
    owner = Keyword.get(opts, :owner, self())

    with executable when is_binary(executable) <- executable(opts),
         {:ok, port} <- open_port(executable, arguments(opts), opts) do
      {:ok,
       %{
         owner: owner,
         owner_monitor: Process.monitor(owner),
         port: port,
         buffer: [],
         buffer_bytes: 0,
         max_line_bytes: TurnBudget.positive(opts, :max_line_bytes, @max_line_bytes),
         budget: nil,
         timer: nil,
         failure: nil,
         next_id: 1,
         waiters: %{}
       }}
    else
      nil -> {:stop, :codex_not_installed}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(_request, _from, %{failure: reason} = state) when not is_nil(reason),
    do: {:reply, {:error, reason}, state}

  def handle_call({:begin_turn, options}, _from, state) do
    cancel_timer(state.timer)
    budget = TurnBudget.new(options)
    tag = make_ref()
    timer = Process.send_after(self(), {:turn_timeout, tag}, budget.timeout_ms)
    {:reply, :ok, %{state | budget: budget, timer: {timer, tag}}}
  end

  def handle_call({:request, method, params}, from, state) do
    id = state.next_id
    message = %{"id" => id, "method" => method, "params" => params}

    case write(state.port, message) do
      :ok ->
        {:noreply, %{state | next_id: id + 1, waiters: Map.put(state.waiters, id, from)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:notify, method, params}, _from, state) do
    {:reply, write(state.port, %{"method" => method, "params" => params}), state}
  end

  def handle_call({:respond, id, result}, _from, state) do
    {:reply, write(state.port, %{"id" => id, "result" => result}), state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case consume_bytes(state, byte_size(data)) do
      {:ok, state} -> {:noreply, decode_lines(data, state)}
      {:error, reason} -> {:noreply, fail(state, reason)}
    end
  end

  def handle_info({:turn_timeout, tag}, %{timer: {_timer, tag}, budget: budget} = state) do
    {:error, reason} = TurnBudget.timeout(budget)
    {:noreply, fail(state, reason)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = {:codex_app_server_exit, status}
    {:noreply, fail(%{state | port: nil}, reason)}
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state)
      when monitor == state.owner_monitor and owner == state.owner do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    :ok
  end

  defp fail(state, reason) do
    close_port(state.port)
    cancel_timer(state.timer)
    reply_waiters(state.waiters, {:error, reason})
    send(state.owner, {:codex_app_server, self(), {:exit, reason}})

    # Keep a small tombstone until the owner closes us. A host tool may still be
    # running; its subsequent respond call must return the limit, not exit :noproc.
    %{
      state
      | port: nil,
        buffer: [],
        buffer_bytes: 0,
        waiters: %{},
        budget: nil,
        timer: nil,
        failure: reason
    }
  end

  defp close_port(port) when is_port(port) do
    # Port.close alone only closes pipes on Unix; an uncooperative child can live
    # on. Kill only this owned subprocess, never a name-based process search.
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp close_port(_port), do: :ok

  defp cancel_timer(nil), do: :ok
  defp cancel_timer({timer, _tag}), do: Process.cancel_timer(timer)

  defp dispatch(%{"id" => id, "result" => result}, state) do
    reply(id, {:ok, result}, state)
  end

  defp dispatch(%{"id" => id, "error" => error}, state) do
    reply(id, {:error, {:codex_app_server_error, error}}, state)
  end

  defp dispatch(%{"id" => _id, "method" => _method} = request, state) do
    send(state.owner, {:codex_app_server, self(), {:request, request}})
    state
  end

  defp dispatch(%{"method" => "turn/completed"} = notification, state) do
    send(state.owner, {:codex_app_server, self(), {:notification, notification}})
    cancel_timer(state.timer)
    %{state | budget: nil, timer: nil}
  end

  defp dispatch(%{"method" => _method} = notification, state) do
    send(state.owner, {:codex_app_server, self(), {:notification, notification}})
    state
  end

  defp dispatch(_message, state), do: state

  defp reply(id, result, state) do
    case Map.pop(state.waiters, id) do
      {nil, _waiters} ->
        state

      {from, waiters} ->
        GenServer.reply(from, result)
        %{state | waiters: waiters}
    end
  end

  defp reply_waiters(waiters, result) do
    Enum.each(waiters, fn {_id, from} -> GenServer.reply(from, result) end)
  end

  # Bound incomplete lines before joining/decoding them. Retain fragments as
  # iodata so a child writing a line one byte at a time cannot force rescans.
  defp decode_lines(_data, %{failure: reason} = state) when not is_nil(reason), do: state

  defp decode_lines(data, state) do
    case :binary.split(data, "\n") do
      [fragment] ->
        case append_fragment(state, fragment) do
          {:ok, state} -> state
          {:error, reason} -> fail(state, reason)
        end

      [fragment, rest] ->
        with {:ok, state} <- append_fragment(state, fragment),
             {:ok, state} <- consume_message(state) do
          line = state.buffer |> Enum.reverse() |> IO.iodata_to_binary()
          state = %{state | buffer: [], buffer_bytes: 0}
          state = decode_line(line, state)
          decode_lines(rest, state)
        else
          {:error, reason} -> fail(state, reason)
        end
    end
  end

  defp append_fragment(state, fragment) do
    size = state.buffer_bytes + byte_size(fragment)

    cond do
      size > state.max_line_bytes ->
        {:error, {:codex_transport_limit, :line_bytes, state.max_line_bytes}}

      fragment == "" ->
        {:ok, state}

      true ->
        {:ok, %{state | buffer: [:binary.copy(fragment) | state.buffer], buffer_bytes: size}}
    end
  end

  defp decode_line("", state), do: state

  defp decode_line(line, state) do
    case JSON.decode(line) do
      {:ok, message} when is_map(message) -> dispatch(message, state)
      {:error, reason} -> fail(state, {:codex_app_server_protocol_error, reason})
      {:ok, _other} -> fail(state, {:codex_app_server_protocol_error, :non_object_message})
    end
  end

  defp consume_bytes(%{budget: nil} = state, _bytes), do: {:ok, state}

  defp consume_bytes(state, bytes) do
    with {:ok, budget} <- TurnBudget.consume(state.budget, bytes, 0),
         do: {:ok, %{state | budget: budget}}
  end

  defp consume_message(%{budget: nil} = state), do: {:ok, state}

  defp consume_message(state) do
    with {:ok, budget} <- TurnBudget.consume(state.budget, 0),
         do: {:ok, %{state | budget: budget}}
  end

  defp write(port, message) do
    case Port.command(port, [JSON.encode!(message), "\n"]) do
      true -> :ok
      false -> {:error, :codex_app_server_closed}
    end
  rescue
    error -> {:error, {:codex_app_server_write_failed, Exception.message(error)}}
  end

  defp executable(opts) do
    Keyword.get(opts, :executable) ||
      System.get_env("BEAM_AGENT_CODEX_BIN") ||
      System.find_executable("codex")
  end

  defp arguments(opts) do
    Keyword.get(opts, :arguments, ["app-server", "--stdio"])
  end

  defp open_port(executable, arguments, opts) do
    port_options = [
      :binary,
      :exit_status,
      :use_stdio,
      :hide,
      {:args, Enum.map(arguments, &String.to_charlist/1)}
    ]

    port_options =
      case Keyword.get(opts, :environment) do
        environment when is_list(environment) ->
          [
            {:env,
             Enum.map(environment, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)}
            | port_options
          ]

        _ ->
          port_options
      end

    {:ok,
     Port.open(
       {:spawn_executable, String.to_charlist(executable)},
       port_options
     )}
  rescue
    error -> {:error, {:codex_app_server_start_failed, Exception.message(error)}}
  end
end
