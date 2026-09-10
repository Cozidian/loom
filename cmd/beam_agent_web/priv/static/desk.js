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
        document.querySelector('[role="alert"]').textContent = "Connection interrupted. Reopen Desk from the CLI; this launch may already have been used.";
      });
    }
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
            ? "Session expired · reload to sign in"
            : "Disconnected · reconnecting",
        );
      const opened = [
        ...panels.querySelectorAll("details[data-agent][open]"),
      ].map((el) => el.dataset.agent);
      const openedEvents = [...panels.querySelectorAll("details[data-event][open]")].map(el => el.dataset.event);
      const scroll = panels.querySelector(".activity")?.scrollTop || 0;
      // HTML is rendered and escaped by Phoenix; the runtime never supplies raw markup.
      panels.innerHTML = await response.text();
      panels.querySelectorAll("details[data-agent]").forEach((el) => {
        el.open = opened.includes(el.dataset.agent);
      });
      panels.querySelectorAll("details[data-event]").forEach(el => { el.open = openedEvents.includes(el.dataset.event); });
      const activity = panels.querySelector(".activity");
      if (activity) activity.scrollTop = scroll;
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
