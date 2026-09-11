(() => {
  const ticket = new URLSearchParams(location.hash.slice(1)).get("launch");
  if (ticket) {
    // Fragments are never sent in HTTP requests. Remove before authenticating.
    history.replaceState(null, "", location.pathname);
    const csrf = document.querySelector('input[name="_csrf_token"]')?.value;
    if (csrf) {
      fetch("/launch", {
        method: "POST", credentials: "same-origin",
        headers: {"Content-Type": "application/x-www-form-urlencoded"},
        body: new URLSearchParams({ticket, _csrf_token: csrf}),
      }).then(async response => {
        if (response.ok) location.replace(location.pathname);
        else document.querySelector('[role="alert"]').textContent = await response.text();
      }).catch(() => {
        document.querySelector('[role="alert"]').textContent = "Connection interrupted. Run ./loom desk again; this launch may already have been used.";
      });
    }
    return;
  }
  document.querySelectorAll('form[action="/sessions"]').forEach(form => {
    form.addEventListener("submit", () => {
      form.querySelectorAll("button").forEach(button => { button.disabled = true; button.textContent = "Opening…"; });
    });
  });
  const startup = document.querySelector(".startup-page");
  if (startup) {
    async function checkStart() {
      try {
        const response = await fetch(location.pathname + "/status", {cache: "no-store", signal: AbortSignal.timeout(10000)});
        if (!response.ok) throw new Error("Startup status unavailable. Check live sessions; no request was repeated.");
        const job = await response.json();
        if (job.status === "ready") {
          location.replace("/sessions/" + encodeURIComponent(job.session_id) + (new URLSearchParams(location.search).get("observer") === "1" ? "/observer" : ""));
          return;
        }
        if (job.status === "failed") {
          document.querySelector("#startup-status").textContent = "Startup stopped: " + job.error + ". Check live sessions before retrying.";
          return;
        }
        document.querySelector("#startup-status").textContent = "Still opening your workspace. The runtime owns this startup; refreshing is safe.";
      } catch (error) {
        document.querySelector("#startup-status").textContent = error.message;
      }
      setTimeout(checkStart, 1500);
    }
    if (startup.dataset.startState === "starting") checkStart();
    return;
  }
  const computer = document.querySelector(".computer-picker");
  if (computer) {
    let current = computer.dataset.current, pageNumber = 0, busy = false;
    const input = document.querySelector("#computer-path");
    const selected = document.querySelector("#workspace-root");
    const status = document.querySelector("#computer-status");
    const submit = document.querySelector("#open-workspace");
    const previous = document.querySelector("#computer-previous");
    const next = document.querySelector("#computer-next");
    async function browse(path, page = 0) {
      if (busy) return;
      busy = true; submit.disabled = true;
      status.textContent = "Reading folders…";
      try {
        const response = await fetch("/workspaces/paths?" + new URLSearchParams({path, page}), {cache: "no-store", signal: AbortSignal.timeout(10000)});
        if (!response.ok) throw new Error("Folder unavailable or access denied. Your existing sessions are unchanged.");
        const listing = await response.json();
        current = listing.path; pageNumber = listing.page;
        selected.value = input.value = current;
        document.querySelector("#computer-up").disabled = !listing.parent;
        document.querySelector("#workspace-kind").textContent = listing.repository ? "Git repository detected." : "No Git root detected here. Documentation observers require a Git workspace.";
        const entries = document.querySelector("#computer-entries");
        entries.replaceChildren();
        for (const entry of listing.entries) {
          const row = document.createElement("li"), button = document.createElement("button");
          button.type = "button"; button.className = "quiet";
          button.dataset.location = entry.path; button.textContent = "▸ " + entry.name;
          row.append(button); entries.append(row);
        }
        entries.scrollTop = 0;
        previous.disabled = pageNumber === 0; next.disabled = !listing.more;
        status.textContent = listing.entries.length ? "Browsing " + current : "No subfolders here. You can select this folder.";
        submit.disabled = false;
      } catch (error) { status.textContent = error.message; }
      finally { busy = false; }
    }
    computer.addEventListener("click", event => {
      const button = event.target.closest("[data-location]");
      if (button) browse(button.dataset.location);
    });
    document.querySelector("#computer-location").addEventListener("submit", event => { event.preventDefault(); browse(input.value); });
    document.querySelector("#computer-up").addEventListener("click", () => browse(current.substring(0, current.lastIndexOf("/")) || "/"));
    previous.addEventListener("click", () => browse(current, pageNumber - 1));
    next.addEventListener("click", () => browse(current, pageNumber + 1));
    return;
  }
  const picker = document.querySelector(".observer-picker");
  if (picker) {
    const locationInput = document.querySelector("#browse-path");
    const paths = document.querySelector("#observer-paths");
    const entries = document.querySelector("#browse-entries");
    const status = document.querySelector("#browse-status");
    const parent = document.querySelector("#browse-parent");
    const selectFolder = document.querySelector("#select-folder");
    let currentPath = ".", parentPath = null, busy = false;

    function select(path) {
      if (busy) return;
      const selected = paths.value.split(/\r?\n/).filter(Boolean);
      if (!selected.includes(path)) {
        if (selected.length >= 20) {
          status.textContent = "Up to 20 paths. Remove a selected line before adding another.";
          return;
        }
        paths.value = [...selected, path].join("\n");
      }
      status.textContent = "Selected " + path + ". Nothing starts until you submit.";
    }

    async function browse(path) {
      if (busy) return;
      busy = true;
      selectFolder.disabled = parent.disabled = true;
      status.textContent = "Reading tracked paths…";
      try {
        const url = new URL(picker.dataset.pathsUrl, location.origin);
        url.searchParams.set("path", path);
        const response = await fetch(url, {cache: "no-store", signal: AbortSignal.timeout(10000)});
        if (!response.ok) throw new Error(response.status === 401
          ? "Session expired. Run ./loom desk to reconnect."
          : "Cannot browse that path. Choose a relative folder inside this Git workspace.");
        const listing = await response.json();
        currentPath = listing.path;
        parentPath = listing.parent;
        locationInput.value = currentPath;
        entries.replaceChildren();
        for (const entry of listing.entries) {
          const row = document.createElement("li");
          const button = document.createElement("button");
          button.type = "button";
          button.className = "quiet";
          button.textContent = (entry.directory ? "▸ " : "+ ") + entry.name;
          button.dataset[entry.directory ? "browsePath" : "selectPath"] = entry.path;
          row.append(button);
          if (entry.directory) {
            const add = document.createElement("button");
            add.type = "button";
            add.className = "quiet";
            add.textContent = "+";
            add.setAttribute("aria-label", "Add " + entry.path);
            add.dataset.selectPath = entry.path;
            row.append(add);
          }
          entries.append(row);
        }
        status.textContent = listing.truncated
          ? "First 200 entries shown. Type a more specific path to browse further."
          : listing.entries.length ? "Browsing " + currentPath
          : "No readable tracked files here. Untracked files are not observed.";
        selectFolder.disabled = false;
      } catch (error) {
        status.textContent = error.message || "Folder browser disconnected. Try again.";
      } finally {
        busy = false;
        parent.disabled = !parentPath;
      }
    }

    picker.addEventListener("click", event => {
      const browseButton = event.target.closest("[data-browse-path]");
      const selectButton = event.target.closest("[data-select-path]");
      if (browseButton) browse(browseButton.dataset.browsePath);
      if (selectButton) select(selectButton.dataset.selectPath);
    });
    document.querySelector("#browse-path-form").addEventListener("submit", event => {
      event.preventDefault();
      browse(locationInput.value);
    });
    parent.addEventListener("click", () => { if (parentPath) browse(parentPath); });
    selectFolder.addEventListener("click", () => select(currentPath));
    return;
  }
  const directory = document.querySelector("#directory");
  if (directory) {
    const connection = document.querySelector("#connection");
    async function refreshDirectory() {
      try {
        const response = await fetch("/sessions-panel", {cache: "no-store", signal: AbortSignal.timeout(10000)});
        if (!response.ok) throw new Error("Session directory disconnected · retrying");
        directory.innerHTML = await response.text();
        connection.textContent = "● Live · synced " + new Date().toLocaleTimeString();
        connection.classList.remove("offline");
      } catch (error) {
        connection.textContent = error.message;
        connection.classList.add("offline");
      } finally { setTimeout(refreshDirectory, 3000); }
    }
    refreshDirectory();
    return;
  }
  const panels = document.querySelector("#panels");
  if (!panels) return;
  const connection = document.querySelector("#connection");
  const prompt = document.querySelector("#prompt");
  // Memory is confined to this browser tab and removed after an accepted submit.
  const key = "beam-agent-desk-draft:" + panels.dataset.sessionId;
  try {
    prompt.value = sessionStorage.getItem(key) || "";
  } catch (_) {}
  prompt.addEventListener("input", () => {
    try {
      sessionStorage.setItem(key, prompt.value);
    } catch (_) {}
  });
  prompt.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      prompt.form.requestSubmit();
    }
  });
  prompt.form.addEventListener("submit", () => {
    try {
      sessionStorage.setItem(key, prompt.value);
    } catch (_) {}
  });
  if (
    document.querySelector("#notice").textContent.includes("Prompt accepted")
  ) {
    // Only clear a draft after the runtime acknowledges its exact submission.
    try {
      if (sessionStorage.getItem(key + "-sent") === prompt.value) {
        sessionStorage.removeItem(key);
        prompt.value = "";
      }
      sessionStorage.removeItem(key + "-sent");
    } catch (_) {}
  }
  prompt.form.addEventListener("submit", () => {
    try {
      sessionStorage.setItem(key + "-sent", prompt.value);
    } catch (_) {}
  });
  async function refresh() {
    if (document.hidden) {
      setTimeout(refresh, 2000);
      return;
    }
    try {
      const response = await fetch(panels.dataset.panelsUrl || "/panels", {
        cache: "no-store",
        signal: AbortSignal.timeout(10000),
      });
      if (!response.ok)
        throw new Error(
          response.status === 401
            ? "Session expired · run ./loom desk to reconnect"
            : "Disconnected · reconnecting",
        );
      // Finish the response before sampling local UI state; scrolling while the
      // body is arriving must not be overwritten by an earlier scroll position.
      const markup = await response.text();
      const opened = [
        ...panels.querySelectorAll("details[data-agent][open]"),
      ].map((el) => el.dataset.agent);
      const openedEvents = [...panels.querySelectorAll("details[data-event][open]")].map(el => el.dataset.event);
      const reportDetails = [...panels.querySelectorAll("details[data-report][open], details[data-followup][open]")].map(el => el.dataset.report || el.dataset.followup);
      const scroll = panels.querySelector(".activity")?.scrollTop || 0;
      const panelScroll = panels.scrollTop;
      const transcriptScroll = panels.querySelector(".message-list")?.scrollTop || 0;
      const focusedObserverAction = document.activeElement
        ?.closest("#documentation-mission form")?.querySelector('input[name="action"]')?.value;
      // HTML is rendered and escaped by Phoenix; the runtime never supplies raw markup.
      panels.innerHTML = markup;
      if (focusedObserverAction) {
        [...panels.querySelectorAll("#documentation-mission form")]
          .find(form => form.querySelector('input[name="action"]')?.value === focusedObserverAction)
          ?.querySelector("button")?.focus({preventScroll: true});
      }
      panels.querySelectorAll("details[data-agent]").forEach((el) => {
        el.open = opened.includes(el.dataset.agent);
      });
      panels.querySelectorAll("details[data-event]").forEach(el => { el.open = openedEvents.includes(el.dataset.event); });
      panels.querySelectorAll("details[data-report], details[data-followup]").forEach(el => { el.open = reportDetails.includes(el.dataset.report || el.dataset.followup); });
      const activity = panels.querySelector(".activity");
      if (activity) activity.scrollTop = scroll;
      panels.scrollTop = panelScroll;
      const transcript = panels.querySelector(".message-list");
      if (transcript) transcript.scrollTop = transcriptScroll;
      connection.textContent =
        "● Live · synced " + new Date().toLocaleTimeString();
      connection.classList.remove("offline");
    } catch (error) {
      connection.textContent = error.message || "Disconnected · reconnecting";
      connection.classList.add("offline");
    } finally {
      setTimeout(refresh, 2000);
    }
  }
  refresh();
})();
