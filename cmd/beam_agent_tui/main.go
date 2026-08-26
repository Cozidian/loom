package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"image/color"
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

var (
	cyan       = lipgloss.Color("#73DACA")
	green      = lipgloss.Color("#9ECE6A")
	yellow     = lipgloss.Color("#E0AF68")
	red        = lipgloss.Color("#F7768E")
	muted      = lipgloss.Color("#565F89")
	foreground = lipgloss.Color("#C0CAF5")
	panel      = lipgloss.Color("#24283B")

	headerStyle    = lipgloss.NewStyle().Bold(true).Foreground(cyan)
	subheaderStyle = lipgloss.NewStyle().Foreground(muted)
	userStyle      = lipgloss.NewStyle().Bold(true).Foreground(cyan)
	agentStyle     = lipgloss.NewStyle().Bold(true).Foreground(green)
	toolStyle      = lipgloss.NewStyle().Foreground(yellow)
	errorStyle     = lipgloss.NewStyle().Foreground(red)
	mutedStyle     = lipgloss.NewStyle().Foreground(muted)
	bodyStyle      = lipgloss.NewStyle().Foreground(foreground)
)

type packet struct {
	Type         string         `json:"type"`
	SessionID    string         `json:"session_id,omitempty"`
	Workspace    string         `json:"workspace,omitempty"`
	Provider     string         `json:"provider,omitempty"`
	Profile      string         `json:"profile,omitempty"`
	Model        string         `json:"model,omitempty"`
	Prompt       string         `json:"prompt,omitempty"`
	Command      string         `json:"command,omitempty"`
	ApprovalID   string         `json:"approval_id,omitempty"`
	Decision     string         `json:"decision,omitempty"`
	OK           bool           `json:"ok,omitempty"`
	Error        string         `json:"error,omitempty"`
	Tone         string         `json:"tone,omitempty"`
	Message      string         `json:"message,omitempty"`
	Title        string         `json:"title,omitempty"`
	Lines        []string       `json:"lines,omitempty"`
	Entries      []entry        `json:"entries,omitempty"`
	ContextStats map[string]any `json:"context_stats,omitempty"`
	Stats        map[string]any `json:"stats,omitempty"`
	Event        map[string]any `json:"event,omitempty"`
	Approval     map[string]any `json:"approval,omitempty"`
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

var commands = []commandItem{
	{ID: "status", Label: "Session status", Hint: "/status"},
	{ID: "new", Label: "New session", Hint: "/new"},
	{ID: "sessions", Label: "Durable sessions", Hint: "/sessions"},
	{ID: "skills", Label: "Project skills", Hint: "/skills"},
	{ID: "reload", Label: "Reload project context", Hint: "/reload"},
	{ID: "compact", Label: "Compact context", Hint: "/compact"},
	{ID: "events", Label: "Event log", Hint: "/events"},
	{ID: "toggle_tools", Label: "Expand or collapse tools", Hint: "ctrl+t"},
	{ID: "clear", Label: "Clear transcript", Hint: "/clear"},
	{ID: "exit", Label: "Leave chat", Hint: "/exit"},
}

type model struct {
	protocol      *protocol
	composer      textarea.Model
	viewport      viewport.Model
	width         int
	height        int
	workspace     string
	sessionID     string
	provider      string
	profile       string
	llmModel      string
	status        string
	entries       []entry
	contextStats  map[string]any
	notice        string
	noticeTone    string
	panelTitle    string
	panelLines    []string
	palette       bool
	paletteIndex  int
	approval      *approval
	toolsExpanded bool
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
	vp.MouseWheelEnabled = false

	m := model{
		protocol:     bridge,
		composer:     composer,
		viewport:     vp,
		width:        80,
		height:       24,
		workspace:    filepath.Base(initial.Workspace),
		sessionID:    initial.SessionID,
		provider:     initial.Provider,
		profile:      initial.Profile,
		llmModel:     initial.Model,
		status:       "ready",
		entries:      initial.Entries,
		contextStats: initial.ContextStats,
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
		if m.palette {
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
			m.palette = true
			m.panelTitle = ""
			m.panelLines = nil
			return m, nil
		case "ctrl+t":
			m.toolsExpanded = !m.toolsExpanded
			m.refreshTranscript(false)
			return m, nil
		case "ctrl+o":
			m.composer.InsertString("\n")
			m.resize(m.width, m.height)
			return m, nil
		case "pgup":
			m.viewport.PageUp()
			return m, nil
		case "pgdown":
			m.viewport.PageDown()
			return m, nil
		case "esc":
			m.panelTitle = ""
			m.panelLines = nil
			m.notice = ""
			m.refreshTranscript(false)
			return m, nil
		case "enter":
			return m.submit()
		}
	}

	var cmd tea.Cmd
	m.composer, cmd = m.composer.Update(message)
	m.resize(m.width, m.height)
	return m, cmd
}

func (m model) View() tea.View {
	header := m.renderHeader()
	body := m.viewport.View()
	if m.palette {
		body = m.renderPalette()
	} else if m.approval != nil {
		body = m.renderApproval()
	} else if m.panelTitle != "" {
		body = m.renderPanel()
	}

	composerBorder := cyan
	label := " Ask BeamAgent "
	if m.status != "ready" {
		composerBorder = yellow
		label = " Working "
	}
	composer := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(composerBorder).
		Padding(0, 1).
		Width(max(10, m.width-2)).
		Render(mutedStyle.Render(label) + "\n" + m.composer.View())

	footerLeft := "^P commands   ^O newline   ^T tool details"
	footerRight := "^C exit"
	if m.status == "working" {
		footerRight = "^C cancel"
	} else if m.status == "cancelling" {
		footerRight = "cancelling…"
	}
	footer := mutedStyle.Render(joinEdges(footerLeft, footerRight, m.width))

	content := lipgloss.JoinVertical(lipgloss.Left, header, body, composer, footer)
	view := tea.NewView(content)
	view.AltScreen = true
	view.MouseMode = tea.MouseModeNone
	view.WindowTitle = "BeamAgent · " + m.workspace
	return view
}

func (m *model) resize(width, height int) {
	m.width = max(40, width)
	m.height = max(14, height)
	composerHeight := min(4, max(2, m.composer.LineCount()))
	m.composer.SetHeight(composerHeight)
	m.composer.SetWidth(max(10, m.width-6))
	m.viewport.SetWidth(m.width)
	m.viewport.SetHeight(max(3, m.height-composerHeight-7))
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

	m.entries = append(m.entries, entry{Kind: "user", Content: prompt})
	m.status = "working"
	m.notice = ""
	m.composer.Reset()
	m.resize(m.width, m.height)
	m.refreshTranscript(true)
	return m, m.send(packet{Type: "submit", Prompt: prompt})
}

func (m model) runSlash(command string) (tea.Model, tea.Cmd) {
	switch command {
	case "/exit", "/quit":
		return m, tea.Quit
	case "/", "/help":
		m.palette = true
		return m, nil
	case "/clear":
		m.entries = nil
		m.notice = ""
		m.refreshTranscript(true)
		return m, nil
	case "/model":
		command = "/status"
	}

	id := strings.TrimPrefix(command, "/")
	for _, item := range commands {
		if item.ID == id && !m.localCommand(item.ID) {
			m.notice = "Loading " + id + "…"
			m.noticeTone = "muted"
			m.refreshTranscript(true)
			return m, m.send(packet{Type: "command", Command: id})
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
		m.palette = false
		return m, nil
	case "up", "k":
		m.paletteIndex = (m.paletteIndex - 1 + len(commands)) % len(commands)
		return m, nil
	case "down", "j":
		m.paletteIndex = (m.paletteIndex + 1) % len(commands)
		return m, nil
	case "enter":
		item := commands[m.paletteIndex]
		m.palette = false
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
		m.approval.Choice = "deny"
		return m, nil
	case "right", "y":
		m.approval.Choice = "allow_once"
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
		} else {
			m.notice, m.noticeTone = "Tool denied", "warning"
		}
	case "notice":
		m.notice, m.noticeTone = message.Message, message.Tone
	case "panel":
		m.panelTitle, m.panelLines = message.Title, message.Lines
		m.notice = ""
	case "session_changed":
		m.sessionID = message.SessionID
		m.entries = []entry{{Kind: "system", Content: "Started " + shortSession(message.SessionID)}}
		m.status = "ready"
		m.panelTitle = ""
		m.panelLines = nil
	case "context_stats":
		m.contextStats = message.Stats
	}
	m.refreshTranscript(true)
}

func (m *model) applyStream(event map[string]any) {
	switch asString(event["type"]) {
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
		m.entries = append(m.entries, entry{Kind: "assistant", Content: delta, ResponseID: responseID, Streaming: true})

	case "response_finished":
		responseID := asString(event["response_id"])
		for i := range m.entries {
			if m.entries[i].ResponseID == responseID {
				m.entries[i].Streaming = false
			}
		}

	case "durable_event":
		durable := asMap(event["event"])
		data := asMap(durable["data"])
		switch asString(durable["type"]) {
		case "assistant_message":
			content := asString(data["content"])
			if content != "" && !m.recentAssistantMatches(content) {
				m.entries = append(m.entries, entry{Kind: "assistant", Content: content})
			}
		case "tool_called":
			m.entries = append(m.entries, entry{
				Kind:      "tool",
				ID:        asString(data["tool_call_id"]),
				Name:      asString(data["name"]),
				Arguments: asMap(data["arguments"]),
				Status:    "running",
			})
		case "tool_result":
			id := asString(data["tool_call_id"])
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
	var b strings.Builder
	for _, item := range m.entries {
		switch item.Kind {
		case "user":
			fmt.Fprintf(&b, "\n%s\n%s\n", userStyle.Render("YOU"), bodyStyle.Render(item.Content))
		case "assistant":
			cursor := ""
			if item.Streaming {
				cursor = " _"
			}
			fmt.Fprintf(&b, "\n%s\n%s\n", agentStyle.Render("AGENT"), bodyStyle.Render(item.Content+cursor))
		case "tool":
			marker := "·"
			if item.Status == "done" {
				marker = "✓"
			} else if item.Status == "error" {
				marker = "×"
			}
			fmt.Fprintf(&b, "%s\n", toolStyle.Render(fmt.Sprintf("%s  %s  %s", marker, item.Name, compactArguments(item.Arguments))))
			if m.toolsExpanded && item.Content != "" {
				fmt.Fprintf(&b, "%s\n", mutedStyle.Render("   "+strings.ReplaceAll(item.Content, "\n", "\n   ")))
			}
		case "error":
			fmt.Fprintf(&b, "\n%s\n", errorStyle.Render("! "+item.Content))
		case "system":
			fmt.Fprintf(&b, "%s\n", mutedStyle.Render("· "+item.Content))
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
	m.viewport.SetContent(strings.TrimLeft(b.String(), "\n"))
	if bottom {
		m.viewport.GotoBottom()
	}
}

func (m model) renderHeader() string {
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
	line1 := headerStyle.Render(joinEdges("BEAM AGENT", right, m.width))
	line2 := subheaderStyle.Render(joinEdges(m.workspace+"  /  "+shortSession(m.sessionID), m.provider, m.width))
	line3 := mutedStyle.Render(strings.Repeat("─", m.width))
	return lipgloss.JoinVertical(lipgloss.Left, line1, line2, line3)
}

func (m model) renderPalette() string {
	rows := make([]string, 0, len(commands))
	for i, item := range commands {
		prefix := "  "
		style := bodyStyle
		if i == m.paletteIndex {
			prefix = "› "
			style = lipgloss.NewStyle().Bold(true).Foreground(panel).Background(cyan)
		}
		rows = append(rows, style.Width(min(72, m.viewport.Width()-6)).Render(joinEdges(prefix+item.Label, item.Hint, min(72, m.viewport.Width()-6))))
	}
	return m.modal("Command palette", strings.Join(rows, "\n"), cyan)
}

func (m model) renderApproval() string {
	args, _ := json.Marshal(m.approval.Arguments)
	deny := "[ Deny ]"
	allow := "  Allow once  "
	if m.approval.Choice == "allow_once" {
		deny, allow = "  Deny  ", "[ Allow once ]"
	}
	content := fmt.Sprintf("Tool      %s\nAccess    %s\nArguments %s\n\n%s     %s\n\n←/→ choose · enter confirm · esc deny", m.approval.Tool, m.approval.Access, args, deny, allow)
	return m.modal("Approval required", content, yellow)
}

func (m model) renderPanel() string {
	return m.modal(m.panelTitle, strings.Join(m.panelLines, "\n"), cyan)
}

func (m model) modal(title, content string, accent color.Color) string {
	width := min(max(44, m.viewport.Width()*3/4), m.viewport.Width()-4)
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(accent).
		Padding(1, 2).
		Width(width).
		Render(headerStyle.Foreground(accent).Render(title) + "\n\n" + content)
	return lipgloss.Place(m.viewport.Width(), m.viewport.Height(), lipgloss.Center, lipgloss.Center, box)
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
		return line[:min(len(line), width)]
	}
	return line
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
