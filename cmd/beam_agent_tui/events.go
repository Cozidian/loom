package main

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

func (m model) renderEventsTab() string {
	if m.eventsData == nil {
		return lipgloss.NewStyle().Padding(2, 2).Foreground(colDim).
			Render("No events yet — send a message on the chat tab first.")
	}

	var b strings.Builder
	fmt.Fprintf(&b, "%s\n\n", m.renderEventCategoryChips())

	rows := m.eventsData.Events
	for i, row := range rows {
		style := bodyStyle
		if i == m.eventsTab.selected {
			style = style.Background(colPanel)
		}
		fmt.Fprintf(&b, "%s\n", style.Render(renderEventRow(row)))
	}

	if m.eventsTab.expanded && m.eventsTab.selected >= 0 && m.eventsTab.selected < len(rows) {
		fmt.Fprintf(&b, "\n%s\n", renderEventDetail(rows[m.eventsTab.selected]))
	}

	fmt.Fprintf(&b, "\n%s\n", styleFaint.Render(fmt.Sprintf(
		"%d/%d matched · showing %d · cursor %d",
		m.eventsData.Matched, m.eventsData.Total, m.eventsData.Returned, m.eventsData.Cursor,
	)))
	fmt.Fprintf(&b, "%s\n", styleFaint.Render("↑/↓ select · enter expand · esc back to chat"))

	return lipgloss.NewStyle().Padding(1, 2).Render(b.String())
}

func (m model) renderEventCategoryChips() string {
	chips := make([]string, 0, len(m.eventsData.AvailableCategories)+1)
	chips = append(chips, renderEventChip("all", m.eventsTab.category == ""))
	for _, category := range m.eventsData.AvailableCategories {
		chips = append(chips, renderEventChip(category, category == m.eventsTab.category))
	}
	return strings.Join(chips, " ")
}

func renderEventChip(label string, active bool) string {
	if active {
		return lipgloss.NewStyle().Background(colPanel).Foreground(colFg).Render(" " + label + " ")
	}
	return mutedStyle.Render(" " + label + " ")
}

func renderEventRow(row eventRow) string {
	timePart := row.At
	if len(timePart) >= 19 {
		timePart = timePart[11:19]
	}
	kind := eventCategoryStyle(row.Category).Render(row.Payload.Type)
	summary := compactArguments(row.Payload.Data)
	left := fmt.Sprintf("%-5d %-8s %s", row.GoalSeq, timePart, kind)
	return left + "  " + styleFaint.Render(summary)
}

func eventCategoryStyle(category string) lipgloss.Style {
	switch category {
	case "tool":
		return styleSand
	case "routing", "verification":
		return styleMint
	case "policy":
		return styleRose
	default:
		return mutedStyle
	}
}

func renderEventDetail(row eventRow) string {
	header := styleFaint.Render(fmt.Sprintf("%d · %s · %s", row.GoalSeq, row.Category, row.Payload.Type))
	body := bodyStyle.Render(compactArguments(row.Payload.Data))
	return lipgloss.NewStyle().Background(colPanel).Padding(0, 1).Render(header + "\n" + body)
}

func (m model) updateEventsTab(key string) (tea.Model, tea.Cmd) {
	if m.eventsData == nil {
		return m, nil
	}
	count := len(m.eventsData.Events)
	switch key {
	case "up", "k":
		if m.eventsTab.selected > 0 {
			m.eventsTab.selected--
		}
	case "down", "j":
		if m.eventsTab.selected < count-1 {
			m.eventsTab.selected++
		}
	case "enter":
		m.eventsTab.expanded = !m.eventsTab.expanded
	}
	return m, nil
}
