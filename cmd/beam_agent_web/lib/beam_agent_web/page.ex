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

    layout("<main class=welcome>#{body}</main>")
  end

  def desk(result, csrf, notice) do
    panel =
      case result do
        {:ok, snapshot} -> panels(snapshot, csrf)
        {:error, _} -> "<p>Waiting for the runtime. We’ll reconnect automatically.</p>"
      end

    layout("""
    <aside><a class="wordmark" href="/">BEAM<span> / DESK</span></a>
      <p class="eyebrow">Workspace control</p><a class="nav active" href="#mission">01 &nbsp; Mission</a>
      <a class="nav" href="#agents">02 &nbsp; Agents</a><a class="nav" href="#activity">03 &nbsp; Activity</a>
      <div class="aside-bottom"><p>Independent agents.<br>One shared direction.</p>
      <form method="post" action="/logout">#{hidden(csrf)}<button class="quiet">Disconnect this browser</button></form></div>
    </aside>
    <main class="workspace"><header><div><p class="eyebrow">The long view</p><h1>Make good things.</h1></div>
      <span class="connection" id="connection" role="status">Connecting</span></header>
      <p id="notice" role="status">#{escape(notice)}</p>
      <div id="panels">#{panel}</div>
      <section class="composer" aria-label="New prompt"><form method="post" action="/commands/submit">
        #{hidden(csrf)}<label for="prompt">What should we work on?</label>
        <textarea id="prompt" name="prompt" rows="3" required maxlength="100000" placeholder="A feature, a question, a bigger ambition…"></textarea>
        <div class="composer-footer"><span>Ctrl / ⌘ + Enter to send · draft kept in this tab</span><button>Set things in motion ↗</button></div>
      </form></section>
      <footer>Runtime-owned work. Public activity view. No synthetic progress.</footer>
    </main>
    """)
  end

  def panels(snapshot, csrf) do
    status = snapshot["status"] || %{}
    tree = snapshot["tree"] || %{}
    agents = flatten(tree["root"])
    approvals = snapshot["pending_approvals"] || []
    events = snapshot["recent_events"] || []

    """
    <section id="mission" class="mission"><div><p class="eyebrow">Mission / #{escape(status["agent_status"])}</p>
      <h2>#{escape(status["current_task"] || if(status["agent_status"] == "running", do: "Work is underway.", else: "Room for your next idea."))}</h2>
      <p class="muted">Session #{escape(snapshot["session_id"])}</p></div>
      <form method="post" action="/commands/cancel">#{hidden(csrf)}<button class="outline">Stop current work</button></form>
    </section>
    <div class="metrics"><article><span>Agents in view</span><strong>#{length(agents)}</strong></article>
      <article><span>Awaiting your decision</span><strong>#{length(approvals)}</strong></article>
      <article><span>Observed events</span><strong>#{escape(snapshot["cursor"] || 0)}</strong></article></div>
    #{approval_cards(approvals, csrf)}
    <div class="columns"><section id="agents"><div class="section-heading"><h2>The team</h2><span>Explore each actor ↓</span></div>
      #{Enum.map_join(agents, &agent_card/1)}</section>
      <section id="activity"><div class="section-heading"><h2>Work, unfolding</h2><span>Latest 24 events</span></div>
      <ol class="activity">#{events |> Enum.take(-24) |> Enum.reverse() |> Enum.map_join(&event_card/1)}</ol></section></div>
    """
  end

  defp approval_cards(approvals, csrf) do
    Enum.map_join(approvals, fn approval ->
      """
      <section class="approval"><h2>Your decision is needed</h2><pre>#{escape(inspect(approval["request"] || approval))}</pre>
      <form method="post" action="/commands/approval">#{hidden(csrf)}
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

  defp layout(body) do
    """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>BeamAgent Desk</title><link rel="stylesheet" href="/assets/desk.css"><script defer src="/assets/desk.js"></script></head>
    <body>#{body}</body></html>
    """
  end
end
