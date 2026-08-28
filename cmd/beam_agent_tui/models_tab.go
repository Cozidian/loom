package main

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

func (m model) renderModelsTab() string {
	if m.modelsData == nil {
		return lipgloss.NewStyle().Padding(2, 2).Foreground(colDim).
			Render("No model registry data yet — open this tab again after connecting.")
	}

	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", styleFaint.Render("PROFILES"))
	for i, endpoint := range m.modelsData.Endpoints {
		marker := "  "
		style := bodyStyle
		if endpoint.ID == m.modelsData.ActiveProfile {
			marker = "› "
			style = styleMint
		}
		if i == m.modelsTab.selected {
			style = style.Background(colPanel)
		}
		model := endpoint.Model
		if model == "" {
			model = "provider default"
		}
		line := fmt.Sprintf("%s%s · %s/%s", marker, endpoint.ID, endpoint.Provider, model)
		status := modelStatusLabel(endpoint, m.modelsData.ActiveProfile)
		fmt.Fprintf(&b, "%s\n", style.Render(joinEdges(line, status, max(0, m.width-4))))
	}

	fmt.Fprintf(&b, "\n%s\n", styleFaint.Render("ROUTING EVIDENCE"))
	fmt.Fprintf(&b, "%s\n", bodyStyle.Render(routingEvidenceLine(m.modelsData.Evidence)))

	fmt.Fprintf(&b, "\n%s\n", styleFaint.Render("SESSION SETTINGS"))
	settings := m.modelsData.SessionSettings
	fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf("approval mode  %s", settings.ApprovalMode)))
	fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf("token budget   %d", settings.TokenBudget)))
	fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf("mcp servers    %d", settings.MCPServerCount)))

	fmt.Fprintf(&b, "\n%s\n", styleFaint.Render("↑/↓ select · esc back to chat"))

	return lipgloss.NewStyle().Padding(1, 2).Render(b.String())
}

func modelStatusLabel(endpoint modelEndpoint, activeProfile string) string {
	if endpoint.ID == activeProfile {
		return "in use"
	}
	if health, ok := endpoint.Health["status"].(string); ok && health != "" {
		return health
	}
	return "available"
}

func routingEvidenceLine(evidence modelEvidence) string {
	switch evidence.State {
	case "ready":
		return fmt.Sprintf("shadow prefers %s", evidence.RecommendedEndpointID)
	case "insufficient_evidence":
		return fmt.Sprintf("evidence warming %d/%d verified", evidence.BestVerifiedSamples, evidence.MinimumVerifiedSamples)
	case "unavailable":
		return "evidence unavailable"
	default:
		return "no routing evidence yet"
	}
}

func (m model) updateModelsTab(key string) (tea.Model, tea.Cmd) {
	if m.modelsData == nil {
		return m, nil
	}
	count := len(m.modelsData.Endpoints)
	switch key {
	case "up", "k":
		if m.modelsTab.selected > 0 {
			m.modelsTab.selected--
		}
	case "down", "j":
		if m.modelsTab.selected < count-1 {
			m.modelsTab.selected++
		}
	}
	return m, nil
}
