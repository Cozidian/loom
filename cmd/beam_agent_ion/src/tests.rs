use crate::{
    app::{App, View},
    ui,
};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::json;

fn key(a: &mut App, code: KeyCode) {
    a.key(KeyEvent::new(code, KeyModifiers::NONE));
}
fn ready() -> App {
    let mut a = App::default();
    a.apply(json!({"type":"init","session_id":"root","workspace":"/tmp/project","entries":[],"approval_mode":"ask"}));
    a
}
fn render(a: &mut App, w: u16, h: u16) -> String {
    let mut t = ratatui::Terminal::new(ratatui::backend::TestBackend::new(w, h)).unwrap();
    t.draw(|f| ui::draw(f, a)).unwrap();
    let b = t.backend().buffer();
    (0..h)
        .map(|y| (0..w).map(|x| b[(x, y)].symbol()).collect::<String>())
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn paints_before_init_and_preserves_early_draft() {
    let mut a = App::default();
    a.editor.insert("draft before backend");
    key(&mut a, KeyCode::Enter);
    assert!(a.outgoing.is_empty());
    assert_eq!(a.editor.text, "draft before backend");
    let frame = render(&mut a, 100, 30);
    assert!(frame.contains("CONNECTING"));
    assert!(frame.contains("draft before backend"));
}
#[test]
fn submitted_work_and_steering_use_existing_packets() {
    let mut a = ready();
    a.editor.set("Build this");
    key(&mut a, KeyCode::Enter);
    assert_eq!(
        a.outgoing.pop().unwrap(),
        json!({"type":"submit","prompt":"Build this","attachments":[]})
    );
    a.apply(json!({"type":"turn_started","prompt":"Build this"}));
    a.editor.set("Keep the API stable");
    key(&mut a, KeyCode::Enter);
    assert_eq!(
        a.outgoing.pop().unwrap(),
        json!({"type":"command","command":"steer","query":"Keep the API stable"})
    );
}
#[test]
fn approvals_default_deny_and_wait_for_runtime_ack() {
    let mut a = ready();
    a.apply(json!({"type":"approval_requested","approval":{"approval_id":"a","tool":"run_command","arguments":{"command":"mix test"}}}));
    key(&mut a, KeyCode::Enter);
    assert_eq!(a.outgoing[0]["decision"], "deny");
    assert_eq!(a.approvals.len(), 1);
    key(&mut a, KeyCode::Enter);
    assert_eq!(a.outgoing.len(), 1);
    a.apply(json!({"type":"approval_failed","approval_id":"a","error":"retry"}));
    assert!(a.resolving.is_none());
    key(&mut a, KeyCode::Right);
    key(&mut a, KeyCode::Enter);
    assert_eq!(a.outgoing[1]["decision"], "allow_once");
    a.apply(json!({"type":"approval_resolved","approval_id":"a","decision":"allow_once"}));
    assert!(a.approvals.is_empty());
}
#[test]
fn durable_and_ephemeral_streams_do_not_duplicate_answers_or_workers() {
    let mut a = ready();
    a.apply(
        json!({"type":"stream","event":{"type":"text_delta","response_id":"r","delta":"Hello"}}),
    );
    a.apply(json!({"type":"stream","event":{"type":"response_finished","response_id":"r"}}));
    let event = json!({"type":"stream","event":{"type":"runtime_event","durability":"durable","goal_seq":1,"scope":{"root?":true},"payload":{"type":"assistant_message","data":{"content":"Hello"}}}});
    a.apply(event.clone());
    a.apply(event);
    assert_eq!(a.entries.len(), 1);
    a.apply(json!({"type":"stream","event":{"type":"runtime_event","durability":"ephemeral","scope":{"root?":false},"payload":{"data":{"type":"text_delta","response_id":"child","delta":"child secret"}}}}));
    assert_eq!(a.entries.len(), 1);
    assert_eq!(a.events.len(), 1);
}
#[test]
fn picker_selection_preempts_submit_and_quotes_spaces() {
    let mut a = ready();
    a.files = vec!["my file.ex".into()];
    a.editor.set("Read @my");
    key(&mut a, KeyCode::Enter);
    assert_eq!(a.editor.text, "Read @\"my file.ex\" ");
    assert!(a.outgoing.is_empty());
    key(&mut a, KeyCode::Enter);
    assert_eq!(a.outgoing[0]["type"], "submit");
}
#[test]
fn disconnected_interface_never_sends_commands() {
    let mut a = ready();
    a.disconnected("EOF".into());
    a.editor.set("/auto");
    key(&mut a, KeyCode::Enter);
    assert!(a.outgoing.is_empty());
    assert_eq!(a.editor.text, "/auto");
}
#[test]
fn all_responsive_views_render_with_unicode_and_overlays() {
    for (w, h) in [(120, 38), (90, 26), (60, 20), (36, 14), (20, 8)] {
        for view in [View::Mission, View::Swarm, View::Ledger] {
            let mut a = ui::demo();
            a.view = view;
            a.editor.set("Plan 👩‍💻 日本語\nsecond line");
            let frame = render(&mut a, w, h);
            assert!(frame.contains("ION") || frame.contains("I O N"));
            a.palette = true;
            render(&mut a, w, h);
            a.palette = false;
            a.drawer = Some(json!({"type":"diff","raw_patch":"+added\n-removed"}));
            render(&mut a, w, h);
            a.apply(json!({"type":"approval_requested","approval":{"approval_id":"a","tool":"run_command","arguments":{"command":"echo safe"}}}));
            render(&mut a, w, h);
        }
    }
}
#[test]
fn actual_worker_metadata_is_visible() {
    let mut a = ui::demo();
    let frame = render(&mut a, 120, 38);
    for expected in [
        "Implementation owner",
        "Repository investigator",
        "capable-model",
        "APPROVAL ASK",
    ] {
        assert!(frame.contains(expected), "missing {expected}");
    }
    a.view = View::Swarm;
    let frame = render(&mut a, 120, 38);
    assert!(frame.contains("Highest eligible capability"));
}
#[test]
fn provider_selection_uses_profile_prefix() {
    let mut a = ready();
    a.apply(json!({"type":"provider_picker","providers":[{"profile":"local","model":"small"}]}));
    key(&mut a, KeyCode::Enter);
    assert_eq!(
        a.outgoing[0],
        json!({"type":"command","command":"connect","query":"profile:local"})
    );
}

#[test]
fn transport_failure_restores_submission_and_unlocks_approval() {
    let mut a = ready();
    a.editor.set("Keep this draft");
    key(&mut a, KeyCode::Enter);
    let packet = a.outgoing.pop().unwrap();
    a.send_failed(&packet, "queue full");
    assert_eq!(a.editor.text, "Keep this draft");
    assert!(!a.pending);
    key(&mut a, KeyCode::Enter);
    a.disconnected("EOF".into());
    assert_eq!(a.editor.text, "Keep this draft");
    a.resolving = Some("a".into());
    a.send_failed(&json!({"type":"approval"}), "writer stopped");
    assert!(a.resolving.is_none());
}

#[test]
fn reconciled_approval_never_inherits_previous_allow_choice() {
    let mut a = ready();
    a.apply(json!({"type":"approval_snapshot","approvals":[{"approval_id":"a"}]}));
    key(&mut a, KeyCode::Right);
    key(&mut a, KeyCode::Right);
    a.apply(json!({"type":"approval_snapshot","approvals":[{"approval_id":"b"}]}));
    key(&mut a, KeyCode::Enter);
    assert_eq!(a.outgoing[0]["approval_id"], "b");
    assert_eq!(a.outgoing[0]["decision"], "deny");
}

#[test]
fn identical_answers_in_separate_turns_are_retained() {
    let mut a = ready();
    for (seq, prompt) in [(1, "First"), (2, "Second")] {
        a.apply(json!({"type":"turn_started","prompt":prompt}));
        a.apply(json!({"type":"stream","event":{"type":"runtime_event","durability":"durable","goal_seq":seq,"scope":{"root?":true},"payload":{"type":"assistant_message","data":{"content":"Hello"}}}}));
        a.apply(json!({"type":"turn_finished","ok":true}));
    }
    assert_eq!(
        a.entries.iter().filter(|e| e.kind == "assistant").count(),
        2
    );
}

#[test]
fn long_approval_arguments_can_be_inspected_without_approving() {
    let mut a = ready();
    a.apply(json!({"type":"approval_requested","approval":{"approval_id":"a","tool":"run_command","arguments":{"command":"long prefix ".repeat(90) + "IMPORTANT_END"}}}));
    assert!(!render(&mut a, 80, 24).contains("IMPORTANT_END"));
    for _ in 0..30 {
        key(&mut a, KeyCode::Down);
        render(&mut a, 80, 24);
    }
    assert!(render(&mut a, 80, 24).contains("IMPORTANT_END"));
    assert!(a.outgoing.is_empty());
    assert_eq!(a.approval_choice, 0);
}

#[test]
fn another_workers_approval_ack_does_not_unlock_the_pending_decision() {
    let mut a = ready();
    a.apply(
        json!({"type":"approval_snapshot","approvals":[{"approval_id":"a"},{"approval_id":"b"}]}),
    );
    key(&mut a, KeyCode::Enter);
    a.apply(json!({"type":"approval_resolved","approval_id":"b","decision":"deny"}));
    key(&mut a, KeyCode::Enter);
    assert_eq!(a.outgoing.len(), 1);
    assert_eq!(a.resolving.as_deref(), Some("a"));
}
