use crate::editor::{Editor, clean};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::{Value, json};
use std::collections::VecDeque;

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
    "models",
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
        self.resolving = None;
        self.notice = format!("Bridge disconnected · {reason}. Draft preserved; Ctrl+Q exits.");
    }
    pub fn send_failed(&mut self, packet: &Value, reason: &str) {
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
    pub fn apply(&mut self, p: Value) {
        match s(&p, "type") {
            "init" => {
                self.initialized = true;
                self.session = s(&p, "session_id").into();
                self.workspace = s(&p, "workspace").into();
                self.profile = s(&p, "profile").into();
                self.model = s(&p, "model").into();
                self.approval_mode = s(&p, "approval_mode").into();
                self.cursor = p["cursor"].as_u64().unwrap_or(0);
                self.entries.clear();
                for e in array(&p, "entries") {
                    self.entry(
                        s(&e, "kind"),
                        if s(&e, "content").is_empty() {
                            s(&e, "name")
                        } else {
                            s(&e, "content")
                        },
                    );
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
            }
            "attachment_imported" => {
                self.attachments.push(p["attachment"].clone());
                self.notice = "Attachment ready · included with next submission".into();
            }
            "attachment_deleted" => self
                .attachments
                .retain(|a| s(a, "id") != s(&p, "attachment_id")),
            "session_changed" => {
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
            "models" | "files" | "sessions" | "diff" | "session_detail" | "panel" | "events"
            | "provider_picker" => {
                self.drawer = Some(p);
                self.drawer_scroll = 0;
                self.selection = 0;
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
                self.durable(s(&e["payload"], "type"), &e["payload"]["data"], root);
                self.events.push_back(e.clone());
                while self.events.len() > 1200 {
                    self.events.pop_front();
                }
            }
            "durable_event" => self.durable(s(&e["event"], "type"), &e["event"]["data"], true),
            "text_delta" => {
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
                for entry in &mut self.entries {
                    if entry.response == s(e, "response_id") {
                        entry.streaming = false;
                    }
                }
            }
            _ => {}
        }
    }
    fn durable(&mut self, kind: &str, data: &Value, root: bool) {
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
            "events" => array(d, "events"),
            _ => vec![],
        }
    }
    fn clamp_selection(&mut self) {
        self.selection = self.selection.min(self.workers.len().saturating_sub(1));
    }
    pub fn key(&mut self, k: KeyEvent) {
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        if ctrl && k.code == KeyCode::Char('q') {
            self.quit = true;
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
        if ctrl && k.code == KeyCode::Char('p') {
            self.palette = !self.palette;
            self.palette_query.clear();
            self.palette_index = 0;
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
                        if ["race", "tournament"].contains(&cmd) {
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
            match k.code {
                KeyCode::Esc => {
                    self.drawer = None;
                    self.selection = 0;
                }
                KeyCode::Down => {
                    self.selection = (self.selection + 1).min(self.rows().len().saturating_sub(1));
                    self.drawer_scroll = self.drawer_scroll.saturating_add(1);
                }
                KeyCode::Up => {
                    self.selection = self.selection.saturating_sub(1);
                    self.drawer_scroll = self.drawer_scroll.saturating_sub(1);
                }
                KeyCode::PageDown => self.drawer_scroll = self.drawer_scroll.saturating_add(10),
                KeyCode::PageUp => self.drawer_scroll = self.drawer_scroll.saturating_sub(10),
                KeyCode::Enter => {
                    if let Some(row) = self.rows().get(self.selection) {
                        let kind = s(self.drawer.as_ref().unwrap(), "type");
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
                        if ["models", "events"].contains(&kind) {
                            self.drawer = Some(row.clone());
                            self.drawer_scroll = 0;
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
                KeyCode::Tab | KeyCode::Enter => {
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
                self.editor.insert(&c.to_string());
                self.dismiss_picker = false;
                self.picker_index = 0;
            }
            KeyCode::Backspace => {
                self.editor.backspace();
                self.dismiss_picker = false;
                self.picker_index = 0;
            }
            KeyCode::Delete => self.editor.delete(),
            KeyCode::Left => self.editor.left(),
            KeyCode::Right => self.editor.right(),
            KeyCode::Home => self.editor.home(),
            KeyCode::End => self.editor.end(),
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
        if !self.initialized || !self.connected || self.pending {
            self.notice = "Waiting for the runtime · draft preserved".into();
            return;
        }
        let text = self.editor.text.trim().to_owned();
        if text.is_empty() {
            return;
        }
        if let Some(rest) = text.strip_prefix('/') {
            let (name, query) = rest.split_once(char::is_whitespace).unwrap_or((rest, ""));
            if name == "help" {
                self.drawer = Some(
                    json!({"type":"panel","title":"KEYMAP / FIELD MANUAL","lines":["F1 mission · F2 actors · F3 ledger","Enter send / steer · Ctrl+J newline · bracketed paste stays a draft","@path selects a repository reference; Enter selects before submitting","Ctrl+P command palette · /race GOAL · /tournament GOAL","/models /files /sessions /connect /auto /verify /new","Ctrl+C cancel active turn · F2 then Ctrl+X cancel selected actor","Approvals default to deny; arrows choose; Enter requests; runtime acknowledges","PageUp/PageDown scroll · Esc return to live · Ctrl+Q exit","/attach PATH imports a PNG/JPEG/GIF/WebP file; /detach ID removes it","Auto mode and model settings remain runtime-owned"]}),
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
            self.outgoing.push(command("steer", &text));
            self.notice = "Steering sent to the active owner".into();
        } else {
            self.outgoing
                .push(json!({"type":"submit","prompt":text,"attachments":self.attachments}));
            self.last_submission = text;
            self.pending = true;
            self.notice = "Submitting to the runtime…".into();
        }
        self.editor.set("");
        self.following = true;
    }
    fn dispatch(&mut self, name: &str, query: &str) {
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
