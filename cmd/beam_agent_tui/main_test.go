package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
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

func TestViewOwnsAltScreenWithTranscriptMouseTracking(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.resize(90, 28)
	view := m.View()

	if !view.AltScreen {
		t.Fatal("expected alternate screen")
	}
	if view.MouseMode != tea.MouseModeCellMotion {
		t.Fatalf("expected wheel-capable mouse tracking, got %v", view.MouseMode)
	}
	if !bytes.Contains([]byte(view.Content), []byte("BEAM")) {
		t.Fatal("expected product wordmark in the tab strip")
	}
	if !bytes.Contains([]byte(view.Content), []byte("1 chat")) {
		t.Fatal("expected the chat tab in the tab strip")
	}
}

func TestTranscriptScrollDoesNotStealComposerInput(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.resize(90, 12)
	for i := 0; i < 30; i++ {
		m.entries = append(m.entries, entry{Kind: "system", Content: "line"})
	}
	m.refreshTranscript(true)

	next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyPgUp})
	scrolled := next.(model)
	if scrolled.viewport.AtBottom() {
		t.Fatal("expected Page Up to move the transcript viewport")
	}

	next, _ = scrolled.Update(tea.KeyPressMsg{Code: 'j', Text: "j"})
	typed := next.(model)
	if typed.composer.Value() != "j" {
		t.Fatalf("expected normal typing to remain in the composer, got %q", typed.composer.Value())
	}
}

func TestTranscriptKeepsScrollPositionWhileNewEventsArrive(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.resize(90, 12)
	for i := 0; i < 30; i++ {
		m.entries = append(m.entries, entry{Kind: "system", Content: "line"})
	}
	m.refreshTranscript(true)
	m.viewport.PageUp()
	offset := m.viewport.YOffset()

	m.entries = append(m.entries, entry{Kind: "system", Content: "new line"})
	m.refreshTranscript(true)
	if m.viewport.YOffset() != offset {
		t.Fatalf("expected transcript offset %d to be preserved, got %d", offset, m.viewport.YOffset())
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

func TestClipboardImageImportAndImageOnlySubmitUseRuntimeAttachments(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)

	next, cmd := m.Update(clipboardImageMsg{image: clipboardImage{
		Data:     "iVBORw0KGgo=",
		Name:     "pasted-image.png",
		MIMEType: "image/png",
	}})
	if cmd == nil {
		t.Fatal("expected attachment import command")
	}
	cmd()

	reader := newProtocol(&wire, &bytes.Buffer{})
	importAction, err := reader.read()
	if err != nil {
		t.Fatal(err)
	}
	if importAction.Type != "attachment_import" || importAction.Data != "iVBORw0KGgo=" || importAction.Provenance != "clipboard" {
		t.Fatalf("unexpected import action: %#v", importAction)
	}

	updated := next.(model)
	updated.applyBackend(packet{Type: "attachment_imported", Attachment: &attachmentItem{
		ID:        "attachment-1",
		Name:      "pasted-image.png",
		MIMEType:  "image/png",
		Width:     20,
		Height:    10,
		SizeBytes: 42,
	}})

	var submitWire bytes.Buffer
	updated.protocol = newProtocol(bytes.NewReader(nil), &submitWire)
	submitted, submitCmd := updated.submit()
	if submitCmd == nil {
		t.Fatal("expected image-only submit command")
	}
	submitCmd()

	submitAction, err := newProtocol(&submitWire, &bytes.Buffer{}).read()
	if err != nil {
		t.Fatal(err)
	}
	if submitAction.Type != "submit" || submitAction.Prompt != "" || len(submitAction.Attachments) != 1 {
		t.Fatalf("unexpected image submit action: %#v", submitAction)
	}
	if submitAction.Attachments[0].ID != "attachment-1" {
		t.Fatalf("missing stable attachment reference: %#v", submitAction.Attachments)
	}
	if !strings.Contains(submitted.(model).entries[0].Content, "pasted-image.png") {
		t.Fatalf("expected attachment summary in user entry: %#v", submitted.(model).entries[0])
	}
}

func TestFailedImageTurnRestoresAttachmentForRetry(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.attachments = []attachmentItem{{ID: "attachment-1", Name: "pasted-image.png"}}

	next, _ := m.submit()
	working := next.(model)
	working.applyBackend(packet{Type: "turn_started"})
	if len(working.attachments) != 0 {
		t.Fatalf("submitted attachments should leave the composer: %#v", working.attachments)
	}

	working.applyBackend(packet{Type: "turn_finished", OK: false, Error: "provider unavailable"})
	if len(working.attachments) != 1 || working.attachments[0].ID != "attachment-1" {
		t.Fatalf("failed turn must restore its attachment: %#v", working.attachments)
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

func TestSteerSlashCommandForwardsMessageToRuntime(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)

	_, cmd := m.runSlash("/steer focus on the failing test")
	if cmd == nil {
		t.Fatal("expected bridge command")
	}
	cmd()

	action, err := newProtocol(&wire, &bytes.Buffer{}).read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Type != "command" || action.Command != "steer" || action.Query != "focus on the failing test" {
		t.Fatalf("unexpected steering action: %#v", action)
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

func TestRaceSlashCommandIsDiscoverableAndForwardsTheGoal(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)

	next, cmd := m.runSlash("/race implement clipboard image paste")
	if cmd == nil {
		t.Fatal("expected provider race bridge command")
	}
	cmd()

	updated := next.(model)
	if updated.status != "providers bidding" || len(updated.entries) != 1 {
		t.Fatalf("expected an immediately visible provider race, got %#v", updated)
	}

	action, err := newProtocol(&wire, &bytes.Buffer{}).read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Command != "race" || action.Query != "implement clipboard image paste" {
		t.Fatalf("unexpected race action: %#v", action)
	}
}

func TestTournamentSlashCommandIsDiscoverableAndForwardsTheGoal(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)

	next, cmd := m.runSlash("/tournament implement clipboard image paste")
	if cmd == nil {
		t.Fatal("expected provider tournament bridge command")
	}
	cmd()

	updated := next.(model)
	if !strings.Contains(updated.entries[0].Content, "Tournament providers") {
		t.Fatalf("expected an immediately visible tournament, got %#v", updated.entries)
	}

	action, err := newProtocol(&wire, &bytes.Buffer{}).read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Command != "tournament" || action.Query != "implement clipboard image paste" {
		t.Fatalf("unexpected tournament action: %#v", action)
	}
}

func TestRaceSlashCommandDoesNotSilentlyDropAttachments(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.attachments = []attachmentItem{{ID: "attachment-1", Name: "clipboard.png"}}

	next, cmd := m.runSlash("/race inspect this image")
	if cmd != nil {
		t.Fatal("attachment race should not be submitted until child attachment propagation exists")
	}
	updated := next.(model)
	if !strings.Contains(updated.notice, "text goals only") {
		t.Fatalf("expected an honest attachment limitation, got %q", updated.notice)
	}
}

func TestProviderPickerSelectsAProfileThroughTheRuntime(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)
	m.applyBackend(packet{
		Type: "provider_picker",
		Providers: []providerOption{
			{Profile: "grok", Provider: "xai", Model: "grok", Auth: "API key", Status: "ready", Connected: true, Active: true},
			{Profile: "openai-chatgpt", Provider: "openai", Model: "gpt-5.4", Auth: "ChatGPT subscription", Status: "ChatGPT available"},
		},
	})

	if m.sheet != sheetProviderPicker || !bytes.Contains([]byte(m.View().Content), []byte("Connect a provider")) {
		t.Fatalf("expected provider picker modal, got %#v", m)
	}

	next, _ := m.updateProviderPicker("down")
	selected := next.(model)
	next, cmd := selected.updateProviderPicker("enter")
	if cmd == nil {
		t.Fatal("expected provider selection bridge command")
	}
	cmd()

	updated := next.(model)
	if updated.sheet == sheetProviderPicker {
		t.Fatal("provider picker should close after selection")
	}

	reader := newProtocol(&wire, &bytes.Buffer{})
	action, err := reader.read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Command != "connect" || action.Query != "profile:openai-chatgpt" {
		t.Fatalf("unexpected provider action: %#v", action)
	}
}

func TestSessionChangeRefreshesTheVisibleProvider(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type:      "session_changed",
		SessionID: "session-new",
		Provider:  "openai",
		Profile:   "openai-chatgpt",
		Model:     "gpt-5.4",
	})

	if m.provider != "openai" || m.profile != "openai-chatgpt" || m.llmModel != "gpt-5.4" {
		t.Fatalf("provider header was not refreshed: %#v", m)
	}
}

func TestInitialAndChangedSessionsRestoreDraftAttachments(t *testing.T) {
	initial := packet{
		Type:         "init",
		SessionID:    "session-old",
		Workspace:    "/tmp/elixir-harness",
		Provider:     "echo",
		Profile:      "echo",
		Model:        "built-in",
		ApprovalMode: "ask",
		Attachments:  []attachmentItem{{ID: "attachment-old", Name: "old.png"}},
	}
	m := newModel(initial, newProtocol(bytes.NewReader(nil), &bytes.Buffer{}))
	if len(m.attachments) != 1 || m.attachments[0].ID != "attachment-old" {
		t.Fatalf("expected initial drafts to be restored: %#v", m.attachments)
	}

	m.applyBackend(packet{
		Type:        "session_changed",
		SessionID:   "session-new",
		Attachments: []attachmentItem{{ID: "attachment-new", Name: "new.png"}},
	})
	if len(m.attachments) != 1 || m.attachments[0].ID != "attachment-new" {
		t.Fatalf("expected changed session drafts to replace old drafts: %#v", m.attachments)
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
	m.applyStream(runtimeEvent(
		"task_outcome_recorded",
		map[string]any{
			"status":       "succeeded",
			"verification": map[string]any{"status": "unverified"},
		},
		"session-root",
		true,
	))

	if len(m.entries) != 4 {
		t.Fatalf("expected three info entries, one answer, and no nil assistant, got %#v", m.entries)
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
	if m.entries[2].Content != "Subagent default · session child · ollama/qwen3:8b" {
		t.Fatal("the inherited child model must be labeled as a default")
	}
	if m.entries[3].Content != "Task outcome · succeeded · unverified" {
		t.Fatal("task outcomes must expose their verification state")
	}
}

func TestSpineGlyphMarksUserRootAndSubagentLines(t *testing.T) {
	entries := []entry{
		{Kind: "user", Content: "fix the bug", Role: spineUser},
		{Kind: "assistant", Content: "on it", Role: spineRoot},
		{Kind: "tool", Content: "", Name: "read", Role: spineSubagent, SessionID: "session-child"},
		{Kind: "info", Content: "Subagent finished", Role: spineSubagent, SessionID: "session-child"},
		{Kind: "info", Content: "MCP ready", Role: spineSystem},
	}
	glyphs := spineGlyphs(entries)
	want := []string{"▌", "│", "├", "╰", "·"}
	for i, g := range want {
		if glyphs[i] != g {
			t.Fatalf("entry %d: expected glyph %q, got %q (all: %v)", i, g, glyphs[i], glyphs)
		}
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

func TestInitialPendingWorkerApprovalIsRestored(t *testing.T) {
	m := newModel(packet{
		Type:         "init",
		SessionID:    "session-root",
		Workspace:    "/tmp/elixir-harness",
		Provider:     "echo",
		Profile:      "echo",
		Model:        "built-in",
		ApprovalMode: "ask",
		Approvals: []map[string]any{{
			"approval_id": "approval-child",
			"session_id":  "session-child-123456",
			"tool":        "create_file",
			"access":      "write",
			"arguments":   map[string]any{"path": "lib/example.ex"},
		}},
	}, newProtocol(bytes.NewReader(nil), &bytes.Buffer{}))

	if m.approval == nil || m.approval.ID != "approval-child" {
		t.Fatalf("expected recovered approval, got %#v", m.approval)
	}
	if m.approval.SessionID != "session-child-123456" {
		t.Fatalf("expected worker identity, got %#v", m.approval)
	}
	if m.status != "waiting approval" {
		t.Fatalf("expected visible waiting state, got %q", m.status)
	}
}

func TestNestedApprovalsQueueAndResolveInOrder(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "approval_requested",
		Approval: map[string]any{
			"approval_id": "approval-1",
			"session_id":  "session-child-1",
			"tool":        "create_file",
			"access":      "write",
		},
	})
	m.applyBackend(packet{
		Type: "approval_requested",
		Approval: map[string]any{
			"approval_id": "approval-2",
			"session_id":  "session-child-2",
			"tool":        "run_command",
			"access":      "execute",
		},
	})
	m.applyBackend(packet{
		Type: "approval_requested",
		Approval: map[string]any{
			"approval_id": "approval-2",
			"session_id":  "session-child-2",
			"tool":        "run_command",
			"access":      "execute",
		},
	})

	if m.approval == nil || m.approval.ID != "approval-1" || len(m.approvalQueue) != 1 {
		t.Fatalf("expected one active and one queued approval, got %#v / %#v", m.approval, m.approvalQueue)
	}

	m.applyBackend(packet{Type: "approval_resolved", ApprovalID: "approval-1", Decision: "allow_once"})
	if m.approval == nil || m.approval.ID != "approval-2" {
		t.Fatalf("expected the second approval to be promoted, got %#v", m.approval)
	}
	if m.status != "waiting approval" {
		t.Fatalf("expected waiting state to remain while queued work exists, got %q", m.status)
	}

	m.applyBackend(packet{Type: "approval_resolved", ApprovalID: "approval-2", Decision: "deny"})
	if m.approval != nil || len(m.approvalQueue) != 0 {
		t.Fatalf("expected the approval queue to be empty, got %#v / %#v", m.approval, m.approvalQueue)
	}
	if m.status != "ready" {
		t.Fatalf("expected the prior status to be restored, got %q", m.status)
	}
}

func TestApprovalSheetDocksBelowVisibleTranscript(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.resize(90, 28)
	m.entries = append(m.entries, entry{Kind: "assistant", Content: "the transcript stays visible"})
	m.refreshTranscript(true)
	m.applyBackend(packet{
		Type: "approval_requested",
		Approval: map[string]any{
			"approval_id": "approval-1",
			"tool":        "run_command",
			"access":      "execute",
		},
	})
	m.resize(m.width, m.height)

	content := m.View().Content
	transcriptAt := bytes.Index([]byte(content), []byte("the transcript stays visible"))
	sheetAt := bytes.Index([]byte(content), []byte("Approval required"))
	if transcriptAt < 0 {
		t.Fatal("expected the transcript to still be visible above the approval sheet")
	}
	if sheetAt < 0 {
		t.Fatal("expected the approval sheet to render")
	}
	if transcriptAt > sheetAt {
		t.Fatal("expected the transcript to appear before the docked sheet, not be replaced by it")
	}
}

func TestApprovalCanPersistAScopedGrant(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)
	m.applyBackend(packet{
		Type: "approval_requested",
		Approval: map[string]any{
			"approval_id": "approval-1",
			"tool":        "run_command",
			"access":      "execute",
		},
	})

	next, _ := m.updateApproval("right")
	next, _ = next.(model).updateApproval("right")
	selected := next.(model)
	if selected.approval.Choice != "allow_always" {
		t.Fatalf("expected allow_always, got %q", selected.approval.Choice)
	}

	submitted, cmd := selected.updateApproval("enter")
	pending := submitted.(model)
	if pending.approval == nil || !pending.approval.Resolving {
		t.Fatalf("approval must remain visible until runtime acknowledgement: %#v", pending.approval)
	}
	cmd()
	reader := newProtocol(&wire, &bytes.Buffer{})
	action, err := reader.read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Decision != "allow_always" {
		t.Fatalf("expected durable approval action, got %#v", action)
	}
}

func TestApprovalDecisionFailureStaysVisibleAndCanRetry(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)
	m.applyBackend(packet{
		Type: "approval_requested",
		Approval: map[string]any{
			"approval_id": "approval-1",
			"session_id":  "session-child",
			"tool":        "create_file",
			"access":      "write",
		},
	})

	submitted, cmd := m.resolveApproval("allow_once")
	cmd()
	updated := submitted.(model)
	if updated.approval == nil || !updated.approval.Resolving {
		t.Fatalf("expected resolving approval to remain active, got %#v", updated.approval)
	}

	updated.applyBackend(packet{Type: "approval_failed", ApprovalID: "approval-1", Error: "unknown approval"})
	if updated.approval == nil || updated.approval.Resolving || updated.approval.Error != "unknown approval" {
		t.Fatalf("expected failed approval to remain retryable, got %#v", updated.approval)
	}

	retried, retryCmd := updated.resolveApproval("allow_once")
	retryCmd()
	retrying := retried.(model)
	if retrying.approval == nil || !retrying.approval.Resolving {
		t.Fatalf("expected retry to await acknowledgement, got %#v", retrying.approval)
	}

	retrying.applyBackend(packet{Type: "approval_resolved", ApprovalID: "approval-1", Decision: "allow_once"})
	if retrying.approval != nil {
		t.Fatalf("expected acknowledged approval to be removed, got %#v", retrying.approval)
	}
}

func TestTurnFinishedDoesNotDismissAnUnresolvedApproval(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "approval_requested",
		Approval: map[string]any{
			"approval_id": "approval-child",
			"session_id":  "session-child",
			"tool":        "create_file",
			"access":      "write",
		},
	})

	m.applyBackend(packet{Type: "turn_finished", OK: true})
	if m.approval == nil || m.approval.ID != "approval-child" {
		t.Fatalf("turn completion must not dismiss an independent pending approval: %#v", m.approval)
	}
	if m.status != "waiting approval" {
		t.Fatalf("expected approval status to remain visible, got %q", m.status)
	}
}

func TestApprovalSnapshotReconcilesMissedNestedRequest(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "approval_requested",
		Approval: map[string]any{
			"approval_id": "approval-escalation",
			"session_id":  "session-root",
			"tool":        "capability_escalation",
			"access":      "write",
		},
	})

	submitted, _ := m.resolveApproval("allow_once")
	m = submitted.(model)
	m.applyBackend(packet{Type: "approval_resolved", ApprovalID: "approval-escalation", Decision: "allow_once"})
	m.applyBackend(packet{
		Type: "approval_snapshot",
		Approvals: []map[string]any{{
			"approval_id": "approval-create-file",
			"session_id":  "session-child",
			"tool":        "create_file",
			"access":      "write",
		}},
	})

	if m.approval == nil || m.approval.ID != "approval-create-file" {
		t.Fatalf("expected authoritative snapshot to restore the nested approval, got %#v", m.approval)
	}
	if m.status != "waiting approval" {
		t.Fatalf("expected reconciled approval to be visible, got %q", m.status)
	}
}

func TestRoutingAndResourceEventsRenderInline(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyStream(runtimeEvent("model_route_selected", map[string]any{
		"selected_endpoint_id": "ollama",
		"reason":               "local free endpoint preferred for simple work",
		"evidence": map[string]any{
			"state":                    "insufficient_evidence",
			"best_verified_samples":    float64(2),
			"minimum_verified_samples": float64(5),
			"recommended_endpoint_id":  nil,
		},
	}, "session-root", true))
	m.applyStream(runtimeEvent("mcp_server_started", map[string]any{
		"server":     "repo",
		"tool_count": float64(3),
	}, "session-root", true))

	if len(m.entries) != 2 || m.entries[0].Kind != "info" || m.entries[1].Kind != "info" {
		t.Fatalf("expected routing and resource info entries, got %#v", m.entries)
	}
	if m.entries[0].Content != "Model routed · ollama · local free endpoint preferred for simple work · evidence warming 2/5 verified" {
		t.Fatalf("unexpected routing info: %q", m.entries[0].Content)
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

func TestTreePacketStoresSnapshotAndBadgesUnfocusedTab(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "tree",
		Root: &goalNode{SessionID: "session-root", State: "completed"},
		Summary: treeSummary{
			WorkerCount:    2,
			CompletedCount: 2,
		},
	})

	if m.treeData == nil || m.treeData.Root.State != "completed" {
		t.Fatalf("expected tree snapshot to be stored, got %#v", m.treeData)
	}
	if m.unseen[tabTree] != 1 {
		t.Fatalf("expected tree tab badge to increment while unfocused, got %d", m.unseen[tabTree])
	}

	m.switchTab(tabTree)
	if m.unseen[tabTree] != 0 {
		t.Fatal("expected switching to the tree tab to clear its badge")
	}
}

func TestDiffPacketStoresSelectedFileDiff(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type:   "diff",
		Path:   "lib/worker/sync.ex",
		Status: "modified",
		Hunks: []diffHunk{
			{Header: "@@ -1,2 +1,3 @@", OldStart: 1, OldCount: 2, NewStart: 1, NewCount: 3},
		},
	})

	if m.selectedDiff == nil || m.selectedDiff.Path != "lib/worker/sync.ex" {
		t.Fatalf("expected selected diff to be stored, got %#v", m.selectedDiff)
	}
	if len(m.selectedDiff.Hunks) != 1 {
		t.Fatalf("expected one hunk, got %d", len(m.selectedDiff.Hunks))
	}
}

func TestEventsTabRendersRowsAndAppliesCursor(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type:                "events",
		Matched:             1,
		Total:               5,
		Returned:            1,
		Cursor:              184,
		AvailableCategories: []string{"tool", "mcp", "verification"},
		Events: []eventRow{
			{
				GoalSeq:  184,
				At:       "2026-08-28T21:04:11.000000Z",
				Category: "tool",
				Payload:  eventPayload{Type: "tool_result", Data: map[string]any{"status": "ok"}},
			},
		},
	})

	if m.cursor != 184 {
		t.Fatalf("expected the events cursor to update m.cursor, got %d", m.cursor)
	}

	m.switchTab(tabEvents)
	content := m.View().Content
	if !bytes.Contains([]byte(content), []byte("tool_result")) {
		t.Fatal("expected the event row's payload type to render")
	}
	if !bytes.Contains([]byte(content), []byte("mcp")) {
		t.Fatal("expected the available category chips to render")
	}
}

func TestEventsTabEnterTogglesDetailExpansion(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "events",
		Events: []eventRow{
			{GoalSeq: 1, Category: "tool", Payload: eventPayload{Type: "tool_called", Data: map[string]any{"name": "read_file"}}},
		},
	})
	m.switchTab(tabEvents)

	next, _ := m.updateEventsTab("enter")
	expanded := next.(model)
	if !expanded.eventsTab.expanded {
		t.Fatal("expected enter to expand the selected event's detail")
	}
	if !bytes.Contains([]byte(expanded.View().Content), []byte("read_file")) {
		t.Fatal("expected the expanded detail to show the event's payload data")
	}
}

// TestModelsPacketDecodesRealTransportShape locks in a bug caught by a live
// smoke test: %ModelEndpoint{}'s `transport` field is a nested map on the
// wire (provider transport config), not a plain string, and a too-strict
// Go field type made the whole packet — and the bridge connection with it —
// fail to decode.
func TestModelsPacketDecodesRealTransportShape(t *testing.T) {
	wire := []byte(`{
		"type": "models",
		"active_profile": "demo",
		"endpoints": [{
			"id": "demo",
			"provider": "demo",
			"model": null,
			"transport": {"type": "http", "timeout_ms": 30000},
			"claims": {"capabilities": ["tools"]},
			"health": {"status": "unknown"}
		}],
		"evidence": {"state": "unavailable"},
		"session_settings": {"approval_mode": "ask", "token_budget": 32000, "mcp_server_count": 0}
	}`)

	var p packet
	if err := json.Unmarshal(wire, &p); err != nil {
		t.Fatalf("expected a real models packet to decode, got %v", err)
	}
	if len(p.Endpoints) != 1 || p.Endpoints[0].ID != "demo" {
		t.Fatalf("expected one decoded endpoint, got %#v", p.Endpoints)
	}
}

func TestModelsTabRendersProfilesAndSettings(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type:          "models",
		ActiveProfile: "echo",
		Endpoints: []modelEndpoint{
			{ID: "echo", Provider: "echo", Model: "built-in"},
			{ID: "openai-chatgpt", Provider: "openai", Model: "gpt-5.4"},
		},
		Evidence: modelEvidence{
			State:                  "insufficient_evidence",
			BestVerifiedSamples:    2,
			MinimumVerifiedSamples: 5,
		},
		Market: &providerMarket{
			ID:      "auction-1",
			Purpose: "provider_race",
			Status:  "awarded",
			Bids: []providerBid{
				{EndpointID: "echo", Score: 90, Confidence: 0.8, EstimatedLatencyMs: 40, CostTier: "free"},
				{EndpointID: "openai-chatgpt", Score: 82, Confidence: 0.7, EstimatedLatencyMs: 300, CostTier: "balanced"},
			},
			Awards: []providerAward{{EndpointID: "echo"}},
		},
		SessionSettings: modelSettings{ApprovalMode: "ask", TokenBudget: 32000, MCPServerCount: 3},
	})
	m.switchTab(tabModels)

	content := m.View().Content
	if !bytes.Contains([]byte(content), []byte("in use")) {
		t.Fatal("expected the active profile to be marked in use")
	}
	if !bytes.Contains([]byte(content), []byte("evidence warming 2/5 verified")) {
		t.Fatal("expected the routing evidence line to render")
	}
	if !bytes.Contains([]byte(content), []byte("mcp servers    3")) {
		t.Fatal("expected the session settings to render")
	}
	if !bytes.Contains([]byte(content), []byte("latest provider race · awarded · 2 bids → 1 lease")) {
		t.Fatal("expected the latest provider market to render")
	}
	if !bytes.Contains([]byte(content), []byte("echo · score 90 · 80% confidence")) {
		t.Fatal("expected provider bids to render")
	}
}

func TestProviderMarketEventsExplainRaceAndUpdateStatus(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.status = "working"
	m.applyStream(runtimeEvent("provider_auction_started", map[string]any{
		"eligible_count":   float64(2),
		"requested_awards": float64(2),
	}, "session-root", true))
	if m.status != "providers bidding" {
		t.Fatalf("expected bidding status, got %q", m.status)
	}
	m.applyStream(runtimeEvent("provider_bid_submitted", map[string]any{
		"endpoint_id":          "claude",
		"score":                float64(91),
		"confidence":           0.82,
		"estimated_latency_ms": float64(420),
		"cost_tier":            "balanced",
	}, "session-root", true))
	m.applyStream(runtimeEvent("race_started", map[string]any{
		"provider_count":  float64(2),
		"candidate_count": float64(2),
	}, "session-root", true))
	if m.status != "racing 2 providers" {
		t.Fatalf("expected race status, got %q", m.status)
	}
	if got := m.entries[len(m.entries)-2].Content; !strings.Contains(got, "Bid · claude · score 91 · 82% confidence") {
		t.Fatalf("expected intelligible bid line, got %q", got)
	}
}

func TestLegacyRaceArenaReplaysAsTournamentAndNeverTreatsFirstSubmissionAsWinner(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	root := "session-root"

	m.applyStream(runtimeEvent("provider_auction_started", map[string]any{
		"auction_id": "auction-1", "purpose": "provider_race",
		"eligible_count": float64(2), "requested_awards": float64(2),
	}, root, true))
	for _, bid := range []map[string]any{
		{"auction_id": "auction-1", "id": "bid-a", "endpoint_id": "claude", "provider": "anthropic", "model": "opus", "score": float64(91), "confidence": 0.82, "cost_tier": "premium"},
		{"auction_id": "auction-1", "id": "bid-b", "endpoint_id": "codex", "provider": "openai", "model": "gpt-5", "score": float64(88), "confidence": 0.77, "cost_tier": "balanced"},
	} {
		m.applyStream(runtimeEvent("provider_bid_submitted", bid, root, true))
	}
	m.applyStream(runtimeEvent("provider_auction_awarded", map[string]any{
		"auction_id": "auction-1", "purpose": "provider_race",
		"awards": []any{
			map[string]any{"endpoint_id": "claude", "provider": "anthropic", "model": "opus"},
			map[string]any{"endpoint_id": "codex", "provider": "openai", "model": "gpt-5"},
		},
	}, root, true))
	m.applyStream(runtimeEvent("race_started", map[string]any{
		"race_id": "race-1", "provider_auction_id": "auction-1",
		"provider_count": float64(2), "candidate_count": float64(2),
	}, root, true))
	m.applyStream(runtimeEvent("race_candidate_started", map[string]any{
		"race_id": "race-1", "candidate_id": "candidate-a", "worker_id": "worker-a",
		"endpoint_id": "claude", "provider": "anthropic", "model": "opus",
	}, root, true))
	m.applyStream(runtimeEvent("race_candidate_started", map[string]any{
		"race_id": "race-1", "candidate_id": "candidate-b", "worker_id": "worker-b",
		"endpoint_id": "codex", "provider": "openai", "model": "gpt-5",
	}, root, true))
	m.applyStream(runtimeEvent("race_candidate_completed", map[string]any{
		"race_id": "race-1", "candidate_id": "candidate-a", "worker_id": "worker-a",
		"endpoint_id": "claude", "verification_status": "passed",
	}, root, true))

	arena := m.latestRace()
	if arena == nil || arena.WinnerID != "" {
		t.Fatalf("first submission must not become a winner: %#v", arena)
	}
	if arena.Phase != "running" || arena.Candidates[0].Status != "submitted" {
		t.Fatalf("expected one submitted lane while the race keeps running: %#v", arena)
	}
	raceEntries := 0
	for _, item := range m.entries {
		if item.Kind == "race" {
			raceEntries++
		}
		if item.Kind == "info" && strings.HasPrefix(item.Content, "Bid ·") {
			t.Fatalf("race bid leaked into the flat transcript: %#v", item)
		}
	}
	if raceEntries != 1 {
		t.Fatalf("expected one grouped race card, got %d", raceEntries)
	}

	m.refreshTranscript(true)
	content := m.viewport.View()
	if !strings.Contains(content, "submitted · awaiting judgment") || !strings.Contains(content, "quality and evidence decide") {
		t.Fatalf("expected the card to explain quality selection, got:\n%s", content)
	}
}

func TestRaceArenaTracksWorkerActivityAndOnlyEvaluatorSelectsWinner(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	root := "session-root"
	m.applyStream(runtimeEvent("provider_auction_started", map[string]any{
		"auction_id": "auction-1", "purpose": "provider_race",
	}, root, true))
	m.applyStream(runtimeEvent("race_started", map[string]any{
		"race_id": "race-1", "provider_auction_id": "auction-1", "candidate_count": float64(1),
	}, root, true))
	m.applyStream(runtimeEvent("race_candidate_started", map[string]any{
		"race_id": "race-1", "candidate_id": "candidate-a", "worker_id": "worker-a", "endpoint_id": "codex",
	}, root, true))
	m.applyStream(runtimeEvent("tool_called", map[string]any{
		"tool_call_id": "call-1", "name": "read_file",
	}, "worker-a", false))

	candidate := &m.latestRace().Candidates[0]
	if candidate.Activity != "using read_file" {
		t.Fatalf("expected worker activity in its lane, got %q", candidate.Activity)
	}
	for _, item := range m.entries {
		if item.Kind == "tool" {
			t.Fatalf("race worker tools should stay grouped in the lane: %#v", item)
		}
	}

	m.applyStream(runtimeEvent("race_candidate_completed", map[string]any{
		"race_id": "race-1", "candidate_id": "candidate-a", "worker_id": "worker-a", "endpoint_id": "codex",
	}, root, true))
	if m.latestRace().WinnerID != "" || m.latestRace().Phase != "judging" {
		t.Fatalf("a submitted result should enter judging without winning: %#v", m.latestRace())
	}
	m.applyStream(runtimeEvent("race_winner_selected", map[string]any{
		"race_id": "race-1", "winner_id": "candidate-a", "winner_endpoint_id": "codex",
	}, root, true))
	if m.latestRace().WinnerID != "candidate-a" || m.latestRace().Phase != "selected" {
		t.Fatalf("expected evaluator selection to mark the winner: %#v", m.latestRace())
	}
}

func TestTournamentParentJudgmentReopensAndClosesTheArenaWithAWinner(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	root := "session-root"
	m.applyStream(runtimeEvent("provider_auction_started", map[string]any{
		"auction_id": "auction-judge", "purpose": "provider_tournament",
	}, root, true))
	m.applyStream(runtimeEvent("tournament_started", map[string]any{
		"tournament_id": "tournament-judge", "provider_auction_id": "auction-judge", "candidate_count": float64(2),
	}, root, true))
	for _, lane := range []map[string]any{
		{"tournament_id": "tournament-judge", "candidate_id": "candidate-1", "worker_id": "worker-1", "endpoint_id": "ollama"},
		{"tournament_id": "tournament-judge", "candidate_id": "candidate-2", "worker_id": "worker-2", "endpoint_id": "grok"},
	} {
		m.applyStream(runtimeEvent("tournament_candidate_started", lane, root, true))
		m.applyStream(runtimeEvent("tournament_candidate_completed", lane, root, true))
	}
	m.applyStream(runtimeEvent("tournament_inconclusive", map[string]any{
		"tournament_id": "tournament-judge",
	}, root, true))
	m.applyStream(runtimeEvent("tournament_judgment_requested", map[string]any{
		"tournament_id": "tournament-judge", "selection_source": "parent_judgment",
	}, root, true))
	if m.latestRace().Phase != "judging" || !strings.Contains(m.latestRace().Status, "parent judge") {
		t.Fatalf("expected parent judgment to reopen judging, got %#v", m.latestRace())
	}
	m.applyStream(runtimeEvent("tournament_winner_selected", map[string]any{
		"tournament_id": "tournament-judge", "winner_id": "candidate-2", "winner_endpoint_id": "grok", "selection_source": "parent_judgment",
	}, root, true))
	m.applyStream(runtimeEvent("tournament_collapsed", map[string]any{
		"tournament_id": "tournament-judge", "winner_id": "candidate-2", "selection_source": "parent_judgment",
	}, root, true))

	arena := m.latestRace()
	if arena.Phase != "selected" || arena.WinnerID != "candidate-2" || arena.Candidates[0].Status != "discarded" {
		t.Fatalf("expected judged tournament winner and discarded loser, got %#v", arena)
	}
	view := m.renderRaceTab()
	for _, want := range []string{"TOURNAMENT STATE", "selected by parent judge", "grok"} {
		if !strings.Contains(view, want) {
			t.Fatalf("expected %q in judged tournament view:\n%s", want, view)
		}
	}
}

func TestSpeedRaceShowsFirstAdmissibleWinnerAndCancelledLanes(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	root := "session-root"
	m.applyStream(runtimeEvent("provider_auction_started", map[string]any{
		"auction_id": "auction-speed", "purpose": "provider_race",
	}, root, true))
	m.applyStream(runtimeEvent("race_started", map[string]any{
		"race_id": "race-speed", "provider_auction_id": "auction-speed",
		"candidate_count": float64(2), "selection_policy": "first_admissible",
	}, root, true))
	for _, lane := range []map[string]any{
		{"race_id": "race-speed", "candidate_id": "fast", "worker_id": "worker-fast", "endpoint_id": "codex"},
		{"race_id": "race-speed", "candidate_id": "slow", "worker_id": "worker-slow", "endpoint_id": "claude"},
	} {
		m.applyStream(runtimeEvent("race_candidate_started", lane, root, true))
	}
	m.applyStream(runtimeEvent("race_candidate_completed", map[string]any{
		"race_id": "race-speed", "candidate_id": "fast", "worker_id": "worker-fast", "endpoint_id": "codex",
	}, root, true))
	m.applyStream(runtimeEvent("race_winner_selected", map[string]any{
		"race_id": "race-speed", "winner_id": "fast", "winner_endpoint_id": "codex",
	}, root, true))
	m.applyStream(runtimeEvent("race_candidate_cancelled", map[string]any{
		"race_id": "race-speed", "candidate_id": "slow", "worker_id": "worker-slow",
	}, root, true))

	arena := m.latestRace()
	if arena.Mode != "race" || arena.WinnerID != "fast" || arena.Candidates[1].Status != "cancelled" {
		t.Fatalf("expected an authoritative speed-race projection, got %#v", arena)
	}
	view := m.renderRaceTab()
	for _, want := range []string{"SPEED RACE", "First admissible terminal result wins", "first admissible finish"} {
		if !strings.Contains(view, want) {
			t.Fatalf("expected %q in speed-race view:\n%s", want, view)
		}
	}
}

func TestRaceTabIsInteractiveAndKeepsExistingTabNumbersStable(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.races = []raceArena{{
		AnchorID: "auction-1", Phase: "running", Status: "independent candidates running",
		Candidates: []raceCandidate{{ID: "a", EndpointID: "claude"}, {ID: "b", EndpointID: "codex"}},
	}}

	next, _ := m.Update(tea.KeyPressMsg{Code: '7', Text: "7"})
	updated := next.(model)
	if updated.tab != tabRace {
		t.Fatalf("expected 7 to open the race arena, got %v", updated.tab)
	}
	next, _ = updated.updateRaceTab("down")
	updated = next.(model)
	if updated.raceTab.selected != 1 {
		t.Fatalf("expected lane focus to move, got %d", updated.raceTab.selected)
	}
	next, _ = updated.updateRaceTab("enter")
	if !next.(model).raceTab.expanded {
		t.Fatal("expected enter to expand bid evidence")
	}
	if !strings.Contains(updated.renderRaceTab(), "Finishing first does not win") {
		t.Fatal("expected the race semantics to be explicit")
	}
}

func TestModelsTabArrowKeysMoveSelection(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "models",
		Endpoints: []modelEndpoint{
			{ID: "echo"}, {ID: "openai-chatgpt"},
		},
	})
	m.switchTab(tabModels)

	next, _ := m.updateModelsTab("down")
	updated := next.(model)
	if updated.modelsTab.selected != 1 {
		t.Fatalf("expected selection to move to 1, got %d", updated.modelsTab.selected)
	}
}

func TestSessionsTabRendersListAndStatus(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "sessions",
		Sessions: []sessionSummary{
			{SessionID: "session-current", Status: "current"},
			{SessionID: "session-old", Status: "idle"},
		},
	})
	m.switchTab(tabSessions)

	content := m.View().Content
	if !bytes.Contains([]byte(content), []byte("current")) {
		t.Fatal("expected the current session's status to render")
	}
	if !bytes.Contains([]byte(content), []byte("2 sessions")) {
		t.Fatal("expected the session count to render")
	}
}

func TestWorkProjectionReplacesRoutineToolsWithLiveSemanticBlocks(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.entries = append(m.entries, entry{Kind: "tool", Name: "read_file", Status: "done"})
	m.applyBackend(packet{
		Type: "work_projection",
		WorkBlocks: []workBlock{{
			ID: "block-1", WorkerID: "worker-1", State: "active", Phase: "implementing",
			Label: "Implementing", Summary: "4 reads · 1 write",
		}},
		Progress: &progressSnapshot{
			Summary: progressSummary{Active: 1}, CriticalWorkerID: "worker-1",
		},
	})

	content := m.viewport.View()
	if !strings.Contains(content, "LIVE WORK") || !strings.Contains(content, "4 reads · 1 write") {
		t.Fatalf("expected a live semantic work block in chat, got:\n%s", content)
	}
	if strings.Contains(content, "read_file") {
		t.Fatalf("routine completed tool should stay collapsed, got:\n%s", content)
	}
}

func TestTreeCanCancelTheSelectedWorker(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)
	m.treeData = &treeSnapshot{Root: &goalNode{SessionID: "worker-1", WorkerID: "worker-1", Role: "root"}}

	_, cmd := m.updateTreeTab("c")
	if cmd == nil {
		t.Fatal("expected cancel worker command")
	}
	cmd()

	action, err := newProtocol(&wire, &bytes.Buffer{}).read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Command != "cancel_worker" || action.Query != "worker-1" {
		t.Fatalf("unexpected worker action: %#v", action)
	}
}

func TestSessionsTabEnterRequestsDetailForSelectedSession(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)
	m.applyBackend(packet{
		Type: "sessions",
		Sessions: []sessionSummary{
			{SessionID: "session-abc", Status: "idle"},
		},
	})
	m.switchTab(tabSessions)

	_, cmd := m.updateSessionsTab("enter")
	if cmd == nil {
		t.Fatal("expected a bridge command requesting session detail")
	}
	cmd()

	reader := newProtocol(&wire, &bytes.Buffer{})
	action, err := reader.read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Command != "sessions" || action.Query != "session-abc" {
		t.Fatalf("unexpected session detail request: %#v", action)
	}
}

func TestSessionsTabAppliesDetailToPreview(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type:     "sessions",
		Sessions: []sessionSummary{{SessionID: "session-abc", Status: "idle"}},
	})
	m.applyBackend(packet{
		Type:        "session_detail",
		SessionID:   "session-abc",
		Provider:    "anthropic",
		Model:       "claude-sonnet-4-6",
		TurnCount:   4,
		GoalPreview: "fix the retry bug",
	})
	m.switchTab(tabSessions)

	content := m.View().Content
	if !bytes.Contains([]byte(content), []byte("fix the retry bug")) {
		t.Fatal("expected the session preview's goal text to render")
	}
	if !bytes.Contains([]byte(content), []byte("anthropic")) || !bytes.Contains([]byte(content), []byte("sonnet-4-6")) {
		t.Fatal("expected the session preview's provider/model to render")
	}
}

func TestFilesTabRendersChangedListAndRequestsDiff(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)
	m.applyBackend(packet{
		Type:   "files",
		Branch: "main",
		Changed: []changedFile{
			{Path: "lib/worker/sync.ex", Insertions: 28, Deletions: 9},
		},
	})
	m.switchTab(tabFiles)

	content := m.View().Content
	if !bytes.Contains([]byte(content), []byte("lib/worker/sync.ex")) {
		t.Fatal("expected the changed file to render")
	}
	if !bytes.Contains([]byte(content), []byte("+28")) {
		t.Fatal("expected the changed file's insertion count to render")
	}

	_, cmd := m.updateFilesTab("enter")
	if cmd == nil {
		t.Fatal("expected a bridge command requesting the file's diff")
	}
	cmd()

	reader := newProtocol(&wire, &bytes.Buffer{})
	action, err := reader.read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Command != "files" || action.Query != "lib/worker/sync.ex" {
		t.Fatalf("unexpected diff request: %#v", action)
	}
}

func TestFilesTabRendersDiffWithAddRemoveMarkers(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type:    "files",
		Changed: []changedFile{{Path: "lib/worker/sync.ex"}},
	})
	m.applyBackend(packet{
		Type: "diff",
		Path: "lib/worker/sync.ex",
		Hunks: []diffHunk{
			{
				Header:   "@@ -61,9 +61,18 @@",
				OldStart: 61,
				NewStart: 61,
				Lines: []diffLine{
					{Kind: "context", OldLine: 61, NewLine: 61, Text: "Enum.reduce_while(0..max_retries, :ok, fn attempt, _ ->"},
					{Kind: "remove", OldLine: 62, Text: "  case pull(state) do"},
					{Kind: "add", NewLine: 62, Text: "  case pull(state) do"},
				},
			},
		},
	})
	m.switchTab(tabFiles)

	content := m.View().Content
	if !bytes.Contains([]byte(content), []byte("hunk 1 of 1")) {
		t.Fatal("expected the hunk header to render")
	}
	if !bytes.Contains([]byte(content), []byte("case pull(state) do")) {
		t.Fatal("expected diff line text to render")
	}
}

func TestFilesTabTabKeyCyclesHunks(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "diff",
		Path: "lib/worker/sync.ex",
		Hunks: []diffHunk{
			{Header: "@@ -1,1 +1,1 @@"},
			{Header: "@@ -10,1 +10,1 @@"},
		},
	})
	m.switchTab(tabFiles)

	next, _ := m.updateFilesTab("tab")
	updated := next.(model)
	if updated.filesTab.selectedHunk != 1 {
		t.Fatalf("expected tab to advance to hunk 1, got %d", updated.filesTab.selectedHunk)
	}

	next, _ = updated.updateFilesTab("tab")
	wrapped := next.(model)
	if wrapped.filesTab.selectedHunk != 0 {
		t.Fatalf("expected tab to wrap back to hunk 0, got %d", wrapped.filesTab.selectedHunk)
	}
}

func TestFailureRendersGenericNextStepsAfterAFailedTurn(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.composer.SetValue("fix the retry bug")
	next, _ := m.submit()
	updated := next.(model)

	updated.applyBackend(packet{Type: "turn_finished", OK: false, Error: "boom"})

	if !updated.pendingFailure {
		t.Fatal("expected a failed turn to set pendingFailure")
	}
	content := updated.View().Content
	if !bytes.Contains([]byte(content), []byte("r retry")) ||
		!bytes.Contains([]byte(content), []byte("e edit and retry")) ||
		!bytes.Contains([]byte(content), []byte("esc stop")) {
		t.Fatalf("expected the generic next-step pills to render, got:\n%s", content)
	}
}

func TestFailureRetryResubmitsLastUserPrompt(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)
	m.composer.SetValue("fix the retry bug")
	next, cmd := m.submit()
	cmd()
	updated := next.(model)
	updated.applyBackend(packet{Type: "turn_finished", OK: false, Error: "boom"})

	next, cmd = updated.Update(tea.KeyPressMsg{Code: 'r', Text: "r"})
	if cmd == nil {
		t.Fatal("expected retry to send a bridge command")
	}
	cmd()
	retried := next.(model)
	if retried.pendingFailure {
		t.Fatal("expected retry to clear pendingFailure")
	}

	reader := newProtocol(&wire, &bytes.Buffer{})
	_, _ = reader.read() // the original submit
	action, err := reader.read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Type != "submit" || action.Prompt != "fix the retry bug" {
		t.Fatalf("expected retry to resubmit the last prompt, got %#v", action)
	}
}

func TestFailureEditPrefillsComposerWithoutSubmitting(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)
	m.composer.SetValue("fix the retry bug")
	next, cmd := m.submit()
	cmd()
	updated := next.(model)
	updated.applyBackend(packet{Type: "turn_finished", OK: false, Error: "boom"})

	next, cmd = updated.Update(tea.KeyPressMsg{Code: 'e', Text: "e"})
	if cmd != nil {
		t.Fatal("expected edit-and-retry to be purely local, no bridge command")
	}
	edited := next.(model)
	if edited.pendingFailure {
		t.Fatal("expected edit to clear pendingFailure")
	}
	if edited.composer.Value() != "fix the retry bug" {
		t.Fatalf("expected the composer to be prefilled with the last prompt, got %q", edited.composer.Value())
	}
}

func TestFailureRAndEDoNotInterceptNormalTyping(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	// No pending failure — r/e must behave like ordinary characters.
	next, _ := m.Update(tea.KeyPressMsg{Code: 'r', Text: "r"})
	typed := next.(model)
	if typed.composer.Value() != "r" {
		t.Fatalf("expected r to type normally when there's no pending failure, got %q", typed.composer.Value())
	}
}

func TestTypingAtShowsWorkspaceFileSuggestionsForEmptyPrefix(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.workspaceFiles = suggestionFiles()

	next, _ := m.Update(tea.KeyPressMsg{Code: '@', Text: "@"})
	updated := next.(model)
	if !updated.fileSuggestions.open || updated.sheet != sheetPanel {
		t.Fatalf("expected typing @ to open the file suggestion panel, got panel=%v sheet=%v", updated.fileSuggestions.open, updated.sheet)
	}

	content := strings.Join(updated.panelLines, "\n")
	for _, want := range []string{"README.md", "lib/nested/worker.go"} {
		if !strings.Contains(content, want) {
			t.Fatalf("expected %q in file suggestions, got:\n%s", want, content)
		}
	}
}

func TestFileSuggestionsFilterCaseInsensitivelyByBasenameAndPath(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.workspaceFiles = suggestionFiles()

	m.composer.SetValue("@WOR")
	m.syncFileSuggestionPanel()
	content := strings.Join(m.panelLines, "\n")
	if !strings.Contains(content, "lib/nested/worker.go") {
		t.Fatalf("expected basename filtering to match worker.go, got:\n%s", content)
	}
	if strings.Contains(content, "README.md") {
		t.Fatalf("expected basename filtering to exclude README.md, got:\n%s", content)
	}

	m.composer.SetValue("@lib/n")
	m.syncFileSuggestionPanel()
	content = strings.Join(m.panelLines, "\n")
	if !strings.Contains(content, "lib/nested/worker.go") {
		t.Fatalf("expected path-prefix filtering to match lib/nested/worker.go, got:\n%s", content)
	}
}

func TestFileSuggestionsShowExplicitNoMatchMessage(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.workspaceFiles = suggestionFiles()
	m.composer.SetValue("@zzz")
	m.syncFileSuggestionPanel()

	if !m.fileSuggestions.open || m.sheet != sheetPanel {
		t.Fatalf("expected a no-match file suggestion state, got panel=%v sheet=%v", m.fileSuggestions.open, m.sheet)
	}
	if got := strings.Join(m.panelLines, "\n"); !strings.Contains(got, "No matching files for @zzz") {
		t.Fatalf("expected an explicit no-match message, got:\n%s", got)
	}
}

func TestFileSuggestionKeyboardSelectionInsertsSecondMatch(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.workspaceFiles = suggestionFiles()

	next, _ := m.Update(tea.KeyPressMsg{Code: '@', Text: "@"})
	next, _ = next.(model).Update(tea.KeyPressMsg{Code: tea.KeyDown})
	next, cmd := next.(model).Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd != nil {
		t.Fatal("selecting a file suggestion must not submit the prompt")
	}

	selected := next.(model)
	if selected.composer.Value() != "@lib/nested/worker.go " {
		t.Fatalf("expected the second file to be inserted, got %q", selected.composer.Value())
	}
	if selected.fileSuggestions.open || selected.sheet != sheetNone {
		t.Fatal("expected file suggestions to close after selection")
	}
}

func TestFileSuggestionSelectionQuotesPathsWithSpaces(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.workspaceFiles = []string{"docs/design notes.md"}

	next, _ := m.Update(tea.KeyPressMsg{Code: '@', Text: "@"})
	next, _ = next.(model).Update(tea.KeyPressMsg{Code: tea.KeyEnter})

	if got := next.(model).composer.Value(); got != "@\"docs/design notes.md\" " {
		t.Fatalf("expected a quoted file reference, got %q", got)
	}
}

func TestFileSuggestionsFilterInsideAnOpenQuotedReference(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.workspaceFiles = []string{"docs/design notes.md", "docs/release notes.md"}
	m.composer.SetValue("@\"des")
	m.syncFileSuggestionPanel()

	if got := m.fileSuggestions.matches; len(got) != 1 || got[0] != "docs/design notes.md" {
		t.Fatalf("expected quoted filtering to find design notes, got %#v", got)
	}
}

func TestFileSuggestionsIgnoreEmailAddressesAndEscapedAtSigns(t *testing.T) {
	for _, value := range []string{"person@example.test", `literal \@README.md`} {
		m := testModel(&bytes.Buffer{})
		m.workspaceFiles = suggestionFiles()
		m.composer.SetValue(value)
		m.syncFileSuggestionPanel()

		if m.fileSuggestions.open {
			t.Fatalf("did not expect file suggestions for %q", value)
		}
	}
}

func TestFileSuggestionSelectionReplacesTokenAtCursor(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.workspaceFiles = []string{"README.md"}
	m.composer.SetValue("inspect @REA before editing")
	m.composer.SetCursorColumn(len([]rune("inspect @REA")))
	m.syncFileSuggestionPanel()

	if !m.fileSuggestions.open {
		t.Fatal("expected suggestions at the cursor inside an existing prompt")
	}
	m.selectFileSuggestion()

	if got := m.composer.Value(); got != "inspect @README.md before editing" {
		t.Fatalf("expected only the active token to be replaced, got %q", got)
	}
	if m.composer.Column() != len([]rune("inspect @README.md")) {
		t.Fatalf("expected cursor after inserted reference, got column %d", m.composer.Column())
	}
}

func TestFileSuggestionSelectionCanNavigateLongLists(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	for i := 0; i < 15; i++ {
		m.workspaceFiles = append(m.workspaceFiles, fmt.Sprintf("file-%02d.txt", i))
	}
	m.composer.SetValue("@")
	m.syncFileSuggestionPanel()

	for i := 0; i < 12; i++ {
		m.moveFileSuggestion(1)
	}

	if m.fileSuggestions.selected != 12 {
		t.Fatalf("expected selection 12, got %d", m.fileSuggestions.selected)
	}
	if got := strings.Join(m.panelLines, "\n"); !strings.Contains(got, "› file-12.txt") {
		t.Fatalf("expected the selected row to remain visible, got:\n%s", got)
	}
}

func TestOpenInEditorReturnsNilWithoutASelectedDiff(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	if cmd := m.openInEditor(); cmd != nil {
		t.Fatal("expected no editor command without a selected diff")
	}
}

func TestOpenInEditorReturnsACommandForASelectedDiff(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{Type: "diff", Path: "lib/worker/sync.ex"})
	if m.workspaceRoot != "/tmp/elixir-harness" {
		t.Fatalf("expected workspaceRoot to come from the init payload, got %q", m.workspaceRoot)
	}
	if cmd := m.openInEditor(); cmd == nil {
		t.Fatal("expected an editor command once a file's diff is selected")
	}
}

func TestOpenInEditorKeyDelegatesFromFilesTab(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{Type: "diff", Path: "lib/worker/sync.ex"})
	m.switchTab(tabFiles)

	_, cmd := m.updateFilesTab("o")
	if cmd == nil {
		t.Fatal("expected the o key to trigger an editor command")
	}
}

// TestEditorCommandGuardsAgainstArgumentInjection locks in a fix from a
// security review: a workspace file can legally be named starting with
// "-" (git diffs report it like any other path), and without a literal
// "--" before the path, exec.Command would hand that string to the editor
// as a bare argument, which many editors reinterpret as a flag instead of
// a filename.
func TestEditorCommandGuardsAgainstArgumentInjection(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{Type: "diff", Path: "-rf"})

	cmd := m.editorCommand()
	if cmd == nil {
		t.Fatal("expected an editor command for a dash-prefixed filename")
	}

	dashIndex, pathIndex := -1, -1
	for i, arg := range cmd.Args {
		if arg == "--" {
			dashIndex = i
		}
		if strings.HasSuffix(arg, "-rf") {
			pathIndex = i
		}
	}
	if dashIndex == -1 {
		t.Fatalf("expected an end-of-options -- marker in argv, got %v", cmd.Args)
	}
	if pathIndex == -1 || pathIndex < dashIndex {
		t.Fatalf("expected the path to appear after -- in argv, got %v", cmd.Args)
	}
}

// TestEditorCommandRejectsPathEscapingWorkspace locks in the same review's
// defense-in-depth check: even though the backend already rejects ".."
// when path is used to scope a git query, the client independently
// verifies the resolved path stays inside workspaceRoot before ever
// handing it to exec.Command.
func TestEditorCommandRejectsPathEscapingWorkspace(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{Type: "diff", Path: "../../etc/passwd"})

	if cmd := m.editorCommand(); cmd != nil {
		t.Fatalf("expected a path escaping the workspace to be rejected, got args %v", cmd.Args)
	}
}

func TestEditorCommandRejectsAbsolutePathWhenWorkspaceIsKnown(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{Type: "diff", Path: "/etc/passwd"})

	if cmd := m.editorCommand(); cmd != nil {
		t.Fatalf("expected an absolute path to be rejected when workspaceRoot is set, got args %v", cmd.Args)
	}
}

func TestSessionsTabRKeySendsResumeCommand(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)
	m.applyBackend(packet{
		Type:     "sessions",
		Sessions: []sessionSummary{{SessionID: "session-old", Status: "idle"}},
	})
	m.switchTab(tabSessions)

	_, cmd := m.updateSessionsTab("r")
	if cmd == nil {
		t.Fatal("expected a bridge command requesting resume")
	}
	cmd()

	reader := newProtocol(&wire, &bytes.Buffer{})
	action, err := reader.read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Command != "resume" || action.Query != "session-old" {
		t.Fatalf("unexpected resume request: %#v", action)
	}
}

func TestSwitchingToADataTabRequestsItsData(t *testing.T) {
	var wire bytes.Buffer
	m := testModel(&wire)

	cmd := m.switchTab(tabTree)
	if cmd == nil {
		t.Fatal("expected switching to the tree tab to fetch its data")
	}
	cmd()

	reader := newProtocol(&wire, &bytes.Buffer{})
	action, err := reader.read()
	if err != nil {
		t.Fatal(err)
	}
	if action.Command != "tree" {
		t.Fatalf("expected a tree command, got %#v", action)
	}
}

func TestSwitchingToChatDoesNotRequestData(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.switchTab(tabTree)
	if cmd := m.switchTab(tabChat); cmd != nil {
		t.Fatal("expected switching to the chat tab not to fetch any data")
	}
}

// TestTabStripStaysOnOneRow locks in a bug caught visually after shipping:
// styling the active tab with a real lipgloss Border() made that one
// segment render as a 2-line block, and joining it into the row with plain
// strings.Join (rather than a layout-aware join) split the whole strip
// across lines — everything after the active tab wrapped onto the border's
// row instead of staying beside it.
func TestTabStripStaysOnOneRow(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.resize(100, 28)
	strip := m.renderTabStrip()

	lines := strings.Split(strip, "\n")
	if len(lines) != 2 {
		t.Fatalf("expected exactly 2 lines (labels + rule), got %d:\n%s", len(lines), strip)
	}

	labelsLine := lines[0]
	for _, want := range []string{"BEAM", "1 chat", "2 tree", "3 files", "4 events", "5 sessions", "6 models", "7 arena"} {
		if !strings.Contains(labelsLine, want) {
			t.Fatalf("expected %q on the tab labels row, got %q", want, labelsLine)
		}
	}
}

func TestBareDigitSwitchesTabsWhenComposerEmpty(t *testing.T) {
	m := testModel(&bytes.Buffer{})

	next, _ := m.Update(tea.KeyPressMsg{Code: '2', Text: "2"})
	updated := next.(model)
	if updated.tab != tabTree {
		t.Fatalf("expected digit 2 to switch to the tree tab, got %v", updated.tab)
	}
	if !bytes.Contains([]byte(updated.View().Content), []byte("No goal tree yet")) {
		t.Fatal("expected the empty tree tab state to render")
	}
}

func TestTreeTabRendersWorkerHierarchyAndSidebar(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "tree",
		Root: &goalNode{
			SessionID: "session-root",
			Role:      "root",
			State:     "running",
			Children: []goalNode{
				{SessionID: "session-child", Role: "subagent", State: "completed", LastTool: "read_file"},
			},
		},
		Summary: treeSummary{WorkerCount: 2, RunningCount: 1, CompletedCount: 1},
		WorkspaceDiff: &treeWorkspace{
			Branch: "main", ChangedFileCount: 3, Insertions: 12, Deletions: 4,
		},
	})
	m.switchTab(tabTree)

	content := m.View().Content
	if !bytes.Contains([]byte(content), []byte("root")) {
		t.Fatal("expected the root worker to render")
	}
	if !bytes.Contains([]byte(content), []byte(shortSession("session-child"))) {
		t.Fatal("expected the child worker's short session id to render")
	}
	if !bytes.Contains([]byte(content), []byte("main")) {
		t.Fatal("expected the workspace branch to render in the sidebar")
	}
	if !bytes.Contains([]byte(content), []byte("2 workers")) {
		t.Fatal("expected the tree summary line to render")
	}
}

func TestTreeTabArrowKeysMoveSelection(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "tree",
		Root: &goalNode{
			SessionID: "session-root",
			Role:      "root",
			State:     "running",
			Children: []goalNode{
				{SessionID: "session-child", Role: "subagent", State: "running"},
			},
		},
	})
	m.switchTab(tabTree)

	next, _ := m.updateTreeTab("down")
	updated := next.(model)
	if updated.treeTab.selected != 1 {
		t.Fatalf("expected selection to move to 1, got %d", updated.treeTab.selected)
	}

	next, _ = updated.updateTreeTab("down")
	clamped := next.(model)
	if clamped.treeTab.selected != 1 {
		t.Fatalf("expected selection to clamp at the last row, got %d", clamped.treeTab.selected)
	}
}

func TestTreeTabRendersAndExpandsRuntimeWorkBlocks(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.applyBackend(packet{
		Type: "tree",
		Root: &goalNode{SessionID: "session-root", Role: "root", State: "running"},
		WorkBlocks: []workBlock{
			{
				ID:         "work-block-1",
				WorkerID:   "session-root",
				State:      "active",
				Phase:      "implementing",
				Label:      "Implementing",
				Summary:    "2 reads · 1 write",
				Files:      []string{"lib/beam_agent.ex"},
				EventIDs:   []string{"one", "two", "three"},
				DurationMs: 1200,
			},
		},
		Progress: &progressSnapshot{Summary: progressSummary{Active: 1, Stalled: 1}},
	})
	m.switchTab(tabTree)
	m.treeTab.selected = 1

	content := m.View().Content
	if !strings.Contains(content, "WORK BLOCKS") || !strings.Contains(content, "Implementing") {
		t.Fatalf("expected compact work block, got %q", content)
	}
	if !strings.Contains(content, "1 active") || !strings.Contains(content, "1 stalled") {
		t.Fatalf("expected runtime progress summary, got %q", content)
	}

	next, _ := m.updateTreeTab("enter")
	updated := next.(model)
	content = updated.View().Content
	if !strings.Contains(content, "lib/beam_agent.ex") || !strings.Contains(content, "3 recorded") {
		t.Fatalf("expected expanded work-block evidence, got %q", content)
	}
}

func TestSpecialistOwnershipAndModelAreVisible(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	block := workBlock{
		ID: "specialist-block", WorkerID: "helper-session", OwnerWorkerID: "owner-session",
		Role: "Repository investigator", State: "active", Phase: "thinking", Label: "Model working",
		EndpointID: "local-helper", Model: "small-model", ExecutionNode: "local",
		AssignmentReason: "Bounded read-only assistance", RoutingReason: "Eligible cheap endpoint",
	}
	m.workBlocks = []workBlock{block}
	live := m.renderLiveWorkProjection()
	for _, want := range []string{"Repository investigator", "local-helper", "small-model", "@ local"} {
		if !strings.Contains(live, want) {
			t.Fatalf("missing %q from live work: %s", want, live)
		}
	}
	details := renderWorkBlockDetails(block, 100)
	for _, want := range []string{"Bounded read-only assistance", "Eligible cheap endpoint", "owner", shortSession("owner-session")} {
		if !strings.Contains(details, want) {
			t.Fatalf("missing %q from details: %s", want, details)
		}
	}
}

func TestDigitKeyTypesIntoComposerWhenNotEmpty(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.composer.SetValue("port 8")

	next, _ := m.Update(tea.KeyPressMsg{Code: '2', Text: "2"})
	updated := next.(model)
	if updated.tab != tabChat {
		t.Fatalf("expected digit to stay in the composer, not switch tabs, got tab %v", updated.tab)
	}
	if updated.composer.Value() != "port 82" {
		t.Fatalf("expected the digit to be typed into the composer, got %q", updated.composer.Value())
	}
}

func TestNonChatTabReclaimsComposerHeight(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.resize(90, 24)
	chatHeight := m.bodyHeight

	m.switchTab(tabEvents)
	if m.bodyHeight <= chatHeight {
		t.Fatalf("expected leaving the composer to grow the body region, chat=%d events=%d", chatHeight, m.bodyHeight)
	}
}

func TestEscReturnsToChatTabFromAnotherTab(t *testing.T) {
	m := testModel(&bytes.Buffer{})
	m.switchTab(tabEvents)

	next, _ := m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	updated := next.(model)
	if updated.tab != tabChat {
		t.Fatalf("expected esc to return to the chat tab, got %v", updated.tab)
	}
}

func suggestionFiles() []string {
	return []string{"README.md", "lib/nested/worker.go"}
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
