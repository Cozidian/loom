use crate::{
    app::{App, View, s},
    editor::clean,
};
use ratatui::{
    Frame,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph},
};
use serde_json::Value;
use unicode_width::UnicodeWidthStr;

pub const INK: Color = Color::Rgb(12, 16, 22);
const PANEL: Color = Color::Rgb(19, 25, 34);
const LINE: Color = Color::Rgb(43, 55, 69);
const WHITE: Color = Color::Rgb(225, 230, 220);
const MUTED: Color = Color::Rgb(134, 150, 166);
const ACID: Color = Color::Rgb(218, 255, 95);
const CYAN: Color = Color::Rgb(83, 214, 220);
const RED: Color = Color::Rgb(255, 118, 127);
const VIOLET: Color = Color::Rgb(185, 161, 255);

fn style(color: Color) -> Style {
    Style::default().fg(color)
}
fn strong(color: Color) -> Style {
    style(color).add_modifier(Modifier::BOLD)
}
fn line(text: impl Into<String>, color: Color) -> Line<'static> {
    Line::styled(clean(&text.into()), style(color))
}
fn panel(title: &str, color: Color) -> Block<'static> {
    Block::default()
        .title(Line::styled(clean(&format!(" {title} ")), strong(color)))
        .borders(Borders::ALL)
        .border_style(style(LINE))
        .style(Style::default().bg(PANEL))
}
fn split(area: Rect, dir: Direction, constraints: Vec<Constraint>) -> Vec<Rect> {
    Layout::default()
        .direction(dir)
        .constraints(constraints)
        .split(area)
        .to_vec()
}
fn text(f: &mut Frame, area: Rect, mut lines: Vec<Line<'static>>) {
    for line in &mut lines {
        for span in &mut line.spans {
            span.content = clean(&span.content).into();
        }
    }
    f.render_widget(Paragraph::new(lines), area);
}
fn wrapped(text: &str, width: u16, color: Color) -> Vec<Line<'static>> {
    text.split('\n')
        .flat_map(|l| {
            textwrap::wrap(l, usize::from(width.max(1)))
                .into_iter()
                .map(|l| line(l.into_owned(), color))
                .collect::<Vec<_>>()
        })
        .collect()
}
fn status_color(state: &str) -> Color {
    match state {
        "failed" | "stalled" | "blocked" => RED,
        "completed" => ACID,
        "waiting" => VIOLET,
        _ => CYAN,
    }
}
pub fn worker_title(w: &Value) -> String {
    let role = s(w, "role");
    if role.is_empty() {
        s(w, "label").into()
    } else {
        role.into()
    }
}

pub fn draw(f: &mut Frame, a: &mut App) {
    let area = f.area();
    f.render_widget(
        Block::default().style(Style::default().bg(INK).fg(WHITE)),
        area,
    );
    if area.width < 36 || area.height < 14 {
        text(
            f,
            area,
            vec![
                line("ION / terminal too small", ACID),
                line("Resize to at least 36 × 14", WHITE),
                line("Draft preserved · Ctrl+Q exits", MUTED),
            ],
        );
        return;
    }
    let zones = split(
        area,
        Direction::Vertical,
        vec![
            Constraint::Length(3),
            Constraint::Length(2),
            Constraint::Min(3),
            Constraint::Length(5),
            Constraint::Length(2),
        ],
    );
    header(f, zones[0], a);
    let tabs = [
        (View::Mission, "01  MISSION"),
        (View::Swarm, "02  ACTORS"),
        (View::Ledger, "03  LEDGER"),
    ];
    let mut nav = vec![Span::raw("  ")];
    for (view, label) in tabs {
        nav.push(Span::styled(
            format!(" {label} "),
            if a.view == view {
                Style::default()
                    .fg(INK)
                    .bg(ACID)
                    .add_modifier(Modifier::BOLD)
            } else {
                style(MUTED)
            },
        ));
        nav.push(Span::raw("  "));
    }
    text(f, zones[1], vec![Line::from(nav)]);
    match a.view {
        View::Mission => mission(f, zones[2], a),
        View::Swarm => swarm(f, zones[2], a),
        View::Ledger => ledger(f, zones[2], a),
    }
    composer(f, zones[3], a);
    text(
        f,
        zones[4],
        vec![
            line(
                format!(
                    "  {}",
                    if a.notice.is_empty() {
                        "Ctrl+P commands · F1/F2/F3 navigate · /help"
                    } else {
                        &a.notice
                    }
                ),
                if a.connected { MUTED } else { RED },
            ),
            line(
                "  ^P commands  ^R prompts  ^Y copy  ^J newline  PgUp trail  ^C cancel  ^Q exit",
                MUTED,
            ),
        ],
    );
    if let Some(d) = a.drawer.clone() {
        drawer(f, area, a, &d);
    }
    if a.palette {
        palette(f, area, a);
    }
    if a.settings_form.is_some() {
        settings_form(f, area, a);
    }
    if let Some(request) = &a.settings_confirm {
        let rect = center(area, 82, 11);
        f.render_widget(Clear, rect);
        let b = panel("REMOVE PROVIDER PROFILE", RED);
        let inside = b.inner(rect);
        f.render_widget(b, rect);
        text(
            f,
            inside,
            vec![
                line(
                    format!("Remove {} from saved configuration?", s(request, "profile")),
                    ACID,
                ),
                line("Active/default profiles cannot be removed.", WHITE),
                line(
                    "Stored credentials and session history are not deleted.",
                    MUTED,
                ),
                line(
                    if a.settings_pending {
                        "Waiting for runtime…"
                    } else {
                        "Enter confirms · Esc cancels"
                    },
                    CYAN,
                ),
                line(&a.notice, MUTED),
            ],
        );
    }
    if let Some(worker) = &a.confirm_cancel {
        let rect = center(area, 72, 10);
        f.render_widget(Clear, rect);
        let b = panel("INTERRUPT ACTOR", RED);
        let inside = b.inner(rect);
        f.render_widget(b, rect);
        text(
            f,
            inside,
            vec![
                line("Cancel this worker through the OTP runtime?", WHITE),
                line(worker, ACID),
                line("", WHITE),
                line("Enter  request cancellation     Esc  keep working", MUTED),
            ],
        );
    }
    if !a.approvals.is_empty() {
        approval(f, area, a);
    }
}
fn header(f: &mut Frame, area: Rect, a: &App) {
    let state = if !a.connected {
        "OFFLINE"
    } else if !a.initialized {
        "CONNECTING"
    } else if !a.approvals.is_empty() {
        "DECISION REQUIRED"
    } else if a.busy {
        "IN FLIGHT"
    } else if a.pending {
        "SUBMITTING"
    } else {
        "READY"
    };
    let workspace = std::path::Path::new(&a.workspace)
        .file_name()
        .unwrap_or_default()
        .to_string_lossy();
    let flag = if a.demo {
        "  DEMO / simulated data"
    } else {
        ""
    };
    text(
        f,
        area,
        vec![
            Line::from(vec![
                Span::styled(
                    "  L O O M  ",
                    Style::default()
                        .fg(INK)
                        .bg(ACID)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!(
                        "  /  {}{flag}",
                        if workspace.is_empty() {
                            "workspace"
                        } else {
                            &workspace
                        }
                    ),
                    strong(WHITE),
                ),
                Span::styled(
                    format!("    ● {state}"),
                    style(if !a.connected { RED } else { CYAN }),
                ),
            ]),
            line(
                format!(
                    "  OTP CONTROL SURFACE    {} / {}    APPROVAL {} · ROUTING {}",
                    a.profile,
                    a.model,
                    a.approval_mode.to_uppercase(),
                    a.model_strategy.to_uppercase()
                ),
                if a.approval_mode == "auto" {
                    ACID
                } else {
                    MUTED
                },
            ),
        ],
    );
}
fn mission(f: &mut Frame, area: Rect, a: &mut App) {
    let columns = if area.width >= 108 {
        split(
            area,
            Direction::Horizontal,
            vec![Constraint::Min(45), Constraint::Length(36)],
        )
    } else {
        vec![area]
    };
    let zones = split(
        columns[0],
        Direction::Vertical,
        vec![Constraint::Length(4), Constraint::Min(1)],
    );
    let live = panel("LIVE ACTIVITY / ^T EXPAND TOOLS", CYAN);
    let live_inner = live.inner(zones[0]);
    f.render_widget(live, zones[0]);
    let elapsed = a.last_activity.map(|t| t.elapsed().as_secs());
    let status = if !a.connected {
        "Disconnected"
    } else if !a.approvals.is_empty() {
        "Waiting for your approval"
    } else if !a.activity.is_empty() {
        &a.activity
    } else {
        "Ready for work"
    };
    text(
        f,
        live_inner,
        vec![
            line(status, CYAN),
            line(
                format!(
                    "{} tools finished · {} team{}",
                    a.tool_count,
                    a.team_mode,
                    if a.busy {
                        elapsed
                            .map(|s| format!(" · {s}s since last activity"))
                            .unwrap_or_default()
                    } else {
                        String::new()
                    }
                ),
                MUTED,
            ),
        ],
    );
    let left = zones[1];
    let b = panel(
        if a.following {
            "WORK TRAIL / LIVE"
        } else {
            "WORK TRAIL / HISTORY"
        },
        WHITE,
    );
    let inner = b.inner(left);
    f.render_widget(b, left);
    if a.entries.is_empty() {
        let mut lines = vec![
            line("", WHITE),
            line("  INTENT → ACTORS → ARTIFACTS", ACID),
            line("", WHITE),
            line("  A place to direct the work.", WHITE),
            line("  Not just watch it happen.", MUTED),
            line("", WHITE),
        ];
        lines.extend(wrapped(if a.initialized{"Describe what you want to build. The runtime assigns models and workers; you keep the whole operation in view."}else{"The interface is ready. Connecting to the OTP runtime and loading your workspace… You can draft your request now."},inner.width.saturating_sub(4),WHITE));
        lines.extend(vec![
            line("", WHITE),
            line("  F2   Follow individual actors", CYAN),
            line("  F3   Inspect the evidence trail", VIOLET),
            line("  ^P   Open the command deck", ACID),
        ]);
        text(f, inner, lines);
    } else {
        let mut lines = vec![];
        for e in &a.entries {
            if (e.kind == "tool" || e.kind == "command") && !a.expand_tools {
                lines.extend(wrapped(
                    e.text.lines().next().unwrap_or(""),
                    inner.width.saturating_sub(2),
                    MUTED,
                ));
                continue;
            }
            let (name, color) = match e.kind.as_str() {
                "user" => ("YOU / INTENT", ACID),
                "assistant" => (
                    if e.streaming {
                        "OWNER / TRANSMITTING"
                    } else {
                        "OWNER / RESULT"
                    },
                    CYAN,
                ),
                "error" => ("RUNTIME / ATTENTION", RED),
                "tool" => ("TOOL / EVIDENCE", MUTED),
                "command" => ("COMMAND / OUTPUT", MUTED),
                "reasoning" => ("MODEL / REASONING SUMMARY", VIOLET),
                _ => ("RUNTIME", VIOLET),
            };
            lines.push(line(format!("  ━ {name}"), color));
            let content = if e.kind == "tool" && e.text.len() > 400 {
                e.text.chars().take(400).collect::<String>() + " … [full detail in Ledger]"
            } else {
                e.text.clone()
            };
            let mut code = false;
            for row in content.lines() {
                if row.starts_with("```") {
                    code = !code;
                    lines.push(line(if code { "  ┌─ code" } else { "  └─" }, MUTED));
                    continue;
                }
                lines.extend(wrapped(
                    row,
                    inner.width.saturating_sub(2),
                    if code {
                        CYAN
                    } else if row.starts_with('#') {
                        ACID
                    } else {
                        WHITE
                    },
                ));
            }
            lines.push(line("", WHITE));
        }
        let max = lines
            .len()
            .saturating_sub(inner.height as usize)
            .min(u16::MAX as usize) as u16;
        if a.following {
            a.scroll = max;
        } else {
            a.scroll = a.scroll.min(max);
        }
        f.render_widget(Paragraph::new(lines).scroll((a.scroll, 0)), inner);
    }
    if columns.len() > 1 {
        activity(f, columns[1], a);
    }
}
fn activity(f: &mut Frame, area: Rect, a: &App) {
    let b = panel("ACTOR TELEMETRY", CYAN);
    let inside = b.inner(area);
    f.render_widget(b, area);
    let summary = &a.progress["summary"];
    let mut lines = vec![
        line(
            format!(
                " {} active  /  {} waiting",
                summary["active"].as_u64().unwrap_or(0),
                summary["waiting"].as_u64().unwrap_or(0)
            ),
            CYAN,
        ),
        line(" ─────────────────────────────", LINE),
    ];
    if a.workers.is_empty() {
        lines.extend(vec![
            line(" No active worker assignments", MUTED),
            line(" Roles and model leases appear", MUTED),
            line(" when the runtime creates them.", MUTED),
        ]);
    }
    for w in a.workers.iter().rev().take(6) {
        let color = status_color(s(w, "state"));
        lines.extend(wrapped(
            &format!(" ● {}", worker_title(w)),
            inside.width,
            color,
        ));
        lines.extend(wrapped(
            &format!("   {}", s(w, "label")),
            inside.width,
            WHITE,
        ));
        lines.extend(wrapped(
            &format!("   {} / {}", s(w, "endpoint_id"), s(w, "model")),
            inside.width,
            MUTED,
        ));
        if !s(w, "blocking_reason").is_empty() {
            lines.extend(wrapped(
                &format!("   ! {}", s(w, "blocking_reason")),
                inside.width,
                RED,
            ));
        }
        lines.push(line("   ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄", LINE));
    }
    text(f, inside, lines);
}
fn swarm(f: &mut Frame, area: Rect, a: &App) {
    let parts = if area.width > 85 {
        split(
            area,
            Direction::Horizontal,
            vec![Constraint::Percentage(48), Constraint::Percentage(52)],
        )
    } else {
        vec![area]
    };
    let b = panel("ACTOR MAP / ↑↓ SELECT · ENTER INSPECT · ^X CANCEL", CYAN);
    let inner = b.inner(parts[0]);
    f.render_widget(b, parts[0]);
    let mut rows = vec![];
    let window = (inner.height as usize / 4).max(1);
    let start = a.selection.saturating_sub(window - 1);
    for (index, w) in a.workers.iter().enumerate().skip(start).take(window) {
        rows.push(Line::styled(
            format!(
                " {} {:02}  {}",
                if index == a.selection { "▶" } else { " " },
                index + 1,
                worker_title(w)
            ),
            if index == a.selection {
                strong(ACID)
            } else {
                style(status_color(s(w, "state")))
            },
        ));
        rows.push(line(
            format!("       {} · {}", s(w, "state"), s(w, "label")),
            WHITE,
        ));
        rows.push(line(
            format!("       {} / {}", s(w, "endpoint_id"), s(w, "model")),
            MUTED,
        ));
        rows.push(line("", LINE));
    }
    if a.workers.is_empty() {
        rows = vec![
            line(" No actors assigned yet.", MUTED),
            line(" F1 returns to your mission.", WHITE),
        ];
    }
    text(f, inner, rows);
    if parts.len() > 1 {
        let b = panel("SELECTED ACTOR / AUTHORITY & EVIDENCE", VIOLET);
        let inside = b.inner(parts[1]);
        f.render_widget(b, parts[1]);
        if let Some(w) = a.workers.get(a.selection) {
            text(f, inside, worker_detail(w, inside.width));
        }
    }
}
fn worker_detail(w: &Value, width: u16) -> Vec<Line<'static>> {
    let mut rows = vec![line(worker_title(w), ACID), line("", WHITE)];
    for (key, label) in [
        ("worker_id", "ACTOR"),
        ("owner_worker_id", "OWNER"),
        ("execution_node", "MACHINE"),
        ("endpoint_id", "ENDPOINT"),
        ("model", "MODEL"),
        ("phase", "PHASE"),
        ("blocking_reason", "BLOCKED"),
        ("assignment_reason", "ASSIGNMENT"),
        ("routing_reason", "ROUTING"),
        ("summary", "EVIDENCE"),
    ] {
        if !s(w, key).is_empty() {
            rows.push(line(label, MUTED));
            rows.extend(wrapped(
                s(w, key),
                width,
                if key == "blocking_reason" { RED } else { WHITE },
            ));
        }
    }
    if let Some(files) = w["files"].as_array() {
        rows.push(line("TOUCHED PATHS", MUTED));
        for path in files {
            rows.extend(wrapped(path.as_str().unwrap_or(""), width, CYAN));
        }
    }
    rows
}
fn event_label(e: &Value) -> String {
    let payload = if e["payload"].is_object() {
        &e["payload"]
    } else {
        e
    };
    let data = &payload["data"];
    format!(
        "{}  {}  {}",
        s(payload, "type").replace('_', " "),
        s(data, "name"),
        s(data, "status")
    )
}
fn ledger(f: &mut Frame, area: Rect, a: &App) {
    let b = panel("FLIGHT RECORDER / DURABLE EVENTS · ENTER EXPANDS", VIOLET);
    let inner = b.inner(area);
    f.render_widget(b, area);
    let start = a
        .selection
        .saturating_sub(inner.height.saturating_sub(1) as usize);
    let mut rows = vec![];
    for (i, e) in a
        .events
        .iter()
        .rev()
        .enumerate()
        .skip(start)
        .take(inner.height as usize)
    {
        let seq = e["goal_seq"].as_u64().unwrap_or(0);
        rows.push(Line::styled(
            format!(
                " {} {:05}  {}",
                if i == a.selection { "▶" } else { " " },
                seq,
                event_label(e)
            ),
            if i == a.selection {
                strong(ACID)
            } else {
                style(WHITE)
            },
        ));
    }
    if rows.is_empty() {
        rows.push(line(
            " No live events yet. Use /events to inspect runtime history.",
            MUTED,
        ));
    }
    text(f, inner, rows);
}
fn composer(f: &mut Frame, area: Rect, a: &App) {
    let title = if a.view != View::Mission {
        "DRAFT PARKED / F1 TO EDIT"
    } else if !a.initialized {
        "DRAFT / CONNECTING"
    } else if a.busy {
        "STEER / SEND DIRECTION TO THE ACTIVE OWNER"
    } else {
        "TRANSMIT / WHAT SHOULD WE BUILD?"
    };
    let b = Block::default()
        .title(Line::styled(format!(" {title} "), strong(ACID)))
        .borders(Borders::ALL)
        .border_style(style(if a.view == View::Mission { ACID } else { LINE }))
        .style(Style::default().bg(PANEL));
    let inner = b.inner(area);
    f.render_widget(b, area);
    let before = &a.editor.text[..a.editor.cursor];
    let row = before.chars().filter(|c| *c == '\n').count();
    let col = UnicodeWidthStr::width(before.rsplit('\n').next().unwrap_or(""));
    let sy = row
        .saturating_sub(inner.height.saturating_sub(1) as usize)
        .min(u16::MAX as usize) as u16;
    let sx = col
        .saturating_sub(inner.width.saturating_sub(2) as usize)
        .min(u16::MAX as usize) as u16;
    let content = if a.editor.text.is_empty() {
        format!(
            "Describe an outcome, reference @files, or open ^P…{}",
            if a.attachments.is_empty() {
                String::new()
            } else {
                format!("\n{} attachment(s) ready", a.attachments.len())
            }
        )
    } else {
        a.editor.text.clone()
    };
    f.render_widget(
        Paragraph::new(content)
            .style(style(if a.editor.text.is_empty() {
                MUTED
            } else {
                WHITE
            }))
            .scroll((sy, sx)),
        inner,
    );
    if a.view == View::Mission
        && a.drawer.is_none()
        && !a.palette
        && a.approvals.is_empty()
        && a.settings_form.is_none()
        && a.settings_confirm.is_none()
    {
        f.set_cursor_position((
            inner.x + (col.saturating_sub(sx as usize) as u16).min(inner.width.saturating_sub(1)),
            inner.y + (row.saturating_sub(sy as usize) as u16).min(inner.height.saturating_sub(1)),
        ));
        let matches = a.matches();
        let commands = a.slash_matches();
        if a.slash_query().is_some() {
            let height = ((commands.len().clamp(1, 6) + 2) as u16).min(area.y);
            let rect = Rect::new(
                area.x + 1,
                area.y.saturating_sub(height),
                area.width.saturating_sub(2).min(80),
                height,
            );
            f.render_widget(Clear, rect);
            let b = panel("COMMANDS / TAB COMPLETE · ENTER SELECT", ACID);
            let inside = b.inner(rect);
            f.render_widget(b, rect);
            let window = inside.height.max(1) as usize;
            let start = a.command_index.saturating_sub(window - 1);
            let rows = if commands.is_empty() {
                vec![line(" No matching command · Esc dismisses", MUTED)]
            } else {
                commands
                    .iter()
                    .enumerate()
                    .skip(start)
                    .take(window)
                    .map(|(i, cmd)| {
                        Line::styled(
                            format!(
                                " {} /{cmd:<13} {}",
                                if i == a.command_index { "▶" } else { " " },
                                command_hint(cmd)
                            ),
                            if i == a.command_index {
                                strong(ACID)
                            } else {
                                style(WHITE)
                            },
                        )
                    })
                    .collect()
            };
            text(f, inside, rows);
        } else if !matches.is_empty() {
            let height = (matches.len().min(7) + 2) as u16;
            let rect = Rect::new(
                area.x + 1,
                area.y.saturating_sub(height),
                area.width.saturating_sub(2).min(75),
                height,
            );
            f.render_widget(Clear, rect);
            let b = panel("REFERENCE / ENTER SELECTS, NEVER SUBMITS", CYAN);
            let inside = b.inner(rect);
            f.render_widget(b, rect);
            let start = a.picker_index.saturating_sub(6);
            text(
                f,
                inside,
                matches
                    .iter()
                    .enumerate()
                    .skip(start)
                    .take(7)
                    .map(|(i, path)| {
                        Line::styled(
                            format!(" {} {path}", if i == a.picker_index { "▶" } else { " " }),
                            if i == a.picker_index {
                                strong(ACID)
                            } else {
                                style(WHITE)
                            },
                        )
                    })
                    .collect(),
            );
        }
    }
}
fn center(area: Rect, width: u16, height: u16) -> Rect {
    let w = width.min(area.width.saturating_sub(4));
    let h = height.min(area.height.saturating_sub(2));
    Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - h) / 2,
        w,
        h,
    )
}
fn drawer(f: &mut Frame, area: Rect, a: &mut App, d: &Value) {
    let rect = center(
        area,
        area.width.saturating_sub(8).min(115),
        area.height.saturating_sub(4),
    );
    f.render_widget(Clear, rect);
    let kind = s(d, "type");
    let title = if s(d, "title").is_empty() {
        kind.to_uppercase()
    } else {
        s(d, "title").into()
    };
    let b = panel(&format!("DOSSIER / {title} · ESC CLOSE"), VIOLET);
    let inner = b.inner(rect);
    f.render_widget(b, rect);
    let rows = a.rows();
    let zones = split(
        inner,
        Direction::Vertical,
        vec![
            Constraint::Length(1),
            Constraint::Min(1),
            Constraint::Length(1),
        ],
    );
    let body = zones[1];
    let help = if d["mission_actions"].is_array() {
        let actions = crate::app::array(d, "mission_actions");
        let shortcuts: Vec<_> = actions
            .iter()
            .filter_map(|action| match action.as_str() {
                Some("start") => Some("s start"),
                Some("pause") => Some("p pause"),
                Some("resume") => Some("r resume"),
                Some("dismiss") => Some("d dismiss"),
                _ => None,
            })
            .collect();
        format!(
            " {} · f refresh · ↑↓ scroll · Esc close",
            shortcuts.join(" · ")
        )
    } else if kind == "models" {
        " Enter chooses model · p manages providers · ^Y copy · Esc back".into()
    } else if kind == "provider_settings" {
        " n new · e edit · u use · x remove · l login · r reload · Enter models".into()
    } else if kind == "model_catalog" {
        " Enter chooses · m manual model ID · Esc back".into()
    } else if kind == "provider_kind_picker" {
        " Choose a provider type · Enter opens form · Esc back".into()
    } else if kind == "prompt_history" {
        format!(" Search: {}▏ · Enter recalls, never sends", a.history_query)
    } else if !rows.is_empty() {
        " ↑↓ select · Enter inspect · ^Y copy · Esc back".into()
    } else {
        " ↑↓ / PgUp PgDn scroll · ^Y copy · Esc back".into()
    };
    text(f, zones[0], vec![line(help, MUTED)]);
    text(f, zones[2], vec![line(&a.notice, CYAN)]);
    let mut lines = vec![];
    if !rows.is_empty() {
        a.selection = a.selection.min(rows.len() - 1);
        let window = body.height.max(1) as usize;
        let mut start = a.drawer_scroll as usize;
        if a.selection < start {
            start = a.selection;
        }
        if a.selection >= start + window {
            start = a.selection + 1 - window;
        }
        start = start.min(rows.len().saturating_sub(window));
        a.drawer_scroll = start as u16;
        for (i, row) in rows.iter().enumerate().skip(start).take(window) {
            let title = match kind {
                "models" => format!("{} / {}", s(row, "id"), s(row, "model")),
                "files" => format!(
                    "{}  +{} −{}",
                    s(row, "path"),
                    row["insertions"],
                    row["deletions"]
                ),
                "sessions" => format!("{}  {}", s(row, "session_id"), s(row, "goal_preview")),
                "provider_picker" => format!("{}  {}", s(row, "profile"), s(row, "model")),
                "provider_settings" => format!(
                    "{} {} / {}  {}  [{}]",
                    if row["active"] == true { "●" } else { " " },
                    s(row, "profile"),
                    s(row, "provider"),
                    s(row, "model"),
                    s(row, "auth_mode")
                ),
                "provider_kind_picker" => s(row, "provider").into(),
                "model_catalog" => format!(
                    "{} {}",
                    s(row, "model"),
                    if row["isDefault"] == true {
                        "· provider default"
                    } else {
                        ""
                    }
                ),
                "prompt_history" => s(row, "prompt").replace('\n', " ↵ "),
                "output_picker" => format!(
                    "{}  {}",
                    s(row, "kind"),
                    s(row, "content").replace('\n', " ↵ ")
                ),
                _ => event_label(row),
            };
            lines.push(Line::styled(
                clean(&format!(
                    " {} {title}",
                    if i == a.selection { "▶" } else { " " }
                )),
                if i == a.selection {
                    strong(ACID)
                } else {
                    style(WHITE)
                },
            ));
        }
        text(f, body, lines);
        return;
    } else if kind == "model_catalog" {
        lines.extend(wrapped(s(d, "message"), body.width, WHITE));
        lines.push(line("Press m to enter a model ID and routing mode", ACID));
    } else if kind == "prompt_history" || kind == "output_picker" {
        lines.push(line(" Nothing here yet / no matches", MUTED));
    } else if kind == "output_detail" {
        lines = wrapped(s(d, "content"), body.width, WHITE);
    } else if kind == "panel" {
        for row in crate::app::array(d, "lines") {
            lines.extend(wrapped(row.as_str().unwrap_or(""), inner.width, WHITE));
        }
    } else if kind == "diff" {
        for row in s(d, "raw_patch").lines() {
            lines.extend(wrapped(
                row,
                inner.width,
                if row.starts_with('+') {
                    ACID
                } else if row.starts_with('-') {
                    RED
                } else {
                    WHITE
                },
            ));
        }
    } else if d["worker_id"].is_string() && d["phase"].is_string() {
        lines = worker_detail(d, inner.width);
        lines.push(line("", WHITE));
        lines.push(line("FULL RUNTIME RECORD", VIOLET));
        lines.extend(wrapped(
            &serde_json::to_string_pretty(d).unwrap_or_default(),
            inner.width,
            WHITE,
        ));
    } else {
        if kind == "session_detail" {
            lines.push(line(" r resumes this session · Esc closes", ACID));
        }
        lines.extend(wrapped(
            &serde_json::to_string_pretty(d).unwrap_or_default(),
            inner.width,
            WHITE,
        ));
    }
    a.drawer_scroll = a.drawer_scroll.min(
        lines
            .len()
            .saturating_sub(body.height as usize)
            .min(u16::MAX as usize) as u16,
    );
    f.render_widget(Paragraph::new(lines).scroll((a.drawer_scroll, 0)), body);
}
fn command_hint(cmd: &str) -> &str {
    match cmd {
        "auto" => "toggle approval policy",
        "attach" => "attach an image file",
        "history" => "recall a previous prompt",
        "output" => "browse and copy earlier output",
        "copy" => "copy latest output / all transcript",
        "race" => "first admissible result wins",
        "tournament" => "compare candidate solutions",
        "models" => "choose a model or inspect endpoints",
        "providers" => "add, edit and select providers/models",
        "mission" => "start/manage the read-only documentation observer",
        "files" => "inspect changed files and diffs",
        "connect" => "select a configured provider",
        _ => "runtime command",
    }
}
fn settings_form(f: &mut Frame, area: Rect, a: &App) {
    let Some(form) = &a.settings_form else {
        return;
    };
    let rect = center(area, 96, 20);
    f.render_widget(Clear, rect);
    let b = panel(
        &format!("{} / {} {}", form.title, form.profile, form.provider),
        ACID,
    );
    let inner = b.inner(rect);
    f.render_widget(b, rect);
    let zones = split(
        inner,
        Direction::Vertical,
        vec![
            Constraint::Length(2),
            Constraint::Min(2),
            Constraint::Length(4),
        ],
    );
    text(
        f,
        zones[0],
        vec![
            line(
                "Tab/↑↓ fields · ^U clear · ^S save/apply · Esc cancel",
                CYAN,
            ),
            line(
                if form.action == "select" {
                    "Saves profile + routing mode; preserves conversation"
                } else {
                    "Saves profile + project endpoints; current profile changes apply now"
                },
                MUTED,
            ),
        ],
    );
    let window = zones[1].height.max(1) as usize;
    let start = form.index.saturating_sub(window - 1);
    for (row, (i, (name, editor))) in form
        .fields
        .iter()
        .enumerate()
        .skip(start)
        .take(window)
        .enumerate()
    {
        let line_area = Rect::new(zones[1].x, zones[1].y + row as u16, zones[1].width, 1);
        let label_width = 14.min(line_area.width.saturating_sub(3));
        let field_area = Rect::new(
            line_area.x + label_width,
            line_area.y,
            line_area.width.saturating_sub(label_width),
            1,
        );
        text(
            f,
            line_area,
            vec![line(
                format!("{}{name:<12}", if i == form.index { "›" } else { " " }),
                if i == form.index { ACID } else { MUTED },
            )],
        );
        let column = UnicodeWidthStr::width(&editor.text[..editor.cursor]);
        let scroll = column
            .saturating_sub(field_area.width.saturating_sub(1) as usize)
            .min(u16::MAX as usize) as u16;
        f.render_widget(
            Paragraph::new(clean(&editor.text))
                .style(style(WHITE))
                .scroll((0, scroll)),
            field_area,
        );
        if i == form.index && !a.settings_pending {
            f.set_cursor_position((
                field_area.x
                    + column
                        .saturating_sub(scroll as usize)
                        .min(field_area.width.saturating_sub(1) as usize)
                        as u16,
                field_area.y,
            ));
        }
    }
    let hint = match form.fields[form.index].0.as_str() {
        "api_key_env" => "Environment variable NAME only. Never paste an API key here.",
        "auth_mode" => "environment | chatgpt (OpenAI) | saved (existing credentials)",
        "strategy" => "manual = pin this model · auto = route automatically · local_only",
        "team_mode" => {
            "auto = task-based subagents · solo = no automatic team. Same-model workers are supported."
        }
        "base_url" => "Changing address clears saved credential references.",
        "profile" => "Unique name: letters, digits, dots, underscores, hyphens",
        _ => "Exact model ID; use the model catalogue where available.",
    };
    let mut footer = wrapped(hint, zones[2].width, MUTED);
    footer.extend(wrapped(
        &a.notice,
        zones[2].width,
        if a.settings_pending { CYAN } else { WHITE },
    ));
    text(f, zones[2], footer);
}
fn palette(f: &mut Frame, area: Rect, a: &App) {
    let rect = center(area, 68, 17);
    f.render_widget(Clear, rect);
    let b = panel("COMMAND DECK / TYPE TO FILTER", ACID);
    let inner = b.inner(rect);
    f.render_widget(b, rect);
    let mut lines = vec![
        line(format!(" › {}_", a.palette_query), WHITE),
        line("", WHITE),
    ];
    let items = a.palette_items();
    let window = inner.height.saturating_sub(2).max(1) as usize;
    let start = a.palette_index.saturating_sub(window - 1);
    for (i, item) in items.iter().enumerate().skip(start).take(window) {
        let hint = match *item {
            "history" => "search and recall a previous prompt",
            "output" => "browse and copy earlier output",
            "copy" => "copy current output to clipboard",
            "race" => "first admissible result wins",
            "tournament" => "compare and select a candidate",
            "auto" => "toggle approval policy — runtime confirms",
            "models" => "inspect providers, leases and evidence",
            "files" => "review changed files and diffs",
            "sessions" => "open the mission archive",
            "connect" => "select a configured provider",
            _ => "inspect / control runtime",
        };
        lines.push(Line::styled(
            format!(
                " {} /{item:<14} {hint}",
                if i == a.palette_index { "▶" } else { " " }
            ),
            if i == a.palette_index {
                strong(ACID)
            } else {
                style(MUTED)
            },
        ));
    }
    if items.is_empty() {
        lines.push(line(" No matching command", MUTED));
    }
    text(f, inner, lines);
}
fn approval(f: &mut Frame, area: Rect, a: &mut App) {
    let request = &a.approvals[0];
    let rect = center(area, 90, 19);
    f.render_widget(Clear, rect);
    let b = panel("AUTHORITY GATE / YOUR DECISION", RED);
    let inner = b.inner(rect);
    f.render_widget(b, rect);
    let mut lines = vec![
        line(
            format!(
                "{} pending · actor {}",
                a.approvals.len(),
                s(request, "session_id")
            ),
            MUTED,
        ),
        line(format!("Tool: {}", s(request, "tool")), ACID),
        line("↑↓ scroll arguments · ← → choose", MUTED),
    ];
    let arguments = wrapped(
        &serde_json::to_string_pretty(&request["arguments"]).unwrap_or_default(),
        inner.width,
        WHITE,
    );
    let visible = (inner.height.saturating_sub(8) as usize).max(1);
    a.approval_scroll = a
        .approval_scroll
        .min(arguments.len().saturating_sub(visible));
    lines.extend(arguments.into_iter().skip(a.approval_scroll).take(visible));
    lines.push(line("", WHITE));
    let labels = [" DENY ", " ALLOW ONCE ", " ALLOW ALWAYS / SCOPED "];
    for (i, label) in labels.iter().enumerate() {
        lines.push(Line::styled(
            label.to_string(),
            if i == a.approval_choice {
                Style::default()
                    .fg(INK)
                    .bg(ACID)
                    .add_modifier(Modifier::BOLD)
            } else {
                style(MUTED)
            },
        ));
    }
    lines.push(line(
        if a.resolving.is_some() {
            "Awaiting runtime acknowledgement…"
        } else {
            "← → choose · Enter requests decision · Esc selects deny"
        },
        CYAN,
    ));
    if !a.notice.is_empty() {
        lines.extend(wrapped(&a.notice, inner.width, MUTED).into_iter().take(2));
    }
    text(f, inner, lines);
}

pub fn demo() -> App {
    let mut a = App {
        demo: true,
        ..App::default()
    };
    a.apply(serde_json::json!({"type":"init","session_id":"session-ion-preview","workspace":"/workspace/orbital","profile":"reasoning","model":"capable-model","approval_mode":"ask","entries":[
        {"kind":"user","content":"Build a Phoenix control plane for the harness. Live actor telemetry, streaming results, and an approval inbox. Keep the runtime in charge."},
        {"kind":"assistant","content":"I’m connecting the interface to the existing OTP runtime.\n\n## One owner. Independent evidence.\nThe implementation stays with me. A repository investigator is mapping the public API while a verification specialist checks the event and approval contracts.\n\n```elixir\nRuntime.connect(session_id, view: :internal)\n```\nThe connection is established. Next: wire the live event stream and exercise reconnect behavior."}],
        "work_blocks":[
            {"worker_id":"owner-7f2","role":"Implementation owner","label":"Wiring live subscriptions","state":"active","phase":"implementing","endpoint_id":"reasoning","model":"capable-model","execution_node":"local","owner_worker_id":"owner-7f2","assignment_reason":"Owns integration and verification","routing_reason":"Highest eligible capability score","summary":"4 reads · 2 writes · 1 model call","files":["lib/web/live/mission.ex","lib/web/router.ex"]},
            {"worker_id":"scout-9a1","role":"Repository investigator","label":"API map delivered","state":"completed","phase":"completed","endpoint_id":"local","model":"small-model","execution_node":"local","owner_worker_id":"owner-7f2","summary":"6 reads · 1 model call"},
            {"worker_id":"check-2c8","role":"Verification specialist","label":"Inspecting reconnect tests","state":"active","phase":"investigating","endpoint_id":"local","model":"small-model","execution_node":"local","owner_worker_id":"owner-7f2","summary":"3 reads · 1 model call"}],
        "progress":{"summary":{"active":2,"waiting":0,"blocked":0,"stalled":0}},"workspace_files":["lib/web/live/mission.ex","lib/web/router.ex","test/reconnect_test.exs"]}));
    a.busy = true;
    a.notice = "DEMO · simulated data, no providers or runtime actions · /help for controls".into();
    for (i, event) in [
        "goal_work_started",
        "provider_auction_awarded",
        "worker_assignment",
        "tool_called",
        "verification_check_finished",
    ]
    .iter()
    .enumerate()
    {
        a.events.push_back(serde_json::json!({"goal_seq":i+1,"payload":{"type":event,"data":{"status":"recorded"}}}));
    }
    a
}
