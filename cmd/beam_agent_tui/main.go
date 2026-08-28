package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"charm.land/bubbles/v2/textarea"
	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

const maxPacketSize = 16 * 1024 * 1024

type packet struct {
	Type         string           `json:"type"`
	SessionID    string           `json:"session_id,omitempty"`
	ProjectID    string           `json:"project_id,omitempty"`
	GoalID       string           `json:"goal_id,omitempty"`
	Cursor       int64            `json:"cursor,omitempty"`
	Workspace    string           `json:"workspace,omitempty"`
	Provider     string           `json:"provider,omitempty"`
	Profile      string           `json:"profile,omitempty"`
	Model        string           `json:"model,omitempty"`
	Prompt       string           `json:"prompt,omitempty"`
	Command      string           `json:"command,omitempty"`
	Query        string           `json:"query,omitempty"`
	ApprovalID   string           `json:"approval_id,omitempty"`
	ApprovalMode string           `json:"approval_mode,omitempty"`
	Decision     string           `json:"decision,omitempty"`
	OK           bool             `json:"ok,omitempty"`
	Error        string           `json:"error,omitempty"`
	Tone         string           `json:"tone,omitempty"`
	Message      string           `json:"message,omitempty"`
	Title        string           `json:"title,omitempty"`
	Lines        []string         `json:"lines,omitempty"`
	Entries      []entry          `json:"entries,omitempty"`
	ContextStats map[string]any   `json:"context_stats,omitempty"`
	Stats        map[string]any   `json:"stats,omitempty"`
	Event        map[string]any   `json:"event,omitempty"`
	Approval     map[string]any   `json:"approval,omitempty"`
	Providers    []providerOption `json:"providers,omitempty"`

	// Structured tab payloads — see packets.go.
	Root                *goalNode               `json:"root,omitempty"`
	Nodes               map[string]any          `json:"nodes,omitempty"`
	Summary             treeSummary             `json:"summary,omitempty"`
	Budget              *treeBudget             `json:"budget,omitempty"`
	ResourcePools       map[string]resourcePool `json:"resource_pools,omitempty"`
	Matched             int                     `json:"matched,omitempty"`
	Total               int                     `json:"total,omitempty"`
	Returned            int                     `json:"returned,omitempty"`
	Filters             []string                `json:"filters,omitempty"`
	AvailableCategories []string                `json:"available_categories,omitempty"`
	Events              []eventRow              `json:"events,omitempty"`
	ActiveProfile       string                  `json:"active_profile,omitempty"`
	Endpoints           []modelEndpoint         `json:"endpoints,omitempty"`
	Evidence            modelEvidence           `json:"evidence,omitempty"`
	SessionSettings     modelSettings           `json:"session_settings,omitempty"`
	Sessions            []sessionSummary        `json:"sessions,omitempty"`
	TurnCount           int                     `json:"turn_count,omitempty"`
	TotalTokens         int64                   `json:"total_tokens,omitempty"`
	LastActiveAt        string                  `json:"last_active_at,omitempty"`
	LastSeq             int64                   `json:"last_seq,omitempty"`
	GoalPreview         string                  `json:"goal_preview,omitempty"`
	Branch              string                  `json:"branch,omitempty"`
	Changed             []changedFile           `json:"changed,omitempty"`
	InContext           []contextFile           `json:"in_context,omitempty"`
	Path                string                  `json:"path,omitempty"`
	Insertions          int                     `json:"insertions,omitempty"`
	Deletions           int                     `json:"deletions,omitempty"`
	Binary              bool                    `json:"binary,omitempty"`
	Hunks               []diffHunk              `json:"hunks,omitempty"`
	RawPatch            string                  `json:"raw_patch,omitempty"`
	Status              string                  `json:"status,omitempty"`
	WorkspaceDiff       *treeWorkspace          `json:"workspace_diff,omitempty"`
}

type entry struct {
	Kind       string         `json:"kind"`
	ID         string         `json:"id,omitempty"`
	ResponseID string         `json:"response_id,omitempty"`
	Name       string         `json:"name,omitempty"`
	Content    string         `json:"content,omitempty"`
	Arguments  map[string]any `json:"arguments,omitempty"`
	Status     string         `json:"status,omitempty"`
	Error      bool           `json:"error,omitempty"`
	Streaming  bool           `json:"streaming,omitempty"`
	Role       spineRole      `json:"-"`
	SessionID  string         `json:"-"`
}

type protocol struct {
	reader *bufio.Reader
	writer io.Writer
	mu     sync.Mutex
}

func newProtocol(reader io.Reader, writer io.Writer) *protocol {
	return &protocol{reader: bufio.NewReader(reader), writer: writer}
}

func (p *protocol) read() (packet, error) {
	var header [4]byte
	if _, err := io.ReadFull(p.reader, header[:]); err != nil {
		return packet{}, err
	}

	size := binary.BigEndian.Uint32(header[:])
	if size == 0 || size > maxPacketSize {
		return packet{}, fmt.Errorf("invalid bridge packet size %d", size)
	}

	payload := make([]byte, size)
	if _, err := io.ReadFull(p.reader, payload); err != nil {
		return packet{}, err
	}

	var message packet
	if err := json.Unmarshal(payload, &message); err != nil {
		return packet{}, err
	}
	return message, nil
}

func (p *protocol) send(message packet) error {
	payload, err := json.Marshal(message)
	if err != nil {
		return err
	}
	if len(payload) > maxPacketSize {
		return fmt.Errorf("bridge packet too large: %d", len(payload))
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(payload)))
	if _, err := p.writer.Write(header[:]); err != nil {
		return err
	}
	_, err = p.writer.Write(payload)
	return err
}

type backendMsg packet
type backendClosedMsg struct{ err error }

type approval struct {
	ID        string
	Tool      string
	Access    string
	Arguments map[string]any
	Choice    string
}

type commandItem struct {
	ID    string
	Label string
	Hint  string
}

type providerOption struct {
	Profile   string `json:"profile"`
	Provider  string `json:"provider"`
	Model     string `json:"model"`
	Auth      string `json:"auth"`
	Status    string `json:"status"`
	Connected bool   `json:"connected"`
	Active    bool   `json:"active"`
}

var commands = []commandItem{
	{ID: "connect", Label: "Connect provider", Hint: "/connect [chatgpt]"},
	{ID: "auto", Label: "Toggle auto approval", Hint: "/auto"},
	{ID: "status", Label: "Session status", Hint: "/status"},
	{ID: "new", Label: "New session", Hint: "/new"},
	{ID: "sessions", Label: "Durable sessions", Hint: "/sessions"},
	{ID: "models", Label: "Model registry", Hint: "/models [refresh|PROFILE]"},
	{ID: "skills", Label: "Project skills", Hint: "/skills"},
	{ID: "reload", Label: "Reload project context", Hint: "/reload"},
	{ID: "compact", Label: "Compact context", Hint: "/compact"},
	{ID: "verify", Label: "Verify workspace", Hint: "/verify"},
	{ID: "events", Label: "Inspect goal events", Hint: "/events [filters]"},
	{ID: "tree", Label: "Goal worker tree", Hint: "/tree"},
	{ID: "budget", Label: "Goal budget", Hint: "/budget"},
	{ID: "repository", Label: "Repository intelligence", Hint: "/repository"},
	{ID: "resources", Label: "Resource scheduler", Hint: "/resources"},
	{ID: "organizations", Label: "Worker organizations", Hint: "/organizations"},
	{ID: "worktrees", Label: "Git worktrees", Hint: "/worktrees"},
	{ID: "toggle_tools", Label: "Expand or collapse tools", Hint: "ctrl+t"},
	{ID: "clear", Label: "Clear transcript", Hint: "/clear"},
	{ID: "exit", Label: "Leave chat", Hint: "/exit"},
}

type model struct {
	protocol       *protocol
	composer       textarea.Model
	viewport       viewport.Model
	width          int
	height         int
	bodyHeight     int
	sheetHeight    int
	workspace      string
	workspaceRoot  string
	sessionID      string
	projectID      string
	goalID         string
	cursor         int64
	provider       string
	profile        string
	llmModel       string
	status         string
	entries        []entry
	contextStats   map[string]any
	notice         string
	noticeTone     string
	panelTitle     string
	panelLines     []string
	sheet          sheetKind
	paletteIndex   int
	providerIndex  int
	providers      []providerOption
	approval       *approval
	approvalMode   string
	toolsExpanded  bool
	pendingFailure bool

	tab         tab
	unseen      [tabCount]int
	treeTab     treeTabState
	filesTab    filesTabState
	eventsTab   eventsTabState
	sessionsTab sessionsTabState
	modelsTab   modelsTabState

	treeData          *treeSnapshot
	eventsData        *eventsSnapshot
	modelsData        *modelsSnapshot
	sessionsData      *sessionsSnapshot
	sessionDetailData *sessionDetail
	filesData         *filesSnapshot
	selectedDiff      *fileDiff
}

func newModel(initial packet, bridge *protocol) model {
	composer := textarea.New()
	composer.Placeholder = "Type a message…"
	composer.Prompt = ""
	composer.ShowLineNumbers = false
	composer.CharLimit = 0
	composer.MaxHeight = 4
	composer.SetHeight(2)
	composer.SetWidth(72)
	composer.Focus()

	vp := viewport.New(viewport.WithWidth(80), viewport.WithHeight(16))
	vp.SoftWrap = true
	vp.MouseWheelEnabled = true

	m := model{
		protocol:      bridge,
		composer:      composer,
		viewport:      vp,
		width:         80,
		height:        24,
		workspace:     filepath.Base(initial.Workspace),
		workspaceRoot: initial.Workspace,
		sessionID:     initial.SessionID,
		projectID:     initial.ProjectID,
		goalID:        initial.GoalID,
		cursor:        initial.Cursor,
		provider:      initial.Provider,
		profile:       initial.Profile,
		llmModel:      initial.Model,
		status:        "ready",
		entries:       initial.Entries,
		contextStats:  initial.ContextStats,
		approvalMode:  initial.ApprovalMode,
	}
	m.refreshTranscript(true)
	return m
}

func (m model) Init() tea.Cmd {
	return m.composer.Focus()
}

func (m model) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := message.(type) {
	case tea.WindowSizeMsg:
		m.resize(msg.Width, msg.Height)
		return m, nil

	case backendMsg:
		m.applyBackend(packet(msg))
		m.resize(m.width, m.height)
		return m, nil

	case editorFinishedMsg:
		if msg.err != nil {
			m.notice = "Editor exited with an error: " + msg.err.Error()
			m.noticeTone = "warning"
			m.refreshTranscript(false)
		}
		return m, nil

	case backendClosedMsg:
		if msg.err != nil && !errors.Is(msg.err, io.EOF) {
			m.notice = "Elixir runtime disconnected: " + msg.err.Error()
			m.noticeTone = "error"
			m.refreshTranscript(true)
			return m, nil
		}
		return m, tea.Quit

	case tea.KeyPressMsg:
		key := msg.String()

		if m.approval != nil {
			return m.updateApproval(key)
		}
		switch m.sheet {
		case sheetProviderPicker:
			return m.updateProviderPicker(key)
		case sheetPalette:
			return m.updatePalette(key)
		}

		switch key {
		case "ctrl+c":
			if m.status == "working" || m.status == "cancelling" {
				m.status = "cancelling"
				m.notice = "Cancelling current turn…"
				m.noticeTone = "warning"
				m.refreshTranscript(true)
				return m, m.send(packet{Type: "cancel"})
			}
			return m, tea.Quit
		case "ctrl+p":
			m.sheet = sheetPalette
			m.panelTitle = ""
			m.panelLines = nil
			m.resize(m.width, m.height)
			return m, nil
		case "ctrl+t":
			m.toolsExpanded = !m.toolsExpanded
			m.refreshTranscript(false)
			return m, nil
		case "ctrl+o":
			if m.tab == tabChat {
				m.composer.InsertString("\n")
				m.resize(m.width, m.height)
			}
			return m, nil
		case "pgup":
			m.viewport.PageUp()
			return m, nil
		case "pgdown":
			m.viewport.PageDown()
			return m, nil
		case "1", "2", "3", "4", "5", "6":
			if m.tab != tabChat || m.composer.Value() == "" {
				return m, m.switchTab(tab(key[0] - '1'))
			}
		case "r", "e":
			if m.tab == tabChat && m.pendingFailure && m.composer.Value() == "" {
				prompt := m.lastUserPrompt()
				m.pendingFailure = false
				if key == "e" {
					m.composer.SetValue(prompt)
					m.resize(m.width, m.height)
					m.refreshTranscript(false)
					return m, nil
				}
				m.refreshTranscript(false)
				if prompt == "" {
					return m, nil
				}
				m.entries = append(m.entries, entry{Kind: "user", Content: prompt, Role: spineUser})
				m.status = "working"
				m.refreshTranscript(true)
				return m, m.send(packet{Type: "submit", Prompt: prompt})
			}
		case "esc":
			if m.sheet != sheetNone {
				m.sheet = sheetNone
				m.panelTitle = ""
				m.panelLines = nil
				m.notice = ""
				m.refreshTranscript(false)
				m.resize(m.width, m.height)
				return m, nil
			}
			if m.tab != tabChat {
				return m, m.switchTab(tabChat)
			}
			m.notice = ""
			m.pendingFailure = false
			m.refreshTranscript(false)
			return m, nil
		case "enter":
			if m.tab == tabChat {
				return m.submit()
			}
			return m.updateActiveTab(key)
		default:
			if m.tab != tabChat {
				return m.updateActiveTab(key)
			}
		}

	case tea.MouseWheelMsg:
		m.viewport, _ = m.viewport.Update(msg)
		return m, nil
	}

	var cmd tea.Cmd
	if m.tab == tabChat {
		m.composer, cmd = m.composer.Update(message)
	}
	m.resize(m.width, m.height)
	return m, cmd
}

func (m model) View() tea.View {
	tabStrip := m.renderTabStrip()

	dim := m.approval != nil || m.sheet != sheetNone
	body := m.renderActiveTab(dim)

	sheet := ""
	switch {
	case m.approval != nil:
		sheet = m.renderApproval()
	case m.sheet == sheetPalette:
		sheet = m.renderPalette()
	case m.sheet == sheetProviderPicker:
		sheet = m.renderProviderPicker()
	case m.sheet == sheetPanel:
		sheet = m.renderPanel()
	}

	composer := ""
	if m.tab == tabChat {
		composerBorder := colMint
		label := " Ask BeamAgent "
		if m.status != "ready" {
			composerBorder = colSand
			label = " Working "
		}
		composer = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(composerBorder).
			Padding(0, 1).
			Width(max(10, m.width-2)).
			Render(mutedStyle.Render(label) + "\n" + m.composer.View())
	}

	footer := mutedStyle.Render(joinEdges(m.footerLeft(), m.footerRight(), m.width))

	content := lipgloss.JoinVertical(lipgloss.Left, tabStrip, body, sheet, composer, footer)
	view := tea.NewView(content)
	view.AltScreen = true
	view.MouseMode = tea.MouseModeCellMotion
	view.WindowTitle = "BeamAgent · " + m.workspace
	return view
}

func (m model) footerLeft() string {
	switch {
	case m.tab != tabChat:
		return "1 back to chat"
	default:
		return "^P commands   wheel/PgUp/PgDn scroll   ^T tool details   1–6 tabs"
	}
}

func (m model) footerRight() string {
	mark := "●"
	status := m.status
	if status == "working" {
		mark = "◉"
	} else if status == "cancelling" {
		mark = "○"
	}
	context := ""
	if usage, ok := number(m.contextStats["utilization_percent"]); ok {
		context = fmt.Sprintf("   ctx %.0f%%", usage)
	}
	right := fmt.Sprintf("%s  %s   %s/%s%s", mark, status, m.profile, m.llmModel, context)
	if m.approvalMode == "auto" {
		right = "AUTO  " + right
	}
	if m.status == "working" {
		right = "^C cancel   " + right
	} else if m.status == "cancelling" {
		right = "cancelling…   " + right
	} else if m.tab == tabChat {
		right = "^C exit   " + right
	}
	return right
}

// Layout budget: tab strip (tab row + rule) + footer (one row) are always
// present; the composer (plus its rounded border) is chat-tab only. A docked
// sheet, once it lands, will claim a further slice of bodyHeight rather than
// overlaying it — see sheets.go.
const (
	tabStripHeight = 2
	footerHeight   = 1
	composerBorder = 2
)

func (m *model) resize(width, height int) {
	m.width = max(40, width)
	m.height = max(14, height)

	composerHeight := 0
	if m.tab == tabChat {
		composerHeight = min(4, max(2, m.composer.LineCount()))
		m.composer.SetHeight(composerHeight)
		m.composer.SetWidth(max(10, m.width-6))
		composerHeight += composerBorder
	}

	remaining := max(3, m.height-tabStripHeight-footerHeight-composerHeight)

	m.sheetHeight = 0
	if lines := m.sheetContentLines(); lines > 0 {
		const sheetChrome = 4 // rule + title + blank line + padding
		maxSheet := max(3, remaining*6/10)
		m.sheetHeight = min(lines+sheetChrome, maxSheet)
	}

	m.bodyHeight = max(3, remaining-m.sheetHeight)
	m.viewport.SetWidth(m.width)
	m.viewport.SetHeight(m.bodyHeight)
}

func (m model) submit() (tea.Model, tea.Cmd) {
	prompt := strings.TrimSpace(m.composer.Value())
	if prompt == "" {
		return m, nil
	}
	if strings.HasPrefix(prompt, "/") {
		m.composer.Reset()
		m.resize(m.width, m.height)
		return m.runSlash(prompt)
	}
	if m.status != "ready" {
		m.notice = "Cancel the current turn before submitting another"
		m.noticeTone = "warning"
		m.refreshTranscript(true)
		return m, nil
	}

	m.entries = append(m.entries, entry{Kind: "user", Content: prompt, Role: spineUser})
	m.status = "working"
	m.notice = ""
	m.pendingFailure = false
	m.composer.Reset()
	m.resize(m.width, m.height)
	m.refreshTranscript(true)
	return m, m.send(packet{Type: "submit", Prompt: prompt})
}

func (m model) runSlash(command string) (tea.Model, tea.Cmd) {
	command = strings.TrimSpace(command)
	name := command
	query := ""
	if separator := strings.IndexByte(command, ' '); separator >= 0 {
		name = command[:separator]
		query = strings.TrimSpace(command[separator+1:])
	}

	switch name {
	case "/exit", "/quit":
		return m, tea.Quit
	case "/", "/help":
		m.sheet = sheetPalette
		return m, nil
	case "/clear":
		m.entries = nil
		m.notice = ""
		m.refreshTranscript(true)
		return m, nil
	case "/model":
		name = "/status"
	}

	id := strings.TrimPrefix(name, "/")
	for _, item := range commands {
		if item.ID == id && !m.localCommand(item.ID) {
			m.notice = "Loading " + id + "…"
			m.noticeTone = "muted"
			m.refreshTranscript(true)
			return m, m.send(packet{Type: "command", Command: id, Query: query})
		}
	}

	m.notice = "Unknown command " + command
	m.noticeTone = "warning"
	m.refreshTranscript(true)
	return m, nil
}

func (m *model) localCommand(id string) bool {
	switch id {
	case "toggle_tools":
		m.toolsExpanded = !m.toolsExpanded
		m.refreshTranscript(false)
		return true
	case "clear":
		m.entries = nil
		m.refreshTranscript(true)
		return true
	case "exit":
		return true
	default:
		return false
	}
}

func (m model) updatePalette(key string) (tea.Model, tea.Cmd) {
	switch key {
	case "esc", "ctrl+p":
		m.sheet = sheetNone
		m.resize(m.width, m.height)
		return m, nil
	case "up", "k":
		m.paletteIndex = (m.paletteIndex - 1 + len(commands)) % len(commands)
		return m, nil
	case "down", "j":
		m.paletteIndex = (m.paletteIndex + 1) % len(commands)
		return m, nil
	case "enter":
		item := commands[m.paletteIndex]
		m.sheet = sheetNone
		m.resize(m.width, m.height)
		if item.ID == "exit" {
			return m, tea.Quit
		}
		if m.localCommand(item.ID) {
			return m, nil
		}
		m.notice = "Loading " + item.ID + "…"
		m.noticeTone = "muted"
		m.refreshTranscript(true)
		return m, m.send(packet{Type: "command", Command: item.ID})
	}
	return m, nil
}

func (m model) updateApproval(key string) (tea.Model, tea.Cmd) {
	switch key {
	case "left", "n":
		m.approval.Choice = previousApprovalChoice(m.approval.Choice)
		return m, nil
	case "right", "y":
		m.approval.Choice = nextApprovalChoice(m.approval.Choice)
		return m, nil
	case "esc":
		return m.resolveApproval("deny")
	case "enter":
		return m.resolveApproval(m.approval.Choice)
	}
	return m, nil
}

func (m model) resolveApproval(decision string) (tea.Model, tea.Cmd) {
	id := m.approval.ID
	m.approval = nil
	m.resize(m.width, m.height)
	return m, m.send(packet{Type: "approval", ApprovalID: id, Decision: decision})
}

func (m *model) applyBackend(message packet) {
	switch message.Type {
	case "turn_started":
		m.status = "working"
	case "turn_cancelling":
		m.status = "cancelling"
	case "turn_finished":
		m.status = "ready"
		m.approval = nil
		m.pendingFailure = !message.OK
		if !message.OK {
			m.entries = append(m.entries, entry{Kind: "error", Content: "Turn failed: " + message.Error})
		}
	case "stream":
		m.applyStream(message.Event)
	case "approval_requested":
		m.approval = &approval{
			ID:        asString(message.Approval["approval_id"]),
			Tool:      asString(message.Approval["tool"]),
			Access:    asString(message.Approval["access"]),
			Arguments: asMap(message.Approval["arguments"]),
			Choice:    "deny",
		}
		m.notice = ""
	case "approval_resolved":
		m.approval = nil
		if message.Decision == "allow_once" {
			m.notice, m.noticeTone = "Approved once", "success"
		} else if message.Decision == "allow_always" {
			m.notice, m.noticeTone = "Scoped permission saved", "success"
		} else {
			m.notice, m.noticeTone = "Tool denied", "warning"
		}
	case "approval_mode":
		m.approvalMode = message.ApprovalMode
		if m.approvalMode == "auto" {
			m.approval = nil
		}
	case "notice":
		m.notice, m.noticeTone = message.Message, message.Tone
	case "panel":
		m.panelTitle, m.panelLines = message.Title, message.Lines
		m.sheet = sheetPanel
		m.notice = ""
	case "provider_picker":
		m.providers = message.Providers
		m.providerIndex = 0
		for i, provider := range m.providers {
			if provider.Active {
				m.providerIndex = i
				break
			}
		}
		if len(m.providers) > 0 {
			m.sheet = sheetProviderPicker
		} else {
			m.sheet = sheetNone
		}
		m.panelTitle = ""
		m.panelLines = nil
		m.notice = ""
	case "session_changed":
		m.sessionID = message.SessionID
		m.goalID = message.SessionID
		if message.Provider != "" {
			m.provider = message.Provider
		}
		if message.Profile != "" {
			m.profile = message.Profile
		}
		if message.Model != "" {
			m.llmModel = message.Model
		}
		m.cursor = 0
		m.entries = []entry{{Kind: "system", Content: "Started " + shortSession(message.SessionID)}}
		m.status = "ready"
		m.panelTitle = ""
		m.panelLines = nil
		m.sheet = sheetNone
		m.providers = nil
	case "context_stats":
		m.contextStats = message.Stats
	case "tree":
		m.treeData = &treeSnapshot{
			Root:          message.Root,
			Nodes:         message.Nodes,
			Summary:       message.Summary,
			Budget:        message.Budget,
			ResourcePools: message.ResourcePools,
			WorkspaceDiff: message.WorkspaceDiff,
		}
		if m.tab != tabTree {
			m.unseen[tabTree]++
		}
	case "events":
		m.eventsData = &eventsSnapshot{
			Matched:             message.Matched,
			Total:               message.Total,
			Returned:            message.Returned,
			Cursor:              message.Cursor,
			Filters:             message.Filters,
			AvailableCategories: message.AvailableCategories,
			Events:              message.Events,
		}
		m.cursor = message.Cursor
		if m.tab != tabEvents {
			m.unseen[tabEvents]++
		}
	case "models":
		m.modelsData = &modelsSnapshot{
			ActiveProfile:   message.ActiveProfile,
			Endpoints:       message.Endpoints,
			Evidence:        message.Evidence,
			SessionSettings: message.SessionSettings,
		}
		if m.tab != tabModels {
			m.unseen[tabModels]++
		}
	case "sessions":
		m.sessionsData = &sessionsSnapshot{Sessions: message.Sessions}
		if m.tab != tabSessions {
			m.unseen[tabSessions]++
		}
	case "session_detail":
		m.sessionDetailData = &sessionDetail{
			SessionID:    message.SessionID,
			Provider:     message.Provider,
			Model:        message.Model,
			TurnCount:    message.TurnCount,
			TotalTokens:  message.TotalTokens,
			LastActiveAt: message.LastActiveAt,
			LastSeq:      message.LastSeq,
			GoalPreview:  message.GoalPreview,
		}
	case "files":
		m.filesData = &filesSnapshot{
			Branch:    message.Branch,
			Changed:   message.Changed,
			InContext: message.InContext,
		}
		if m.tab != tabFiles {
			m.unseen[tabFiles]++
		}
	case "diff":
		m.selectedDiff = &fileDiff{
			Path:       message.Path,
			Status:     message.Status,
			Insertions: message.Insertions,
			Deletions:  message.Deletions,
			Binary:     message.Binary,
			Hunks:      message.Hunks,
			RawPatch:   message.RawPatch,
		}
		m.filesTab.selectedHunk = 0
	}
	m.refreshTranscript(true)
}

func (m *model) applyStream(event map[string]any) {
	switch asString(event["type"]) {
	case "runtime_event":
		m.applyRuntimeEvent(event)

	case "text_delta":
		responseID := asString(event["response_id"])
		delta := asString(event["delta"])
		for i := range m.entries {
			if m.entries[i].Kind == "assistant" && m.entries[i].ResponseID == responseID {
				m.entries[i].Content += delta
				m.entries[i].Streaming = true
				return
			}
		}
		m.entries = append(m.entries, entry{Kind: "assistant", Content: delta, ResponseID: responseID, Streaming: true, Role: spineRoot})

	case "response_finished":
		responseID := asString(event["response_id"])
		for i := range m.entries {
			if m.entries[i].ResponseID == responseID {
				m.entries[i].Streaming = false
			}
		}

	case "durable_event":
		durable := asMap(event["event"])
		m.applyDurableEvent(
			asString(durable["type"]),
			asMap(durable["data"]),
			"",
			true,
		)
	}
}

func (m *model) applyRuntimeEvent(event map[string]any) {
	payload := asMap(event["payload"])
	scope := asMap(event["scope"])
	root := asBool(scope["root?"])
	sessionID := asString(scope["session_id"])

	if asString(event["durability"]) == "ephemeral" {
		if root {
			m.applyStream(asMap(payload["data"]))
		}
		return
	}

	if goalSeq, ok := number(event["goal_seq"]); ok && int64(goalSeq) > m.cursor {
		m.cursor = int64(goalSeq)
	}

	eventType := asString(payload["type"])
	data := asMap(payload["data"])
	m.applyDurableEvent(eventType, data, sessionID, root)

	if info, role, scopeID := runtimeInfo(eventType, data, sessionID, root); info != "" {
		m.entries = append(m.entries, entry{Kind: "info", Content: info, Role: role, SessionID: scopeID})
	}
}

func (m *model) applyDurableEvent(eventType string, data map[string]any, sessionID string, root bool) {
	switch eventType {
	case "assistant_message":
		if !root {
			return
		}
		content := asString(data["content"])
		if content != "" && !m.recentAssistantMatches(content) {
			m.entries = append(m.entries, entry{Kind: "assistant", Content: content, Role: spineRoot})
		}
	case "tool_called":
		role := spineRoot
		if !root {
			role = spineSubagent
		}
		m.entries = append(m.entries, entry{
			Kind:      "tool",
			ID:        runtimeToolID(sessionID, asString(data["tool_call_id"])),
			Name:      runtimeToolName(sessionID, asString(data["name"]), root),
			Arguments: asMap(data["arguments"]),
			Status:    "running",
			Role:      role,
			SessionID: sessionID,
		})
	case "tool_result":
		id := runtimeToolID(sessionID, asString(data["tool_call_id"]))
		for i := range m.entries {
			if m.entries[i].Kind == "tool" && m.entries[i].ID == id {
				m.entries[i].Content = asString(data["content"])
				m.entries[i].Error = asBool(data["is_error"])
				if m.entries[i].Error {
					m.entries[i].Status = "error"
				} else {
					m.entries[i].Status = "done"
				}
				return
			}
		}
	}
}

// runtimeInfo renders a durable-event info line and classifies which
// session it belongs to, so the transcript spine can draw it as a root fact
// (·) or as part of a specific subagent's branch (├/╰).
func runtimeInfo(eventType string, data map[string]any, sessionID string, root bool) (text string, role spineRole, scopeID string) {
	text = runtimeInfoText(eventType, data, sessionID, root)
	if text == "" {
		return "", spineSystem, ""
	}
	switch eventType {
	case "agent_started":
		if !root {
			return text, spineSubagent, sessionID
		}
	case "subagent_spawned":
		return text, spineSubagent, asString(data["child_session_id"])
	case "agent_construction_requested", "agent_constructed":
		return text, spineSubagent, asString(data["target_session_id"])
	case "agent_spec_applied":
		return text, spineSubagent, sessionID
	case "turn_finished", "model_response_failed":
		if !root {
			return text, spineSubagent, sessionID
		}
	}
	return text, spineSystem, ""
}

func runtimeInfoText(eventType string, data map[string]any, sessionID string, root bool) string {
	switch eventType {
	case "session_started":
		if root {
			return "Goal started · " + shortSession(sessionID)
		}
	case "agent_started":
		model := asString(data["model"])
		if model == "" {
			model = "built-in"
		}
		label := "Default model"
		if !root {
			label = "Subagent default · " + shortSession(sessionID)
		}
		result := label + " · " + asString(data["provider"]) + "/" + model
		if asBool(data["recovered"]) {
			result += " · recovered"
		}
		return result
	case "subagent_spawned":
		return "Subagent spawned · " + shortSession(asString(data["child_session_id"]))
	case "agent_construction_requested":
		requested := asString(data["role_requested"])
		if requested == "" {
			requested = asString(data["template_requested"])
		}
		if requested == "" {
			requested = "dynamic specialist"
		}
		return "Agent requested · " + requested + " · " + shortSession(asString(data["target_session_id"]))
	case "agent_constructed":
		return "Agent constructed · " + asString(data["role"]) + " · " + asString(data["authority"]) + " authority · " + shortSession(asString(data["target_session_id"]))
	case "agent_spec_applied":
		return "Agent ready · " + asString(data["role"]) + " · " + shortSession(sessionID)
	case "agent_construction_failed":
		return "Agent construction failed · " + asString(data["failure_code"])
	case "turn_finished":
		if !root {
			return "Subagent " + asString(data["reason"]) + " · " + shortSession(sessionID)
		}
	case "model_response_failed":
		return "Model response failed · " + shortSession(sessionID)
	case "approval_policy_changed":
		return "Approval policy · " + asString(data["from"]) + " → " + asString(data["to"])
	case "tool_loop_stalled":
		return "Repeated tool result ×" + asString(data["repetitions"]) + " · switching to answer-only"
	case "model_route_selected":
		selected := asString(data["selected_endpoint_id"])
		if selected == "" {
			selected = "deterministic"
		}
		return "Model routed · " + selected + " · " + asString(data["reason"]) + routingEvidenceSuffix(data)
	case "mcp_server_started":
		return "MCP ready · " + asString(data["server"]) + " · " + asString(data["tool_count"]) + " tools"
	case "mcp_server_restarted":
		return "MCP restarted · " + asString(data["server"]) + " · attempt " + asString(data["attempt"])
	case "mcp_server_stopped":
		return "MCP stopped · " + asString(data["server"])
	case "mcp_server_failed", "mcp_server_unavailable":
		return "MCP unavailable · " + asString(data["server"])
	case "permission_granted":
		return "Scoped permission saved · " + asString(data["tool"])
	case "permission_revoked":
		return "Scoped permission revoked"
	case "capability_denied":
		return "Capability denied · " + asString(data["reason"])
	case "model_outcome_recorded":
		return "Model outcome · " + asString(data["status"]) + " · " + asString(data["latency_ms"]) + " ms"
	case "task_outcome_recorded":
		result := "Task outcome · " + asString(data["status"])
		if verification := verificationStatus(data); verification != "" {
			result += " · " + verification
		}
		return result
	case "verification_attached":
		return "Verification · " + verificationStatus(data)
	case "verification_started":
		return "Verification started · " + asString(data["check_count"]) + " checks · " + asString(data["source"])
	case "verification_check_started":
		return "Verifying · " + asString(data["check_id"])
	case "verification_check_finished":
		return "Verification check · " + asString(data["check_id"]) + " · " + asString(data["status"]) + " · " + asString(data["duration_ms"]) + " ms"
	case "verification_finished":
		return "Verification " + asString(data["status"]) + " · " + asString(data["passed_count"]) + "/" + asString(data["check_count"]) + " checks"
	case "verification_cancelled":
		return "Verification cancelled"
	}
	return ""
}

func routingEvidenceSuffix(data map[string]any) string {
	evidence := asMap(data["evidence"])
	switch asString(evidence["state"]) {
	case "ready":
		return " · shadow prefers " + asString(evidence["recommended_endpoint_id"])
	case "insufficient_evidence":
		return " · evidence warming " + asString(evidence["best_verified_samples"]) + "/" + asString(evidence["minimum_verified_samples"]) + " verified"
	case "unavailable":
		return " · evidence unavailable"
	default:
		return ""
	}
}

func verificationStatus(data map[string]any) string {
	return asString(asMap(data["verification"])["status"])
}

func runtimeToolID(sessionID, toolCallID string) string {
	if sessionID == "" {
		return toolCallID
	}
	return sessionID + ":" + toolCallID
}

func runtimeToolName(sessionID, name string, root bool) string {
	if root || sessionID == "" {
		return name
	}
	return shortSession(sessionID) + " · " + name
}

func (m model) recentAssistantMatches(content string) bool {
	start := max(0, len(m.entries)-2)
	for _, item := range m.entries[start:] {
		if item.Kind == "assistant" && item.Content == content {
			return true
		}
	}
	return false
}

func (m *model) refreshTranscript(bottom bool) {
	wasAtBottom := m.viewport.AtBottom()
	previousOffset := m.viewport.YOffset()
	glyphs := spineGlyphs(m.entries)
	var b strings.Builder
	for i, item := range m.entries {
		glyph, style := glyphs[i], spineGlyphStyle(glyphs[i])
		switch item.Kind {
		case "user":
			fmt.Fprintf(&b, "%s\n", withSpine(glyph, style, bodyStyle.Render(item.Content)))
		case "assistant":
			cursor := ""
			if item.Streaming {
				cursor = " _"
			}
			fmt.Fprintf(&b, "%s\n", withSpine(glyph, style, bodyStyle.Render(item.Content+cursor)))
		case "tool":
			marker := "·"
			if item.Status == "done" {
				marker = "✓"
			} else if item.Status == "error" {
				marker = "×"
			}
			fmt.Fprintf(&b, "%s\n", withSpine(glyph, style, toolStyle.Render(fmt.Sprintf("%s  %s  %s", marker, item.Name, compactArguments(item.Arguments)))))
			if m.toolsExpanded && item.Content != "" {
				fmt.Fprintf(&b, "%s\n", withSpine(glyph, style, mutedStyle.Render(strings.ReplaceAll(item.Content, "\n", "\n   "))))
			}
		case "error":
			fmt.Fprintf(&b, "%s\n", withSpine(glyph, style, errorStyle.Render(item.Content)))
		case "system":
			fmt.Fprintf(&b, "%s\n", withSpine(glyph, style, mutedStyle.Render(item.Content)))
		case "info":
			fmt.Fprintf(&b, "%s\n", withSpine(glyph, style, mutedStyle.Render(item.Content)))
		}
	}
	if m.notice != "" {
		style := mutedStyle
		if m.noticeTone == "error" {
			style = errorStyle
		} else if m.noticeTone == "warning" {
			style = toolStyle
		} else if m.noticeTone == "success" {
			style = agentStyle
		}
		fmt.Fprintf(&b, "\n%s\n", style.Render("· "+m.notice))
	}
	if m.pendingFailure {
		fmt.Fprintf(&b, "\n%s\n", m.renderFailureActions())
	}
	m.viewport.SetContent(strings.TrimLeft(b.String(), "\n"))
	if bottom && wasAtBottom {
		m.viewport.GotoBottom()
	} else {
		m.viewport.SetYOffset(previousOffset)
	}
}

func (m model) renderPalette() string {
	rows := make([]string, 0, len(commands))
	width := min(72, m.width-6)
	for i, item := range commands {
		prefix := "  "
		style := bodyStyle
		if i == m.paletteIndex {
			prefix = "› "
			style = lipgloss.NewStyle().Bold(true).Foreground(colPanel).Background(colMint)
		}
		rows = append(rows, style.Width(width).Render(joinEdges(prefix+item.Label, item.Hint, width)))
	}
	return m.sheetBox("Command palette", strings.Join(rows, "\n"), colMint)
}

func (m model) renderProviderPicker() string {
	rows := make([]string, 0, len(m.providers)+2)
	width := min(96, m.width-6)
	for i, provider := range m.providers {
		marker := "  "
		if provider.Connected {
			marker = "✓ "
		}
		if provider.Active {
			marker += "● "
		} else {
			marker += "  "
		}
		left := marker + provider.Profile + "  " + provider.Provider + "/" + provider.Model
		right := provider.Auth + "  " + provider.Status
		style := bodyStyle
		if i == m.providerIndex {
			style = lipgloss.NewStyle().Bold(true).Foreground(colPanel).Background(colMint)
		}
		rows = append(rows, style.Width(width).Render(joinEdges(left, right, width)))
	}
	rows = append(rows, "", mutedStyle.Render("↑/↓ choose · enter connect · esc close"))
	return m.sheetBox("Connect a provider", strings.Join(rows, "\n"), colMint)
}

func (m model) updateProviderPicker(key string) (tea.Model, tea.Cmd) {
	if len(m.providers) == 0 {
		m.sheet = sheetNone
		m.resize(m.width, m.height)
		return m, nil
	}
	switch key {
	case "esc":
		m.sheet = sheetNone
		m.resize(m.width, m.height)
		return m, nil
	case "up", "k":
		m.providerIndex = (m.providerIndex - 1 + len(m.providers)) % len(m.providers)
		return m, nil
	case "down", "j":
		m.providerIndex = (m.providerIndex + 1) % len(m.providers)
		return m, nil
	case "enter":
		provider := m.providers[m.providerIndex]
		m.sheet = sheetNone
		m.resize(m.width, m.height)
		m.notice = "Connecting " + provider.Profile + "…"
		m.noticeTone = "muted"
		m.refreshTranscript(true)
		return m, m.send(packet{Type: "command", Command: "connect", Query: "profile:" + provider.Profile})
	}
	return m, nil
}

func (m model) renderApproval() string {
	args, _ := json.Marshal(m.approval.Arguments)
	deny := "[ Deny ]"
	allow := "  Allow once  "
	always := "  Allow always  "
	if m.approval.Choice == "allow_once" {
		deny, allow = "  Deny  ", "[ Allow once ]"
	} else if m.approval.Choice == "allow_always" {
		deny, always = "  Deny  ", "[ Allow always ]"
	}
	content := fmt.Sprintf("Tool      %s\nAccess    %s\nArguments %s\n\n%s     %s     %s\n\n←/→ choose · enter confirm · esc deny", m.approval.Tool, m.approval.Access, args, deny, allow, always)
	return m.sheetBox("Approval required", content, colSand)
}

func nextApprovalChoice(choice string) string {
	switch choice {
	case "deny":
		return "allow_once"
	case "allow_once":
		return "allow_always"
	default:
		return "deny"
	}
}

func previousApprovalChoice(choice string) string {
	switch choice {
	case "deny":
		return "allow_always"
	case "allow_always":
		return "allow_once"
	default:
		return "deny"
	}
}

func (m model) renderPanel() string {
	return m.sheetBox(m.panelTitle, strings.Join(m.panelLines, "\n"), colMint)
}

func (m model) send(message packet) tea.Cmd {
	return func() tea.Msg {
		if err := m.protocol.send(message); err != nil {
			return backendClosedMsg{err: err}
		}
		return nil
	}
}

func compactArguments(arguments map[string]any) string {
	if len(arguments) == 0 {
		return ""
	}
	keys := make([]string, 0, len(arguments))
	for key := range arguments {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		value := fmt.Sprint(arguments[key])
		if len(value) > 80 {
			value = value[:79] + "…"
		}
		if len(keys) == 1 && (key == "path" || key == "command" || key == "query") {
			parts = append(parts, value)
		} else {
			parts = append(parts, key+": "+value)
		}
	}
	return strings.Join(parts, "  ")
}

func joinEdges(left, right string, width int) string {
	gap := max(1, width-lipgloss.Width(left)-lipgloss.Width(right))
	line := left + strings.Repeat(" ", gap) + right
	if lipgloss.Width(line) > width {
		return truncateToWidth(line, width)
	}
	return line
}

// truncateToWidth cuts s to at most width display cells, respecting rune
// boundaries — plain byte slicing corrupts multi-byte characters (en dashes,
// status dots) once a line runs long enough to need truncating.
func truncateToWidth(s string, width int) string {
	var b strings.Builder
	used := 0
	for _, r := range s {
		w := lipgloss.Width(string(r))
		if used+w > width {
			break
		}
		b.WriteRune(r)
		used += w
	}
	return b.String()
}

func shortSession(sessionID string) string {
	if strings.HasPrefix(sessionID, "session-") {
		suffix := strings.TrimPrefix(sessionID, "session-")
		return "session " + suffix[:min(8, len(suffix))]
	}
	return sessionID
}

func asString(value any) string {
	if value == nil {
		return ""
	}
	if text, ok := value.(string); ok {
		return text
	}
	return fmt.Sprint(value)
}

func asBool(value any) bool {
	result, _ := value.(bool)
	return result
}

func asMap(value any) map[string]any {
	result, _ := value.(map[string]any)
	if result == nil {
		return map[string]any{}
	}
	return result
}

func number(value any) (float64, bool) {
	result, ok := value.(float64)
	return result, ok
}

func runBackendReader(bridge *protocol, program *tea.Program) {
	for {
		message, err := bridge.read()
		if err != nil {
			program.Send(backendClosedMsg{err: err})
			return
		}
		program.Send(backendMsg(message))
	}
}

func main() {
	bridgeInput := os.NewFile(3, "beam-agent-bridge-input")
	bridgeOutput := os.NewFile(4, "beam-agent-bridge-output")
	if bridgeInput == nil || bridgeOutput == nil {
		os.Exit(2)
	}
	defer bridgeInput.Close()
	defer bridgeOutput.Close()

	bridge := newProtocol(bridgeInput, bridgeOutput)
	initial, err := bridge.read()
	if err != nil {
		os.Exit(2)
	}
	if initial.Type != "init" {
		os.Exit(2)
	}

	program := tea.NewProgram(
		newModel(initial, bridge),
		tea.WithInput(os.Stdin),
		tea.WithOutput(os.Stdout),
	)
	go runBackendReader(bridge, program)
	if _, err := program.Run(); err != nil {
		os.Exit(4)
	}
}
