package main

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

const treeSidebarWidth = 32

func (m model) renderTreeTab() string {
	if m.treeData == nil {
		return lipgloss.NewStyle().Padding(2, 2).Foreground(colDim).
			Render("No goal tree yet — send a message on the chat tab first.")
	}

	listWidth := max(20, m.width-treeSidebarWidth-3)
	left := lipgloss.NewStyle().Width(listWidth).Height(m.bodyHeight).Padding(1, 2).
		Render(m.renderTreeList(listWidth))
	right := lipgloss.NewStyle().Width(treeSidebarWidth).Height(m.bodyHeight).Padding(1, 2).
		Render(m.renderTreeSidebar())

	return lipgloss.JoinHorizontal(lipgloss.Top, left, right)
}

func (m model) renderTreeList(width int) string {
	var b strings.Builder

	if m.treeData.Root != nil {
		flat := flattenGoalTree(*m.treeData.Root)
		for i, line := range flat {
			style := bodyStyle
			if i == m.treeTab.selected {
				style = style.Background(colPanel)
			}
			fmt.Fprintf(&b, "%s\n", style.Render(line.render(width)))
		}
	}

	summary := m.treeData.Summary
	fmt.Fprintf(&b, "\n%s\n", mutedStyle.Render(strings.Repeat("─", max(0, width))))
	fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf(
		"%d workers · %d running · %d completed · %d failed · %d restarts",
		summary.WorkerCount, summary.RunningCount, summary.CompletedCount, summary.FailedCount, summary.RestartCount,
	)))
	fmt.Fprintf(&b, "\n%s\n", styleFaint.Render("↑/↓ select · esc back to chat"))

	return b.String()
}

type treeLine struct {
	depth int
	glyph string
	style lipgloss.Style
	label string
	right string
}

func (l treeLine) render(width int) string {
	indent := strings.Repeat("  ", l.depth)
	left := indent + l.style.Render(l.glyph) + " " + l.label
	return joinEdges(left, styleFaint.Render(l.right), width)
}

func flattenGoalTree(root goalNode) []treeLine {
	var lines []treeLine
	var walk func(node goalNode, depth int)
	walk = func(node goalNode, depth int) {
		glyph, style := goalStateGlyph(node.State, node.Role)
		label := shortSession(node.SessionID)
		if node.Role == "root" {
			label += " · root"
		}
		lines = append(lines, treeLine{
			depth: depth,
			glyph: glyph,
			style: style,
			label: label,
			right: goalStateDetail(node),
		})
		for _, child := range node.Children {
			walk(child, depth+1)
		}
	}
	walk(root, 0)
	return lines
}

func goalStateGlyph(state, role string) (string, lipgloss.Style) {
	if role == "root" {
		return "◈", styleMint
	}
	switch state {
	case "completed":
		return "✓", styleMint
	case "running":
		return "◍", styleSand
	case "failed":
		return "×", styleRose
	case "cancelled":
		return "×", styleFaint
	default:
		return "○", styleFaint
	}
}

func goalStateDetail(node goalNode) string {
	parts := []string{node.State}
	if node.LastTool != "" {
		parts = append(parts, node.LastTool)
	}
	if node.DurationMs > 0 {
		parts = append(parts, fmt.Sprintf("%.1fs", float64(node.DurationMs)/1000))
	}
	if node.RestartCount > 0 {
		parts = append(parts, fmt.Sprintf("restarts %d", node.RestartCount))
	}
	return strings.Join(parts, " · ")
}

func (m model) renderTreeSidebar() string {
	var b strings.Builder

	fmt.Fprintf(&b, "%s\n", styleFaint.Render("BUDGET"))
	if budget := m.treeData.Budget; budget != nil && len(budget.Allocations) > 0 {
		for _, alloc := range budget.Allocations {
			fmt.Fprintf(&b, "%s\n", bodyStyle.Render(shortSession(alloc.WorkerID)))
			fmt.Fprintf(&b, "%s\n", styleFaint.Render(alloc.Status+" · "+formatUsageMap(alloc.Usage, alloc.Limits)))
		}
	} else {
		fmt.Fprintf(&b, "%s\n", styleFaint.Render("no budget data"))
	}

	fmt.Fprintf(&b, "\n%s\n", styleFaint.Render("WORKSPACE"))
	if ws := m.treeData.WorkspaceDiff; ws != nil {
		branch := ws.Branch
		if branch == "" {
			branch = "detached"
		}
		fmt.Fprintf(&b, "%s\n", bodyStyle.Render(branch))
		fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf(
			"%d files · +%d −%d", ws.ChangedFileCount, ws.Insertions, ws.Deletions,
		)))
	} else {
		fmt.Fprintf(&b, "%s\n", styleFaint.Render("no changes"))
	}

	fmt.Fprintf(&b, "\n%s\n", styleFaint.Render("RESOURCE POOLS"))
	if len(m.treeData.ResourcePools) > 0 {
		for name, pool := range m.treeData.ResourcePools {
			fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf(
				"%s · %v/%v · %v queued", name, pool.Active, pool.Limit, pool.Queued,
			)))
		}
	} else {
		fmt.Fprintf(&b, "%s\n", styleFaint.Render("idle"))
	}

	return b.String()
}

func formatUsageMap(usage, limits map[string]any) string {
	if len(usage) == 0 {
		return "no usage"
	}
	parts := make([]string, 0, len(usage))
	for key, value := range usage {
		parts = append(parts, fmt.Sprintf("%s=%v/%v", key, value, limits[key]))
	}
	return strings.Join(parts, " · ")
}

func (m model) updateTreeTab(key string) (tea.Model, tea.Cmd) {
	if m.treeData == nil || m.treeData.Root == nil {
		return m, nil
	}
	count := len(flattenGoalTree(*m.treeData.Root))
	switch key {
	case "up", "k":
		if m.treeTab.selected > 0 {
			m.treeTab.selected--
		}
	case "down", "j":
		if m.treeTab.selected < count-1 {
			m.treeTab.selected++
		}
	}
	return m, nil
}
