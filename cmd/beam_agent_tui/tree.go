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
			if m.treeData.Progress != nil && line.workerID == m.treeData.Progress.CriticalWorkerID {
				style = style.Foreground(colRose)
			}
			if i == m.treeTab.selected {
				style = style.Background(colPanel)
			}
			fmt.Fprintf(&b, "%s\n", style.Render(line.render(width)))
		}
	}

	if len(m.treeData.WorkBlocks) > 0 {
		workerCount := 0
		if m.treeData.Root != nil {
			workerCount = len(flattenGoalTree(*m.treeData.Root))
		}

		fmt.Fprintf(&b, "\n%s\n", styleFaint.Render("WORK BLOCKS"))
		for i, block := range m.treeData.WorkBlocks {
			selected := m.treeTab.selected == workerCount+i
			critical := m.treeData.Progress != nil && block.WorkerID == m.treeData.Progress.CriticalWorkerID
			fmt.Fprintf(&b, "%s\n", m.renderWorkBlock(block, selected, critical, width))
			if m.treeTab.expanded[block.ID] {
				fmt.Fprintf(&b, "%s\n", renderWorkBlockDetails(block, width))
			}
		}
	}

	summary := m.treeData.Summary
	fmt.Fprintf(&b, "\n%s\n", mutedStyle.Render(strings.Repeat("─", max(0, width))))
	fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf(
		"%d workers · %d running · %d completed · %d failed · %d restarts",
		summary.WorkerCount, summary.RunningCount, summary.CompletedCount, summary.FailedCount, summary.RestartCount,
	)))
	fmt.Fprintf(&b, "\n%s\n", styleFaint.Render("↑/↓ select · enter expand · r refresh · esc chat"))

	fmt.Fprintf(&b, "\n%s\n", styleFaint.Render("↑/↓ select · enter evidence · c cancel worker · r refresh"))
	return b.String()
}

func (m model) renderWorkBlock(block workBlock, selected, critical bool, width int) string {
	disclosure := "▸"
	if m.treeTab.expanded[block.ID] {
		disclosure = "▾"
	}
	glyph, glyphStyle := workBlockGlyph(block)
	left := fmt.Sprintf("%s %s %s", disclosure, glyphStyle.Render(glyph), block.Label)
	right := block.Summary
	if block.DurationMs > 0 {
		right += fmt.Sprintf(" · %.1fs", float64(block.DurationMs)/1000)
	}
	line := joinEdges(left, styleFaint.Render(right), width)
	if critical {
		line = styleRose.Render(line)
	}
	if selected {
		return bodyStyle.Background(colPanel).Render(line)
	}
	return bodyStyle.Render(line)
}

func workBlockGlyph(block workBlock) (string, lipgloss.Style) {
	if block.Phase == "suspected_stalled" || block.Phase == "stalled" {
		return "!", styleRose
	}
	switch block.State {
	case "completed":
		return "✓", styleMint
	case "failed":
		return "×", styleRose
	case "cancelled":
		return "×", styleFaint
	case "waiting", "blocked":
		return "◌", styleSand
	default:
		return "◍", styleSand
	}
}

func renderWorkBlockDetails(block workBlock, width int) string {
	lines := []string{
		"  " + styleFaint.Render("worker") + "  " + shortSession(block.WorkerID),
		"  " + styleFaint.Render("phase") + "   " + strings.ReplaceAll(block.Phase, "_", " "),
	}
	if block.BlockingReason != "" {
		lines = append(lines, "  "+styleRose.Render("blocked")+" "+block.BlockingReason)
	}
	if len(block.Files) > 0 {
		lines = append(lines, "  "+styleFaint.Render("files")+"   "+strings.Join(block.Files, ", "))
	}
	lines = append(lines, "  "+styleFaint.Render("events")+fmt.Sprintf("  %d recorded", len(block.EventIDs)))
	return lipgloss.NewStyle().Width(max(1, width-2)).Foreground(colDim).Render(strings.Join(lines, "\n"))
}

type treeLine struct {
	depth    int
	workerID string
	glyph    string
	style    lipgloss.Style
	label    string
	right    string
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
			depth:    depth,
			workerID: node.WorkerID,
			glyph:    glyph,
			style:    style,
			label:    label,
			right:    goalStateDetail(node),
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

	if progress := m.treeData.Progress; progress != nil {
		fmt.Fprintf(&b, "\n%s\n", styleFaint.Render("LIVE STATE"))
		fmt.Fprintf(&b, "%s\n", bodyStyle.Render(fmt.Sprintf(
			"%d active · %d waiting", progress.Summary.Active, progress.Summary.Waiting,
		)))
		if progress.Summary.Blocked > 0 || progress.Summary.Stalled > 0 {
			fmt.Fprintf(&b, "%s\n", styleRose.Render(fmt.Sprintf(
				"%d blocked · %d stalled", progress.Summary.Blocked, progress.Summary.Stalled,
			)))
		}
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
	count := len(flattenGoalTree(*m.treeData.Root)) + len(m.treeData.WorkBlocks)
	switch key {
	case "up", "k":
		if m.treeTab.selected > 0 {
			m.treeTab.selected--
		}
	case "down", "j":
		if m.treeTab.selected < count-1 {
			m.treeTab.selected++
		}
	case "enter":
		workerCount := len(flattenGoalTree(*m.treeData.Root))
		index := m.treeTab.selected - workerCount
		if index >= 0 && index < len(m.treeData.WorkBlocks) {
			if m.treeTab.expanded == nil {
				m.treeTab.expanded = make(map[string]bool)
			}
			id := m.treeData.WorkBlocks[index].ID
			m.treeTab.expanded[id] = !m.treeTab.expanded[id]
		}
	case "r":
		return m, m.refreshTabCmd(tabTree)
	case "c":
		if workerID := m.selectedTreeWorkerID(); workerID != "" {
			return m, m.send(packet{Type: "command", Command: "cancel_worker", Query: workerID})
		}
	}
	return m, nil
}

func (m model) selectedTreeWorkerID() string {
	if m.treeData == nil || m.treeData.Root == nil {
		return ""
	}
	workers := flattenGoalTree(*m.treeData.Root)
	if m.treeTab.selected >= 0 && m.treeTab.selected < len(workers) {
		return workers[m.treeTab.selected].workerID
	}
	index := m.treeTab.selected - len(workers)
	if index >= 0 && index < len(m.treeData.WorkBlocks) {
		return m.treeData.WorkBlocks[index].WorkerID
	}
	return ""
}
