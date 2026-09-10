defmodule BeamAgentWeb.Page do
  @moduledoc false

  def login(csrf, configured, error \\ nil) do
    body =
      if configured do
        """
        <p class="eyebrow">Your workspace, in motion</p><h1>A desk for<br>ambitious work.</h1>
        <p class="lede">Connect to your running harness. Agents keep working when you close this window.</p>
        <form method="post" action="/login">#{hidden(csrf)}
          <label for="token">Runtime access token</label>
          <input id="token" name="token" type="password" required autocomplete="off">
          <button>Open workspace <span aria-hidden="true">↗</span></button>
        </form><p role="alert">#{escape(error)}</p>
        """
      else
        """
        <p class="eyebrow">One small connection</p><h1>Your desk<br>is ready.</h1>
        <p class="lede">Set BEAM_AGENT_RUNTIME_URL to your loopback HTTP API address and
        BEAM_AGENT_RUNTIME_TOKEN to its access token, then restart this frontend.</p>
        <p>The URL must use http://127.0.0.1 and contain no token or query string.</p>
        """
      end

    layout(
      "<main class=welcome><a class=wordmark href=/><span class=brand-mark>λ</span> BEAM<span> / DESK</span></a>#{night_scene()}<div class=welcome-copy>#{body}</div></main>"
    )
  end

  def overview(directory, csrf, notice) do
    layout("""
    <main class="control-center"><header class="masthead"><a class="wordmark" href="/"><span class="brand-mark">λ</span> BEAM<span> / DESK</span></a>
    <span class="edition">LOCAL FIRST / AFTER HOURS</span></header>
    <section class="overview-hero"><div class="hero-copy"><p class="eyebrow">~/ personal control center</p><h1>Your work,<br> together.</h1>
    <p class="lede">A quiet place to build ambitious things.<br>All your runtimes. One open channel.</p>
    </div>#{night_scene()}</section>
    <header class="directory-intro"><p class="eyebrow">01 / Runtime directory</p>
    <span class="connection" id="connection" role="status">Connecting</span></header>
    <p class="muted">Live sessions on this computer. Opening a session attaches to its existing runtime; it does not restart it.</p>
    <p role="status">#{escape(notice)}</p><div id="directory">#{directory(directory)}</div>
    <div class="directory-actions"><form method="post" action="/sessions">#{hidden(csrf)}<button>Start a new session</button>
    <p class="muted">Uses the workspace and provider profile chosen when launching Desk. No model call until you submit a prompt.</p></form>
    <form method="post" action="/logout">#{hidden(csrf)}<button class="quiet">Disconnect this browser</button></form></div>
    <footer>BEAM / DESK <span>Local connections. Runtime-owned work.</span></footer></main>
    """)
  end

  def directory(directory) do
    sessions = directory["sessions"] || []

    """
    <div class="section-heading"><h2>Live sessions <span class="session-count">#{length(sessions)}</span></h2><span>Verified local runtime connections · up to 200</span></div>
    #{if directory["unavailable"], do: "<p>Discovery unavailable. Session count is unknown.</p>", else: ""}
    #{if sessions == [], do: "<p class=muted>No discoverable live sessions. Start a TUI with the rebuilt CLI. Older running binaries need one restart to publish their connection.</p>", else: ""}
    <div class="session-grid">#{Enum.map_join(sessions, fn session -> """
        <article class="session-card"><div class="card-chrome" aria-hidden="true"><span>● ● ●</span><span>runtime.ex</span></div><p class="eyebrow">Live runtime · PID #{escape(session["owner_pid"])}</p>
        <h2>#{escape(Path.basename(session["workspace"] || "Workspace"))}</h2><p class="muted">#{escape(session["workspace"])}</p>
        <p class="session-id">#{escape(session["session_id"])}</p><a class="session-open" href="/sessions/#{escape(session["session_id"])}">Open session ↗</a>
        <div class="attach-command"><p class="muted">Attach a terminal</p><code>./beam_agent attach #{escape(session["session_id"])}</code></div></article>
      """ end)}</div>
    """
  end

  def desk(result, csrf, notice, session_id \\ nil) do
    prefix = session_prefix(session_id)

    panel =
      case result do
        {:ok, snapshot} ->
          panels(snapshot, csrf, session_id)

        {:error, _} ->
          "<p>Session runtime unavailable. No session was restarted. Return to the overview to choose a live session.</p>"
      end

    layout("""
    <aside><a class="wordmark" href="/"><span class="brand-mark">λ</span> BEAM<span> / DESK</span></a>
      <p class="eyebrow">Workspace control</p><a class="nav active" href="#mission">01 &nbsp; Mission</a>
      <a class="nav" href="#conversation">02 &nbsp; Output</a>
      <a class="nav" href="#agents">03 &nbsp; Agents</a><a class="nav" href="#activity">04 &nbsp; Activity</a>
      <div class="aside-bottom">#{night_scene()}<p>Independent agents.<br>One shared direction.</p>
      <form method="post" action="/logout">#{hidden(csrf)}<button class="quiet">Disconnect this browser</button></form></div>
    </aside>
    <main class="workspace"><header><div><p class="eyebrow">~/ workspace / mission control</p><h1>Make good things.</h1></div>
      <span class="connection" id="connection" role="status">Connecting</span></header>
      <p id="notice" role="status">#{escape(notice)}</p>
      <p><a href="/">← All live sessions</a></p>
      <div id="panels" data-session-id="#{escape(session_id || "legacy")}" data-panels-url="#{prefix}/panels">#{panel}</div>
      <section class="composer" aria-label="New prompt"><form method="post" action="#{prefix}/commands/submit">
        #{hidden(csrf)}<label for="prompt">What should we work on?</label>
        <textarea id="prompt" name="prompt" rows="3" required maxlength="100000" placeholder="A feature, a question, a bigger ambition…"></textarea>
        <div class="composer-footer"><span>Ctrl / ⌘ + Enter to send · draft kept in this tab</span><button>Set things in motion ↗</button></div>
      </form></section>
      <footer>Private conversation · redacted activity · runtime-owned work</footer>
    </main>
    """)
  end

  def panels(snapshot, csrf, session_id \\ nil) do
    prefix = session_prefix(session_id)
    status = snapshot["status"] || %{}
    tree = snapshot["tree"] || %{}
    agents = flatten(tree["root"])
    approvals = snapshot["pending_approvals"] || []
    events = snapshot["recent_events"] || []

    """
    <section id="mission" class="mission"><div><p class="eyebrow">Mission / #{escape(status["agent_status"])}</p>
      <h2>#{escape(status["current_task"] || if(status["agent_status"] == "running", do: "Work is underway.", else: "Room for your next idea."))}</h2>
      <p class="muted">Session #{escape(snapshot["session_id"])}</p></div>
      <form method="post" action="#{prefix}/commands/cancel">#{hidden(csrf)}<button class="outline">Stop current work</button></form>
    </section>
    <p class="session-hint">Attach a terminal to this live session: <code>./beam_agent attach #{escape(snapshot["session_id"])}</code>.
      Attaching does not create another runtime. <a href="/">View all sessions</a>.</p>
    #{conversation(snapshot)}
    <div class="metrics"><article><span>Agents in this session</span><strong>#{length(agents)}</strong></article>
      <article><span>Awaiting your decision</span><strong>#{length(approvals)}</strong></article>
      <article><span>Observed events</span><strong>#{escape(snapshot["cursor"] || 0)}</strong></article></div>
    #{approval_cards(approvals, csrf, prefix)}
    <div class="columns"><section id="agents"><div class="section-heading"><h2>The team</h2><span>Explore each actor ↓</span></div>
      #{Enum.map_join(agents, &agent_card/1)}</section>
      <section id="activity"><div class="section-heading"><h2>Work, unfolding</h2><span>Latest 24 events</span></div>
      <ol class="activity">#{events |> Enum.take(-24) |> Enum.reverse() |> Enum.map_join(&event_card/1)}</ol></section></div>
    """
  end

  defp conversation(%{"conversation" => conversation}) do
    messages = conversation["messages"] || []
    status = conversation["status"] || "idle"

    label =
      case status do
        "running" -> "Working · waiting for the next model response"
        "waiting_for_model" -> "Still waiting for the model · no recent progress"
        "verifying" -> "Checking the result"
        "reviewing" -> "Reviewing the result"
        "completed" -> "Work completed"
        "idle" -> "Ready for your first prompt"
        _ -> "Work stopped · inspect activity for details"
      end

    """
    <section id="conversation" class="conversation" aria-label="Conversation and output">
      <div class="section-heading"><h2>Conversation &amp; output</h2><span>Latest 24 messages · private to this session</span></div>
      <div class="work-state" role="status"><span class="state-dot #{if status in ["running", "waiting_for_model", "verifying", "reviewing"], do: "working", else: ""}"></span>
        <strong>#{escape(label)}</strong><span>#{escape(conversation["provider"])} / #{escape(conversation["model"])}</span></div>
      #{if messages == [], do: "<p class=muted>Your prompt and the assistant’s output will appear here. Activity events remain below.</p>", else: Enum.map_join(messages, &message_card/1)}
      <p class="muted">Verification: #{escape(conversation["verification"] || "not reported")} · Review: #{escape(conversation["review"] || "not reported")}</p>
    </section>
    """
  end

  defp conversation(_) do
    """
    <section id="conversation" class="conversation"><h2>Conversation &amp; output</h2>
    <p role="status">Output is unavailable from this runtime. Rebuild and restart with <code>./beam_agent desk</code>.
    Activity connectivity does not confirm conversation access.</p></section>
    """
  end

  defp message_card(message) do
    role = if message["role"] == "user", do: "You", else: "Assistant output"

    """
    <article class="message #{if role == "You", do: "user", else: "assistant"}" data-message="#{escape(message["id"])}">
      <div class="message-heading"><strong>#{role}</strong><time>#{escape(message["at"])}</time></div>
      <pre class="message-content">#{escape(message["content"])}</pre>
      #{if message["truncated"], do: "<p class=muted>Long message shortened for this view. Full content remains in session history.</p>", else: ""}
    </article>
    """
  end

  defp session_prefix(nil), do: ""
  defp session_prefix(id), do: "/sessions/" <> URI.encode(id, &URI.char_unreserved?/1)

  defp approval_cards(approvals, csrf, prefix) do
    Enum.map_join(approvals, fn approval ->
      """
      <section class="approval"><h2>Your decision is needed</h2><pre>#{escape(inspect(approval["request"] || approval))}</pre>
      <form method="post" action="#{prefix}/commands/approval">#{hidden(csrf)}
        <input type="hidden" name="approval_id" value="#{escape(approval["approval_id"])}">
        <button name="decision" value="allow_once">Allow once</button><button class="outline" name="decision" value="deny">Deny</button>
      </form></section>
      """
    end)
  end

  defp agent_card(agent) do
    """
    <details class="agent" data-agent="#{escape(agent["session_id"])}"><summary>
      <span class="agent-mark">↗</span><span><b>#{escape(agent["role"] || "Workspace agent")}</b>
      <small>#{escape(get_in(agent, ["last_routed", "model"]) || agent["session_id"])}</small></span>
      <span class="badge">#{escape(agent["state"] || "observed")}</span></summary>
      <pre>#{escape(Jason.encode!(Map.drop(agent, ["children"]), pretty: true))}</pre></details>
    """
  end

  defp event_card(event) do
    payload = event["payload"] || %{}
    type = payload["type"] || event["type"] || "event"

    """
    <li><span class="event-seq">#{escape(event["goal_seq"])}</span><details data-event="#{escape(event["goal_seq"])}"><summary>#{escape(String.replace(type, "_", " "))}</summary>
    <pre>#{escape(Jason.encode!(payload["data"] || %{}, pretty: true))}</pre></details></li>
    """
  end

  defp flatten(nil), do: []
  defp flatten(root), do: [root | Enum.flat_map(root["children"] || [], &flatten/1)]
  defp hidden(csrf), do: "<input type=hidden name=_csrf_token value=\"#{escape(csrf)}\">"
  defp escape(nil), do: ""
  defp escape(value) when is_map(value) or is_list(value), do: escape(Jason.encode!(value))

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp night_scene do
    """
    <div class="night-scene" aria-hidden="true"><img src="/assets/night-shift.svg" alt="" width="640" height="400">
      <span class="scene-caption">AFTER HOURS <span>心 / IN THE FLOW</span></span></div>
    """
  end

  defp layout(body) do
    """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>BeamAgent Desk</title><link rel="stylesheet" href="/assets/desk.css"><script defer src="/assets/desk.js"></script></head>
    <body>#{body}</body></html>
    """
  end
end
