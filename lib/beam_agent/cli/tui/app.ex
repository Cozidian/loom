defmodule BeamAgent.CLI.TUI.App do
  @moduledoc false
  use TermUI.Elm

  alias BeamAgent.CLI.TUI.Controller
  alias TermUI.Event
  alias TermUI.Renderer.{DisplayWidth, Style}

  @commands [
    %{id: :status, label: "Session status", hint: "/status"},
    %{id: :new, label: "New session", hint: "/new"},
    %{id: :sessions, label: "Durable sessions", hint: "/sessions"},
    %{id: :skills, label: "Project skills", hint: "/skills"},
    %{id: :reload, label: "Reload project context", hint: "/reload"},
    %{id: :events, label: "Event log", hint: "/events"},
    %{id: :toggle_tools, label: "Expand or collapse tools", hint: "ctrl+t"},
    %{id: :clear, label: "Clear transcript view", hint: "/clear"},
    %{id: :exit, label: "Leave chat", hint: "/exit"}
  ]

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    {detected_width, detected_height} = dimensions()
    width = Keyword.get(opts, :width) || detected_width
    height = Keyword.get(opts, :height) || detected_height

    %{
      session_id: session_id,
      config: config,
      controller: nil,
      entries: history(session_id),
      input: "",
      cursor: 0,
      status: :idle,
      approval: nil,
      palette?: false,
      palette_index: 0,
      panel: nil,
      notice: nil,
      tools_expanded?: false,
      scroll_from_bottom: 0,
      width: width,
      height: height
    }
  end

  @impl true
  def event_to_msg(%Event.Resize{width: width, height: height}, _state),
    do: {:msg, {:resize, width, height}}

  def event_to_msg(%Event.Paste{content: content}, _state), do: {:msg, {:paste, content}}

  def event_to_msg(%Event.Key{key: "c", modifiers: modifiers} = event, state) do
    if :ctrl in modifiers, do: {:msg, :ctrl_c}, else: character_message(event, state)
  end

  def event_to_msg(%Event.Key{key: "p", modifiers: modifiers} = event, state) do
    if :ctrl in modifiers, do: {:msg, :toggle_palette}, else: character_message(event, state)
  end

  def event_to_msg(%Event.Key{key: "o", modifiers: modifiers} = event, state) do
    if :ctrl in modifiers, do: {:msg, :newline}, else: character_message(event, state)
  end

  def event_to_msg(%Event.Key{key: "t", modifiers: modifiers} = event, state) do
    if :ctrl in modifiers, do: {:msg, :toggle_tools}, else: character_message(event, state)
  end

  def event_to_msg(%Event.Key{key: :escape}, _state), do: {:msg, :escape}

  def event_to_msg(%Event.Key{key: :enter, modifiers: modifiers}, _state),
    do: {:msg, if(:ctrl in modifiers, do: :newline, else: :enter)}

  def event_to_msg(%Event.Key{key: :backspace}, _state), do: {:msg, :backspace}
  def event_to_msg(%Event.Key{key: :delete}, _state), do: {:msg, :delete}
  def event_to_msg(%Event.Key{key: :left}, _state), do: {:msg, :left}
  def event_to_msg(%Event.Key{key: :right}, _state), do: {:msg, :right}
  def event_to_msg(%Event.Key{key: :up}, _state), do: {:msg, :up}
  def event_to_msg(%Event.Key{key: :down}, _state), do: {:msg, :down}
  def event_to_msg(%Event.Key{key: :home}, _state), do: {:msg, :home}
  def event_to_msg(%Event.Key{key: :end}, _state), do: {:msg, :end}
  def event_to_msg(%Event.Key{key: :page_up}, _state), do: {:msg, :page_up}
  def event_to_msg(%Event.Key{key: :page_down}, _state), do: {:msg, :page_down}

  def event_to_msg(%Event.Key{char: char}, _state) when is_binary(char) and char != "",
    do: {:msg, {:insert, char}}

  def event_to_msg(%Event.Key{key: key}, _state) when is_binary(key),
    do: {:msg, {:insert, key}}

  def event_to_msg(_event, _state), do: :ignore

  defp character_message(%Event.Key{char: char}, _state) when is_binary(char) and char != "",
    do: {:msg, {:insert, char}}

  defp character_message(%Event.Key{key: key}, _state) when is_binary(key),
    do: {:msg, {:insert, key}}

  defp character_message(_event, _state), do: :ignore

  @impl true
  def update({:controller_ready, controller}, state), do: {%{state | controller: controller}, []}

  def update({:resize, width, height}, state),
    do: {%{state | width: max(width, 40), height: max(height, 10)}, []}

  def update(:toggle_palette, state) do
    {%{state | palette?: not state.palette?, panel: nil, notice: nil}, []}
  end

  def update(:escape, %{approval: approval} = state) when not is_nil(approval) do
    decide_approval(state, :deny)
  end

  def update(:escape, %{palette?: true} = state), do: {%{state | palette?: false}, []}

  def update(:escape, %{panel: panel} = state) when not is_nil(panel),
    do: {%{state | panel: nil}, []}

  def update(:escape, state), do: {state, []}

  def update(:ctrl_c, %{status: status, controller: controller} = state)
      when status in [:running, :cancelling] and is_pid(controller) do
    Controller.cancel(controller)
    {%{state | status: :cancelling, notice: {:warning, "Cancelling current turn…"}}, []}
  end

  def update(:ctrl_c, state), do: {state, [:quit]}

  def update(:toggle_tools, state),
    do: {%{state | tools_expanded?: not state.tools_expanded?}, []}

  def update(:up, %{approval: approval} = state) when not is_nil(approval), do: {state, []}

  def update(:up, %{palette?: true} = state) do
    index = Integer.mod(state.palette_index - 1, length(@commands))
    {%{state | palette_index: index}, []}
  end

  def update(:down, %{approval: approval} = state) when not is_nil(approval), do: {state, []}

  def update(:down, %{palette?: true} = state) do
    index = Integer.mod(state.palette_index + 1, length(@commands))
    {%{state | palette_index: index}, []}
  end

  def update(:left, %{approval: approval} = state) when not is_nil(approval),
    do: {%{state | approval: Map.put(approval, :choice, :deny)}, []}

  def update(:right, %{approval: approval} = state) when not is_nil(approval),
    do: {%{state | approval: Map.put(approval, :choice, :allow_once)}, []}

  def update(:enter, %{approval: %{choice: choice}} = state), do: decide_approval(state, choice)

  def update({:insert, key}, %{approval: approval} = state)
      when not is_nil(approval) and key in ["y", "Y"],
      do: decide_approval(state, :allow_once)

  def update({:insert, key}, %{approval: approval} = state)
      when not is_nil(approval) and key in ["n", "N"],
      do: decide_approval(state, :deny)

  def update({:insert, _key}, %{approval: approval} = state) when not is_nil(approval),
    do: {state, []}

  def update(:enter, %{palette?: true} = state) do
    command = Enum.at(@commands, state.palette_index)
    execute_command(command.id, %{state | palette?: false})
  end

  def update(:enter, state), do: submit_input(state)
  def update(:newline, state), do: insert_text(state, "\n")
  def update({:paste, content}, state), do: insert_text(state, content)
  def update({:insert, content}, state), do: insert_text(state, content)

  def update(:backspace, state) do
    graphemes = String.graphemes(state.input)

    if state.cursor > 0 do
      next = List.delete_at(graphemes, state.cursor - 1) |> Enum.join()
      {%{state | input: next, cursor: state.cursor - 1}, []}
    else
      {state, []}
    end
  end

  def update(:delete, state) do
    graphemes = String.graphemes(state.input)

    if state.cursor < length(graphemes) do
      {%{state | input: List.delete_at(graphemes, state.cursor) |> Enum.join()}, []}
    else
      {state, []}
    end
  end

  def update(:left, state), do: {%{state | cursor: max(0, state.cursor - 1)}, []}

  def update(:right, state),
    do: {%{state | cursor: min(length(String.graphemes(state.input)), state.cursor + 1)}, []}

  def update(:home, state), do: {%{state | cursor: 0}, []}
  def update(:end, state), do: {%{state | cursor: length(String.graphemes(state.input))}, []}

  def update(:page_up, state),
    do: {%{state | scroll_from_bottom: state.scroll_from_bottom + 8}, []}

  def update(:page_down, state),
    do: {%{state | scroll_from_bottom: max(0, state.scroll_from_bottom - 8)}, []}

  def update({:turn_started, _prompt}, state), do: {%{state | status: :running}, []}
  def update(:turn_cancelling, state), do: {%{state | status: :cancelling}, []}

  def update({:turn_finished, {:ok, _answer}}, state),
    do: {%{state | status: :idle, approval: nil, notice: nil}, []}

  def update({:turn_finished, {:error, reason}}, state) do
    entry = %{kind: :error, content: "Turn failed: #{format_error(reason)}", id: unique_id()}
    {%{state | status: :idle, approval: nil, entries: state.entries ++ [entry]}, []}
  end

  def update({:stream, event}, state), do: {apply_stream_event(state, event), []}

  def update({:approval_requested, request}, state) do
    approval = Map.put(request, :choice, :deny)
    {%{state | approval: approval, notice: nil}, []}
  end

  def update({:approval_resolved, approval_id, decision}, state) do
    notice =
      if decision == :allow_once, do: {:success, "Approved once"}, else: {:warning, "Tool denied"}

    state =
      if state.approval && state.approval.approval_id == approval_id,
        do: %{state | approval: nil, notice: notice},
        else: state

    {state, []}
  end

  def update({:notice, tone, message}, state), do: {%{state | notice: {tone, message}}, []}

  def update({:panel, title, lines}, state),
    do: {%{state | panel: {title, lines}, notice: nil}, []}

  def update({:session_changed, session_id}, state) do
    entry = %{kind: :system, content: "Started #{short_session(session_id)}", id: unique_id()}

    {%{
       state
       | session_id: session_id,
         entries: [entry],
         scroll_from_bottom: 0,
         status: :idle,
         panel: nil
     }, []}
  end

  def update(_message, state), do: {state, []}

  @impl true
  def view(state) do
    width = state.width
    transcript_height = max(2, state.height - composer_height(state) - 4)

    lines =
      header_lines(state) ++
        body_lines(state, transcript_height) ++
        composer_lines(state) ++
        [footer_line(state)]

    stack(:vertical, Enum.map(lines, &text(pad_line(&1.text, width), &1.style)))
  end

  def command_count, do: length(@commands)

  defp submit_input(state) do
    prompt = String.trim(state.input)

    cond do
      prompt == "" ->
        {state, []}

      String.starts_with?(prompt, "/") ->
        execute_slash(prompt, %{state | input: "", cursor: 0})

      state.status in [:running, :cancelling] ->
        {%{state | notice: {:warning, "Cancel the current turn before submitting another"}}, []}

      not is_pid(state.controller) ->
        {%{state | notice: {:error, "TUI controller is not ready"}}, []}

      true ->
        Controller.submit(state.controller, prompt)
        entry = %{kind: :user, content: prompt, id: unique_id()}

        {%{
           state
           | input: "",
             cursor: 0,
             entries: state.entries ++ [entry],
             status: :running,
             notice: nil,
             panel: nil,
             scroll_from_bottom: 0
         }, []}
    end
  end

  defp execute_slash("/exit", state), do: {state, [:quit]}
  defp execute_slash("/quit", state), do: {state, [:quit]}
  defp execute_slash("/help", state), do: {%{state | palette?: true}, []}
  defp execute_slash("/", state), do: {%{state | palette?: true}, []}
  defp execute_slash("/clear", state), do: execute_command(:clear, state)
  defp execute_slash("/model", state), do: execute_command(:status, state)

  defp execute_slash("/" <> command, state) do
    case Enum.find(@commands, &(&1.id |> to_string() == command)) do
      nil -> {%{state | notice: {:warning, "Unknown command /#{command}"}}, []}
      found -> execute_command(found.id, state)
    end
  end

  defp execute_command(:exit, state), do: {state, [:quit]}
  defp execute_command(:clear, state), do: {%{state | entries: [], scroll_from_bottom: 0}, []}
  defp execute_command(:toggle_tools, state), do: update(:toggle_tools, state)

  defp execute_command(command, %{controller: controller} = state) when is_pid(controller) do
    Controller.command(controller, command)
    {%{state | panel: nil, notice: {:muted, "Loading #{command}…"}}, []}
  end

  defp execute_command(_command, state),
    do: {%{state | notice: {:error, "TUI controller is not ready"}}, []}

  defp decide_approval(%{approval: approval, controller: controller} = state, decision)
       when is_pid(controller) do
    Controller.decide(controller, approval.approval_id, decision)
    {%{state | approval: nil}, []}
  end

  defp decide_approval(state, _decision), do: {%{state | approval: nil}, []}

  defp insert_text(state, content) do
    graphemes = String.graphemes(state.input)
    {before, after_cursor} = Enum.split(graphemes, state.cursor)
    inserted = String.graphemes(content)

    {%{
       state
       | input: Enum.join(before ++ inserted ++ after_cursor),
         cursor: state.cursor + length(inserted)
     }, []}
  end

  defp apply_stream_event(state, %{type: :text_delta, response_id: response_id, delta: delta}) do
    case Enum.find_index(
           state.entries,
           &(&1.kind == :assistant and &1[:response_id] == response_id)
         ) do
      nil ->
        entry = %{
          kind: :assistant,
          content: delta,
          response_id: response_id,
          streaming?: true,
          id: unique_id()
        }

        %{state | entries: state.entries ++ [entry], scroll_from_bottom: 0}

      index ->
        entries =
          List.update_at(state.entries, index, fn entry ->
            %{entry | content: entry.content <> delta, streaming?: true}
          end)

        %{state | entries: entries, scroll_from_bottom: 0}
    end
  end

  defp apply_stream_event(state, %{type: :response_finished, response_id: response_id}) do
    update_entry(state, &(&1[:response_id] == response_id), &Map.put(&1, :streaming?, false))
  end

  defp apply_stream_event(state, %{
         type: :durable_event,
         event: %{"type" => "assistant_message", "data" => data}
       }) do
    content = data["content"]

    cond do
      not is_binary(content) or content == "" ->
        state

      Enum.any?(Enum.take(state.entries, -2), &(&1.kind == :assistant and &1.content == content)) ->
        state

      true ->
        entry = %{kind: :assistant, content: content, streaming?: false, id: unique_id()}
        %{state | entries: state.entries ++ [entry], scroll_from_bottom: 0}
    end
  end

  defp apply_stream_event(state, %{
         type: :durable_event,
         event: %{"type" => "tool_called", "data" => data}
       }) do
    entry = %{
      kind: :tool,
      id: data["tool_call_id"] || unique_id(),
      name: data["name"],
      arguments: data["arguments"] || %{},
      status: :running,
      content: nil,
      error?: false
    }

    %{state | entries: state.entries ++ [entry], scroll_from_bottom: 0}
  end

  defp apply_stream_event(state, %{
         type: :durable_event,
         event: %{"type" => "tool_result", "data" => data}
       }) do
    update_entry(
      state,
      &(&1.kind == :tool and &1.id == data["tool_call_id"]),
      &Map.merge(&1, %{
        status: if(data["is_error"], do: :error, else: :done),
        content: data["content"],
        error?: data["is_error"] || false
      })
    )
  end

  defp apply_stream_event(state, _event), do: state

  defp update_entry(state, predicate, updater) do
    case Enum.find_index(state.entries, predicate) do
      nil -> state
      index -> %{state | entries: List.update_at(state.entries, index, updater)}
    end
  end

  defp header_lines(state) do
    workspace = Path.basename(state.config["workspace_root"])
    model = state.config["model"] || "built-in"
    left = "  BEAM AGENT"

    right =
      "#{status_mark(state.status)}  #{status_label(state.status)}   #{state.config["profile"]}/#{model}  "

    [
      line(join_edges(left, right, state.width), style(:header)),
      line(
        "  #{workspace}  /  #{short_session(state.session_id)}",
        style(:subheader)
      ),
      line("  " <> String.duplicate("─", max(0, state.width - 4)), style(:divider))
    ]
  end

  defp body_lines(%{approval: approval} = state, height) when not is_nil(approval),
    do:
      modal_lines("Approval required", approval_content(approval), state.width, height, :warning)

  defp body_lines(%{palette?: true} = state, height),
    do: palette_lines(state, height)

  defp body_lines(%{panel: {title, lines}} = state, height),
    do: modal_lines(title, lines, state.width, height, :accent)

  defp body_lines(state, height) do
    lines = transcript_lines(state)
    max_offset = max(0, length(lines) - height)
    offset = min(state.scroll_from_bottom, max_offset)
    start = max(0, length(lines) - height - offset)
    visible = Enum.slice(lines, start, height)
    visible ++ List.duplicate(line("", style(:body)), max(0, height - length(visible)))
  end

  defp transcript_lines(state) do
    content_width = min(112, max(20, state.width - 8))

    state.entries
    |> Enum.with_index()
    |> Enum.reduce({[], nil}, fn {entry, index}, {lines, previous_kind} ->
      next_kind = state.entries |> Enum.at(index + 1, %{}) |> Map.get(:kind)

      rendered =
        entry_lines(entry, content_width, state.tools_expanded?, previous_kind, next_kind)

      {lines ++ rendered, entry.kind}
    end)
    |> elem(0)
    |> maybe_append_notice(state.notice, content_width)
  end

  defp entry_lines(
         %{kind: :user, content: content},
         width,
         _expanded?,
         _previous_kind,
         _next_kind
       ) do
    [line("", style(:body)), line("  YOU", style(:user_label))] ++
      styled_wrapped(content, width, "  │ ", :user, :words)
  end

  defp entry_lines(
         %{kind: :assistant, content: content} = entry,
         width,
         _expanded?,
         _previous_kind,
         _next_kind
       ) do
    cursor = if entry[:streaming?], do: " _", else: ""

    [line("", style(:body)), line("  AGENT", style(:assistant_label))] ++
      styled_markdown(content <> cursor, width, "  │ ", :assistant)
  end

  defp entry_lines(%{kind: :tool} = entry, width, expanded?, previous_kind, next_kind) do
    marker =
      case entry.status do
        :running -> "·"
        :done -> "✓"
        :error -> "×"
      end

    tone = if entry.status == :error, do: :error, else: :tool
    label = if previous_kind == :tool, do: [], else: [line("  TOOLS", style(:tool_label))]
    subject = compact_arguments(entry.arguments, width - String.length(entry.name) - 13)
    branch = if next_kind == :tool, do: "├─", else: "└─"

    summary =
      "  #{branch} #{marker}  #{entry.name}" <> if(subject == "", do: "", else: "  #{subject}")

    base = label ++ [line(summary, style(tone))]

    if expanded? and is_binary(entry.content) do
      base ++
        styled_wrapped(
          entry.content,
          width - 2,
          "  │    ",
          if(entry.error?, do: :error, else: :muted),
          :hard
        )
    else
      base
    end
  end

  defp entry_lines(
         %{kind: :error, content: content},
         width,
         _expanded?,
         _previous_kind,
         _next_kind
       ),
       do: [line("", style(:body))] ++ styled_wrapped(content, width, "  ! ", :error, :words)

  defp entry_lines(
         %{kind: :system, content: content},
         width,
         _expanded?,
         _previous_kind,
         _next_kind
       ),
       do: styled_wrapped(content, width, "  · ", :muted, :words)

  defp entry_lines(_entry, _width, _expanded?, _previous_kind, _next_kind), do: []

  defp maybe_append_notice(lines, nil, _width), do: lines

  defp maybe_append_notice(lines, {tone, message}, width),
    do: lines ++ styled_wrapped(message, width, "  · ", tone, :words)

  defp composer_lines(state) do
    width = state.width
    inner_width = max(10, width - 6)
    border_tone = if state.status in [:running, :cancelling], do: :warning, else: :accent
    label = if state.status == :idle, do: " Ask BeamAgent ", else: " Queue after this turn "

    top =
      "  ┌─#{label}" <>
        String.duplicate("─", max(0, width - String.length(label) - 6)) <> "┐"

    bottom = "  └" <> String.duplicate("─", max(0, width - 4)) <> "┘"

    visible_input_lines(state, inner_width)
    |> Enum.map(&line("  │ " <> pad_line(&1, inner_width) <> " │", style(:input)))
    |> then(fn input_lines ->
      [line(top, style(border_tone))] ++ input_lines ++ [line(bottom, style(border_tone))]
    end)
  end

  defp footer_line(state) do
    left = "  ^P commands   ^O newline   ^T tool details"

    right =
      case state.status do
        :idle -> "^C exit  "
        :running -> "^C cancel  "
        :cancelling -> "cancelling…  "
      end

    line(join_edges(left, right, state.width), style(:footer))
  end

  defp palette_lines(state, height) do
    content_width = modal_box_width(state.width) - 4

    items =
      @commands
      |> Enum.with_index()
      |> Enum.map(fn {command, index} ->
        selected? = index == state.palette_index
        prefix = if selected?, do: "› ", else: "  "
        text = join_edges(prefix <> command.label, command.hint, content_width)
        line(text, style(if(selected?, do: :selected, else: :body)))
      end)

    modal_with_rows("Command palette", items, state.width, height, :accent)
  end

  defp modal_lines(title, content, width, height, tone) do
    content_width = modal_box_width(width) - 4
    rows = Enum.map(content, &line(truncate(&1, content_width), style(:body)))
    modal_with_rows(title, rows, width, height, tone)
  end

  defp modal_with_rows(title, rows, width, height, tone) do
    box_width = modal_box_width(width)

    top =
      "  ┌─ #{title} " <>
        String.duplicate("─", max(0, box_width - String.length(title) - 5)) <> "┐"

    framed_rows =
      Enum.map(rows, fn row ->
        line("  │ " <> pad_line(row.text, box_width - 4) <> " │", row.style)
      end)

    bottom = "  └" <> String.duplicate("─", max(0, box_width - 2)) <> "┘"
    padding = max(0, div(height - length(rows) - 2, 2))
    blank_rows = List.duplicate(line("", style(:body)), padding)

    (blank_rows ++ [line(top, style(tone))] ++ framed_rows ++ [line(bottom, style(tone))])
    |> Enum.take(height)
    |> pad_rows(height)
  end

  defp modal_box_width(width), do: min(max(44, div(width * 3, 4)), width - 4)

  defp approval_content(approval) do
    choice = approval.choice
    deny = if choice == :deny, do: "[ Deny ]", else: "  Deny  "
    allow = if choice == :allow_once, do: "[ Allow once ]", else: "  Allow once  "

    [
      "Tool      #{approval.tool}",
      "Access    #{approval.access}",
      "Arguments #{JSON.encode!(approval.arguments)}",
      "",
      "#{deny}     #{allow}",
      "←/→ choose · enter confirm · esc deny"
    ]
  end

  defp visible_input_lines(state, width) do
    graphemes = String.graphemes(state.input)
    {before, after_cursor} = Enum.split(graphemes, state.cursor)
    with_cursor = Enum.join(before) <> "▌" <> Enum.join(after_cursor)
    content = if state.input == "", do: "Type a message… _", else: with_cursor

    lines = wrap_text(content, width)
    Enum.take(lines, -min(4, length(lines)))
  end

  defp composer_height(state) do
    inner_width = max(10, state.width - 6)
    content = if state.input == "", do: "Type a message…", else: state.input <> "_"
    min(4, max(1, length(wrap_text(content, inner_width)))) + 2
  end

  defp styled_wrapped(content, width, prefix, tone, wrapping) do
    content
    |> wrap_text(max(1, width - String.length(prefix)), wrapping)
    |> Enum.map(&line(prefix <> &1, style(tone)))
  end

  defp styled_markdown(content, width, prefix, default_tone) do
    available = max(1, width - String.length(prefix))

    content
    |> String.split("\n", trim: false)
    |> Enum.reduce({[], false}, fn source, {lines, code?} ->
      markdown_line(source, available, default_tone, code?, lines)
    end)
    |> elem(0)
    |> Enum.map(fn {text, tone} -> line(prefix <> text, style(tone)) end)
  end

  defp wrap_text(text, width) do
    wrap_text(text, width, :hard)
  end

  defp wrap_text(text, width, wrapping) do
    text
    |> String.split("\n", trim: false)
    |> Enum.flat_map(&wrap_line(&1, width, wrapping))
  end

  defp wrap_line("", _width, _wrapping), do: [""]

  defp wrap_line(text, width, :hard) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp wrap_line(text, width, :words) do
    words =
      text
      |> String.split(~r/\s+/, trim: true)
      |> Enum.flat_map(&hard_wrap(&1, width))

    {lines, current} =
      Enum.reduce(words, {[], ""}, fn word, {lines, current} ->
        candidate = if current == "", do: word, else: current <> " " <> word

        if display_width(candidate) <= width do
          {lines, candidate}
        else
          {[current | lines], word}
        end
      end)

    case {lines, current} do
      {[], ""} -> [""]
      {lines, ""} -> Enum.reverse(lines)
      {lines, current} -> Enum.reverse([current | lines])
    end
  end

  defp markdown_line(source, width, default_tone, code?, lines) do
    trimmed = String.trim_leading(source)

    cond do
      String.starts_with?(trimmed, "```") ->
        {lines, not code?}

      code? ->
        rows = Enum.map(hard_wrap(source, width), &{&1, :code})
        {lines ++ rows, code?}

      Regex.match?(~r/^[#]{1,6}\s+/, trimmed) ->
        heading = Regex.replace(~r/^[#]{1,6}\s+/, trimmed, "") |> clean_inline_markdown()
        rows = Enum.map(wrap_line(heading, width, :words), &{&1, :heading})
        {lines ++ rows, code?}

      String.starts_with?(trimmed, "- ") ->
        item = "• " <> (String.trim_leading(trimmed, "- ") |> clean_inline_markdown())
        rows = Enum.map(wrap_line(item, width, :words), &{&1, default_tone})
        {lines ++ rows, code?}

      String.starts_with?(trimmed, "> ") ->
        quote = "│ " <> (String.trim_leading(trimmed, "> ") |> clean_inline_markdown())
        rows = Enum.map(wrap_line(quote, width, :words), &{&1, :muted})
        {lines ++ rows, code?}

      true ->
        cleaned = clean_inline_markdown(source)
        rows = Enum.map(wrap_line(cleaned, width, :words), &{&1, default_tone})
        {lines ++ rows, code?}
    end
  end

  defp clean_inline_markdown(source) do
    source
    |> String.replace("**", "")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, "\\1 (\\2)")
  end

  defp hard_wrap(text, width) do
    {lines, current, _current_width} =
      Enum.reduce(String.graphemes(text), {[], "", 0}, fn grapheme,
                                                          {lines, current, current_width} ->
        grapheme_width = max(1, display_width(grapheme))

        if current != "" and current_width + grapheme_width > width do
          {[current | lines], grapheme, grapheme_width}
        else
          {lines, current <> grapheme, current_width + grapheme_width}
        end
      end)

    case {lines, current} do
      {[], ""} -> [""]
      {lines, ""} -> Enum.reverse(lines)
      {lines, current} -> Enum.reverse([current | lines])
    end
  end

  defp history(session_id) do
    case BeamAgent.events(session_id) do
      {:ok, events} -> Enum.reduce(events, [], &history_event/2)
      {:error, _reason} -> []
    end
  end

  defp history_event(%{"type" => "user_message", "data" => data}, entries),
    do: entries ++ [%{kind: :user, content: data["content"], id: unique_id()}]

  defp history_event(%{"type" => "assistant_message", "data" => data}, entries) do
    if is_binary(data["content"]) and data["content"] != "" do
      entries ++ [%{kind: :assistant, content: data["content"], id: unique_id()}]
    else
      entries
    end
  end

  defp history_event(%{"type" => "tool_called", "data" => data}, entries) do
    entries ++
      [
        %{
          kind: :tool,
          id: data["tool_call_id"],
          name: data["name"],
          arguments: data["arguments"] || %{},
          status: :running,
          content: nil,
          error?: false
        }
      ]
  end

  defp history_event(%{"type" => "tool_result", "data" => data}, entries) do
    case Enum.find_index(entries, &(&1.kind == :tool and &1.id == data["tool_call_id"])) do
      nil ->
        entries

      index ->
        List.update_at(entries, index, fn entry ->
          Map.merge(entry, %{
            status: if(data["is_error"], do: :error, else: :done),
            content: data["content"],
            error?: data["is_error"] || false
          })
        end)
    end
  end

  defp history_event(_event, entries), do: entries

  defp dimensions do
    width =
      case :io.columns(:standard_io) do
        {:ok, value} -> value
        _ -> 80
      end

    height =
      case :io.rows(:standard_io) do
        {:ok, value} -> value
        _ -> 24
      end

    {max(width, 40), max(height, 14)}
  end

  defp status_label(:idle), do: "ready"
  defp status_label(:running), do: "working"
  defp status_label(:cancelling), do: "cancelling"

  defp status_mark(:idle), do: "●"
  defp status_mark(:running), do: "◉"
  defp status_mark(:cancelling), do: "○"

  defp style(:header), do: Style.new(fg: :bright_cyan, attrs: [:bold])
  defp style(:subheader), do: Style.new(fg: :bright_black)
  defp style(:divider), do: Style.new(fg: :bright_black)
  defp style(:body), do: Style.new(fg: :white)
  defp style(:user_label), do: Style.new(fg: :bright_cyan, attrs: [:bold])
  defp style(:user), do: Style.new(fg: :bright_white)
  defp style(:assistant_label), do: Style.new(fg: :bright_green, attrs: [:bold])
  defp style(:assistant), do: Style.new(fg: :white)
  defp style(:tool_label), do: Style.new(fg: :bright_black, attrs: [:bold])
  defp style(:tool), do: Style.new(fg: :yellow)
  defp style(:error), do: Style.new(fg: :bright_red)
  defp style(:warning), do: Style.new(fg: :bright_yellow)
  defp style(:success), do: Style.new(fg: :bright_green)
  defp style(:muted), do: Style.new(fg: :bright_black)
  defp style(:accent), do: Style.new(fg: :bright_cyan)
  defp style(:selected), do: Style.new(fg: :bright_cyan, attrs: [:bold])
  defp style(:input), do: Style.new(fg: :bright_white)
  defp style(:footer), do: Style.new(fg: :bright_black)
  defp style(:code), do: Style.new(fg: :bright_cyan)
  defp style(:heading), do: Style.new(fg: :bright_white, attrs: [:bold])

  defp line(text, style), do: %{text: text, style: style}

  defp pad_rows(lines, height),
    do: lines ++ List.duplicate(line("", style(:body)), max(0, height - length(lines)))

  defp pad_line(text, width) do
    text = truncate(text, width)
    text <> String.duplicate(" ", max(0, width - display_width(text)))
  end

  defp truncate(text, width) do
    graphemes = String.graphemes(to_string(text))

    if display_width(text) <= width do
      Enum.join(graphemes)
    else
      {visible, _used} =
        Enum.reduce_while(graphemes, {[], 0}, fn grapheme, {visible, used} ->
          next = used + max(1, display_width(grapheme))

          if next > max(0, width - 1) do
            {:halt, {visible, used}}
          else
            {:cont, {[grapheme | visible], next}}
          end
        end)

      visible |> Enum.reverse() |> Enum.join() |> Kernel.<>("…")
    end
  end

  defp join_edges(left, right, width) do
    gap = max(1, width - display_width(left) - display_width(right))
    truncate(left <> String.duplicate(" ", gap) <> right, width)
  end

  defp compact_arguments(arguments, width) do
    rendered =
      case Enum.sort_by(arguments, fn {key, _value} -> to_string(key) end) do
        [{key, value}] when key in ["path", :path, "command", :command, "query", :query] ->
          argument_value(value)

        pairs ->
          Enum.map_join(pairs, "  ", fn {key, value} ->
            "#{key}: #{argument_value(value)}"
          end)
      end

    truncate(rendered, max(1, width))
  end

  defp argument_value(value) when is_binary(value), do: value
  defp argument_value(value), do: inspect(value, limit: 4)

  defp display_width(text), do: DisplayWidth.width(to_string(text))

  defp format_error(reason), do: inspect(reason, pretty: true, limit: 8)

  defp short_session("session-" <> suffix), do: "session " <> String.slice(suffix, 0, 8)
  defp short_session(session_id), do: session_id
  defp unique_id, do: System.unique_integer([:positive, :monotonic])
end
