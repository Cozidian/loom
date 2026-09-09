//! Clipboard writes occur only after an explicit copy action, never from events.
use base64::{Engine, engine::general_purpose::STANDARD};
use std::{
    io::{self, Write},
    process::{Command, Stdio},
    sync::mpsc::{self, Receiver},
    time::{Duration, Instant},
};

pub type CopyResult = Result<String, String>;

pub fn osc52(text: &str) -> Result<String, String> {
    if text.len() > 100_000 {
        return Err("Output exceeds the terminal clipboard limit (100 KB); copy an individual output with /output".into());
    }
    Ok(format!(
        "\x1b]52;c;{}\x07",
        STANDARD.encode(text.as_bytes())
    ))
}

/// None means an OSC52 request was sent, not that the terminal acknowledged it.
pub fn start(text: String) -> Result<Option<Receiver<CopyResult>>, String> {
    if text.len() > 1024 * 1024 {
        return Err("Output exceeds the 1 MiB clipboard limit".into());
    }
    let remote =
        std::env::var_os("SSH_TTY").is_some() || std::env::var_os("SSH_CONNECTION").is_some();
    let terminal = std::env::var("BEAM_AGENT_ION_CLIPBOARD").as_deref() == Ok("osc52");
    let native = if remote || terminal {
        None
    } else if cfg!(target_os = "macos") {
        Some(("/usr/bin/pbcopy", vec![]))
    } else if std::env::var_os("WAYLAND_DISPLAY").is_some() && available("wl-copy") {
        Some(("wl-copy", vec![]))
    } else if std::env::var_os("DISPLAY").is_some() && available("xclip") {
        Some(("xclip", vec!["-selection", "clipboard"]))
    } else {
        None
    };
    let Some((program, args)) = native else {
        let sequence = osc52(&text)?;
        let mut stdout = io::stdout().lock();
        stdout
            .write_all(sequence.as_bytes())
            .and_then(|_| stdout.flush())
            .map_err(|e| e.to_string())?;
        return Ok(None);
    };
    let (tx, rx) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let _ = tx.send(native_copy(program, &args, text));
    });
    Ok(Some(rx))
}

fn available(name: &str) -> bool {
    std::env::var_os("PATH")
        .is_some_and(|path| std::env::split_paths(&path).any(|p| p.join(name).is_file()))
}

fn native_copy(program: &str, args: &[&str], text: String) -> CopyResult {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("Clipboard unavailable: {e}"))?;
    let mut input = child.stdin.take().ok_or("Clipboard stdin unavailable")?;
    let writer = std::thread::spawn(move || input.write_all(text.as_bytes()));
    let deadline = Instant::now() + Duration::from_secs(2);
    let result = loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break Ok("Output copied to clipboard".into()),
            Ok(Some(_)) => break Err("Clipboard helper failed".into()),
            Err(e) => break Err(format!("Clipboard helper failed: {e}")),
            _ if Instant::now() >= deadline => break Err("Clipboard helper timed out".into()),
            _ => std::thread::sleep(Duration::from_millis(10)),
        }
    };
    if result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    let written = writer.join().map_err(|_| "Clipboard writer stopped")?;
    written.map_err(|e| format!("Clipboard write failed: {e}"))?;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn terminal_copy_encodes_content_and_bounds_size() {
        let text = "hello 👩‍💻\n\x1b]52;c;untrusted\x07";
        let sequence = osc52(text).unwrap();
        let encoded = sequence
            .strip_prefix("\x1b]52;c;")
            .unwrap()
            .strip_suffix('\x07')
            .unwrap();
        assert_eq!(STANDARD.decode(encoded).unwrap(), text.as_bytes());
        assert!(osc52(&"x".repeat(100_001)).is_err());
    }
}
