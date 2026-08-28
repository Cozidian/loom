package main

import (
	"strings"

	"charm.land/lipgloss/v2"
)

// spineRole classifies a transcript entry for the left-gutter glyph.
// spineRoot is the zero value, so entries hydrated from a session's history
// (which the backend sends without this client-only field) default to a
// plain root line rather than mislabeling as the user.
type spineRole int

const (
	spineRoot spineRole = iota
	spineUser
	spineSystem
	spineSubagent
)

// spineGlyphs computes the left-gutter marker for every transcript entry in
// one forward pass: ▌ for the user, │ for root agent output, ├/╰ for a
// subagent's block (╰ on the last line seen so far for that session), ·
// for system/info facts. Depth is read from the glyph, never counted from
// indentation width.
func spineGlyphs(entries []entry) []string {
	lastOf := map[string]int{}
	for i, e := range entries {
		if e.Kind != "user" && e.Role == spineSubagent && e.SessionID != "" {
			lastOf[e.SessionID] = i
		}
	}

	glyphs := make([]string, len(entries))
	for i, e := range entries {
		switch {
		case e.Kind == "user":
			glyphs[i] = "▌"
		case e.Kind == "system":
			glyphs[i] = "·"
		case e.Role == spineSubagent && e.SessionID != "":
			if lastOf[e.SessionID] == i {
				glyphs[i] = "╰"
			} else {
				glyphs[i] = "├"
			}
		case e.Role == spineSystem:
			glyphs[i] = "·"
		default:
			glyphs[i] = "│"
		}
	}
	return glyphs
}

func spineGlyphStyle(glyph string) lipgloss.Style {
	switch glyph {
	case "▌":
		return styleMint
	case "·":
		return styleFaint
	default:
		return mutedStyle
	}
}

// withSpine prefixes an already-styled (possibly multi-line) block with its
// spine glyph on the first line and a blank continuation on the rest, so
// wrapped or multi-paragraph content doesn't repeat the branch character.
func withSpine(glyph string, glyphStyle lipgloss.Style, styledContent string) string {
	lines := strings.Split(styledContent, "\n")
	for i, line := range lines {
		if i == 0 {
			lines[i] = glyphStyle.Render(glyph) + "  " + line
		} else {
			lines[i] = "   " + line
		}
	}
	return strings.Join(lines, "\n")
}
