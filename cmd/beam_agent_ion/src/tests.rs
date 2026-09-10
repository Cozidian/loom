use crate::{
    app::{App, View},
    ui,
};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::json;

fn key(a: &mut App, code: KeyCode) {
    a.key(KeyEvent::new(code, KeyModifiers::NONE));
}
fn ctrl(a: &mut App, c: char) {
    a.key(KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL));
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

fn settings(a: &mut App) {
    a.apply(json!({"type":"provider_settings","revision":"rev1","model_strategy":"auto",
        "providers":[{"profile":"cloud","provider":"openai","model":"old-model","api_key_env":"OPENAI_API_KEY","auth_mode":"environment"}],
        "kinds":[{"provider":"echo","model":null}]}));
}

fn durable_event(a: &mut App, seq: u64, worker: &str, kind: &str, data: serde_json::Value) {
    a.apply(json!({"type":"stream","event":{"type":"runtime_event","durability":"durable","goal_seq":seq,
        "scope":{"session_id":worker,"root?":worker=="root"},"payload":{"type":kind,"data":data}}}));
}

#[test]
fn mission_distinguishes_queued_and_running_subagents() {
    let mut a = ready();
    durable_event(
        &mut a,
        1,
        "root",
        "worker_queued",
        json!({"worker_id":"child"}),
    );
    assert!(a.activity.contains("worker capacity"));
    assert!(a.entries.iter().any(|e| e.text.contains("Subagent queued")));
    durable_event(
        &mut a,
        2,
        "root",
        "work_run_task_attempt_started",
        json!({"task_id":"frontend"}),
    );
    assert!(a.activity.contains("frontend"));
}

#[test]
fn mission_tracks_tools_without_model_commentary_and_deduplicates_replay() {
    let mut a = ready();
    a.apply(json!({"type":"turn_started","prompt":"Build Phoenix"}));
    durable_event(
        &mut a,
        1,
        "root",
        "work_planning_decided",
        json!({"reason":"Pinned owner; automatic team"}),
    );
    durable_event(
        &mut a,
        2,
        "root",
        "tool_called",
        json!({"tool_call_id":"read1","name":"read_file","arguments":{"path":"lib/router.ex"}}),
    );
    assert!(a.activity.contains("lib/router.ex"));
    assert!(render(&mut a, 100, 30).contains("lib/router.ex"));
    durable_event(
        &mut a,
        3,
        "root",
        "tool_result",
        json!({"tool_call_id":"read1","name":"read_file","content":"PRIVATE_TOOL_DETAIL","is_error":false,"error":null}),
    );
    assert_eq!(a.tool_count, 1);
    assert!(a.active_tools.is_empty());
    assert_eq!(a.entries.iter().filter(|e| e.kind == "tool").count(), 1);
    assert!(!render(&mut a, 100, 30).contains("PRIVATE_TOOL_DETAIL"));
    ctrl(&mut a, 't');
    assert!(render(&mut a, 100, 30).contains("PRIVATE_TOOL_DETAIL"));
    durable_event(
        &mut a,
        3,
        "root",
        "tool_result",
        json!({"tool_call_id":"read1","name":"read_file"}),
    );
    assert_eq!(a.tool_count, 1);
    assert_eq!(a.activity, "Waiting for provider");
    a.last_activity = Some(std::time::Instant::now() - std::time::Duration::from_secs(65));
    assert!(render(&mut a, 100, 30).contains("65s since last activity"));
    a.apply(json!({"type":"turn_finished","ok":true}));
    assert!(!render(&mut a, 100, 30).contains("since last activity"));
}

#[test]
fn helper_tools_do_not_collide_with_owner_and_errors_are_visible() {
    let mut a = ready();
    for (seq, worker) in [(1, "root"), (2, "helper")] {
        durable_event(
            &mut a,
            seq,
            worker,
            "tool_called",
            json!({"tool_call_id":"same","name":"read_file","arguments":{"path":"README.md"}}),
        );
    }
    durable_event(
        &mut a,
        3,
        "helper",
        "tool_result",
        json!({"tool_call_id":"same","name":"read_file","is_error":true,"error":"denied"}),
    );
    assert_eq!(a.active_tools.len(), 1);
    assert!(a.entries.iter().any(|e| e.text.starts_with("! subagent")));
    assert!(a.entries.iter().any(|e| e.text.starts_with("… read_file")));
}

#[test]
fn summaries_and_command_output_are_separate_from_final_answers() {
    let mut a = ready();
    for delta in ["Checking ", "the API"] {
        a.apply(json!({"type":"stream","event":{"type":"reasoning_summary_delta","response_id":"r1","item_id":"i1","summary_index":0,"delta":delta}}));
    }
    assert_eq!(a.entries.back().unwrap().text, "Checking the API");
    assert_eq!(a.entries.back().unwrap().kind, "reasoning");
    a.apply(
        json!({"type":"stream","event":{"type":"command_output_delta","delta":"3 tests passed"}}),
    );
    assert!(render(&mut a, 100, 30).contains("3 tests passed"));
    durable_event(
        &mut a,
        1,
        "root",
        "assistant_message",
        json!({"content":"Done"}),
    );
    assert_eq!(
        a.entries.iter().filter(|e| e.kind == "assistant").count(),
        1
    );
    assert_eq!(
        a.entries.iter().filter(|e| e.kind == "reasoning").count(),
        1
    );
}

#[test]
fn model_picker_preserves_automatic_team_when_pinning_owner() {
    let mut a = ready();
    settings(&mut a);
    a.team_mode = "auto".into();
    key(&mut a, KeyCode::Char('u'));
    ctrl(&mut a, 's');
    let request = a.outgoing.pop().unwrap();
    assert_eq!(request["strategy"], "manual");
    assert_eq!(request["team_mode"], "auto");
}

#[test]
fn model_selection_uses_catalogue_and_explicit_save_without_submitting() {
    let mut a = ready();
    a.editor.set("unfinished draft");
    a.apply(json!({"type":"models","endpoints":[{"id":"cloud","model":"old-model"}]}));
    key(&mut a, KeyCode::Enter);
    assert_eq!(
        a.outgoing.pop().unwrap(),
        json!({"type":"provider_settings","action":"catalog","profile":"cloud"})
    );
    a.apply(json!({"type":"model_catalog","profile":"cloud","revision":"rev1","models":[{"model":"new-model","displayName":"New model"}]}));
    key(&mut a, KeyCode::Enter);
    assert!(a.outgoing.is_empty());
    let form = a.settings_form.as_ref().unwrap();
    assert_eq!(form.fields[0].1.text, "new-model");
    assert_eq!(form.fields[1].1.text, "manual");
    key(&mut a, KeyCode::Enter);
    assert!(a.outgoing.is_empty());
    ctrl(&mut a, 's');
    let packet = a.outgoing.pop().unwrap();
    assert_eq!(packet["action"], "select");
    assert_eq!(packet["model"], "new-model");
    assert_eq!(packet["strategy"], "manual");
    assert_eq!(packet["revision"], "rev1");
    assert!(a.settings_pending);
    ctrl(&mut a, 's');
    assert!(a.outgoing.is_empty());
    assert_eq!(a.model, "");
    a.apply(json!({"type":"settings_applied","profile":"cloud","model":"new-model","model_strategy":"manual"}));
    assert_eq!(a.model, "new-model");
    assert_eq!(a.session, "root");
    assert_eq!(a.editor.text, "unfinished draft");
    assert!(a.settings_form.is_none());
}

#[test]
fn provider_forms_add_edit_cancel_and_confirm_deletion() {
    let mut a = ready();
    settings(&mut a);
    key(&mut a, KeyCode::Char('n'));
    key(&mut a, KeyCode::Enter);
    assert!(a.settings_form.is_some());
    for c in "local".chars() {
        key(&mut a, KeyCode::Char(c));
    }
    ctrl(&mut a, 's');
    let packet = a.outgoing.pop().unwrap();
    assert_eq!(packet["profile"], "local");
    assert_eq!(packet["fields"]["provider"], "echo");
    assert_eq!(packet["fields"]["auth_mode"], "environment");
    assert_eq!(packet["editing"], false);
    a.apply(json!({"type":"settings_failed","message":"Profile already exists"}));
    assert!(!a.settings_pending);
    assert!(a.settings_form.is_some());
    assert!(render(&mut a, 100, 30).contains("Profile already exists"));
    key(&mut a, KeyCode::Esc);
    settings(&mut a);
    key(&mut a, KeyCode::Char('e'));
    assert_eq!(a.settings_form.as_ref().unwrap().fields[0].0, "model");
    ctrl(&mut a, 'u');
    for c in "edited-model".chars() {
        key(&mut a, KeyCode::Char(c));
    }
    ctrl(&mut a, 's');
    let packet = a.outgoing.pop().unwrap();
    assert_eq!(packet["editing"], true);
    assert_eq!(packet["fields"]["model"], "edited-model");
    assert!(packet["fields"].get("api_key").is_none());
    a.apply(json!({"type":"settings_applied","profile":"cloud","model":"edited-model","model_strategy":"auto"}));
    settings(&mut a);
    key(&mut a, KeyCode::Char('x'));
    assert!(a.settings_confirm.is_some());
    key(&mut a, KeyCode::Esc);
    assert!(a.outgoing.is_empty());
    key(&mut a, KeyCode::Char('x'));
    key(&mut a, KeyCode::Enter);
    assert_eq!(a.outgoing.pop().unwrap()["action"], "delete");
}

#[test]
fn manual_model_form_can_set_auto_and_survives_disconnect_and_small_terminals() {
    let mut a = ready();
    a.apply(json!({"type":"model_catalog","profile":"cloud","revision":"rev1","models":[],"configured_model":"old-model","discovery":"manual"}));
    key(&mut a, KeyCode::Char('m'));
    for (w, h) in [(160, 45), (80, 24), (40, 12), (20, 6)] {
        render(&mut a, w, h);
    }
    key(&mut a, KeyCode::Tab);
    ctrl(&mut a, 'u');
    for c in "auto".chars() {
        key(&mut a, KeyCode::Char(c));
    }
    ctrl(&mut a, 's');
    assert_eq!(a.outgoing.pop().unwrap()["strategy"], "auto");
    a.disconnected("test".into());
    assert!(!a.settings_pending);
    key(&mut a, KeyCode::Esc);
    assert!(a.settings_form.is_none());
}

#[test]
fn providers_command_and_models_shortcut_request_runtime_settings() {
    let mut a = ready();
    a.editor.set("/providers");
    key(&mut a, KeyCode::Enter);
    assert_eq!(
        a.outgoing.pop().unwrap(),
        json!({"type":"provider_settings","action":"list"})
    );
    settings(&mut a);
    a.apply(json!({"type":"models","endpoints":[]}));
    key(&mut a, KeyCode::Char('p'));
    assert_eq!(a.outgoing.pop().unwrap()["action"], "list");
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

#[test]
fn menu_help_stays_pinned_and_selection_only_scrolls_at_the_edge() {
    for (kind, field) in [
        ("events", "events"),
        ("models", "endpoints"),
        ("files", "changed"),
        ("sessions", "sessions"),
        ("provider_picker", "providers"),
    ] {
        let mut a = ready();
        let rows: Vec<_> = (0..40).map(|i| json!({"type":format!("row{i:02}"),"id":format!("row{i:02}"),"path":format!("row{i:02}"),"session_id":format!("row{i:02}"),"profile":format!("row{i:02}")})).collect();
        a.apply(json!({"type":kind,field:rows}));
        let before = render(&mut a, 100, 24);
        let help_row = before.lines().position(|l| l.contains("Esc back")).unwrap();
        key(&mut a, KeyCode::Down);
        let after = render(&mut a, 100, 24);
        assert_eq!(a.selection, 1);
        assert_eq!(a.drawer_scroll, 0);
        assert_eq!(after.lines().nth(help_row), before.lines().nth(help_row));
        assert!(after.contains("row00"));
        key(&mut a, KeyCode::End);
        let end = render(&mut a, 100, 24);
        assert!(end.contains("row39"));
        assert_eq!(end.lines().nth(help_row), before.lines().nth(help_row));
        key(&mut a, KeyCode::Down);
        assert_eq!(end, render(&mut a, 100, 24));
        key(&mut a, KeyCode::Home);
        render(&mut a, 100, 24);
        assert_eq!(a.drawer_scroll, 0);
    }
}

#[test]
fn detail_scroll_is_bounded_and_escape_returns_to_selected_event() {
    let mut a = ready();
    a.apply(json!({"type":"events","events":[{"type":"first"},{"type":"second","data":"a"}]}));
    key(&mut a, KeyCode::Down);
    key(&mut a, KeyCode::Enter);
    for _ in 0..100 {
        key(&mut a, KeyCode::PageDown);
    }
    assert!(render(&mut a, 100, 24).contains("second"));
    assert_eq!(a.drawer_scroll, 0);
    key(&mut a, KeyCode::Esc);
    assert_eq!(a.selection, 1);
    assert_eq!(a.drawer.as_ref().unwrap()["type"], "events");
}

#[test]
fn prompt_history_loads_runtime_prompts_preserves_draft_and_never_sends_on_recall() {
    let mut a = ready();
    a.apply(json!({"type":"init","entries":[{"kind":"user","content":"old 👩‍💻"},{"kind":"assistant","content":"not a prompt"},{"kind":"user","content":"recent\nmultiline"}]}));
    a.editor.set("unfinished");
    a.editor.cursor = 3;
    key(&mut a, KeyCode::Up);
    assert_eq!(a.editor.text, "recent\nmultiline");
    key(&mut a, KeyCode::Up);
    assert_eq!(a.editor.text, "old 👩‍💻");
    key(&mut a, KeyCode::Down);
    key(&mut a, KeyCode::Down);
    assert_eq!(a.editor.text, "unfinished");
    assert_eq!(a.editor.cursor, 3);
    assert!(a.outgoing.is_empty());
    ctrl(&mut a, 'r');
    key(&mut a, KeyCode::Char('o'));
    key(&mut a, KeyCode::Char('l'));
    key(&mut a, KeyCode::Char('d'));
    assert_eq!(a.rows().len(), 1);
    key(&mut a, KeyCode::Enter);
    assert_eq!(a.editor.text, "old 👩‍💻");
    assert!(a.outgoing.is_empty());
    key(&mut a, KeyCode::Enter);
    assert_eq!(a.outgoing[0]["prompt"], "old 👩‍💻");
}

#[test]
fn failed_prompts_are_recallable_and_multiline_arrows_still_edit() {
    let mut a = ready();
    a.editor.set("retry me");
    key(&mut a, KeyCode::Enter);
    a.apply(json!({"type":"turn_finished","ok":false,"error":"model rejected"}));
    a.outgoing.clear();
    key(&mut a, KeyCode::Up);
    assert_eq!(a.editor.text, "retry me");
    assert!(a.outgoing.is_empty());
    a.leave_history();
    a.editor.set("first\nsecond");
    key(&mut a, KeyCode::Up);
    assert_eq!(a.editor.text, "first\nsecond");
    assert_eq!(a.editor.cursor, 5);
    assert!(a.history_index.is_none());
}

#[test]
fn slash_completion_supports_prefixes_and_selection_without_execution() {
    let mut a = ready();
    a.editor.set("/a");
    assert_eq!(a.slash_matches(), vec!["auto", "attach"]);
    assert!(render(&mut a, 100, 24).contains("/auto"));
    key(&mut a, KeyCode::Enter);
    assert_eq!(a.editor.text, "/auto ");
    assert!(a.outgoing.is_empty());
    key(&mut a, KeyCode::Enter);
    assert_eq!(
        a.outgoing[0],
        json!({"type":"command","command":"auto","query":""})
    );
    assert_eq!(a.approval_mode, "ask");
    a.editor.set("/a existing args");
    a.editor.cursor = 2;
    a.dismiss_picker = false;
    key(&mut a, KeyCode::Down);
    key(&mut a, KeyCode::Tab);
    assert_eq!(a.editor.text, "/attach existing args");
    a.editor.set("/doesnotexist");
    a.dismiss_picker = false;
    assert!(a.slash_matches().is_empty());
    key(&mut a, KeyCode::Tab);
    assert_eq!(a.editor.text, "/doesnotexist");
}

#[test]
fn copying_is_explicit_full_text_and_local_only() {
    let mut a = ready();
    a.apply(json!({"type":"stream","event":{"type":"text_delta","response_id":"r","delta":"Result 👩‍💻\nwith code"}}));
    assert!(a.clipboard.is_none());
    ctrl(&mut a, 'y');
    assert_eq!(a.clipboard.take().unwrap(), "Result 👩‍💻\nwith code");
    assert!(a.outgoing.is_empty());
    a.editor.set("/output");
    key(&mut a, KeyCode::Enter);
    key(&mut a, KeyCode::Enter);
    ctrl(&mut a, 'y');
    assert_eq!(a.clipboard.take().unwrap(), "Result 👩‍💻\nwith code");
    assert!(a.outgoing.is_empty());
    a.apply(json!({"type":"approval_requested","approval":{"approval_id":"a","arguments":{"command":"inspect me"}}}));
    ctrl(&mut a, 'y');
    assert!(a.clipboard.take().unwrap().contains("inspect me"));
    assert!(a.outgoing.is_empty());
    assert!(a.resolving.is_none());
}
