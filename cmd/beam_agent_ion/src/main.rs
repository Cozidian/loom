mod app;
mod clipboard;
mod editor;
mod markdown;
mod protocol;
mod ui;

use app::App;
use crossterm::{
    event::{
        self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
        Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseEventKind,
    },
    execute,
};
use serde_json::{Value, json};
use std::{
    fs::{File, OpenOptions},
    io::{self, BufReader},
    sync::mpsc::{self, SyncSender, TrySendError},
    time::{Duration, Instant},
};

enum Message {
    Packet(Value),
    Failed(String),
    Exited,
}

fn bridge() -> io::Result<(mpsc::Receiver<Message>, SyncSender<Value>)> {
    // The inherited protocol descriptors are separate from stdin/stdout, which
    // remain the user's terminal. No terminal escapes ever enter the JSON wire.
    let input = File::open("/dev/fd/3")?;
    let mut output = OpenOptions::new().write(true).open("/dev/fd/4")?;
    let (tx, rx) = mpsc::sync_channel(128);
    let reader_tx = tx.clone();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(input);
        loop {
            match protocol::read_packet(&mut reader) {
                Ok(p) => {
                    if reader_tx.send(Message::Packet(p)).is_err() {
                        break;
                    }
                }
                Err(e) => {
                    let _ = reader_tx.send(Message::Failed(e.to_string()));
                    break;
                }
            }
        }
    });
    let (writer_tx, writer_rx) = mpsc::sync_channel::<Value>(32);
    std::thread::spawn(move || {
        for p in writer_rx {
            if let Err(e) = protocol::write_packet(&mut output, &p) {
                let _ = tx.send(Message::Failed(e.to_string()));
                break;
            }
            if p["type"] == "exit" {
                let _ = tx.send(Message::Exited);
                break;
            }
        }
    });
    Ok((rx, writer_tx))
}

fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.iter().any(|x| x == "--help") {
        println!(
            "Loom / ION Ratatui frontend\n\nRun through the existing bridge:\n  BEAM_AGENT_TUI_BIN=./beam_agent_ion ./loom\n\n  --demo       interactive preview; no backend or model calls\n  --snapshot   render a 120x38 demo frame to plain text\n  --help       show this help\n\nF1 mission · F2 actors · F3 ledger · Ctrl+P commands · Ctrl+Q exit"
        );
        return Ok(());
    }
    if args.iter().any(|x| x == "--snapshot") {
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(120, 38)).unwrap();
        terminal.draw(|f| ui::draw(f, &mut ui::demo())).unwrap();
        let buffer = terminal.backend().buffer();
        for y in 0..38 {
            let row: String = (0..120).map(|x| buffer[(x, y)].symbol()).collect();
            println!("{}", row.trim_end());
        }
        return Ok(());
    }
    let demo = args.iter().any(|x| x == "--demo");
    let transport = if demo {
        None
    } else {
        Some(bridge().map_err(|e| {
            io::Error::other(format!(
                "Launch ION through BEAM_AGENT_TUI_BIN or use --demo: {e}"
            ))
        })?)
    };
    let mut a = if demo { ui::demo() } else { App::default() };
    // Paint before reading init. The backend may still be bootstrapping.
    let mut terminal = ratatui::init();
    let previous_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = execute!(io::stdout(), DisableBracketedPaste, DisableMouseCapture);
        previous_hook(info);
    }));
    let result = (|| -> io::Result<()> {
        execute!(io::stdout(), EnableBracketedPaste, EnableMouseCapture)?;
        let mut exit_started = None;
        let mut dirty = true;
        let mut copying: Option<mpsc::Receiver<clipboard::CopyResult>> = None;
        let mut activity_tick = Instant::now();
        loop {
            if activity_tick.elapsed() >= Duration::from_secs(1) {
                dirty = dirty || a.busy;
                if a.poll_catalog() {
                    dirty = true;
                }
                activity_tick = Instant::now();
            }
            if dirty {
                terminal.draw(|f| ui::draw(f, &mut a))?;
                dirty = false;
            }
            if let Some((rx, _)) = &transport {
                for message in rx.try_iter().take(64) {
                    dirty = true;
                    match message {
                        Message::Packet(p) => a.apply(p),
                        Message::Failed(e) => a.disconnected(e),
                        Message::Exited => return Ok(()),
                    }
                }
            }
            if let Some(text) = a.clipboard.take() {
                dirty = true;
                if copying.is_some() {
                    a.notice = "Copy already in progress · try again shortly".into();
                } else {
                    match clipboard::start(text) {
                        Ok(Some(rx)) => {
                            copying = Some(rx);
                            a.notice = "Copying output…".into();
                        }
                        Ok(None) => a.notice =
                            "Clipboard request sent (OSC52); terminal must allow clipboard access"
                                .into(),
                        Err(e) => a.notice = format!("Not copied: {e}"),
                    }
                }
            }
            if let Some(rx) = &copying {
                match rx.try_recv() {
                    Ok(result) => {
                        a.notice = result.unwrap_or_else(|e| format!("Not copied: {e}"));
                        copying = None;
                        dirty = true;
                    }
                    Err(mpsc::TryRecvError::Disconnected) => {
                        copying = None;
                        a.notice = "Clipboard worker stopped".into();
                        dirty = true;
                    }
                    Err(mpsc::TryRecvError::Empty) => {}
                }
            }
            if a.quit {
                if transport.is_none() || !a.connected {
                    return Ok(());
                }
                if exit_started.is_none() {
                    a.outgoing.push(json!({"type":"exit"}));
                    exit_started = Some(Instant::now());
                }
                if exit_started.is_some_and(|t: Instant| t.elapsed() > Duration::from_secs(1)) {
                    return Ok(());
                }
            }
            for p in std::mem::take(&mut a.outgoing) {
                dirty = true;
                if let Some((_, tx)) = &transport {
                    match tx.try_send(p) {
                        Ok(()) => {}
                        Err(TrySendError::Full(packet)) => {
                            a.send_failed(&packet, "bridge queue is full");
                        }
                        Err(TrySendError::Disconnected(packet)) => {
                            a.send_failed(&packet, "writer stopped");
                            a.disconnected("writer stopped".into());
                        }
                    }
                } else {
                    a.pending = false;
                    a.resolving = None;
                    a.notice = "DEMO · command preview only; no runtime action was taken".into();
                }
            }
            if event::poll(Duration::from_millis(50))? {
                dirty = true;
                match event::read()? {
                    Event::Key(k) if k.kind != KeyEventKind::Release => a.key(k),
                    Event::Paste(text) => {
                        if a.approvals.is_empty()
                            && a.settings_form.is_some()
                            && !a.settings_pending
                        {
                            let form = a.settings_form.as_mut().unwrap();
                            form.fields[form.index]
                                .1
                                .insert(&text.replace(['\r', '\n'], ""));
                        } else if a.approvals.is_empty()
                            && !a.palette
                            && a.drawer.is_none()
                            && a.settings_confirm.is_none()
                            && a.settings_form.is_none()
                        {
                            a.leave_history();
                            a.editor.insert(&text);
                            a.dismiss_picker = false;
                            a.command_index = 0;
                        }
                    }
                    Event::Mouse(m) => {
                        let code = match m.kind {
                            MouseEventKind::ScrollUp => Some(KeyCode::PageUp),
                            MouseEventKind::ScrollDown => Some(KeyCode::PageDown),
                            _ => None,
                        };
                        if let Some(code) = code {
                            a.key(KeyEvent::new(code, KeyModifiers::NONE));
                        }
                    }
                    Event::Resize(_, _) => {}
                    _ => {}
                }
            }
        }
    })();
    let _ = execute!(io::stdout(), DisableBracketedPaste, DisableMouseCapture);
    ratatui::restore();
    result
}

#[cfg(test)]
mod tests;
