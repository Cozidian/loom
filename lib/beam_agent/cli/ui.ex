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
    command("/events", "show the current event count and log path")
    command("/clear", "clear the terminal and redraw the session")
    command("/help", "show this command list")
    command("/exit", "leave the chat; the session stays resumable")
    blank()
  end

  def status(config, session_id, event_path) do
    blank()
    line([:bright, "Session"])
    field("provider", config["provider"])
    field("model", config["model"] || "built-in")
    field("session", session_id)
    field("events", event_path)
    blank()
  end

  def notice(message), do: line([:faint, message])
  def success(message), do: line([@success, "✓ ", :reset, message])
  def warning(message), do: line([:yellow, "! ", :reset, message])

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
    case config["model"] do
      model when is_binary(model) and model != "" -> "#{config["provider"]}/#{model}"
      _ -> config["provider"]
    end
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
