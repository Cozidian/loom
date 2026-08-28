package main

import (
	"image/color"
	"strings"

	"charm.land/lipgloss/v2"
)

// sheetBox docks title/body to the bottom edge of the screen, full width,
// with a rule above it — never a centered overlay. The active tab stays
// visible above it, so the transcript (or whatever the active tab shows)
// never disappears behind an answer the user is deciding on.
func (m model) sheetBox(title, body string, accent color.Color) string {
	rule := mutedStyle.Render(strings.Repeat("─", m.width))
	header := lipgloss.NewStyle().Bold(true).Foreground(accent).Render(title)
	content := lipgloss.NewStyle().
		Background(colPanel).
		Padding(1, 2).
		Width(m.width).
		MaxHeight(max(3, m.sheetHeight)).
		Render(header + "\n\n" + body)
	return lipgloss.JoinVertical(lipgloss.Left, rule, content)
}

// sheetContentLines estimates how many lines the currently active sheet
// wants, so resize() can give it a real slice of the terminal instead of
// guessing — sheets earn their height rather than floating over the body.
func (m model) sheetContentLines() int {
	switch {
	case m.approval != nil:
		return 7
	case m.sheet == sheetPalette:
		return len(commands)
	case m.sheet == sheetProviderPicker:
		return len(m.providers) + 2
	case m.sheet == sheetPanel:
		return len(m.panelLines)
	default:
		return 0
	}
}
