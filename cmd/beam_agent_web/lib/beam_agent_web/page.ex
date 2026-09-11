defmodule BeamAgentWeb.Page do
  @moduledoc false

  def login(csrf, configured, error \\ nil) do
    body =
      if configured do
        """
        <p class="eyebrow">Your workspace, in motion</p><h1>A desk for<br>ambitious work.</h1>
        <p class="lede">Connect to your running harness. Agents keep working when you close this window.</p>
        <p>Open a fresh connection from your terminal: <code>./loom desk</code>.<br>
        No login credentials needed. This reconnects without restarting your agents.</p>
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
      "<main class=welcome><a class=wordmark href=/><span class=brand-mark>╬</span> LOOM<span> / DESK</span></a>#{night_scene()}<div class=welcome-copy>#{body}</div></main>"
    )
  end

  def overview(directory, csrf, notice) do
    layout("""
    <main class="control-center"><header class="masthead"><a class="wordmark" href="/"><span class="brand-mark">╬</span> LOOM<span> / DESK</span></a>
    <span class="edition">LOCAL FIRST / AFTER HOURS</span></header>
    <section class="overview-hero"><div class="hero-copy"><p class="eyebrow">~/ personal control center</p><h1>Your work,<br> together.</h1>
    <p class="lede">A quiet place to build ambitious things.<br>All your runtimes. One open channel.</p>
    </div>#{night_scene()}</section>
    <header class="directory-intro"><p class="eyebrow">01 / Runtime directory</p>
    <span class="connection" id="connection" role="status">Connecting</span></header>
    <p class="muted">Live sessions on this computer. Opening a session attaches to its existing runtime; it does not restart it.</p>
    <p role="status">#{escape(notice)}</p><div id="directory">#{directory(directory)}</div>
    <div class="directory-actions"><form method="post" action="/sessions">#{hidden(csrf)}<input type="hidden" name="request_id" value="#{start_id()}"><button>Start a new session</button>
    <p class="muted">Uses the workspace and provider profile chosen when launching Desk. No model call until you submit a prompt.</p></form>
    <a class="session-open" href="/workspaces">Choose another workspace</a>
    <form method="post" action="/logout">#{hidden(csrf)}<button class="quiet">Disconnect this browser</button></form></div>
    <footer>LOOM / DESK <span>Local connections. Runtime-owned work.</span></footer></main>
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
        <div class="attach-command"><p class="muted">Attach a terminal</p><code>./loom attach #{escape(session["session_id"])}</code></div></article>
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
    <aside><a class="wordmark" href="/"><span class="brand-mark">╬</span> LOOM<span> / DESK</span></a>
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
      <div id="panels" tabindex="0" aria-label="Session details" data-session-id="#{escape(session_id || "legacy")}" data-panels-url="#{prefix}/panels">#{panel}</div>
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
    <p class="session-hint">Attach a terminal to this live session: <code>./loom attach #{escape(snapshot["session_id"])}</code>.
      Attaching does not create another runtime. <a href="/">View all sessions</a>.</p>
    #{conversation(snapshot)}
    #{documentation_mission(snapshot, csrf, prefix)}
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

  defp documentation_mission(%{"documentation_mission" => mission}, csrf, prefix)
       when is_map(mission) do
    labels = %{
      "start" => "Start documentation observer",
      "pause" => "Pause observer",
      "resume" => "Resume observer",
      "dismiss" => "Dismiss report",
      "stop" => "Stop observer & fixes",
      "delete" => "Delete observer"
    }

    actions = mission["available_actions"] || []
    report = mission["report"]

    """
    <section id="documentation-mission" class="documentation-mission" aria-label="Documentation observer">
      <div class="section-heading"><h2>Documentation observer</h2><span>#{escape(mission["status"])}</span></div>
      <p>Read-only advice from this session’s selected model. No automatic edits. Assessments may consume provider allowance.</p>
      <p class="muted">#{escape(mission["attempts"] || 0)} / #{escape(mission["max_assessments"] || 3)} assessments · #{escape(mission["quiet_seconds"] || 60)}s quiet period · #{escape(mission["cooldown_seconds"] || 300)}s cooldown</p>
      <p class="muted">Future tracked changes in: #{escape(Enum.join(mission["paths"] || ["lib", "src", "test", "docs", "README.md"], ", "))}. Keep the runtime owner running.</p>
      <p class="muted">#{escape(mission["reason"])}</p>
      <p><a href="/workspaces?observer=1">Observe a different repository ↗</a></p>
      <div class="observer-actions">#{Enum.filter(actions, &Map.has_key?(labels, &1)) |> Enum.map_join(fn action -> "<form method=\"post\" action=\"#{prefix}/commands/documentation_mission\">#{hidden(csrf)}<input type=\"hidden\" name=\"action\" value=\"#{action}\"><button class=\"outline\">#{labels[action]}</button></form>" end)}
      #{if mission["status"] in ["disabled", "paused", "stopped"], do: "<a class=\"outline observer-configure\" href=\"#{prefix}/observer\">Choose folders</a>", else: "<span class=\"muted\">Pause to change watched folders.</span>"}</div>
      <p class="muted">Pause stops assessments only. Stop cancels this observer and its fix agents.
      #{if mission["status"] == "stopped", do: "Delete removes its configuration and report. ", else: ""}Session history and retained worktrees are always kept; the workspace harness stays running.</p>
      #{observer_report(report, prefix)}
      #{observer_followups(mission["followups"] || [], csrf, prefix)}
    </section>
    """
  end

  defp documentation_mission(_, _, _),
    do:
      "<section id=\"documentation-mission\"><h2>Documentation observer</h2><p>Mission status unavailable. No observer has been started by this view.</p></section>"

  defp observer_report(report, prefix) when is_map(report) do
    findings = report["findings"] || []

    """
    <article class="observer-report">
      <div class="section-heading"><h3>#{if findings == [], do: "Assessment", else: "#{length(findings)} findings to review"}</h3><span class="badge">#{escape(report["status"])} · not verified</span></div>
      <p class="muted">Partial evidence, not a verdict. A finding may disappear when the full source is checked.</p>
      <div class="finding-grid">#{Enum.map_join(findings, fn finding -> """
        <section class="finding-card"><h4>#{escape(finding["title"])}</h4>
          #{finding_sections(finding)}
          #{if report["status"] == "advisory", do: "<a class=\"session-open\" href=\"#{prefix}/observer/followup?#{escape(URI.encode_query(%{report_id: report["id"], finding_id: finding["id"]}))}\">Prepare a fix ↗</a>", else: "<p>Stale findings cannot launch work.</p>"}
        </section>
      """ end)}</div>
      <details data-report="#{escape(report["id"])}"><summary>Original report &amp; coverage notes</summary><pre>#{escape(report["content"])}</pre></details>
      <p class="muted">Observed by #{escape(report["worker_id"])} · Each follow-up requires your confirmation.</p>
    </article>
    """
  end

  defp observer_report(_, _),
    do: "<p class=\"muted\">No report yet. Reports appear after an assessment.</p>"

  defp finding_sections(finding) do
    sections = finding["sections"] || %{}

    if map_size(sections) == 0 do
      "<pre class=\"finding-text\">#{escape(finding["body"])}</pre>"
    else
      "<dl>" <>
        Enum.map_join(
          [
            {"evidence", "Evidence"},
            {"uncertainty", "Uncertainty"},
            {"next action", "Suggested action"}
          ],
          fn {key, label} ->
            "<div class=\"finding-#{String.replace(key, " ", "-")}\"><dt>#{label}</dt><dd>#{escape(sections[key] || "Not separately stated; inspect the original report.")}</dd></div>"
          end
        ) <> "</dl>"
    end
  end

  def observer_followup(finding, params, csrf) do
    prefix = session_prefix(params["session_id"])

    layout("""
    <main class="control-center observer-setup"><a href="#{if prefix == "", do: "/", else: prefix}">← Back to session</a>
      <p class="eyebrow">Explicit hand-off / Documentation</p><h1>From finding<br>to proposed fix.</h1>
      <section class="finding-card"><h2>#{escape(finding["title"])}</h2>#{finding_sections(finding)}</section>
      <p>A separate implementation agent will re-read the full evidence and prepare a documentation patch in an isolated Git worktree seeded with current tracked files.</p>
      <p>No automatic merge, commit or push. File tools only: shell tests and rendering are not available in this mode. An unsupported finding should result in an explanation, not an edit.</p>
      <p class="muted">Uses this session’s model and approval policy; may consume additional provider allowance beyond observer assessments. The observer pauses. Old findings are rejected if the watched files have changed. Untracked files are not copied; the retained worktree also contains your existing tracked edits.</p>
      <form method="post" action="#{prefix}/commands/documentation_mission">#{hidden(csrf)}
        <input type="hidden" name="action" value="prepare_fix"><input type="hidden" name="report_id" value="#{escape(params["report_id"])}"><input type="hidden" name="finding_id" value="#{escape(params["finding_id"])}">
        <button>Start isolated fix agent</button>
      </form>
    </main>
    """)
  end

  defp observer_followups(items, csrf, prefix) do
    Enum.map_join(items, fn item ->
      """
      <section class="followup-card"><div class="section-heading"><h4>#{escape(item["title"])}</h4><span class="badge">#{escape(item["status"])}</span></div>
        <p class="muted">Separate fix agent · Not integrated or independently verified</p>
        <p>#{escape(item["error"])}</p>
        #{if item["worker_id"], do: "<p>Worker <code>#{escape(item["worker_id"])}</code> · <a href=\"#agents\">Inspect in team</a></p>", else: ""}
        #{if item["worktree"], do: "<p>Retained worktree <code>#{escape(item["worktree"])}</code></p>", else: ""}
        #{if item["output"], do: "<details data-followup=\"#{escape(item["id"])}\"><summary>Agent output</summary><pre>#{escape(item["output"])}</pre></details>", else: ""}
        #{if item["status"] in ["preparing", "running", "accepted", "requested"], do: "<form method=\"post\" action=\"#{prefix}/commands/documentation_mission\">#{hidden(csrf)}<input type=\"hidden\" name=\"action\" value=\"cancel_fix\"><input type=\"hidden\" name=\"followup_id\" value=\"#{escape(item["id"])}\"><button class=\"quiet\">Cancel fix agent</button></form>", else: ""}
      </section>
      """
    end)
  end

  def observer(mission, listing, csrf, session_id) do
    prefix = session_prefix(session_id)
    configuring = mission["status"] in ["paused", "stopped"]
    editable = mission["status"] in ["disabled", "paused", "stopped"]
    selected = if configuring, do: Enum.join(mission["paths"] || [], "\n"), else: ""

    layout("""
    <main class="control-center observer-setup">
      <a class="wordmark" href="/"><span class="brand-mark">╬</span> LOOM<span> / DESK</span></a>
      <p><a href="#{if prefix == "", do: "/", else: prefix}">← Back to session</a></p>
      <p class="eyebrow">Background / Documentation</p><h1>Choose what<br>to watch.</h1>
      <p class="lede">Browse this session’s repository. Add folders or individual files to the observer’s scope.</p>
      <p class="observer-root">Workspace on the runtime computer: <code>#{escape(listing["workspace"])}</code></p>
      <p class="muted">Only readable Git-tracked files and their folders appear. No uploads and no model calls while browsing.
      <a href="/workspaces?observer=1">Choose a different repository on this computer ↗</a></p>
      <div class="observer-picker" data-paths-url="#{prefix}/observer/paths">
        <section class="folder-browser" aria-label="Repository browser">
          <form id="browse-path-form"><label for="browse-path">Browse path</label><div class="browse-location">
            <input id="browse-path" value="." maxlength="200" autocomplete="off"><button class="outline">Open folder</button></div></form>
          <div class="observer-actions"><button type="button" id="browse-parent" class="quiet" disabled>↑ Up</button>
            <button type="button" id="select-folder" class="outline">Add this folder</button></div>
          <p id="browse-status" role="status">#{cond do
      listing["truncated"] -> "First 200 entries shown. Type a more specific path to browse further."
      listing["entries"] == [] -> "No readable tracked files here. Untracked files are not observed."
      true -> "Choose a folder below, or add the whole workspace with “Add this folder”."
    end}</p>
          <ul id="browse-entries">#{observer_entries(listing)}</ul>
        </section>
        <section class="observer-selection" aria-label="Selected scope">
          <form method="post" action="#{prefix}/commands/documentation_mission">
            #{hidden(csrf)}<input type="hidden" name="action" value="#{if configuring, do: "configure", else: "start"}">
            <label for="observer-paths">Watched paths</label>
            <textarea id="observer-paths" name="paths" rows="7" required maxlength="4200" placeholder="Add folders from the browser, or type one relative path per line.">#{escape(selected)}</textarea>
            <noscript><p>Folder navigation needs JavaScript. You can still enter relative paths here and submit.</p></noscript>
            <p class="muted">Up to 20 paths, relative to the workspace above. Use <code>.</code> for all tracked files. Remove a line to exclude that selection.</p>
            <p>Read-only advice · #{escape(mission["attempts"] || 0)} / #{escape(mission["max_assessments"] || 3)} assessments used.
            Assessments use this session’s model and may consume provider allowance.</p>
            <p class="muted">#{if configuring, do: "Saving records a new baseline and clears the current report. The assessment allowance is not reset. The observer stays paused until you resume it.", else: "Starting records a baseline. Only future stable tracked changes trigger an assessment. Keep the runtime owner running."}</p>
            <button #{if editable, do: "", else: "disabled"}>#{if configuring, do: "Save watched paths", else: "Start documentation observer"}</button>
            #{if editable, do: "", else: "<p>Pause the observer in the session before changing its scope.</p>"}
          </form>
        </section>
      </div>
    </main>
    """)
  end

  defp observer_entries(listing) do
    Enum.map_join(listing["entries"] || [], fn entry ->
      """
      <li><button type="button" class="quiet" data-#{if entry["directory"], do: "browse", else: "select"}-path="#{escape(entry["path"])}">#{if entry["directory"], do: "▸", else: "+"} #{escape(entry["name"])}</button>
      #{if entry["directory"], do: "<button type=\"button\" class=\"quiet\" data-select-path=\"#{escape(entry["path"])}\" aria-label=\"Add #{escape(entry["path"])}\">+</button>", else: ""}</li>
      """
    end)
  end

  def start_id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  def session_start(result) do
    {state, message} =
      case result do
        {:ok, %{"status" => "starting"}} ->
          {"starting",
           "The runtime is initializing your workspace. Refreshing this page will not create another session."}

        {:ok, job} ->
          {"failed", "Startup stopped: #{job["error"]}. Check live sessions before trying again."}

        _ ->
          {"unavailable",
           "Startup status unavailable. Check live sessions; no startup request has been repeated."}
      end

    layout("""
    <main class="control-center observer-setup startup-page" data-start-state="#{state}">
      <a class="wordmark" href="/"><span class="brand-mark">╬</span> LOOM / DESK</a>
      <p class="eyebrow">Runtime / Startup</p><h1>#{if state == "starting", do: "Opening your workspace…", else: "Let’s check the runtime."}</h1>
      <p id="startup-status" role="status">#{escape(message)}</p>
      <p>No model call is needed to create a session.</p><a href="/">← All live sessions</a>
    </main>
    """)
  end

  def workspaces(result, csrf, observer) do
    case result do
      {:ok, listing} ->
        layout("""
        <main class="control-center observer-setup">
          <a class="wordmark" href="/"><span class="brand-mark">╬</span> LOOM / DESK</a>
          <p><a href="/">← All live sessions</a></p><p class="eyebrow">This computer / Workspace</p>
          <h1>A new place<br>to work.</h1>
          <p class="lede">Choose a folder on the computer running Desk. Existing sessions keep their own workspace.</p>
          <div class="computer-picker" data-current="#{escape(listing["path"])}" data-home="#{escape(listing["home"])}">
            <section class="folder-browser" aria-label="Computer folders">
              <form id="computer-location"><label for="computer-path">Folder on this computer</label>
                <div class="browse-location"><input id="computer-path" value="#{escape(listing["path"])}" maxlength="4096" required><button class="outline">Open folder</button></div></form>
              <div class="observer-actions"><button type="button" data-location="/" class="quiet">Computer /</button>
                <button type="button" data-location="#{escape(listing["home"])}" class="quiet">Home</button>
                <button type="button" id="computer-up" class="quiet">↑ Up</button></div>
              <p id="computer-status" role="status">Directory names only. Browsing does not start agents or read file contents.</p>
              <ul id="computer-entries">#{Enum.map_join(listing["entries"], fn entry -> "<li><button type=\"button\" class=\"quiet\" data-location=\"#{escape(entry["path"])}\">▸ #{escape(entry["name"])}</button></li>" end)}</ul>
              <div class="observer-actions"><button type="button" id="computer-previous" class="quiet" disabled>Previous page</button>
                <button type="button" id="computer-next" class="quiet" #{if listing["more"], do: "", else: "disabled"}>Next page</button></div>
            </section>
            <section class="observer-selection"><form method="post" action="/sessions">
              #{hidden(csrf)}<input type="hidden" name="request_id" value="#{start_id()}">
              <input type="hidden" name="observer" value="#{if observer, do: "1", else: "0"}">
              <label for="workspace-root">New session workspace</label><input id="workspace-root" name="workspace" value="#{escape(listing["path"])}" readonly required>
              <p id="workspace-kind" class="muted">#{if listing["repository"], do: "Git repository detected.", else: "No Git root detected here. Documentation observers require a Git workspace."}</p>
              <p>This explicitly gives a new session access to the selected folder, using Desk’s configured provider and approval policy.</p>
              <p class="muted">No model call until you submit work or start an observer. Nothing changes in your existing sessions.</p>
              <button id="open-workspace">#{if observer, do: "Use folder for an observer", else: "Create session here"}</button>
            </form></section>
          </div>
        </main>
        """)

      _ ->
        layout(
          "<main class=\"control-center observer-setup\"><h1>Workspace browser unavailable</h1><p>This needs the rebuilt Desk control center. A single-session attachment cannot browse the computer.</p><a href=\"/\">← All live sessions</a></main>"
        )
    end
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
      <div class="message-list" tabindex="0" aria-label="Message history">#{if messages == [], do: "<p class=muted>Your prompt and the assistant’s output will appear here. Activity events remain below.</p>", else: Enum.map_join(messages, &message_card/1)}</div>
      <p class="muted">Verification: #{escape(conversation["verification"] || "not reported")} · Review: #{escape(conversation["review"] || "not reported")}</p>
    </section>
    """
  end

  defp conversation(_) do
    """
    <section id="conversation" class="conversation"><h2>Conversation &amp; output</h2>
    <p role="status">Output is unavailable from this runtime. Rebuild and restart with <code>./loom desk</code>.
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
    <title>Loom Desk</title><link rel="stylesheet" href="/assets/desk.css"><script defer src="/assets/desk.js"></script></head>
    <body>#{body}</body></html>
    """
  end
end
