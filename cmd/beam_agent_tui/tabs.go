package main

import (
	"fmt"
	"strconv"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

// tab identifies one of the numbered views over a single session. Tabs
// are views onto the same goal, not separate modes — number keys jump
// straight to any of them.
type tab int

const (
	tabChat tab = iota
	tabTree
	tabFiles
	tabEvents
	tabSessions
	tabModels
	tabRace
	tabCount
)

var tabLabels = [tabCount]string{
	tabChat:     "chat",
	tabTree:     "tree",
	tabFiles:    "files",
	tabEvents:   "events",
	tabSessions: "sessions",
	tabModels:   "models",
	tabRace:     "arena",
}

// sheetKind identifies which bottom-docked sheet, if any, is currently
// shown over the active tab. Approval is tracked separately on model.approval
// since it is backend-authoritative and always takes priority over any
// user-invoked sheet.
type sheetKind int

const (
	sheetNone sheetKind = iota
	sheetPalette
	sheetProviderPicker
	sheetPanel
)

type treeTabState struct {
	selected int
	expanded map[string]bool
}

type filesTabState struct {
	selectedFile int
	selectedHunk int
}

type eventsTabState struct {
	selected int
	category string
	query    string
	expanded bool
	follow   bool
}

type sessionsTabState struct {
	selected   int
	filterText string
}

type modelsTabState struct {
	selected int
}

type raceTabState struct {
	selected int
	expanded bool
}

// switchTab moves focus to t, clears its unseen badge, moves composer focus
// so only the chat tab ever receives typed text, and returns a command to
// (re)fetch that tab's backend data — otherwise a data-driven tab would
// show nothing until the user already knew its slash command.
func (m *model) switchTab(t tab) tea.Cmd {
	m.tab = t
	m.unseen[t] = 0
	if t == tabChat {
		m.composer.Focus()
	} else {
		m.composer.Blur()
	}
	m.resize(m.width, m.height)
	return m.refreshTabCmd(t)
}

func (m model) refreshTabCmd(t tab) tea.Cmd {
	switch t {
	case tabTree:
		return m.send(packet{Type: "command", Command: "tree"})
	case tabEvents:
		return m.send(packet{Type: "command", Command: "events"})
	case tabModels:
		return m.send(packet{Type: "command", Command: "models"})
	case tabSessions:
		return m.send(packet{Type: "command", Command: "sessions"})
	case tabFiles:
		return m.send(packet{Type: "command", Command: "files"})
	default:
		return nil
	}
}

// renderTabStrip draws the tab labels on one row and a single shared rule
// beneath them on the next. The mockup gives each tab its own bottom
// border (mint for the active one, transparent for the rest); a terminal
// can't stack per-segment borders without breaking horizontal layout — a
// styled Border() on one segment renders as a 2-line block, and joining
// that into a row of otherwise 1-line segments splits the strip across
// lines — so instead this collapses both borders into one rule row, dim
// throughout except for a mint span positioned under the active tab.
func (m model) renderTabStrip() string {
	const wordmark = "BEAM"
	const gap = "  "

	labels := make([]string, tabCount)
	rendered := make([]string, tabCount)
	for i := tab(0); i < tabCount; i++ {
		labels[i] = fmt.Sprintf("%d %s", i+1, tabLabels[i])
		text := labels[i]
		if i != m.tab && m.unseen[i] > 0 {
			text += " " + styleMint.Render(strconv.Itoa(m.unseen[i]))
		}
		if i == m.tab {
			rendered[i] = lipgloss.NewStyle().Foreground(colFg).Render(text)
		} else {
			rendered[i] = mutedStyle.Render(text)
		}
	}
	left := styleWordmark.Render(wordmark) + gap + strings.Join(rendered, gap)

	right := m.workspace + " · " + shortSession(m.sessionID)
	rightStyle := mutedStyle
	if m.approval != nil {
		right = "waiting on you"
		rightStyle = styleSand
	} else if m.status == "cancelling" {
		right = "cancelling…"
		rightStyle = styleSand
	}
	if lipgloss.Width(left)+lipgloss.Width(right)+1 > m.width {
		right = shortSession(m.sessionID)
	}
	if lipgloss.Width(left)+lipgloss.Width(right)+1 > m.width {
		right = ""
	}
	line := joinEdges(left, rightStyle.Render(right), m.width)

	activeStart := lipgloss.Width(wordmark) + lipgloss.Width(gap)
	for i := tab(0); i < m.tab; i++ {
		width := lipgloss.Width(labels[i])
		if m.unseen[i] > 0 {
			width += lipgloss.Width(" " + strconv.Itoa(m.unseen[i]))
		}
		activeStart += width + lipgloss.Width(gap)
	}
	activeWidth := lipgloss.Width(labels[m.tab])
	trailing := max(0, m.width-activeStart-activeWidth)

	rule := mutedStyle.Render(strings.Repeat("─", max(0, activeStart))) +
		styleMint.Render(strings.Repeat("─", activeWidth)) +
		mutedStyle.Render(strings.Repeat("─", trailing))

	return lipgloss.JoinVertical(lipgloss.Left, line, rule)
}

// renderActiveTab draws the body for the currently selected tab. dim is set
// when a sheet is docked below it, so the active view can mute its own
// accents rather than being literally alpha-blended (terminals have no
// compositing).
func (m model) renderActiveTab(dim bool) string {
	switch m.tab {
	case tabChat:
		return m.viewport.View()
	case tabTree:
		return m.renderTreeTab()
	case tabEvents:
		return m.renderEventsTab()
	case tabModels:
		return m.renderModelsTab()
	case tabSessions:
		return m.renderSessionsTab()
	case tabFiles:
		return m.renderFilesTab()
	case tabRace:
		return m.renderRaceTab()
	default:
		return m.renderTabPlaceholder()
	}
}

func (m model) renderTabPlaceholder() string {
	label := tabLabels[m.tab]
	title := strings.ToUpper(label[:1]) + label[1:]
	return lipgloss.NewStyle().Padding(2, 2).Foreground(colDim).
		Render(title + " — not wired up yet")
}

// updateActiveTab routes a key press to the currently selected non-chat
// tab's own handler. The chat tab never reaches here — its keys are handled
// directly in Update().
func (m model) updateActiveTab(key string) (tea.Model, tea.Cmd) {
	switch m.tab {
	case tabTree:
		return m.updateTreeTab(key)
	case tabEvents:
		return m.updateEventsTab(key)
	case tabModels:
		return m.updateModelsTab(key)
	case tabSessions:
		return m.updateSessionsTab(key)
	case tabFiles:
		return m.updateFilesTab(key)
	case tabRace:
		return m.updateRaceTab(key)
	default:
		return m, nil
	}
}
