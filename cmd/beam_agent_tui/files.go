package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

const filesSidebarWidth = 34

// editorFinishedMsg reports the outcome of an $EDITOR session opened from
// the diff view. Nothing in the model reacts to a nil error beyond
// resuming normal operation — tea.ExecProcess already restores the
// terminal for us.
type editorFinishedMsg struct{ err error }

func (m model) renderFilesTab() string {
	if m.filesData == nil {
		return lipgloss.NewStyle().Padding(2, 2).Foreground(colDim).
			Render("No changed files yet.")
	}

	sidebar := lipgloss.NewStyle().Width(filesSidebarWidth).Height(m.bodyHeight).Padding(1, 2).
		Render(m.renderFilesList())
	diffWidth := max(20, m.width-filesSidebarWidth-3)
	diff := lipgloss.NewStyle().Width(diffWidth).Height(m.bodyHeight).Padding(1, 2).
		Render(m.renderDiffPane(diffWidth))

	return lipgloss.JoinHorizontal(lipgloss.Top, sidebar, diff)
}

func (m model) renderFilesList() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf("CHANGED · %d", len(m.filesData.Changed))))
	for i, file := range m.filesData.Changed {
		style := bodyStyle
		if i == m.filesTab.selectedFile {
			style = style.Background(colPanel)
		}
		stats := styleFaint.Render(fmt.Sprintf("+%d −%d", file.Insertions, file.Deletions))
		if file.Binary {
			stats = styleFaint.Render("binary")
		}
		fmt.Fprintf(&b, "%s\n", style.Render(joinEdges(file.Path, stats, max(0, filesSidebarWidth-4))))
	}

	if len(m.filesData.InContext) > 0 {
		fmt.Fprintf(&b, "\n%s\n", styleFaint.Render(fmt.Sprintf("IN CONTEXT · %d", len(m.filesData.InContext))))
		for _, file := range m.filesData.InContext {
			fmt.Fprintf(&b, "%s\n", styleFaint.Render(file.Path+" · "+file.Tag))
		}
	}

	fmt.Fprintf(&b, "\n%s\n", styleFaint.Render("↑/↓ select · enter diff · tab next hunk · esc back"))
	return b.String()
}

func (m model) renderDiffPane(width int) string {
	if m.selectedDiff == nil {
		return styleFaint.Render("select a file and press enter to load its diff")
	}

	diff := m.selectedDiff
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", bodyStyle.Render(diff.Path))

	if diff.Binary {
		fmt.Fprintf(&b, "%s\n", styleFaint.Render("binary file"))
		return b.String()
	}
	if len(diff.Hunks) == 0 {
		fmt.Fprintf(&b, "%s\n", styleFaint.Render("no hunks"))
		return b.String()
	}

	hunkIndex := min(m.filesTab.selectedHunk, len(diff.Hunks)-1)
	hunk := diff.Hunks[hunkIndex]
	fmt.Fprintf(&b, "%s\n", styleFaint.Render(fmt.Sprintf("hunk %d of %d", hunkIndex+1, len(diff.Hunks))))
	fmt.Fprintf(&b, "%s\n", styleFaint.Render(hunk.Header))
	for _, line := range hunk.Lines {
		fmt.Fprintf(&b, "%s\n", renderDiffLine(line, width))
	}
	return b.String()
}

const diffLineGutterWidth = 9 // "%3d %3d  " + kind marker

func renderDiffLine(line diffLine, width int) string {
	gutter, style := " ", bodyStyle
	switch line.Kind {
	case "add":
		gutter, style = "+", styleDiffAdd
	case "remove":
		gutter, style = "-", styleDiffDel
	}

	oldNo, newNo := "   ", "   "
	if line.OldLine > 0 {
		oldNo = fmt.Sprintf("%3d", line.OldLine)
	}
	if line.NewLine > 0 {
		newNo = fmt.Sprintf("%3d", line.NewLine)
	}

	text := truncateToWidth(line.Text, max(1, width-diffLineGutterWidth))
	prefix := styleFaint.Render(oldNo+" "+newNo) + " " + gutter + " "
	return prefix + style.Render(text)
}

func (m model) updateFilesTab(key string) (tea.Model, tea.Cmd) {
	if key == "tab" {
		if m.selectedDiff != nil && len(m.selectedDiff.Hunks) > 0 {
			m.filesTab.selectedHunk = (m.filesTab.selectedHunk + 1) % len(m.selectedDiff.Hunks)
		}
		return m, nil
	}
	if key == "o" {
		return m, m.openInEditor()
	}

	if m.filesData == nil {
		return m, nil
	}
	count := len(m.filesData.Changed)
	switch key {
	case "up", "k":
		if m.filesTab.selectedFile > 0 {
			m.filesTab.selectedFile--
			m.filesTab.selectedHunk = 0
		}
	case "down", "j":
		if m.filesTab.selectedFile < count-1 {
			m.filesTab.selectedFile++
			m.filesTab.selectedHunk = 0
		}
	case "enter":
		if m.filesTab.selectedFile < count {
			path := m.filesData.Changed[m.filesTab.selectedFile].Path
			return m, m.send(packet{Type: "command", Command: "files", Query: path})
		}
	}
	return m, nil
}

// editorsWithLineFlag support opening straight to a line via a leading
// "+N" argument — the common convention across terminal editors.
var editorsWithLineFlag = map[string]bool{
	"vi": true, "vim": true, "nvim": true, "nano": true, "emacs": true,
}

// openInEditor suspends the alt-screen program and hands the terminal to
// $EDITOR (falling back to vi) on the currently selected diff's file, via
// tea.ExecProcess so the program's terminal state is restored correctly
// afterward — a naive exec.Command.Run() would corrupt it.
func (m model) openInEditor() tea.Cmd {
	if m.selectedDiff == nil || m.selectedDiff.Path == "" {
		return nil
	}

	editor := os.Getenv("EDITOR")
	if editor == "" {
		editor = "vi"
	}

	path := m.selectedDiff.Path
	if m.workspaceRoot != "" && !filepath.IsAbs(path) {
		path = filepath.Join(m.workspaceRoot, path)
	}

	line := 0
	if hunks := m.selectedDiff.Hunks; len(hunks) > 0 {
		hunk := hunks[min(m.filesTab.selectedHunk, len(hunks)-1)]
		line = hunk.NewStart
	}

	args := []string{path}
	if line > 0 && editorsWithLineFlag[filepath.Base(editor)] {
		args = []string{fmt.Sprintf("+%d", line), path}
	}

	cmd := exec.Command(editor, args...)
	if m.workspaceRoot != "" {
		cmd.Dir = m.workspaceRoot
	}

	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		return editorFinishedMsg{err: err}
	})
}
