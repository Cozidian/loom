package main

import (
	"bytes"
	"encoding/json"
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

	_, cmd := selected.updateApproval("enter")
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
	for _, want := range []string{"BEAM", "1 chat", "2 tree", "3 files", "4 events", "5 sessions", "6 models"} {
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
