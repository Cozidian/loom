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

func testModel(writer *bytes.Buffer) model {
	bridge := newProtocol(bytes.NewReader(nil), writer)
	return newModel(packet{
		Type:      "init",
		SessionID: "session-123456789",
		Workspace: "/tmp/elixir-harness",
		Provider:  "echo",
		Profile:   "echo",
		Model:     "built-in",
	}, bridge)
}
