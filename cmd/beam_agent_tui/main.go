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
	Type           string           `json:"type"`
	SessionID      string           `json:"session_id,omitempty"`
	ProjectID      string           `json:"project_id,omitempty"`
	GoalID         string           `json:"goal_id,omitempty"`
	Cursor         int64            `json:"cursor,omitempty"`
	Workspace      string           `json:"workspace,omitempty"`
	Provider       string           `json:"provider,omitempty"`
	Profile        string           `json:"profile,omitempty"`
	Model          string           `json:"model,omitempty"`
	Prompt         string           `json:"prompt,omitempty"`
	Data           string           `json:"data,omitempty"`
	Name           string           `json:"name,omitempty"`
	MIMEType       string           `json:"mime_type,omitempty"`
	Provenance     string           `json:"provenance,omitempty"`
	Attachments    []attachmentItem `json:"attachments,omitempty"`
	Attachment     *attachmentItem  `json:"attachment,omitempty"`
	AttachmentID   string           `json:"attachment_id,omitempty"`
	Command        string           `json:"command,omitempty"`
	Query          string           `json:"query,omitempty"`
	ApprovalID     string           `json:"approval_id,omitempty"`
	ApprovalMode   string           `json:"approval_mode,omitempty"`
	Decision       string           `json:"decision,omitempty"`
	OK             bool             `json:"ok,omitempty"`
	Error          string           `json:"error,omitempty"`
	Tone           string           `json:"tone,omitempty"`
	Message        string           `json:"message,omitempty"`
	Title          string           `json:"title,omitempty"`
	Lines          []string         `json:"lines,omitempty"`
	Entries        []entry          `json:"entries,omitempty"`
	ContextStats   map[string]any   `json:"context_stats,omitempty"`
	Stats          map[string]any   `json:"stats,omitempty"`
	Event          map[string]any   `json:"event,omitempty"`
	Approval       map[string]any   `json:"approval,omitempty"`
	Approvals      []map[string]any `json:"approvals,omitempty"`
	Providers      []providerOption `json:"providers,omitempty"`
	WorkspaceFiles []string         `json:"workspace_files,omitempty"`

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
	Market              *providerMarket         `json:"market,omitempty"`
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
	RaceEvents          []map[string]any        `json:"race_events,omitempty"`
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

type attachmentItem struct {
	ID         string `json:"id,omitempty"`
	Kind       string `json:"kind,omitempty"`
	Name       string `json:"name,omitempty"`
	MIMEType   string `json:"mime_type,omitempty"`
	SizeBytes  int64  `json:"size_bytes,omitempty"`
	Width      int    `json:"width,omitempty"`
	Height     int    `json:"height,omitempty"`
	Status     string `json:"status,omitempty"`
	Summary    string `json:"summary,omitempty"`
	Provenance string `json:"provenance,omitempty"`
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
type clipboardImageMsg struct {
	image clipboardImage
	err   error
}

type fileSuggestionState struct {
	open     bool
	query    string
	matches  []string
	selected int
}

type approval struct {
	ID        string
	SessionID string
	Tool      string
	Access    string
	Arguments map[string]any
	Choice    string
	Decision  string
	Error     string
	Resolving bool
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
	{ID: "race", Label: "Race providers", Hint: "/race GOAL"},
	{ID: "skills", Label: "Project skills", Hint: "/skills"},
	{ID: "reload", Label: "Reload project context", Hint: "/reload"},
	{ID: "compact", Label: "Compact context", Hint: "/compact"},
	{ID: "verify", Label: "Verify workspace", Hint: "/verify"},
	{ID: "steer", Label: "Steer active work", Hint: "/steer MESSAGE"},
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
	protocol                 *protocol
	composer                 textarea.Model
	viewport                 viewport.Model
	width                    int
	height                   int
	bodyHeight               int
	sheetHeight              int
	workspace                string
	workspaceRoot            string
	sessionID                string
	projectID                string
	goalID                   string
	cursor                   int64
	provider                 string
	profile                  string
	llmModel                 string
	status                   string
	entries                  []entry
	contextStats             map[string]any
	notice                   string
	noticeTone               string
	panelTitle               string
	panelLines               []string
	sheet                    sheetKind
	paletteIndex             int
	providerIndex            int
	providers                []providerOption
	approval                 *approval
	approvalQueue            []approval
	approvalStatus           string
	approvalMode             string
	attachments              []attachmentItem
	lastSubmittedAttachments []attachmentItem
	toolsExpanded            bool
	pendingFailure           bool
	workspaceFiles           []string
	fileSuggestions          fileSuggestionState

	tab         tab
	unseen      [tabCount]int
	treeTab     treeTabState
	filesTab    filesTabState
	eventsTab   eventsTabState
	sessionsTab sessionsTabState
	modelsTab   modelsTabState
	raceTab     raceTabState
	races       []raceArena

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
		protocol:       bridge,
		composer:       composer,
		viewport:       vp,
		width:          80,
		height:         24,
		workspace:      filepath.Base(initial.Workspace),
		workspaceRoot:  initial.Workspace,
		sessionID:      initial.SessionID,
		projectID:      initial.ProjectID,
		goalID:         initial.GoalID,
		cursor:         initial.Cursor,
		provider:       initial.Provider,
		profile:        initial.Profile,
		llmModel:       initial.Model,
		status:         "ready",
		entries:        initial.Entries,
		contextStats:   initial.ContextStats,
		approvalMode:   initial.ApprovalMode,
		attachments:    initial.Attachments,
		workspaceFiles: append([]string(nil), initial.WorkspaceFiles...),
	}
	for _, event := range initial.RaceEvents {
		m.applyRaceProjection(event, true)
	}
	for _, pending := range initial.Approvals {
		m.enqueueApproval(approvalFromMap(pending))
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

	case clipboardImageMsg:
		if msg.err != nil {
			m.notice = "Could not attach clipboard image: " + msg.err.Error()
			m.noticeTone = "error"
			m.refreshTranscript(false)
			return m, nil
		}
		m.notice = "Importing clipboard image…"
		m.noticeTone = "muted"
		m.refreshTranscript(false)
		return m, m.send(packet{
			Type:       "attachment_import",
			Data:       msg.image.Data,
			Name:       msg.image.Name,
			MIMEType:   msg.image.MIMEType,
			Provenance: "clipboard",
		})

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
		if m.fileSuggestions.open {
			switch key {
			case "up":
				m.moveFileSuggestion(-1)
				m.resize(m.width, m.height)
				return m, nil
			case "down":
				m.moveFileSuggestion(1)
				m.resize(m.width, m.height)
				return m, nil
			case "enter", "tab":
				if len(m.fileSuggestions.matches) > 0 {
					m.selectFileSuggestion()
					m.resize(m.width, m.height)
					return m, nil
				}
			case "esc":
				m.clearFileSuggestions()
				m.resize(m.width, m.height)
				return m, nil
			}
		}
		switch m.sheet {
		case sheetProviderPicker:
			return m.updateProviderPicker(key)
		case sheetPalette:
			return m.updatePalette(key)
		}

		switch key {
		case "ctrl+v":
			if m.tab == tabChat && m.status == "ready" {
				m.notice = "Reading clipboard image…"
				m.noticeTone = "muted"
				m.refreshTranscript(false)
				return m, readClipboardImageCmd()
			}
		case "ctrl+x":
			if m.tab == tabChat && m.status == "ready" && len(m.attachments) > 0 {
				attachment := m.attachments[len(m.attachments)-1]
				m.notice = "Removing " + attachment.Name + "…"
				m.noticeTone = "muted"
				m.refreshTranscript(false)
				return m, m.send(packet{Type: "attachment_delete", AttachmentID: attachment.ID})
			}
		case "ctrl+c":
			if activeStatus(m.status) {
				m.status = "cancelling"
				m.notice = "Cancelling current turn…"
				m.noticeTone = "warning"
				m.refreshTranscript(true)
				return m, m.send(packet{Type: "cancel"})
			}
			return m, tea.Quit
		case "ctrl+p":
			m.clearFileSuggestions()
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
				m.syncFileSuggestionPanel()
				m.resize(m.width, m.height)
			}
			return m, nil
		case "pgup":
			m.viewport.PageUp()
			return m, nil
		case "pgdown":
			m.viewport.PageDown()
			return m, nil
		case "1", "2", "3", "4", "5", "6", "7":
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
				return m, m.send(packet{Type: "submit", Prompt: prompt, Attachments: m.lastSubmittedAttachments})
			}
		case "esc":
			if m.sheet != sheetNone {
				m.clearFileSuggestions()
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
		m.syncFileSuggestionPanel()
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
		attachmentLines := m.renderComposerAttachments()
		composerBody := m.composer.View()
		if attachmentLines != "" {
			composerBody = attachmentLines + "\n" + composerBody
		}
		composer = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(composerBorder).
			Padding(0, 1).
			Width(max(10, m.width-2)).
			Render(mutedStyle.Render(label) + "\n" + composerBody)
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
		return "^V image   ^X remove   ^P commands"
	}
}

func (m model) footerRight() string {
	mark := "●"
	status := m.status
	if activeStatus(status) && status != "cancelling" {
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
	if activeStatus(m.status) && m.status != "cancelling" {
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
		composerHeight += composerBorder + len(m.attachments)
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
	if prompt == "" && len(m.attachments) == 0 {
		return m, nil
	}
	if strings.HasPrefix(prompt, "/") {
		m.composer.Reset()
		m.clearFileSuggestions()
		m.resize(m.width, m.height)
		return m.runSlash(prompt)
	}
	if m.status != "ready" {
		m.notice = "Cancel the current turn before submitting another"
		m.noticeTone = "warning"
		m.refreshTranscript(true)
		return m, nil
	}

	m.entries = append(m.entries, entry{Kind: "user", Content: userEntryContent(prompt, m.attachments), Role: spineUser})
	m.status = "working"
	m.notice = ""
	m.pendingFailure = false
	m.composer.Reset()
	m.clearFileSuggestions()
	m.lastSubmittedAttachments = append([]attachmentItem(nil), m.attachments...)
	m.resize(m.width, m.height)
	m.refreshTranscript(true)
	return m, m.send(packet{Type: "submit", Prompt: prompt, Attachments: m.attachments})
}

func (m model) renderComposerAttachments() string {
	if len(m.attachments) == 0 {
		return ""
	}
	lines := make([]string, 0, len(m.attachments))
	for _, attachment := range m.attachments {
		lines = append(lines, styleMint.Render(fmt.Sprintf("▣ %s · %dx%d · %s", attachment.Name, attachment.Width, attachment.Height, humanBytes(attachment.SizeBytes))))
	}
	return strings.Join(lines, "\n")
}

func userEntryContent(prompt string, attachments []attachmentItem) string {
	if len(attachments) == 0 {
		return prompt
	}
	parts := make([]string, 0, len(attachments))
	for _, attachment := range attachments {
		parts = append(parts, fmt.Sprintf("[image: %s · %dx%d]", attachment.Name, attachment.Width, attachment.Height))
	}
	if prompt == "" {
		return strings.Join(parts, " ")
	}
	return prompt + "\n" + strings.Join(parts, " ")
}

func humanBytes(size int64) string {
	if size < 1024 {
		return fmt.Sprintf("%d B", size)
	}
	if size < 1024*1024 {
		return fmt.Sprintf("%.1f KB", float64(size)/1024)
	}
	return fmt.Sprintf("%.1f MB", float64(size)/(1024*1024))
}

func (m *model) syncFileSuggestionPanel() {
	token, ok := activeFileSuggestionToken(
		m.composer.Value(),
		m.composer.Line(),
		m.composer.Column(),
	)
	if !ok {
		m.clearFileSuggestions()
		return
	}

	selected := m.fileSuggestions.selected
	if !m.fileSuggestions.open || token.query != m.fileSuggestions.query {
		selected = 0
	}

	matches := matchFileSuggestions(m.workspaceFiles, token.query)
	if len(matches) == 0 {
		selected = 0
	} else {
		selected = min(selected, len(matches)-1)
	}

	m.fileSuggestions = fileSuggestionState{
		open:     true,
		query:    token.query,
		matches:  matches,
		selected: selected,
	}
	m.sheet = sheetPanel
	m.panelTitle = "File suggestions"
	m.panelLines = fileSuggestionLines(token.query, matches, selected)
}

type fileSuggestionToken struct {
	query string
	line  int
	start int
	end   int
}

func activeFileSuggestionToken(value string, line, column int) (fileSuggestionToken, bool) {
	lines := strings.Split(value, "\n")
	if line < 0 || line >= len(lines) {
		return fileSuggestionToken{}, false
	}

	current := []rune(lines[line])
	column = min(max(column, 0), len(current))

	for start := column - 1; start >= 0; start-- {
		if current[start] == '@' {
			if start > 0 && !fileSuggestionBoundary(current[start-1]) {
				return fileSuggestionToken{}, false
			}

			queryStart := start + 1
			quoted := queryStart < len(current) && current[queryStart] == '"'
			if quoted {
				queryStart++
				if queryStart > column || containsRune(current[queryStart:column], '"') {
					return fileSuggestionToken{}, false
				}
			} else if containsFileSuggestionBoundary(current[queryStart:column]) {
				return fileSuggestionToken{}, false
			}

			end := column
			if quoted {
				for end < len(current) {
					end++
					if current[end-1] == '"' {
						break
					}
				}
			} else {
				for end < len(current) && !fileSuggestionTerminator(current[end]) {
					end++
				}
			}

			return fileSuggestionToken{
				query: string(current[queryStart:column]),
				line:  line,
				start: start,
				end:   end,
			}, true
		}
	}

	return fileSuggestionToken{}, false
}

func fileSuggestionBoundary(ch rune) bool {
	switch ch {
	case ' ', '\t', '\r', '\n', '(', '[', '{', '<', '"', '\'':
		return true
	default:
		return false
	}
}

func fileSuggestionTerminator(ch rune) bool {
	return fileSuggestionBoundary(ch) || strings.ContainsRune(")]}>,;:!?", ch)
}

func containsFileSuggestionBoundary(value []rune) bool {
	for _, ch := range value {
		if fileSuggestionTerminator(ch) {
			return true
		}
	}
	return false
}

func containsRune(value []rune, expected rune) bool {
	for _, ch := range value {
		if ch == expected {
			return true
		}
	}
	return false
}

func matchFileSuggestions(files []string, query string) []string {
	if query == "" {
		return files
	}

	query = strings.ToLower(query)
	matches := make([]string, 0, len(files))
	for _, path := range files {
		if strings.HasPrefix(strings.ToLower(path), query) || strings.HasPrefix(strings.ToLower(filepath.Base(path)), query) {
			matches = append(matches, path)
		}
	}
	return matches
}

func fileSuggestionLines(query string, matches []string, selected int) []string {
	label := "@" + query
	if len(matches) == 0 {
		return []string{"No matching files for " + label}
	}

	start, end := fileSuggestionWindow(len(matches), selected, 10)
	lines := make([]string, 0, end-start+2)
	lines = append(lines, fmt.Sprintf("%d matches for %s", len(matches), label))
	for index := start; index < end; index++ {
		line := "  " + matches[index]
		if index == selected {
			line = styleMint.Bold(true).Render("› " + matches[index])
		}
		lines = append(lines, line)
	}
	lines = append(lines, "↑/↓ choose · enter/tab insert · esc close")
	return lines
}

func fileSuggestionWindow(total, selected, limit int) (int, int) {
	if total <= limit {
		return 0, total
	}
	start := max(0, min(selected-limit/2, total-limit))
	return start, start + limit
}

func (m *model) moveFileSuggestion(delta int) {
	count := len(m.fileSuggestions.matches)
	if count == 0 {
		return
	}
	m.fileSuggestions.selected = (m.fileSuggestions.selected + delta + count) % count
	m.panelLines = fileSuggestionLines(
		m.fileSuggestions.query,
		m.fileSuggestions.matches,
		m.fileSuggestions.selected,
	)
}

func (m *model) selectFileSuggestion() {
	if len(m.fileSuggestions.matches) == 0 {
		return
	}

	token, ok := activeFileSuggestionToken(
		m.composer.Value(),
		m.composer.Line(),
		m.composer.Column(),
	)
	if !ok {
		m.clearFileSuggestions()
		return
	}

	lines := strings.Split(m.composer.Value(), "\n")
	current := []rune(lines[token.line])
	path := m.fileSuggestions.matches[m.fileSuggestions.selected]
	reference := "@" + path
	if strings.ContainsAny(path, " \t\r\n") {
		reference = "@\"" + path + "\""
	}

	prefix := current[:token.start]
	suffix := current[token.end:]
	separator := ""
	if len(suffix) == 0 {
		separator = " "
	}

	lines[token.line] = string(prefix) + reference + separator + string(suffix)
	m.composer.SetValue(strings.Join(lines, "\n"))
	for m.composer.Line() > token.line {
		m.composer.CursorUp()
	}
	m.composer.SetCursorColumn(len(prefix) + len([]rune(reference+separator)))
	m.clearFileSuggestions()
}

func (m *model) clearFileSuggestions() {
	wasOpen := m.fileSuggestions.open
	m.fileSuggestions = fileSuggestionState{}
	if wasOpen && m.sheet == sheetPanel && m.panelTitle == "File suggestions" {
		m.sheet = sheetNone
		m.panelTitle = ""
		m.panelLines = nil
	}
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
	case "/race":
		if query == "" {
			m.notice = "Usage: /race GOAL"
			m.noticeTone = "warning"
			m.refreshTranscript(true)
			return m, nil
		}
		if m.status != "ready" {
			m.notice = "Cancel the current turn before starting a provider race"
			m.noticeTone = "warning"
			m.refreshTranscript(true)
			return m, nil
		}
		if len(m.attachments) > 0 {
			m.notice = "Send attached images normally; provider races currently accept text goals only"
			m.noticeTone = "warning"
			m.refreshTranscript(true)
			return m, nil
		}
		m.entries = append(m.entries, entry{Kind: "user", Content: "Race providers · " + query, Role: spineUser})
		m.status = "providers bidding"
		m.notice = ""
		m.refreshTranscript(true)
		return m, m.send(packet{Type: "command", Command: "race", Query: query})
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
	if m.approval.Resolving {
		return m, nil
	}

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
	m.approval.Resolving = true
	m.approval.Decision = decision
	m.approval.Error = ""
	m.status = "resolving approval"
	m.resize(m.width, m.height)
	return m, m.send(packet{Type: "approval", ApprovalID: id, Decision: decision})
}

func (m *model) applyBackend(message packet) {
	switch message.Type {
	case "turn_started":
		m.status = "working"
		if m.lastSubmittedAttachments != nil {
			m.attachments = nil
		}
	case "turn_cancelling":
		m.status = "cancelling"
	case "turn_finished":
		if m.approval == nil {
			m.status = "ready"
		} else {
			m.approvalStatus = "ready"
			if m.approval.Resolving {
				m.status = "resolving approval"
			} else {
				m.status = "waiting approval"
			}
		}
		m.pendingFailure = !message.OK
		if !message.OK {
			if len(m.attachments) == 0 && len(m.lastSubmittedAttachments) > 0 {
				m.attachments = append([]attachmentItem(nil), m.lastSubmittedAttachments...)
			}
			m.entries = append(m.entries, entry{Kind: "error", Content: "Turn failed: " + message.Error})
		} else {
			m.lastSubmittedAttachments = nil
		}
	case "stream":
		m.applyStream(message.Event)
	case "approval_requested":
		m.clearFileSuggestions()
		m.enqueueApproval(approvalFromMap(message.Approval))
		m.notice = ""
	case "approval_resolved":
		m.removeApproval(message.ApprovalID)
		if message.Decision == "allow_once" {
			m.notice, m.noticeTone = "Approved once", "success"
		} else if message.Decision == "allow_always" {
			m.notice, m.noticeTone = "Scoped permission saved", "success"
		} else {
			m.notice, m.noticeTone = "Tool denied", "warning"
		}
	case "approval_failed":
		m.failApproval(message.ApprovalID, message.Error)
	case "approval_snapshot":
		m.reconcileApprovals(message.Approvals)
	case "approval_mode":
		m.approvalMode = message.ApprovalMode
		if m.approvalMode == "auto" {
			m.approval = nil
			m.approvalQueue = nil
			if m.status == "waiting approval" || m.status == "resolving approval" {
				m.status = m.approvalStatus
			}
			m.approvalStatus = ""
		}
	case "notice":
		m.notice, m.noticeTone = message.Message, message.Tone
	case "panel":
		m.clearFileSuggestions()
		m.panelTitle, m.panelLines = message.Title, message.Lines
		m.sheet = sheetPanel
		m.notice = ""
	case "provider_picker":
		m.clearFileSuggestions()
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
	case "attachment_imported":
		if message.Attachment != nil {
			alreadyPresent := false
			for _, attachment := range m.attachments {
				alreadyPresent = alreadyPresent || attachment.ID == message.Attachment.ID
			}
			if !alreadyPresent {
				m.attachments = append(m.attachments, *message.Attachment)
			}
			m.notice = "Attached " + message.Attachment.Name
			m.noticeTone = "success"
		}
	case "attachment_deleted":
		kept := m.attachments[:0]
		for _, attachment := range m.attachments {
			if attachment.ID != message.AttachmentID {
				kept = append(kept, attachment)
			}
		}
		m.attachments = kept
		m.notice = "Attachment removed"
		m.noticeTone = "success"
	case "attachment_failed":
		m.notice = "Attachment failed: " + message.Error
		m.noticeTone = "error"
	case "session_changed":
		m.clearFileSuggestions()
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
		m.races = nil
		m.raceTab = raceTabState{}
		m.status = "ready"
		m.panelTitle = ""
		m.panelLines = nil
		m.sheet = sheetNone
		m.providers = nil
		m.attachments = append([]attachmentItem(nil), message.Attachments...)
		m.lastSubmittedAttachments = nil
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
			Market:          message.Market,
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
	m.applyMarketStatus(eventType, data)
	groupedRaceEvent := m.applyRaceEvent(eventType, data, sessionID, root, false)
	if !groupedRaceEvent {
		m.applyDurableEvent(eventType, data, sessionID, root)
	}
	if groupedRaceEvent {
		return
	}

	if info, role, scopeID := runtimeInfo(eventType, data, sessionID, root); info != "" {
		m.entries = append(m.entries, entry{Kind: "info", Content: info, Role: role, SessionID: scopeID})
	}
}

func (m *model) applyMarketStatus(eventType string, data map[string]any) {
	switch eventType {
	case "provider_auction_started":
		m.status = "providers bidding"
	case "provider_auction_awarded":
		if asString(data["purpose"]) == "provider_race" {
			m.status = "racing providers"
		} else {
			m.status = "working"
		}
	case "race_started":
		count := asString(data["provider_count"])
		if count == "" {
			count = asString(data["candidate_count"])
		}
		m.status = "racing " + count + " providers"
	case "race_collapsed", "race_inconclusive", "provider_auction_settled":
		m.status = "working"
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
	case "model_route_reused":
		selected := asString(data["selected_endpoint_id"])
		if selected == "" {
			selected = "deterministic"
		}
		return "Model lease reused · " + selected
	case "provider_auction_started":
		return "Provider market opened · " + asString(data["eligible_count"]) + " eligible · " + asString(data["requested_awards"]) + " lease" + pluralCount(data["requested_awards"])
	case "provider_bid_submitted":
		latency := ""
		if value := asString(data["estimated_latency_ms"]); value != "" {
			latency = " · ~" + value + " ms"
		}
		return "Bid · " + asString(data["endpoint_id"]) + " · score " + asString(data["score"]) + " · " + percent(data["confidence"]) + " confidence" + latency + " · " + asString(data["cost_tier"])
	case "provider_auction_awarded":
		awards := asSlice(data["awards"])
		ids := make([]string, 0, len(awards))
		for _, raw := range awards {
			ids = append(ids, asString(asMap(raw)["endpoint_id"]))
		}
		return "Provider lease awarded · " + strings.Join(ids, ", ")
	case "provider_auction_settled":
		winner := asString(data["winner_endpoint_id"])
		if winner == "" {
			winner = "no deterministic winner"
		}
		return "Provider market settled · " + asString(data["status"]) + " · " + winner
	case "race_started":
		return "Provider race started · " + asString(data["provider_count"]) + " providers · " + asString(data["candidate_count"]) + " candidates"
	case "race_candidate_started":
		return "Candidate " + asString(data["candidate_id"]) + " · " + asString(data["endpoint_id"]) + " started"
	case "race_candidate_completed":
		return "Candidate " + asString(data["candidate_id"]) + " · " + asString(data["endpoint_id"]) + " · " + asString(data["verification_status"])
	case "race_winner_selected":
		return "Race winner · " + asString(data["winner_endpoint_id"]) + " · " + asString(data["winner_id"])
	case "race_inconclusive":
		return "Provider race needs independent judgment"
	case "goal_steered":
		return "Live steering queued for active worker"
	case "path_lease_denied":
		return "Write lease conflict · " + asString(data["path"])
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
		mode := asString(evidence["mode"])
		if mode == "" {
			mode = "shadow"
		}
		return " · " + mode + " prefers " + asString(evidence["recommended_endpoint_id"])
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
		case "race":
			if arena := m.raceByAnchor(item.ID); arena != nil {
				fmt.Fprintf(&b, "%s\n", withSpine(glyph, style, m.renderCompactRace(*arena)))
			}
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
	args := compactArguments(m.approval.Arguments)
	deny := "[ Deny ]"
	allow := "  Allow once  "
	always := "  Allow always  "
	if m.approval.Choice == "allow_once" {
		deny, allow = "  Deny  ", "[ Allow once ]"
	} else if m.approval.Choice == "allow_always" {
		deny, always = "  Deny  ", "[ Allow always ]"
	}
	worker := shortSession(m.approval.SessionID)
	footer := "←/→ choose · enter confirm · esc deny"
	if m.approval.Resolving {
		footer = "Waiting for runtime acknowledgement…"
		if m.approval.Decision != "" {
			footer = "Resolving " + strings.ReplaceAll(m.approval.Decision, "_", " ") + "…"
		}
	} else if m.approval.Error != "" {
		footer = "Decision failed: " + m.approval.Error + "\n←/→ choose · enter retry · esc deny"
	}
	content := fmt.Sprintf("Worker    %s\nTool      %s\nAccess    %s\nArguments %s\n\n%s     %s     %s\n\n%s", worker, m.approval.Tool, m.approval.Access, args, deny, allow, always, footer)
	return m.sheetBox("Approval required", content, colSand)
}

func approvalFromMap(value map[string]any) approval {
	return approval{
		ID:        asString(value["approval_id"]),
		SessionID: asString(value["session_id"]),
		Tool:      asString(value["tool"]),
		Access:    asString(value["access"]),
		Arguments: asMap(value["arguments"]),
		Choice:    "deny",
	}
}

func (m *model) enqueueApproval(next approval) {
	if next.ID == "" {
		return
	}
	if m.approval != nil && m.approval.ID == next.ID {
		return
	}
	for _, queued := range m.approvalQueue {
		if queued.ID == next.ID {
			return
		}
	}
	if m.approval == nil {
		m.approvalStatus = m.status
		m.approval = &next
	} else {
		m.approvalQueue = append(m.approvalQueue, next)
	}
	m.status = "waiting approval"
}

func (m *model) removeApproval(id string) {
	if m.approval != nil && m.approval.ID == id {
		m.approval = nil
	}
	filtered := m.approvalQueue[:0]
	for _, queued := range m.approvalQueue {
		if queued.ID != id {
			filtered = append(filtered, queued)
		}
	}
	m.approvalQueue = filtered
	if m.approval == nil && len(m.approvalQueue) > 0 {
		next := m.approvalQueue[0]
		m.approvalQueue = m.approvalQueue[1:]
		m.approval = &next
		if m.approval.Resolving {
			m.status = "resolving approval"
		} else {
			m.status = "waiting approval"
		}
	}
	if m.approval == nil && (m.status == "waiting approval" || m.status == "resolving approval") {
		m.status = m.approvalStatus
		m.approvalStatus = ""
	}
}

func (m *model) failApproval(id string, message string) {
	if m.approval != nil && m.approval.ID == id {
		m.approval.Resolving = false
		m.approval.Decision = ""
		m.approval.Error = message
		m.status = "waiting approval"
		return
	}
	for i := range m.approvalQueue {
		if m.approvalQueue[i].ID == id {
			m.approvalQueue[i].Resolving = false
			m.approvalQueue[i].Decision = ""
			m.approvalQueue[i].Error = message
			return
		}
	}
}

func (m *model) reconcileApprovals(values []map[string]any) {
	existing := make(map[string]approval, len(m.approvalQueue)+1)
	activeID := ""
	if m.approval != nil {
		activeID = m.approval.ID
		existing[m.approval.ID] = *m.approval
	}
	for _, queued := range m.approvalQueue {
		existing[queued.ID] = queued
	}

	next := make([]approval, 0, len(values))
	for _, value := range values {
		item := approvalFromMap(value)
		if previous, ok := existing[item.ID]; ok {
			item.Choice = previous.Choice
			item.Decision = previous.Decision
			item.Error = previous.Error
			item.Resolving = previous.Resolving
		}
		next = append(next, item)
	}

	if activeID != "" {
		for i := range next {
			if next[i].ID == activeID {
				next[0], next[i] = next[i], next[0]
				break
			}
		}
	}

	m.approval = nil
	m.approvalQueue = nil
	if len(next) > 0 {
		m.approval = &next[0]
		m.approvalQueue = append(m.approvalQueue, next[1:]...)
		if m.approvalStatus == "" {
			m.approvalStatus = m.status
		}
		if m.approval.Resolving {
			m.status = "resolving approval"
		} else {
			m.status = "waiting approval"
		}
	} else if m.status == "waiting approval" || m.status == "resolving approval" {
		m.status = m.approvalStatus
		m.approvalStatus = ""
	}
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

func asSlice(value any) []any {
	result, _ := value.([]any)
	return result
}

func percent(value any) string {
	if numeric, ok := number(value); ok {
		return fmt.Sprintf("%.0f%%", numeric*100)
	}
	return "unknown"
}

func pluralCount(value any) string {
	if numeric, ok := number(value); ok && numeric == 1 {
		return ""
	}
	return "s"
}

func activeStatus(status string) bool {
	return status == "working" || status == "cancelling" || status == "providers bidding" ||
		status == "racing providers" || strings.HasPrefix(status, "racing ")
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
