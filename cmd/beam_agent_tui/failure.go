package main

import (
	"strings"

	"charm.land/lipgloss/v2"
)

// renderFailureActions is phase 1 of the failure-state design: a fixed,
// backend-independent set of next steps shown after any failed turn. There
// is no "suggested fix" concept in the backend yet — that would need an LLM
// diagnosis pass, out of scope here — so every failure gets the same three
// pure client actions: retry, edit and retry, or stop.
//
// Keys are r/e/esc rather than the mockup's 1/2/3, since bare digits on the
// chat tab already switch tabs (see the composer-empty guard in Update()) —
// reusing them here would collide with that established convention.
func (m model) renderFailureActions() string {
	pills := []string{
		lipgloss.NewStyle().Background(colRose).Foreground(colBase).Padding(0, 1).Render("r retry"),
		lipgloss.NewStyle().Foreground(colDim).Padding(0, 1).Render("e edit and retry"),
		lipgloss.NewStyle().Foreground(colDim).Padding(0, 1).Render("esc stop"),
	}
	box := lipgloss.NewStyle().Background(colPanel).Padding(0, 1).Render(
		bodyStyle.Render("Next  ") + strings.Join(pills, "  "),
	)
	return box
}

// lastUserPrompt returns the most recently submitted user message, or ""
// if there isn't one — used by the retry/edit-and-retry failure actions.
func (m model) lastUserPrompt() string {
	for i := len(m.entries) - 1; i >= 0; i-- {
		if m.entries[i].Kind == "user" {
			return m.entries[i].Content
		}
	}
	return ""
}
