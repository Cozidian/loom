package main

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

const sessionsSidebarWidth = 36

func (m model) renderSessionsTab() string {
	if m.sessionsData == nil {
		return lipgloss.NewStyle().Padding(2, 2).Foreground(colDim).
			Render("No durable sessions yet.")
	}

	listWidth := max(20, m.width-sessionsSidebarWidth-3)
	left := lipgloss.NewStyle().Width(listWidth).Height(m.bodyHeight).Padding(1, 2).
		Render(m.renderSessionsList(listWidth))
	right := lipgloss.NewStyle().Width(sessionsSidebarWidth).Height(m.bodyHeight).Padding(1, 2).
		Render(m.renderSessionPreview())

	return lipgloss.JoinHorizontal(lipgloss.Top, left, right)
}

func (m model) renderSessionsList(width int) string {
	var b strings.Builder
	for i, session := range m.sessionsData.Sessions {
		style := bodyStyle
		if i == m.sessionsTab.selected {
			style = style.Background(colPanel)
		}
		left := shortSession(session.SessionID)
		right := sessionStatusStyle(session.Status).Render(session.Status)
		fmt.Fprintf(&b, "%s\n", style.Render(joinEdges(left, right, width)))
	}
	fmt.Fprintf(&b, "\n%s\n", styleFaint.Render(fmt.Sprintf("%d sessions", len(m.sessionsData.Sessions))))
	fmt.Fprintf(&b, "%s\n", styleFaint.Render("↑/↓ select · enter preview · r resume · esc back to chat"))
	return b.String()
}

func sessionStatusStyle(status string) lipgloss.Style {
	switch status {
	case "current", "active":
		return styleMint
	case "failed":
		return styleRose
	default:
		return styleFaint
	}
}

func (m model) renderSessionPreview() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", styleFaint.Render("PREVIEW"))
	if m.sessionDetailData == nil {
		fmt.Fprintf(&b, "%s\n", styleFaint.Render("press enter to load a session's detail"))
		return b.String()
	}

	detail := m.sessionDetailData
	if detail.GoalPreview != "" {
		fmt.Fprintf(&b, "%s\n\n", bodyStyle.Render(detail.GoalPreview))
	}
	fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf("turns      %d", detail.TurnCount)))
	fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf("tokens     %d", detail.TotalTokens)))
	fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf("provider   %s/%s", detail.Provider, detail.Model)))
	fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf("last seq   %d", detail.LastSeq)))
	return b.String()
}

func (m model) updateSessionsTab(key string) (tea.Model, tea.Cmd) {
	if m.sessionsData == nil {
		return m, nil
	}
	count := len(m.sessionsData.Sessions)
	switch key {
	case "up", "k":
		if m.sessionsTab.selected > 0 {
			m.sessionsTab.selected--
		}
	case "down", "j":
		if m.sessionsTab.selected < count-1 {
			m.sessionsTab.selected++
		}
	case "enter":
		if m.sessionsTab.selected < count {
			id := m.sessionsData.Sessions[m.sessionsTab.selected].SessionID
			return m, m.send(packet{Type: "command", Command: "sessions", Query: id})
		}
	case "r":
		// A distinct key from enter (preview) since resuming switches the
		// active runtime to a different session — a bigger action than
		// just loading a preview, so it shouldn't share a key with it.
		if m.sessionsTab.selected < count {
			id := m.sessionsData.Sessions[m.sessionsTab.selected].SessionID
			return m, m.send(packet{Type: "command", Command: "resume", Query: id})
		}
	}
	return m, nil
}
