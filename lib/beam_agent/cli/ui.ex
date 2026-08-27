defmodule BeamAgent.CLI.UI do
  @moduledoc false

  @accent :cyan
  @success :green

  def setup_header do
    blank()
    line([:bright, @accent, "◆", :reset, :bright, " beam agent"])
    line([:faint, "  First-time setup · choose a model and where sessions live"])
    divider()
  end

  def choose_provider(providers, default) do
    blank()
    line([:bright, "Choose a provider"])

    providers
    |> Enum.with_index(1)
    |> Enum.each(fn {provider, index} ->
      line([
        :faint,
        "  ",
        String.pad_leading(Integer.to_string(index), 2),
        :reset,
        "  ",
        @accent,
        String.pad_trailing(provider.name, 11),
        :reset,
        provider.label
      ])
    end)

    blank()

    case IO.gets(format([:bright, @accent, "Select", :reset, " [#{default}]: "])) do
      :eof ->
        default

      input ->
        resolve_provider(String.trim(input), providers, default)
    end
  end

  def session_header(config, session_id) do
    blank()
    line([:bright, @accent, "◆", :reset, :bright, " beam agent"])

    line([
      :faint,
      "  ",
      provider_label(config),
      "  ·  ",
      short_session(session_id)
    ])

    divider()
    line([:faint, "  Type a message · /help commands · /exit leave"])
    blank()
  end

  def one_shot_header(config, session_id) do
    line([
      :faint,
      "beam agent  ·  ",
      provider_label(config),
      "  ·  ",
      short_session(session_id)
    ])
  end

  def prompt, do: IO.gets(format([:bright, @accent, "› ", :reset]))

  def assistant(content) do
    blank()
    line([:bright, @success, "◆", :reset, :bright, " assistant"])
    block(content || "")
    blank()
  end

  def begin_live_turn do
    Process.put({__MODULE__, :live}, %{response_open?: false})
    begin_wait()
  end

  def live_event(%{type: :text_delta, delta: delta}) when is_binary(delta) and delta != "" do
    state = live_state()

    state =
      if state.response_open? do
        state
      else
        end_wait()
        blank()
        line([:bright, @success, "◆", :reset, :bright, " assistant"])
        IO.write("  ")
        %{state | response_open?: true}
      end

    IO.write(indent_delta(delta))
    Process.put({__MODULE__, :live}, state)
  end

  def live_event(%{type: :response_finished}) do
    close_live_response()
    begin_wait()
  end

  def live_event(%{type: :response_failed}) do
    close_live_response()
  end

  def live_event(%{type: :durable_event, event: %{"type" => type} = event})
      when type in ["tool_called", "tool_result"] do
    close_live_response()
    end_wait()
    live_tool_event(event)
    begin_wait()
  end

  def live_event(_event), do: :ok

  def end_live_turn do
    close_live_response()
    end_wait()
    Process.delete({__MODULE__, :live})
  end

  def tool_trace(events) do
    relevant = Enum.filter(events, &(&1["type"] in ["tool_called", "tool_result"]))

    if relevant != [] do
      blank()

      Enum.each(relevant, fn
        %{"type" => "tool_called", "data" => data} ->
          arguments = format_arguments(data["arguments"] || %{})
          line([:yellow, "◇", :reset, :faint, " tool  ", :reset, data["name"], arguments])

        %{"type" => "tool_result", "data" => data} ->
          marker = if data["is_error"], do: [:red, "!"], else: [@success, "↳"]
          line(["  ", marker, :reset, :faint, "  ", compact(data["content"])])
      end)
    end
  end

  def command_help do
    blank()
    line([:bright, "Commands"])
    command("/new", "start a fresh session")
    command("/sessions", "list durable sessions")
    command("/status", "show provider, model, session, and event log")
    command("/auto", "toggle automatic approval of risky tools")
    command("/compact", "summarize older completed turns now")
    command("/skills", "list skills discovered for this session")
    command("/reload", "reload project instructions and skill metadata")
    command("/events", "show the current event count and log path")
    command("/clear", "clear the terminal and redraw the session")
    command("/help", "show this command list")
    command("/exit", "leave the chat; the session stays resumable")
    blank()
  end

  def status(config, session_id, event_path, context, context_stats) do
    blank()
    line([:bright, "Session"])
    field("provider", config["provider"])
    field("profile", config["profile"])
    field("model", config["model"] || "built-in")
    field("session", session_id)
    field("workspace", config["workspace_root"])
    field("approval", config["approval_policy"])
    field("instructions", length(context.instructions))
    field("skills", length(context.skills))
    field("project context", String.slice(context.fingerprint, 0, 12))

    field(
      "model context",
      "#{context_stats.estimated_tokens}/#{context_stats.window_tokens} est. tokens " <>
        "(#{context_stats.utilization_percent}%)"
    )

    field("compactions", context_stats.compaction_count)
    field("events", event_path)
    blank()
  end

  def notice(message), do: line([:faint, message])
  def success(message), do: line([@success, "✓ ", :reset, message])
  def warning(message), do: line([:yellow, "! ", :reset, message])

  def approval(request) do
    end_wait()
    blank()
    line([:yellow, "◆", :reset, :bright, " approval required"])
    field("tool", request.tool)
    field("access", request.access)
    field("arguments", compact(JSON.encode!(request.arguments)))

    decision =
      case IO.gets(format([:bright, @accent, "Allow once?", :reset, " [y/N]: "])) do
        input when is_binary(input) ->
          if String.downcase(String.trim(input)) in ["y", "yes"], do: :allow_once, else: :deny

        _ ->
          :deny
      end

    if decision == :allow_once, do: success("Approved once"), else: warning("Denied")
    begin_wait()
    decision
  end

  def begin_wait do
    if ansi?(), do: IO.write(format([:faint, "  ◌ thinking…", :reset]))
  end

  def end_wait do
    if ansi?(), do: IO.write("\r" <> IO.ANSI.clear_line())
  end

  def clear do
    if ansi?(), do: IO.write(IO.ANSI.clear() <> IO.ANSI.home())
  end

  defp command(name, description) do
    line(["  ", @accent, String.pad_trailing(name, 12), :reset, description])
  end

  defp resolve_provider("", _providers, default), do: default

  defp resolve_provider(input, providers, _default) do
    case Integer.parse(input) do
      {index, ""} when index > 0 ->
        case Enum.at(providers, index - 1) do
          nil -> input
          provider -> provider.name
        end

      _ ->
        input
    end
  end

  defp field(name, value) do
    line([:faint, "  ", String.pad_trailing(name, 10), :reset, to_string(value)])
  end

  defp provider_label(config) do
    provider =
      case config["model"] do
        model when is_binary(model) and model != "" -> "#{config["provider"]}/#{model}"
        _ -> config["provider"]
      end

    profile = config["profile"]

    if is_binary(profile) and profile != config["provider"],
      do: "#{profile}  ·  #{provider}",
      else: provider
  end

  defp short_session("session-" <> suffix), do: "session " <> String.slice(suffix, 0, 8)
  defp short_session(session_id), do: session_id

  defp format_arguments(arguments) when map_size(arguments) == 0, do: ""

  defp format_arguments(arguments) do
    formatted =
      arguments
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join("  ", fn {key, value} -> "#{key}=#{compact(value)}" end)

    "  " <> formatted
  end

  defp compact(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 160)
  end

  defp compact(value), do: inspect(value, limit: 8, printable_limit: 160)

  defp live_tool_event(%{"type" => "tool_called", "data" => data}) do
    arguments = format_arguments(data["arguments"] || %{})
    line([:yellow, "◇", :reset, :faint, " tool  ", :reset, data["name"], arguments])
  end

  defp live_tool_event(%{"type" => "tool_result", "data" => data}) do
    marker = if data["is_error"], do: [:red, "!"], else: [@success, "↳"]
    line(["  ", marker, :reset, :faint, "  ", compact(data["content"])])
  end

  defp close_live_response do
    state = live_state()

    if state.response_open? do
      IO.write("\n\n")
      Process.put({__MODULE__, :live}, %{state | response_open?: false})
    end
  end

  defp live_state, do: Process.get({__MODULE__, :live}, %{response_open?: false})

  defp indent_delta(delta), do: String.replace(delta, "\n", "\n  ")

  defp block(content) do
    content
    |> String.split("\n")
    |> Enum.each(&IO.puts("  " <> &1))
  end

  defp divider, do: line([:faint, String.duplicate("─", width())])
  defp blank, do: IO.puts("")
  defp line(parts), do: IO.puts(format(parts))

  defp format(parts), do: parts |> IO.ANSI.format(ansi?()) |> IO.iodata_to_binary()

  defp width do
    case :io.columns(:standard_io) do
      {:ok, columns} -> columns |> max(36) |> min(88)
      _ -> 64
    end
  end

  defp ansi? do
    IO.ANSI.enabled?() and is_nil(System.get_env("NO_COLOR"))
  end
end
