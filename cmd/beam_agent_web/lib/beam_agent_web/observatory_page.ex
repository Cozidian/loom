defmodule BeamAgentWeb.ObservatoryPage do
  @moduledoc false
  def body(report, session_id) do
    prefix = if session_id, do: "/sessions/#{URI.encode(session_id)}", else: ""
    name = Path.basename(report["workspace_root"] || "Workspace")

    """
    <main class="observatory cockpit" data-session-id="#{esc(session_id || "")}" data-session-url="#{prefix}">
      <header class="obs-masthead">
        <a class="obs-brand" href="/" aria-label="Loom home">╬</a>
        <div class="obs-identity"><span class="obs-eyebrow">LOOM / REPOSITORY OBSERVATORY</span><h1>#{esc(name)}<span class="obs-local">LOCAL MODEL</span></h1></div>
        <div class="obs-revision"><span class="obs-live-dot"></span>#{if report["dirty"], do: "Working changes", else: "Clean worktree"}<code>#{esc(String.slice(report["head"] || "unversioned", 0, 8))}</code></div>
        <a class="obs-back" href="#{if prefix == "", do: "/", else: prefix}">← Back to session</a>
      </header>
      <section class="obs-commandbar" aria-label="Exploration controls">
        <div class="obs-modes" role="group" aria-label="Exploration mode">
          <button type="button" data-mode="understand" class="active" aria-pressed="true">01 <strong>Understand</strong></button>
          <button type="button" data-mode="investigate" aria-pressed="false">02 <strong>Investigate</strong></button>
          <button type="button" data-mode="rehearse" aria-pressed="false">03 <strong>Rehearse a change</strong></button>
        </div>
        <button type="button" id="obs-health-button" class="obs-quiet">Evidence &amp; blind spots ↗</button>
        <a class="obs-quiet" href="#{prefix}/observatory/data" download="repository-intelligence.json">↓ Model JSON</a>
      </section>
      <div class="obs-workspace">
        <aside class="obs-navigator" aria-label="Repository navigator">
          <div class="obs-nav-heading"><span class="obs-eyebrow">SYSTEM INDEX</span><span id="obs-component-count"></span></div>
          <label class="obs-search"><span class="sr-only">Find a component or file</span><input id="obs-search" type="search" placeholder="Find a component or file…" autocomplete="off"><kbd>/</kbd></label>
          <div id="obs-tree"></div>
          <section class="obs-investigations"><h2>Start here <span>↗</span></h2><p>Evidence-led investigation routes</p><div id="obs-investigations"></div></section>
        </aside>
        <section class="obs-stage" aria-label="System atlas">
          <div class="obs-stage-heading"><div><p class="obs-eyebrow" id="obs-stage-eyebrow">SYSTEM ATLAS / CURRENT WORKTREE</p><h2 id="obs-stage-title">See the system. Find your bearings.</h2><p id="obs-stage-description">Follow the boundaries, then pull a component apart.</p></div><button id="obs-reset" type="button" class="obs-quiet">↺ Reset view</button></div>
          <div class="obs-lenses" id="obs-lenses" role="group" aria-label="Map lens">
            <span>LENS</span><div id="obs-lens-buttons" class="obs-lens-buttons"></div>
          </div>
          <div class="obs-map" id="obs-map"><svg id="obs-atlas" role="group" aria-label="Interactive component map"></svg><div id="obs-empty" hidden>No components match. Try another search or reset the view.</div>
            <div class="obs-map-tools"><button type="button" id="obs-zoom-in" aria-label="Zoom in">+</button><button type="button" id="obs-zoom-out" aria-label="Zoom out">−</button><button type="button" id="obs-isolate" aria-pressed="false">Isolate neighborhood</button></div>
            <div class="obs-map-legend"><span><i class="obs-line"></i> consumer → dependency</span><span id="obs-map-scope">Inferred layers · static references</span></div>
          </div>
          <div class="obs-map-footer"><label>ASSEMBLY <input type="range" id="obs-spread" min="0" max="100" value="55" aria-label="Explode architectural layers"> EXPLODED</label><span id="obs-map-count"></span></div>
          <section class="obs-time" aria-label="Repository time lens"><div class="obs-time-heading"><span class="obs-eyebrow">TIME LENS</span><strong id="obs-time-label">Current worktree</strong><button type="button" id="obs-time-play" class="obs-quiet">▶ Play history</button><button type="button" id="obs-time-now" class="obs-quiet">Now</button></div><div id="obs-time-bars" aria-hidden="true"></div><input type="range" id="obs-time-range" aria-label="Scrub sampled commit history" min="0" max="0" value="0"><p id="obs-time-detail">Actual commit activity projected onto today’s architecture. This is not a reconstruction of historical topology.</p></section>
        </section>
        <aside class="obs-inspector" id="obs-inspector" aria-label="Selection evidence"><p>Select a component to investigate its role and relationships.</p></aside>
      </div>
      <footer class="obs-statusbar"><span id="obs-coverage">Building local model…</span><span>OBSERVE → REASON → CHANGE → VERIFY</span><span id="obs-announcement" role="status" aria-live="polite"></span></footer>
      <dialog id="obs-evidence-dialog" class="obs-dialog"><div class="obs-dialog-heading"><div><p class="obs-eyebrow">MODEL PROVENANCE</p><h2>What we know. What we don’t.</h2></div><button type="button" id="obs-close-evidence" aria-label="Close evidence">×</button></div><div id="obs-dimensions"></div><h3>Signal sources</h3><div id="obs-integrations"></div><h3>Model boundaries</h3><ul id="obs-limits"></ul><p id="obs-generated"></p></dialog>
      <dialog id="obs-brief-dialog" class="obs-dialog"><div class="obs-dialog-heading"><div><p class="obs-eyebrow">AGENT HANDOFF / REVIEW BEFORE RUNNING</p><h2>An investigation with a starting point.</h2></div><button type="button" id="obs-close-brief" aria-label="Close investigation brief">×</button></div><label for="obs-brief">Editable investigation brief</label><textarea id="obs-brief" rows="18"></textarea><div class="obs-brief-actions"><button id="obs-copy-brief" type="button">Copy brief</button><button id="obs-download-brief" type="button">Download .md</button><button id="obs-send-brief" type="button">Open as session draft ↗</button></div><p>No agent runs until you submit the draft in the session. Existing drafts are preserved.</p></dialog>
      <noscript><p>The interactive atlas requires JavaScript. <a href="#{prefix}/observatory/data">Download the evidence model</a>.</p><pre>#{esc(JSON.encode!(Map.take(report, ["file_count", "ci", "libraries"])))}</pre></noscript>
    </main>
    """
  end

  defp esc(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
