use crate::editor::{Editor, clean};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::time::Instant;

pub fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
pub fn array(v: &Value, key: &str) -> Vec<Value> {
    v[key].as_array().cloned().unwrap_or_default()
}
pub fn command(name: &str, query: &str) -> Value {
    json!({"type":"command","command":name,"query":query})
}
pub const COMMANDS: &[&str] = &[
    "mission",
    "models",
    "providers",
    "files",
    "sessions",
    "events",
    "tree",
    "race",
    "tournament",
    "connect",
    "auto",
    "verify",
    "status",
    "budget",
    "resources",
    "organizations",
    "worktrees",
    "repository",
    "skills",
    "reload",
    "compact",
    "new",
];

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum View {
    Mission,
    Swarm,
    Ledger,
}
#[derive(Clone)]
pub struct Entry {
    pub kind: String,
    pub text: String,
    pub response: String,
    pub streaming: bool,
}
pub struct SettingsForm {
    pub title: String,
    pub action: String,
    pub profile: String,
    pub provider: String,
    pub revision: String,
    pub editing: bool,
    pub fields: Vec<(String, Editor)>,
    pub index: usize,
}
pub struct App {
    pub initialized: bool,
    pub connected: bool,
    pub busy: bool,
    pub pending: bool,
    pub session: String,
    pub workspace: String,
    pub model: String,
    pub profile: String,
    pub approval_mode: String,
    pub cursor: u64,
    pub editor: Editor,
    pub last_submission: String,
    pub prompt_history: VecDeque<String>,
    pub history_index: Option<usize>,
    pub history_draft: Option<Editor>,
    pub history_query: String,
    pub command_index: usize,
    pub clipboard: Option<String>,
    pub settings: Value,
    pub settings_form: Option<SettingsForm>,
    pub settings_confirm: Option<Value>,
    pub settings_pending: bool,
    pub model_strategy: String,
    pub model_query: String,
    pub model_searching: bool,
    pub team_mode: String,
    pub activity: String,
    pub last_activity: Option<Instant>,
    pub tool_count: usize,
    pub expand_tools: bool,
    pub active_tools: Vec<(String, Instant)>,
    pub entries: VecDeque<Entry>,
    pub events: VecDeque<Value>,
    pub workers: Vec<Value>,
    pub approvals: VecDeque<Value>,
    pub resolving: Option<String>,
    pub approval_choice: usize,
    pub approval_scroll: usize,
    pub files: Vec<String>,
    pub attachments: Vec<Value>,
    pub progress: Value,
    pub stats: Value,
    pub view: View,
    pub selection: usize,
    pub scroll: u16,
    pub following: bool,
    pub palette: bool,
    pub palette_query: String,
    pub palette_index: usize,
    pub picker_index: usize,
    pub dismiss_picker: bool,
    pub drawer: Option<Value>,
    pub drawer_scroll: u16,
    pub drawer_stack: Vec<(Value, usize, u16)>,
    pub confirm_cancel: Option<String>,
    pub notice: String,
    pub outgoing: Vec<Value>,
    pub quit: bool,
    pub demo: bool,
}

impl Default for App {
    fn default() -> Self {
        Self {
            initialized: false,
            connected: true,
            busy: false,
            pending: false,
            session: String::new(),
            workspace: String::new(),
            model: String::new(),
            profile: String::new(),
            approval_mode: "ask".into(),
            cursor: 0,
            editor: Editor::default(),
            last_submission: String::new(),
            prompt_history: VecDeque::new(),
            history_index: None,
            history_draft: None,
            history_query: String::new(),
            command_index: 0,
            clipboard: None,
            settings: Value::Null,
            settings_form: None,
            settings_confirm: None,
            settings_pending: false,
            model_strategy: "auto".into(),
            model_query: String::new(),
            model_searching: false,
            team_mode: "solo".into(),
            activity: String::new(),
            last_activity: None,
            tool_count: 0,
            expand_tools: false,
            active_tools: vec![],
            entries: VecDeque::new(),
            events: VecDeque::new(),
            workers: vec![],
            approvals: VecDeque::new(),
            resolving: None,
            approval_choice: 0,
            approval_scroll: 0,
            files: vec![],
            attachments: vec![],
            progress: Value::Null,
            stats: Value::Null,
            view: View::Mission,
            selection: 0,
            scroll: 0,
            following: true,
            palette: false,
            palette_query: String::new(),
            palette_index: 0,
            picker_index: 0,
            dismiss_picker: false,
            drawer: None,
            drawer_scroll: 0,
            drawer_stack: vec![],
            confirm_cancel: None,
            notice: String::new(),
            outgoing: vec![],
            quit: false,
            demo: false,
        }
    }
}

impl App {
    fn entry(&mut self, kind: &str, text: &str) {
        if kind == "user" {
            self.remember_prompt(text);
        }
        self.entries.push_back(Entry {
            kind: kind.into(),
            text: clean(text),
            response: String::new(),
            streaming: false,
        });
        while self.entries.len() > 600 {
            self.entries.pop_front();
        }
    }
    pub fn disconnected(&mut self, reason: String) {
        if self.pending && self.editor.text.is_empty() {
            self.editor.set(&self.last_submission);
        }
        self.connected = false;
        self.pending = false;
        self.settings_pending = false;
        self.resolving = None;
        self.notice = format!("Bridge disconnected · {reason}. Draft preserved; Ctrl+Q exits.");
    }
    pub fn send_failed(&mut self, packet: &Value, reason: &str) {
        if s(packet, "type") == "provider_settings" {
            self.settings_pending = false;
        }
        if s(packet, "type") == "submit" {
            if self.editor.text.is_empty() {
                self.editor.set(s(packet, "prompt"));
            }
            self.pending = false;
        }
        if s(packet, "command") == "steer" && self.editor.text.is_empty() {
            self.editor.set(s(packet, "query"));
        }
        if s(packet, "type") == "approval" {
            self.resolving = None;
        }
        self.notice = format!("Action not sent: {reason}. Draft/approval preserved.");
    }
    pub fn apply(&mut self, mut p: Value) {
        if s(&p, "type") == "models" && p["combined"] == true {
            p["type"] = json!("model_catalog");
        }
        match s(&p, "type") {
            "init" => {
                self.initialized = true;
                self.session = s(&p, "session_id").into();
                self.workspace = s(&p, "workspace").into();
                self.profile = s(&p, "profile").into();
                self.model = s(&p, "model").into();
                self.model_strategy = if s(&p, "model_strategy").is_empty() {
                    "manual"
                } else {
                    s(&p, "model_strategy")
                }
                .into();
                self.approval_mode = s(&p, "approval_mode").into();
                self.cursor = p["cursor"].as_u64().unwrap_or(0);
                self.entries.clear();
                self.team_mode = p["team_mode"].as_str().unwrap_or("solo").into();
                self.active_tools.clear();
                self.tool_count = 0;
                self.activity.clear();
                self.last_activity = None;
                for e in array(&p, "entries") {
                    self.entry(
                        s(&e, "kind"),
                        if s(&e, "content").is_empty() {
                            s(&e, "name")
                        } else {
                            s(&e, "content")
                        },
                    );
                    if s(&e, "kind") == "tool"
                        && let Some(last) = self.entries.back_mut()
                    {
                        last.response = s(&e, "id").into();
                        last.text = format!(
                            "{} · {}\n{}",
                            s(&e, "status"),
                            s(&e, "name"),
                            s(&e, "content")
                        );
                    }
                }
                self.workers = array(&p, "work_blocks");
                self.progress = p["progress"].clone();
                self.stats = p["context_stats"].clone();
                self.attachments = array(&p, "attachments");
                self.files = array(&p, "workspace_files")
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect();
                self.approvals = array(&p, "approvals").into();
                for event in array(&p, "competition_events") {
                    self.events.push_back(event);
                }
                self.notice = "Runtime connected · your workspace is ready".into();
            }
            "turn_started" => {
                self.busy = true;
                self.active_tools.clear();
                self.tool_count = 0;
                self.signal("Preparing work");
                self.pending = false;
                self.attachments.clear();
                let prompt = s(&p, "prompt");
                if !prompt.is_empty()
                    && !self
                        .entries
                        .back()
                        .is_some_and(|e| e.kind == "user" && e.text == prompt)
                {
                    self.entry("user", prompt);
                }
            }
            "turn_finished" => {
                self.busy = false;
                self.active_tools.clear();
                self.signal("Turn finished");
                self.pending = false;
                for e in &mut self.entries {
                    e.streaming = false;
                }
                if p["ok"] == false {
                    self.entry("error", s(&p, "error"));
                    self.notice = "Work stopped with an error · inspect the ledger".into();
                } else {
                    self.notice = "Turn complete · results remain in the workspace".into();
                }
            }
            "turn_cancelling" => {
                self.notice = "Cancellation requested · waiting for runtime".into()
            }
            "stream" => self.stream(&p["event"]),
            "work_projection" | "tree" => {
                self.workers = array(&p, "work_blocks");
                self.progress = p["progress"].clone();
                if self.drawer.is_none() && self.view == View::Swarm {
                    self.clamp_selection();
                }
            }
            "approval_requested" => {
                let a = p["approval"].clone();
                let id = s(&a, "approval_id");
                if !self.approvals.iter().any(|x| s(x, "approval_id") == id) {
                    self.approvals.push_back(a);
                }
            }
            "approval_snapshot" => {
                let previous = self.approvals.front().cloned();
                self.approvals = array(&p, "approvals").into();
                if previous.as_ref().map(|a| s(a, "approval_id"))
                    != self.approvals.front().map(|a| s(a, "approval_id"))
                {
                    self.approval_choice = 0;
                    self.approval_scroll = 0;
                }
                if !self
                    .approvals
                    .iter()
                    .any(|a| Some(s(a, "approval_id")) == self.resolving.as_deref())
                {
                    self.resolving = None;
                }
            }
            "approval_resolved" => {
                let front_resolved = self
                    .approvals
                    .front()
                    .is_some_and(|a| s(a, "approval_id") == s(&p, "approval_id"));
                self.approvals
                    .retain(|a| s(a, "approval_id") != s(&p, "approval_id"));
                if self.resolving.as_deref() == Some(s(&p, "approval_id")) {
                    self.resolving = None;
                }
                if front_resolved {
                    self.approval_choice = 0;
                    self.approval_scroll = 0;
                }
                self.notice = format!("Runtime acknowledged: {}", s(&p, "decision"));
            }
            "approval_failed" => {
                if self.resolving.as_deref() == Some(s(&p, "approval_id")) {
                    self.resolving = None;
                }
                self.notice = s(&p, "error").into();
            }
            "approval_mode" => self.approval_mode = s(&p, "approval_mode").into(),
            "context_stats" => self.stats = p["stats"].clone(),
            "notice" | "attachment_failed" => {
                self.notice = if s(&p, "message").is_empty() {
                    s(&p, "error")
                } else {
                    s(&p, "message")
                }
                .into();
                if self.pending && s(&p, "tone") == "error" {
                    self.pending = false;
                    if self.editor.text.is_empty() {
                        self.editor.set(&self.last_submission);
                    }
                }
                if self.settings_pending && s(&p, "tone") == "error" {
                    self.settings_pending = false;
                }
            }
            "attachment_imported" => {
                self.attachments.push(p["attachment"].clone());
                self.notice = "Attachment ready · included with next submission".into();
            }
            "attachment_deleted" => self
                .attachments
                .retain(|a| s(a, "id") != s(&p, "attachment_id")),
            "session_changed" => {
                self.active_tools.clear();
                self.activity.clear();
                self.last_activity = None;
                self.tool_count = 0;
                self.team_mode = p["team_mode"].as_str().unwrap_or("solo").into();
                self.leave_history();
                self.drawer_stack.clear();
                self.session = s(&p, "session_id").into();
                self.entries.clear();
                self.events.clear();
                self.workers.clear();
                self.approvals.clear();
                self.resolving = None;
                self.approval_choice = 0;
                self.approval_scroll = 0;
                self.busy = false;
                self.pending = false;
                self.cursor = 0;
                self.drawer = None;
                self.profile = s(&p, "profile").into();
                self.model = s(&p, "model").into();
                self.attachments = array(&p, "attachments");
                self.outgoing.push(command("tree", ""));
            }
            "mission_update" => {
                if self
                    .drawer
                    .as_ref()
                    .is_some_and(|d| d["mission_actions"].is_array())
                {
                    let mut updated = p;
                    updated["type"] = json!("panel");
                    self.drawer = Some(updated);
                }
            }
            "models" | "files" | "sessions" | "diff" | "session_detail" | "panel" | "events"
            | "provider_picker" => {
                self.drawer_stack.clear();
                self.drawer = Some(p);
                self.drawer_scroll = 0;
                self.selection = 0;
            }
            "provider_settings" => {
                if let Some(mode) = p["team_mode"].as_str() {
                    self.team_mode = mode.into();
                }
                self.settings_pending = false;
                if self.notice.starts_with("Checking provider settings") {
                    self.notice = "Providers ready · n new · e edit · u use · Enter models".into();
                }
                self.settings = p.clone();
                self.model_strategy = s(&p, "model_strategy").into();
                self.drawer_stack.clear();
                self.drawer = Some(p);
                self.selection = 0;
                self.drawer_scroll = 0;
            }
            "model_catalog" => {
                self.settings_pending = false;
                if p["combined"] == true {
                    self.model_strategy = s(&p, "model_strategy").into();
                    self.notice = if p["refreshing"] == true {
                        "Refreshing model catalogue · r checks again"
                    } else {
                        "Loom picks by default · Enter locks a model for this conversation"
                    }
                    .into();
                    let problems: Vec<String> = array(&p, "sources")
                        .iter()
                        .filter(|source| matches!(s(source, "status"), "stale" | "unavailable"))
                        .map(|source| format!("{} {}", s(source, "profile"), s(source, "status")))
                        .collect();
                    if !problems.is_empty() {
                        self.notice = format!("{} · r refresh · p providers", problems.join(" · "));
                    }
                    // Refresh replaces this drawer rather than growing the back stack.
                    if self
                        .drawer
                        .as_ref()
                        .is_some_and(|d| s(d, "type") == "model_catalog" && d["combined"] == true)
                    {
                        self.drawer = Some(p);
                    } else {
                        self.model_query.clear();
                        self.model_searching = false;
                        self.open_drawer(p);
                    }
                } else {
                    self.notice =
                        "Model catalogue ready · Enter selects · m enters a model ID".into();
                    self.open_drawer(p);
                }
            }
            "settings_applied" => {
                if let Some(mode) = p["team_mode"].as_str() {
                    self.team_mode = mode.into();
                }
                self.settings_pending = false;
                self.settings_form = None;
                self.settings_confirm = None;
                self.profile = s(&p, "profile").into();
                self.model = s(&p, "model").into();
                self.model_strategy = s(&p, "model_strategy").into();
                self.notice = format!(
                    "Selection applied · {} / {} · {} · {} team",
                    self.profile, self.model, self.model_strategy, self.team_mode
                );
            }
            "settings_failed" => {
                self.settings_pending = false;
                self.notice = format!("Settings not applied: {}", s(&p, "message"));
            }
            _ => {} // Forward-compatible with additional backend notifications.
        }
    }
    fn stream(&mut self, e: &Value) {
        match s(e, "type") {
            "runtime_event" => {
                let scope = &e["scope"];
                let root = scope["root?"]
                    .as_bool()
                    .unwrap_or(s(scope, "session_id") == self.session);
                if s(e, "durability") == "ephemeral" {
                    if root {
                        self.stream(&e["payload"]["data"]);
                    }
                    return;
                }
                if let Some(seq) = e["goal_seq"].as_u64() {
                    if seq <= self.cursor {
                        return;
                    }
                    self.cursor = seq;
                }
                let mut data = e["payload"]["data"].clone();
                data["_worker"] = e["scope"]["session_id"].clone();
                self.durable(s(&e["payload"], "type"), &data, root);
                self.events.push_back(e.clone());
                while self.events.len() > 1200 {
                    self.events.pop_front();
                }
            }
            "durable_event" => self.durable(s(&e["event"], "type"), &e["event"]["data"], true),
            "text_delta" => {
                self.signal("Receiving model response");
                let id = s(e, "response_id");
                let delta = clean(s(e, "delta"));
                if let Some(entry) = self
                    .entries
                    .iter_mut()
                    .rev()
                    .find(|entry| entry.response == id && entry.kind == "assistant")
                {
                    if entry.text.len() < 256_000 {
                        entry.text.push_str(&delta);
                    }
                    entry.streaming = true;
                } else {
                    self.entry("assistant", &delta);
                    if let Some(last) = self.entries.back_mut() {
                        last.response = id.into();
                        last.streaming = true;
                    }
                }
            }
            "response_finished" => {
                self.signal("Model response finished");
                for entry in &mut self.entries {
                    if entry.response == s(e, "response_id") {
                        entry.streaming = false;
                    }
                }
            }
            "reasoning_summary_delta" => {
                self.signal("Receiving reasoning summary");
                let id = format!(
                    "summary:{}:{}:{}",
                    s(e, "response_id"),
                    s(e, "item_id"),
                    e["summary_index"]
                );
                if let Some(entry) = self
                    .entries
                    .iter_mut()
                    .rev()
                    .find(|entry| entry.response == id)
                {
                    let remaining = 16_000usize.saturating_sub(entry.text.chars().count());
                    entry
                        .text
                        .extend(clean(s(e, "delta")).chars().take(remaining));
                } else {
                    self.entry(
                        "reasoning",
                        &s(e, "delta").chars().take(16_000).collect::<String>(),
                    );
                    self.entries.back_mut().unwrap().response = id;
                }
            }
            "command_output_delta" => {
                self.signal("Receiving command output");
                let delta: String = clean(s(e, "delta")).chars().take(8_192).collect();
                if let Some(entry) = self
                    .entries
                    .back_mut()
                    .filter(|entry| entry.kind == "command")
                {
                    if entry.text.len() < 16_000 {
                        entry.text.push_str(&delta);
                    }
                } else {
                    self.entry("command", &delta);
                }
            }
            _ => {}
        }
    }
    fn durable(&mut self, kind: &str, data: &Value, root: bool) {
        match kind {
            "tool_called" | "tool_result" => self.tool_event(kind, data, root),
            "work_planning_decided" if root => {
                self.entry("info", &format!("Team decision · {}", s(data, "reason")));
                self.signal("Planning work");
            }
            "automatic_helpers_decided" if root => {
                self.entry("info", &format!("Team · {}", s(data, "reason")));
            }
            "worker_queued" => {
                self.entry("info", "Subagent queued · waiting for worker capacity");
                self.signal("Waiting for worker capacity");
            }
            "work_run_started" => {
                let tasks = data.get("task_count").and_then(Value::as_u64).unwrap_or(0);
                let slots = data
                    .get("maximum_parallelism")
                    .and_then(Value::as_u64)
                    .unwrap_or(1);
                self.entry(
                    "info",
                    &format!("Team graph · {tasks} tasks · {slots} worker slots"),
                );
            }
            "worker_dequeued" => {
                self.signal("Worker capacity available · starting subagent");
            }
            "worker_queue_cancelled" => {
                self.signal("Queued subagent cancelled");
            }
            "resource_queued" => {
                self.signal("Waiting for runtime resource capacity");
            }
            "work_run_task_attempt_started" => {
                self.signal(&format!("Subagent started · {}", s(data, "task_id")));
            }
            "worker_stall_suspected" => {
                self.entry(
                    "info",
                    "No recent worker signal · waiting is not proof of a stall",
                );
            }
            "worker_progress_resumed" => {
                self.signal("Worker activity resumed");
            }
            "verification_started" => {
                self.signal("Running verification");
            }
            "verification_finished" => {
                self.signal("Verification finished · inspect results");
            }
            "model_route_selected" if root => {
                self.entry("info", &format!("Model choice · {}", s(data, "reason")));
            }
            "model_response_started" if root => {
                self.signal("Waiting for provider");
            }
            "command_output_delta" => {
                self.signal("Receiving command output");
            }
            _ => {}
        }
        if kind == "assistant_message" && root && !s(data, "content").is_empty() {
            let content = clean(s(data, "content"));
            if let Some(last) = self
                .entries
                .iter_mut()
                .rev()
                .find(|e| e.kind == "assistant" || e.kind == "user")
                .filter(|e| e.kind == "assistant")
                && (last.streaming || last.text == content)
            {
                last.text = content;
                last.streaming = false;
                return;
            }
            self.entry("assistant", &content);
        }
        if kind == "user_message"
            && root
            && !s(data, "content").is_empty()
            && !self
                .entries
                .back()
                .is_some_and(|e| e.kind == "user" && e.text == s(data, "content"))
        {
            self.entry("user", s(data, "content"));
        }
        if kind == "model_response_started" && root {
            self.model = s(data, "model").into();
            self.profile = s(data, "provider_profile").into();
        }
    }

    fn signal(&mut self, activity: &str) {
        self.activity = clean(activity);
        self.last_activity = Some(Instant::now());
    }

    fn tool_event(&mut self, kind: &str, data: &Value, root: bool) {
        let worker = if s(data, "_worker").is_empty() {
            self.session.as_str()
        } else {
            s(data, "_worker")
        };
        let id = format!("{worker}:{}", s(data, "tool_call_id"));
        let name = s(data, "name");
        let label = if root {
            name.to_owned()
        } else {
            format!("subagent · {name}")
        };
        if kind == "tool_called" {
            let args = &data["arguments"];
            let target = ["path", "command", "query"]
                .iter()
                .find_map(|key| args[*key].as_str())
                .unwrap_or("");
            let target: String = clean(target).chars().take(240).collect();
            let label = format!("{label} {target}");
            self.signal(&format!("Running {label}"));
            self.entry("tool", &format!("… {label}"));
            self.entries.back_mut().unwrap().response = id.clone();
            if self.active_tools.len() < 128 {
                self.active_tools.push((id, Instant::now()));
            }
        } else {
            self.tool_count += 1;
            let elapsed = self
                .active_tools
                .iter()
                .position(|(key, _)| key == &id)
                .map(|i| self.active_tools.remove(i).1.elapsed().as_secs_f64());
            let failed =
                data["is_error"] == true || (!data["error"].is_null() && data["error"] != false);
            let mark = if failed { "!" } else { "✓" };
            let duration = elapsed.map(|s| format!(" · {s:.1}s")).unwrap_or_default();
            let result = if failed && !data["error"].is_null() {
                &data["error"]
            } else {
                &data["content"]
            };
            let detail = result
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| result.to_string());
            let detail: String = clean(&detail).chars().take(8_000).collect();
            if let Some(entry) = self
                .entries
                .iter_mut()
                .rev()
                .find(|e| e.kind == "tool" && e.response == id)
            {
                let title = entry
                    .text
                    .lines()
                    .next()
                    .unwrap_or("")
                    .trim_start_matches("… ");
                entry.text = format!("{mark} {title}{duration}\n{detail}");
            } else {
                self.entry("tool", &format!("{mark} {label}{duration}\n{detail}"));
            }
            self.signal(if self.active_tools.is_empty() {
                "Waiting for provider"
            } else {
                "Tools running"
            });
        }
    }
    pub fn matches(&self) -> Vec<String> {
        if self.dismiss_picker {
            return vec![];
        }
        self.editor
            .reference()
            .map(|(_, q)| {
                self.files
                    .iter()
                    .filter(|p| {
                        !p.contains(['"', '\n']) && p.to_lowercase().contains(&q.to_lowercase())
                    })
                    .take(30)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default()
    }
    pub fn palette_items(&self) -> Vec<&'static str> {
        COMMANDS
            .iter()
            .copied()
            .chain(["history", "output", "copy"])
            .filter(|c| c.contains(&self.palette_query.to_lowercase()))
            .collect()
    }
    pub fn rows(&self) -> Vec<Value> {
        let Some(d) = &self.drawer else { return vec![] };
        match s(d, "type") {
            "models" => array(d, "endpoints"),
            "sessions" => array(d, "sessions"),
            "files" => array(d, "changed"),
            "provider_picker" => array(d, "providers"),
            "provider_settings" => array(d, "providers"),
            "provider_kind_picker" => array(d, "kinds"),
            "model_catalog" if d["combined"] == true => {
                let mut rows = vec![json!({"automatic":true})];
                rows.extend(array(d, "models").into_iter().filter(|row| {
                    format!(
                        "{} {} {}",
                        s(row, "profile"),
                        s(row, "provider"),
                        s(row, "model")
                    )
                    .to_lowercase()
                    .contains(&self.model_query.to_lowercase())
                }));
                rows
            }
            "model_catalog" => array(d, "models"),
            "events" => array(d, "events"),
            "output_picker" => array(d, "outputs"),
            "prompt_history" => self
                .prompt_history
                .iter()
                .enumerate()
                .rev()
                .filter(|(_, p)| {
                    p.to_lowercase()
                        .contains(&self.history_query.to_lowercase())
                })
                .map(|(i, p)| json!({"prompt":p,"history_index":i}))
                .collect(),
            _ => vec![],
        }
    }
    fn clamp_selection(&mut self) {
        self.selection = self.selection.min(self.workers.len().saturating_sub(1));
    }
    fn remember_prompt(&mut self, prompt: &str) {
        if !prompt.trim().is_empty() && self.prompt_history.back().is_none_or(|p| p != prompt) {
            self.prompt_history.push_back(prompt.to_owned());
            if self.prompt_history.len() > 200 {
                self.prompt_history.pop_front();
            }
        }
    }
    pub fn leave_history(&mut self) {
        self.history_index = None;
        self.history_draft = None;
    }
    fn recall_prompt(&mut self, index: usize) {
        if let Some(prompt) = self.prompt_history.get(index) {
            if self.history_draft.is_none() {
                self.history_draft = Some(self.editor.clone());
            }
            self.editor.set(prompt);
            self.history_index = Some(index);
            self.dismiss_picker = true;
            self.notice =
                "History draft · edit or Enter to send · Down returns to your draft".into();
        }
    }
    fn history_step(&mut self, older: bool) {
        let next = if older {
            self.history_index
                .unwrap_or(self.prompt_history.len())
                .checked_sub(1)
        } else {
            self.history_index.map(|i| i + 1)
        };
        if let Some(index) = next {
            if index < self.prompt_history.len() {
                self.recall_prompt(index);
            } else if let Some(draft) = self.history_draft.take() {
                self.editor = draft;
                self.history_index = None;
                self.notice = "Original draft restored".into();
            }
        }
    }
    pub fn slash_query(&self) -> Option<&str> {
        if self.dismiss_picker || !self.editor.text.starts_with('/') || self.editor.cursor == 0 {
            return None;
        }
        let query = &self.editor.text[1..self.editor.cursor];
        (!query.contains(char::is_whitespace)).then_some(query)
    }
    pub fn slash_matches(&self) -> Vec<&'static str> {
        let Some(query) = self.slash_query() else {
            return vec![];
        };
        COMMANDS
            .iter()
            .copied()
            .chain([
                "help", "history", "output", "copy", "attach", "detach", "resume", "steer",
                "cancel", "quit",
            ])
            .filter(|c| c.starts_with(&query.to_lowercase()))
            .collect()
    }
    fn complete_command(&mut self, name: &str) {
        let end = self
            .editor
            .text
            .find(char::is_whitespace)
            .unwrap_or(self.editor.text.len());
        self.editor.text.replace_range(..end, &format!("/{name}"));
        self.editor.cursor = name.len() + 1;
        if self.editor.text.len() == self.editor.cursor {
            self.editor.insert(" ");
        }
        self.dismiss_picker = true;
        self.command_index = 0;
    }
    fn open_drawer(&mut self, value: Value) {
        if let Some(previous) = self.drawer.take() {
            self.drawer_stack
                .push((previous, self.selection, self.drawer_scroll));
        }
        self.drawer = Some(value);
        self.selection = 0;
        self.drawer_scroll = 0;
    }
    fn open_history(&mut self) {
        self.history_query.clear();
        self.open_drawer(json!({"type":"prompt_history"}));
    }
    fn open_output(&mut self) {
        let outputs: Vec<_> = self
            .entries
            .iter()
            .rev()
            .filter(|e| e.kind != "user")
            .map(|e| json!({"type":"output_detail","kind":e.kind,"content":e.text}))
            .collect();
        self.open_drawer(json!({"type":"output_picker","outputs":outputs}));
    }
    pub fn poll_catalog(&mut self) -> bool {
        let refreshing = self.drawer.as_ref().is_some_and(|d| {
            s(d, "type") == "model_catalog" && d["combined"] == true && d["refreshing"] == true
        });
        if refreshing && !self.busy && !self.settings_pending && self.connected && !self.demo {
            self.request_settings(json!({"action":"catalog"}));
            true
        } else {
            false
        }
    }
    fn request_settings(&mut self, mut request: Value) {
        if !self.initialized || !self.connected || self.settings_pending {
            self.notice = "Wait for the runtime/settings request".into();
            return;
        }
        if self.demo {
            self.notice = "DEMO · settings are read-only".into();
            return;
        }
        request["type"] = json!("provider_settings");
        self.settings_pending = true;
        self.notice = "Checking provider settings…".into();
        self.outgoing.push(request);
    }
    fn provider_form(&mut self, row: &Value, editing: bool) {
        let mut fields = vec![];
        for key in ["profile", "model", "base_url", "api_key_env", "auth_mode"] {
            if (editing && key == "profile") || (!editing && key == "model") {
                continue;
            }
            let mut editor = Editor::default();
            editor.set(if key == "auth_mode" && s(row, key).is_empty() {
                "environment"
            } else {
                s(row, key)
            });
            fields.push((key.to_owned(), editor));
        }
        self.settings_form = Some(SettingsForm {
            title: if editing {
                "EDIT PROVIDER"
            } else {
                "NEW PROVIDER"
            }
            .into(),
            action: "save".into(),
            profile: s(row, "profile").into(),
            provider: s(row, "provider").into(),
            revision: s(&self.settings, "revision").into(),
            editing,
            fields,
            index: 0,
        });
    }
    fn selection_form(&mut self, profile: &str, model: &str, revision: &str) {
        let mut value = Editor::default();
        value.set(model);
        let mut strategy = Editor::default();
        strategy.set("manual");
        let mut team = Editor::default();
        team.set(&self.team_mode);
        self.settings_form = Some(SettingsForm {
            title: "SAVE & USE MODEL".into(),
            action: "select".into(),
            profile: profile.into(),
            provider: String::new(),
            revision: revision.into(),
            editing: true,
            fields: vec![
                ("model".into(), value),
                ("strategy".into(), strategy),
                ("team_mode".into(), team),
            ],
            index: 0,
        });
    }
    fn form_key(&mut self, k: KeyEvent) {
        if self.settings_pending {
            return;
        }
        if k.code == KeyCode::Esc {
            self.settings_form = None;
            return;
        }
        let form = self.settings_form.as_mut().unwrap();
        if k.modifiers.contains(KeyModifiers::CONTROL) && k.code == KeyCode::Char('s') {
            let fields: serde_json::Map<String, Value> = form
                .fields
                .iter()
                .map(|(key, e)| (key.clone(), json!(e.text)))
                .collect();
            let mut request = json!({"action":form.action,"profile":form.profile,"revision":form.revision,"editing":form.editing});
            if form.action == "select" {
                request["model"] = fields["model"].clone();
                request["strategy"] = fields["strategy"].clone();
                request["team_mode"] = fields["team_mode"].clone();
            } else {
                let mut fields = fields;
                if !form.editing {
                    request["profile"] = fields.remove("profile").unwrap_or_default();
                }
                fields.insert("provider".into(), json!(form.provider));
                request["fields"] = Value::Object(fields);
            }
            self.request_settings(request);
            return;
        }
        match k.code {
            KeyCode::Tab | KeyCode::Down | KeyCode::Enter => {
                form.index = (form.index + 1) % form.fields.len()
            }
            KeyCode::BackTab | KeyCode::Up => {
                form.index = (form.index + form.fields.len() - 1) % form.fields.len()
            }
            KeyCode::Left => form.fields[form.index].1.left(),
            KeyCode::Right => form.fields[form.index].1.right(),
            KeyCode::Home => form.fields[form.index].1.home(),
            KeyCode::End => form.fields[form.index].1.end(),
            KeyCode::Backspace => form.fields[form.index].1.backspace(),
            KeyCode::Delete => form.fields[form.index].1.delete(),
            KeyCode::Char('u') if k.modifiers.contains(KeyModifiers::CONTROL) => {
                form.fields[form.index].1.set("")
            }
            KeyCode::Char(c)
                if !k
                    .modifiers
                    .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
            {
                form.fields[form.index].1.insert(&c.to_string())
            }
            _ => {}
        }
    }
    pub fn copy_output(&mut self, all: bool) {
        let content = if all {
            self.entries
                .iter()
                .map(|e| format!("{}\n{}", e.kind.to_uppercase(), e.text))
                .collect::<Vec<_>>()
                .join("\n\n")
        } else if let Some(d) = &self.drawer {
            let rows = self.rows();
            let value = rows.get(self.selection).unwrap_or(d);
            match s(value, "type") {
                "output_detail" => s(value, "content").to_owned(),
                "diff" => s(value, "raw_patch").to_owned(),
                "panel" => array(value, "lines")
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join("\n"),
                _ => serde_json::to_string_pretty(value).unwrap_or_default(),
            }
        } else if self.view == View::Swarm {
            self.workers
                .get(self.selection)
                .map(|w| serde_json::to_string_pretty(w).unwrap_or_default())
                .unwrap_or_default()
        } else if self.view == View::Ledger {
            self.events
                .iter()
                .rev()
                .nth(self.selection)
                .map(|e| serde_json::to_string_pretty(e).unwrap_or_default())
                .unwrap_or_default()
        } else {
            self.entries
                .iter()
                .rev()
                .find(|e| e.kind != "user")
                .map(|e| e.text.clone())
                .unwrap_or_default()
        };
        if content.is_empty() {
            self.notice = "Nothing to copy yet · /output browses earlier output".into();
        } else {
            self.clipboard = Some(content);
            self.notice = "Copying output…".into();
        }
    }
    pub fn key(&mut self, k: KeyEvent) {
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        if ctrl
            && k.code == KeyCode::Char('t')
            && self.settings_form.is_none()
            && self.approvals.is_empty()
        {
            self.expand_tools = !self.expand_tools;
            return;
        }
        if ctrl && k.code == KeyCode::Char('q') {
            self.quit = true;
            return;
        }
        if ctrl && k.code == KeyCode::Char('y') {
            if self.settings_form.is_some() {
                self.notice = "Close the settings form before copying output".into();
                return;
            }
            if let Some(approval) = self.approvals.front() {
                self.clipboard = serde_json::to_string_pretty(approval).ok();
            } else {
                self.copy_output(false);
            }
            return;
        }
        if !self.approvals.is_empty() {
            match k.code {
                KeyCode::PageDown | KeyCode::Down => {
                    self.approval_scroll = self.approval_scroll.saturating_add(1);
                    return;
                }
                KeyCode::PageUp | KeyCode::Up => {
                    self.approval_scroll = self.approval_scroll.saturating_sub(1);
                    return;
                }
                _ => {}
            }
            if self.resolving.is_some() {
                return;
            }
            match k.code {
                KeyCode::Left => self.approval_choice = self.approval_choice.saturating_sub(1),
                KeyCode::Right => self.approval_choice = (self.approval_choice + 1).min(2),
                KeyCode::Esc => self.approval_choice = 0,
                KeyCode::Enter if self.connected => {
                    let id = s(&self.approvals[0], "approval_id").to_owned();
                    let decision = ["deny", "allow_once", "allow_always"][self.approval_choice];
                    self.outgoing
                        .push(json!({"type":"approval","approval_id":id,"decision":decision}));
                    self.resolving = Some(id);
                }
                _ => {}
            }
            return;
        }
        if let Some(worker) = self.confirm_cancel.clone() {
            if k.code == KeyCode::Enter && self.connected {
                self.outgoing.push(command("cancel_worker", &worker));
                self.confirm_cancel = None;
            }
            if k.code == KeyCode::Esc {
                self.confirm_cancel = None;
            }
            return;
        }
        if self.settings_form.is_some() {
            self.form_key(k);
            return;
        }
        if let Some(request) = self.settings_confirm.clone() {
            if !self.settings_pending {
                match k.code {
                    KeyCode::Esc => self.settings_confirm = None,
                    KeyCode::Enter => self.request_settings(request),
                    _ => {}
                }
            }
            return;
        }
        if ctrl && k.code == KeyCode::Char('p') {
            self.palette = !self.palette;
            self.palette_query.clear();
            self.palette_index = 0;
            return;
        }
        if ctrl && k.code == KeyCode::Char('r') && !self.palette {
            self.open_history();
            return;
        }
        if self.palette {
            match k.code {
                KeyCode::Esc => self.palette = false,
                KeyCode::Char(c) if !ctrl => {
                    self.palette_query.push(c);
                    self.palette_index = 0;
                }
                KeyCode::Backspace => {
                    self.palette_query.pop();
                    self.palette_index = 0;
                }
                KeyCode::Up => self.palette_index = self.palette_index.saturating_sub(1),
                KeyCode::Down => {
                    self.palette_index =
                        (self.palette_index + 1).min(self.palette_items().len().saturating_sub(1))
                }
                KeyCode::Enter => {
                    if let Some(cmd) = self.palette_items().get(self.palette_index).copied() {
                        self.palette = false;
                        if cmd == "history" {
                            self.open_history();
                        } else if cmd == "output" {
                            self.open_output();
                        } else if cmd == "copy" {
                            self.copy_output(false);
                        } else if ["race", "tournament"].contains(&cmd) {
                            self.editor.set(&format!("/{cmd} "));
                            self.view = View::Mission;
                        } else {
                            self.dispatch(cmd, "");
                        }
                    }
                }
                _ => {}
            }
            return;
        }
        if self.drawer.is_some() {
            if let Some(d) = &self.drawer
                && d["mission_actions"].is_array()
            {
                let action = match k.code {
                    KeyCode::Char('s') => "start",
                    KeyCode::Char('p') => "pause",
                    KeyCode::Char('r') => "resume",
                    KeyCode::Char('d') => "dismiss",
                    KeyCode::Char('x') => "stop",
                    KeyCode::Char('X') => "delete",
                    KeyCode::Char('f') => "status",
                    _ => "",
                };
                if !action.is_empty() {
                    if action == "status"
                        || array(d, "mission_actions")
                            .iter()
                            .any(|v| v.as_str() == Some(action))
                    {
                        self.outgoing.push(command("mission", action));
                    }
                    return;
                }
            }
            let kind = self
                .drawer
                .as_ref()
                .map(|d| s(d, "type"))
                .unwrap_or("")
                .to_owned();
            let combined = kind == "model_catalog"
                && self.drawer.as_ref().is_some_and(|d| d["combined"] == true);
            if combined && self.model_searching {
                match k.code {
                    KeyCode::Esc | KeyCode::Enter => self.model_searching = false,
                    KeyCode::Backspace => {
                        self.model_query.pop();
                        self.selection = 0;
                    }
                    KeyCode::Char(c) if !ctrl => {
                        self.model_query.push(c);
                        self.selection = 0;
                    }
                    _ => {}
                }
                return;
            }
            if combined {
                let revision = self.drawer.as_ref().unwrap()["revision"].clone();
                match k.code {
                    KeyCode::Char('/') => {
                        self.model_searching = true;
                        return;
                    }
                    KeyCode::Char('p') => {
                        self.request_settings(json!({"action":"list"}));
                        return;
                    }
                    KeyCode::Char('r') => {
                        self.request_settings(json!({"action":"refresh_catalog"}));
                        return;
                    }
                    KeyCode::Enter => {
                        if let Some(row) = self.rows().get(self.selection).cloned() {
                            if row["automatic"] == true {
                                self.request_settings(
                                    json!({"action":"automatic","revision":revision}),
                                );
                            } else if row["enabled"] == false
                                || row["selectable"] == false
                                || s(&row, "health") == "unavailable"
                            {
                                self.notice =
                                    "This model is unavailable · check its provider or refresh"
                                        .into();
                            } else {
                                self.request_settings(json!({"action":"lock","profile":row["profile"],"model":row["model"],"revision":revision}));
                            }
                        }
                        return;
                    }
                    _ => {}
                }
            }
            if kind == "models" && k.code == KeyCode::Char('p') {
                self.request_settings(json!({"action":"list"}));
                return;
            }
            if kind == "provider_settings" {
                let selected = self.rows().get(self.selection).cloned();
                match k.code {
                    KeyCode::Char('n') => {
                        self.open_drawer(
                            json!({"type":"provider_kind_picker","kinds":self.settings["kinds"]}),
                        );
                        return;
                    }
                    KeyCode::Char('e') => {
                        if let Some(row) = selected {
                            self.provider_form(&row, true);
                        }
                        return;
                    }
                    KeyCode::Char('r') => {
                        self.request_settings(json!({"action":"list"}));
                        return;
                    }
                    KeyCode::Char(' ') => {
                        if let Some(row) = selected {
                            self.request_settings(json!({"action":"toggle","profile":row["profile"],"revision":self.settings["revision"]}));
                        }
                        return;
                    }
                    KeyCode::Char('u') => {
                        if let Some(row) = selected {
                            let revision = s(&self.settings, "revision").to_owned();
                            self.selection_form(s(&row, "profile"), s(&row, "model"), &revision);
                        }
                        return;
                    }
                    KeyCode::Char('x') => {
                        if let Some(row) = selected {
                            self.settings_confirm = Some(
                                json!({"action":"delete","profile":row["profile"],"revision":self.settings["revision"],"confirmed":true}),
                            );
                        }
                        return;
                    }
                    KeyCode::Char('l') => {
                        if let Some(row) = selected {
                            self.dispatch("connect", &format!("profile:{}", s(&row, "profile")));
                        }
                        return;
                    }
                    _ => {}
                }
            }
            if kind == "model_catalog" && !combined && k.code == KeyCode::Char('m') {
                let d = self.drawer.clone().unwrap();
                self.selection_form(
                    s(&d, "profile"),
                    s(&d, "configured_model"),
                    s(&d, "revision"),
                );
                return;
            }
            let row_count = self.rows().len();
            let history = self
                .drawer
                .as_ref()
                .is_some_and(|d| s(d, "type") == "prompt_history");
            match k.code {
                KeyCode::Esc => {
                    if let Some((value, selection, scroll)) = self.drawer_stack.pop() {
                        self.drawer = Some(value);
                        self.selection = selection;
                        self.drawer_scroll = scroll;
                    } else {
                        self.drawer = None;
                        self.selection = 0;
                    }
                }
                KeyCode::Down => {
                    if row_count > 0 {
                        self.selection = (self.selection + 1).min(row_count - 1);
                    } else {
                        self.drawer_scroll = self.drawer_scroll.saturating_add(1);
                    }
                }
                KeyCode::Up => {
                    if row_count > 0 {
                        self.selection = self.selection.saturating_sub(1);
                    } else {
                        self.drawer_scroll = self.drawer_scroll.saturating_sub(1);
                    }
                }
                KeyCode::PageDown if row_count > 0 => {
                    self.selection = (self.selection + 10).min(row_count - 1)
                }
                KeyCode::PageUp if row_count > 0 => {
                    self.selection = self.selection.saturating_sub(10)
                }
                KeyCode::PageDown => self.drawer_scroll = self.drawer_scroll.saturating_add(10),
                KeyCode::PageUp => self.drawer_scroll = self.drawer_scroll.saturating_sub(10),
                KeyCode::Home => {
                    self.selection = 0;
                    self.drawer_scroll = 0;
                }
                KeyCode::End if row_count > 0 => self.selection = row_count - 1,
                KeyCode::Char(c) if history && !ctrl => {
                    self.history_query.push(c);
                    self.selection = 0;
                    self.drawer_scroll = 0;
                }
                KeyCode::Backspace if history => {
                    self.history_query.pop();
                    self.selection = 0;
                    self.drawer_scroll = 0;
                }
                KeyCode::Enter => {
                    if let Some(row) = self.rows().get(self.selection) {
                        if history {
                            if let Some(index) = row["history_index"].as_u64() {
                                self.recall_prompt(index as usize);
                            }
                            self.drawer = None;
                            self.drawer_stack.clear();
                            self.view = View::Mission;
                            return;
                        }
                        let kind = s(self.drawer.as_ref().unwrap(), "type");
                        if kind == "provider_kind_picker" {
                            self.provider_form(row, false);
                            return;
                        }
                        if kind == "models" || kind == "provider_settings" {
                            let profile = if kind == "models" {
                                s(row, "id")
                            } else {
                                s(row, "profile")
                            };
                            self.request_settings(json!({"action":"catalog","profile":profile}));
                            return;
                        }
                        if kind == "model_catalog" {
                            let d = self.drawer.clone().unwrap();
                            self.selection_form(
                                s(&d, "profile"),
                                s(row, "model"),
                                s(&d, "revision"),
                            );
                            return;
                        }
                        let cmd = match kind {
                            "models" => "models",
                            "files" => "files",
                            "sessions" => "sessions",
                            "provider_picker" => "connect",
                            _ => "",
                        };
                        let query = match kind {
                            "files" => s(row, "path").to_owned(),
                            "sessions" => s(row, "session_id").to_owned(),
                            "provider_picker" => format!("profile:{}", s(row, "profile")),
                            _ => s(row, "id").to_owned(),
                        };
                        if ["models", "events", "output_picker"].contains(&kind) {
                            self.open_drawer(row.clone());
                            return;
                        }
                        if !cmd.is_empty() && !query.is_empty() {
                            self.dispatch(cmd, &query);
                        }
                    }
                }
                KeyCode::Char('r')
                    if self
                        .drawer
                        .as_ref()
                        .is_some_and(|d| s(d, "type") == "session_detail") =>
                {
                    let id = s(self.drawer.as_ref().unwrap(), "session_id").to_owned();
                    self.dispatch("resume", &id);
                }
                _ => {}
            }
            return;
        }
        if let KeyCode::F(n @ 1..=3) = k.code {
            self.view = [View::Mission, View::Swarm, View::Ledger][(n - 1) as usize];
            self.selection = 0;
            return;
        }
        if ctrl && k.code == KeyCode::Char('c') {
            if self.busy && self.connected {
                self.outgoing.push(json!({"type":"cancel"}));
                self.notice = "Requesting cancellation…".into();
            } else {
                self.editor.set("");
                self.leave_history();
            }
            return;
        }
        if ctrl && k.code == KeyCode::Char('x') && self.view == View::Swarm {
            self.confirm_cancel = self
                .workers
                .get(self.selection)
                .map(|w| s(w, "worker_id").to_owned());
            return;
        }
        if self.view != View::Mission {
            let count = if self.view == View::Swarm {
                self.workers.len()
            } else {
                self.events.len()
            };
            match k.code {
                KeyCode::Up => self.selection = self.selection.saturating_sub(1),
                KeyCode::Down => self.selection = (self.selection + 1).min(count.saturating_sub(1)),
                KeyCode::Enter => {
                    self.drawer = if self.view == View::Swarm {
                        self.workers.get(self.selection).cloned()
                    } else {
                        self.events.iter().rev().nth(self.selection).cloned()
                    };
                    self.drawer_scroll = 0;
                }
                KeyCode::Esc => self.view = View::Mission,
                _ => {}
            }
            return;
        }
        let commands = self.slash_matches();
        if !commands.is_empty() {
            let selected = commands[self.command_index.min(commands.len() - 1)];
            match k.code {
                KeyCode::Down => {
                    self.command_index = (self.command_index + 1).min(commands.len() - 1);
                    return;
                }
                KeyCode::Up => {
                    self.command_index = self.command_index.saturating_sub(1);
                    return;
                }
                KeyCode::Tab => {
                    self.complete_command(selected);
                    return;
                }
                KeyCode::Enter
                    if k.modifiers.is_empty() && self.slash_query() != Some(selected) =>
                {
                    self.complete_command(selected);
                    return;
                }
                KeyCode::Esc => {
                    self.dismiss_picker = true;
                    return;
                }
                _ => {}
            }
        }
        let matches = self.matches();
        if !matches.is_empty() {
            match k.code {
                KeyCode::Down => {
                    self.picker_index = (self.picker_index + 1).min(matches.len() - 1);
                    return;
                }
                KeyCode::Up => {
                    self.picker_index = self.picker_index.saturating_sub(1);
                    return;
                }
                KeyCode::Tab | KeyCode::Enter if k.modifiers.is_empty() => {
                    self.editor
                        .insert_reference(&matches[self.picker_index.min(matches.len() - 1)]);
                    self.picker_index = 0;
                    return;
                }
                KeyCode::Esc => {
                    self.dismiss_picker = true;
                    return;
                }
                _ => {}
            }
        }
        match k.code {
            KeyCode::Enter
                if k.modifiers.contains(KeyModifiers::ALT)
                    || k.modifiers.contains(KeyModifiers::SHIFT) =>
            {
                self.editor.insert("\n")
            }
            KeyCode::Enter => self.submit(),
            KeyCode::Char('j') if ctrl => self.editor.insert("\n"),
            KeyCode::Char('a') if ctrl => self.editor.home(),
            KeyCode::Char('e') if ctrl => self.editor.end(),
            KeyCode::Char(c) if !ctrl && !k.modifiers.contains(KeyModifiers::ALT) => {
                self.leave_history();
                self.editor.insert(&c.to_string());
                self.dismiss_picker = false;
                self.picker_index = 0;
                self.command_index = 0;
            }
            KeyCode::Backspace => {
                self.leave_history();
                self.editor.backspace();
                self.dismiss_picker = false;
                self.picker_index = 0;
                self.command_index = 0;
            }
            KeyCode::Delete => self.editor.delete(),
            KeyCode::Left => self.editor.left(),
            KeyCode::Right => self.editor.right(),
            KeyCode::Home => self.editor.home(),
            KeyCode::End => self.editor.end(),
            KeyCode::Up
                if self.history_index.is_some()
                    || !self.editor.text[..self.editor.cursor].contains('\n') =>
            {
                self.history_step(true)
            }
            KeyCode::Down
                if self.history_index.is_some()
                    || !self.editor.text[self.editor.cursor..].contains('\n') =>
            {
                self.history_step(false)
            }
            KeyCode::Up => self.editor.vertical(false),
            KeyCode::Down => self.editor.vertical(true),
            KeyCode::PageUp => {
                self.following = false;
                self.scroll = self.scroll.saturating_sub(8);
            }
            KeyCode::PageDown => {
                self.scroll = self.scroll.saturating_add(8);
            }
            KeyCode::Esc => {
                self.following = true;
                self.dismiss_picker = true;
            }
            _ => {}
        }
    }
    fn submit(&mut self) {
        if !self.initialized || !self.connected || self.pending || self.settings_pending {
            self.notice = "Waiting for the runtime · draft preserved".into();
            return;
        }
        let text = self.editor.text.trim().to_owned();
        if text.is_empty() {
            return;
        }
        if let Some(rest) = text.strip_prefix('/') {
            let (name, query) = rest.split_once(char::is_whitespace).unwrap_or((rest, ""));
            if name == "history" {
                self.editor.set("");
                self.open_history();
            } else if name == "output" {
                self.open_output();
            } else if name == "copy" {
                if !query.is_empty() && query.trim() != "all" {
                    self.notice =
                        "Use /copy for latest output or /copy all for the transcript".into();
                    return;
                }
                self.copy_output(query.trim() == "all");
            } else if name == "help" {
                self.drawer = Some(
                    json!({"type":"panel","title":"KEYMAP / FIELD MANUAL","lines":["F1 mission · F2 actors · F3 ledger","Enter send / steer · Ctrl+J newline · bracketed paste stays a draft","@path selects a repository reference; Enter selects before submitting","/prefix offers commands; Tab or Enter completes a partial command without executing","Up/Down recall prompts at draft boundaries; Ctrl+R searches history","Mouse drag selects in the terminal; Ctrl+Y copies output or the inspected record · /output browses older output · /copy all copies the transcript","Ctrl+P command palette · /race GOAL · /tournament GOAL","/models /files /sessions /connect /auto /verify /new","Ctrl+C cancel active turn · F2 then Ctrl+X cancel selected actor","Approvals default to deny; arrows choose; Enter requests; runtime acknowledges","PageUp/PageDown scroll · Esc return to live · Ctrl+Q exit","/attach PATH imports a PNG/JPEG/GIF/WebP file; /detach ID removes it","Auto mode and model settings remain runtime-owned"]}),
                );
            } else if name == "quit" {
                self.quit = true;
            } else if name == "cancel" {
                self.outgoing.push(json!({"type":"cancel"}));
            } else if name == "attach" {
                self.attach(query);
            } else if name == "detach" {
                self.outgoing
                    .push(json!({"type":"attachment_delete","attachment_id":query}));
            } else if COMMANDS.contains(&name) || ["resume", "steer"].contains(&name) {
                if self.busy && ["new", "resume", "race", "tournament", "connect"].contains(&name) {
                    self.notice =
                        "Finish or cancel the current turn first · draft preserved".into();
                    return;
                }
                self.dispatch(name, query);
            } else {
                self.notice = format!("Unknown command /{name} · Ctrl+P opens the palette");
                return;
            }
        } else if self.busy {
            self.remember_prompt(&text);
            self.outgoing.push(command("steer", &text));
            self.notice = "Steering sent to the active owner".into();
        } else {
            self.remember_prompt(&text);
            self.outgoing
                .push(json!({"type":"submit","prompt":text,"attachments":self.attachments}));
            self.last_submission = text;
            self.pending = true;
            self.notice = "Submitting to the runtime…".into();
        }
        self.editor.set("");
        self.leave_history();
        self.following = true;
    }
    fn dispatch(&mut self, name: &str, query: &str) {
        if name == "providers" {
            self.request_settings(json!({"action":"list"}));
            return;
        }
        if !self.initialized || !self.connected {
            self.notice = "Runtime not connected".into();
            return;
        }
        if self.busy && ["new", "resume", "race", "tournament", "connect"].contains(&name) {
            self.notice = "Finish or cancel the current turn first".into();
            return;
        }
        if name == "tree" {
            self.view = View::Swarm;
        }
        self.outgoing.push(command(name, query));
        self.notice = format!("Requested {name} · waiting for runtime");
    }
    fn attach(&mut self, path: &str) {
        use base64::Engine;
        use std::io::Read;
        let path = path.trim().trim_matches('"');
        let mime = match path
            .rsplit('.')
            .next()
            .unwrap_or("")
            .to_lowercase()
            .as_str()
        {
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "gif" => "image/gif",
            "webp" => "image/webp",
            _ => {
                self.notice = "Attach a PNG, JPEG, GIF or WebP file".into();
                return;
            }
        };
        let result = std::fs::metadata(path).and_then(|m| {
            if !m.is_file() {
                Err(std::io::Error::other("attachment must be a regular file"))
            } else if m.len() > 10 * 1024 * 1024 {
                Err(std::io::Error::other("image exceeds 10 MiB"))
            } else {
                let mut bytes = Vec::new();
                std::fs::File::open(path)?
                    .take(10 * 1024 * 1024 + 1)
                    .read_to_end(&mut bytes)?;
                if bytes.len() > 10 * 1024 * 1024 {
                    Err(std::io::Error::other("image exceeds 10 MiB"))
                } else {
                    Ok(bytes)
                }
            }
        });
        match result {
            Ok(bytes) => self.outgoing.push(json!({
                "type": "attachment_import",
                "data": base64::engine::general_purpose::STANDARD.encode(bytes),
                "mime_type": mime,
                "name": std::path::Path::new(path).file_name().unwrap_or_default().to_string_lossy(),
                "provenance": "upload"
            })),
            Err(e) => self.notice = format!("Attachment not imported: {e}"),
        }
    }
}
