package main

import (
	"bytes"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestProtocolRoundTrip(t *testing.T) {
	var wire bytes.Buffer
	writer := newProtocol(bytes.NewReader(nil), &wire)
	want := packet{Type: "submit", Prompt: "hello"}
	if err := writer.send(want); err != nil {
		t.Fatal(err)
	}

	reader := newProtocol(&wire, &bytes.Buffer{})
	got, err := reader.read()
	if err != nil {
		t.Fatal(err)
	}
	if got.Type != want.Type || got.Prompt != want.Prompt {
		t.Fatalf("unexpected packet: %#v", got)
	}
}

func TestViewOwnsAltScreenWithoutMouseTracking(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.resize(90, 28)
	view := m.View()

	if !view.AltScreen {
		t.Fatal("expected alternate screen")
	}
	if view.MouseMode != tea.MouseModeNone {
		t.Fatalf("mouse tracking must stay disabled, got %v", view.MouseMode)
	}
	if !bytes.Contains([]byte(view.Content), []byte("BEAM AGENT")) {
		t.Fatal("expected product header")
	}
}

func TestSubmitSendsFramedActionAndAddsUserEntry(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)
	m.composer.SetValue("hello\nworld")

	next, cmd := m.submit()
	if cmd == nil {
		t.Fatal("expected bridge command")
	}
	cmd()

	updated := next.(model)
	if updated.status != "working" || len(updated.entries) != 1 {
		t.Fatalf("unexpected submitted model: %#v", updated)
	}
	if updated.entries[0].Content != "hello\nworld" {
		t.Fatalf("unexpected prompt entry: %#v", updated.entries[0])
	}

	reader := newProtocol(&wire, &bytes.Buffer{})
	action, err := reader.read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Type != "submit" || action.Prompt != "hello\nworld" {
		t.Fatalf("unexpected action: %#v", action)
	}
}

func TestEventSlashCommandForwardsFiltersToElixir(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)

	next, cmd := m.runSlash("/events category=tool worker=children limit=12")
	if cmd == nil {
		t.Fatal("expected bridge command")
	}
	cmd()

	updated := next.(model)
	if updated.notice != "Loading events…" {
		t.Fatalf("unexpected notice: %q", updated.notice)
	}

	reader := newProtocol(&wire, &bytes.Buffer{})
	action, err := reader.read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Type != "command" || action.Command != "events" {
		t.Fatalf("unexpected action: %#v", action)
	}
	if action.Query != "category=tool worker=children limit=12" {
		t.Fatalf("filters were not preserved: %#v", action)
	}
}

func TestModelsSlashCommandForwardsHealthRefresh(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)

	_, cmd := m.runSlash("/models refresh")
	if cmd == nil {
		t.Fatal("expected bridge command")
	}
	cmd()

	reader := newProtocol(&wire, &bytes.Buffer{})
	action, err := reader.read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Command != "models" || action.Query != "refresh" {
		t.Fatalf("unexpected models action: %#v", action)
	}
}

func TestStreamedAnswerIsNotDuplicatedByDurableEvent(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyStream(map[string]any{
		"type":        "text_delta",
		"response_id": "response-1",
		"delta":       "hello",
	})
	m.applyStream(map[string]any{
		"type": "durable_event",
		"event": map[string]any{
			"type": "assistant_message",
			"data": map[string]any{"content": "hello"},
		},
	})

	if len(m.entries) != 1 || m.entries[0].Content != "hello" {
		t.Fatalf("expected one assistant entry, got %#v", m.entries)
	}
}

func TestRuntimeEventsRenderGoalAndSubagentActivityWithoutNilAssistant(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyStream(runtimeEvent("session_started", map[string]any{}, "session-root", true))
	m.applyStream(runtimeEvent("assistant_message", map[string]any{"content": nil}, "session-root", true))
	m.applyStream(runtimeEvent("assistant_message", map[string]any{"content": "4"}, "session-root", true))
	m.applyStream(runtimeEvent("turn_finished", map[string]any{"reason": "completed"}, "session-root", true))
	m.applyStream(runtimeEvent(
		"agent_started",
		map[string]any{"provider": "ollama", "model": "qwen3:8b", "recovered": false},
		"session-child",
		false,
	))

	if len(m.entries) != 3 {
		t.Fatalf("expected two info entries, one answer, and no nil assistant, got %#v", m.entries)
	}
	if m.entries[0].Kind != "info" || m.entries[1].Kind != "assistant" || m.entries[2].Kind != "info" {
		t.Fatalf("expected runtime info entries, got %#v", m.entries)
	}
	if m.entries[1].Content != "4" {
		t.Fatalf("expected the root answer to render, got %#v", m.entries)
	}
	if bytes.Contains([]byte(m.View().Content), []byte("AGENT\nnil")) {
		t.Fatal("nil assistant content must not render")
	}
	if bytes.Contains([]byte(m.View().Content), []byte("Subagent completed · session root")) {
		t.Fatal("the root turn must not render as a completed subagent")
	}
}

func TestRuntimeEventsExplainRepeatedToolRecovery(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyStream(runtimeEvent(
		"tool_loop_stalled",
		map[string]any{"repetitions": float64(3)},
		"session-root",
		true,
	))

	if len(m.entries) != 1 || m.entries[0].Kind != "info" {
		t.Fatalf("expected one recovery info entry, got %#v", m.entries)
	}
	if m.entries[0].Content != "Repeated tool result ×3 · switching to answer-only" {
		t.Fatalf("unexpected recovery entry: %#v", m.entries[0])
	}
}

func TestRuntimeEventAdvancesGoalCursor(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	event := runtimeEvent("command_received", map[string]any{}, "session-root", true)
	event["goal_seq"] = float64(42)
	m.applyStream(event)

	if m.cursor != 42 {
		t.Fatalf("expected cursor 42, got %d", m.cursor)
	}
}

func TestApprovalStartsFailClosed(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "approval_requested",
		Approval: map[string]any{
			"approval_id": "approval-1",
			"tool":        "run_command",
			"access":      "execute",
			"arguments":   map[string]any{"command": "mix test"},
		},
	})

	if m.approval == nil || m.approval.Choice != "deny" {
		t.Fatalf("approval must default to deny: %#v", m.approval)
	}
}

func TestAutoModeIsVisibleAndClearsApproval(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "approval_requested",
		Approval: map[string]any{
			"approval_id": "approval-1",
			"tool":        "run_command",
			"access":      "execute",
		},
	})
	m.applyBackend(packet{Type: "approval_mode", ApprovalMode: "auto"})

	if m.approval != nil {
		t.Fatal("auto mode should dismiss a pending approval")
	}
	if m.approvalMode != "auto" {
		t.Fatalf("expected auto mode, got %q", m.approvalMode)
	}
	if !bytes.Contains([]byte(m.View().Content), []byte("AUTO")) {
		t.Fatal("auto mode must be visible in the header")
	}
}

func testModel(writer *bytes.Buffer) model {
	bridge := newProtocol(bytes.NewReader(nil), writer)
	return newModel(packet{
		Type:         "init",
		SessionID:    "session-123456789",
		Workspace:    "/tmp/elixir-harness",
		Provider:     "echo",
		Profile:      "echo",
		Model:        "built-in",
		ApprovalMode: "ask",
	}, bridge)
}

func runtimeEvent(eventType string, data map[string]any, sessionID string, root bool) map[string]any {
	return map[string]any{
		"type":       "runtime_event",
		"durability": "durable",
		"scope": map[string]any{
			"session_id": sessionID,
			"root?":      root,
		},
		"payload": map[string]any{
			"type": eventType,
			"data": data,
		},
	}
}
