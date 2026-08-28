package main

import "charm.land/lipgloss/v2"

// Palette — "plum ink": one mint accent for the live thing, sand for
// anything awaiting you, rose for errors and deletions. No other colors
// exist. Diff tints are the only two-tone exception, used for add/remove
// backgrounds in the files (diff review) tab.
var (
	colBase   = lipgloss.Color("#141019")
	colChrome = lipgloss.Color("#110D16")
	colPanel  = lipgloss.Color("#1C1624")
	colRule   = lipgloss.Color("#241E2E")
	colSpine  = lipgloss.Color("#3A3346")
	colFaint  = lipgloss.Color("#565064")
	colDim    = lipgloss.Color("#8A819B")
	colFg     = lipgloss.Color("#E6E0EE")
	colMint   = lipgloss.Color("#63D3AD")
	colSand   = lipgloss.Color("#DFA860")
	colRose   = lipgloss.Color("#EF7A80")

	colDiffAddBg = lipgloss.Color("#132019")
	colDiffAddFg = lipgloss.Color("#9ED3BD")
	colDiffDelBg = lipgloss.Color("#221419")
	colDiffDelFg = lipgloss.Color("#D9A3A8")
)

var (
	styleWordmark = lipgloss.NewStyle().Bold(true).Foreground(colMint)
	agentStyle    = lipgloss.NewStyle().Bold(true).Foreground(colFg)
	toolStyle     = lipgloss.NewStyle().Foreground(colSand)
	errorStyle    = lipgloss.NewStyle().Foreground(colRose)
	mutedStyle    = lipgloss.NewStyle().Foreground(colDim)
	bodyStyle     = lipgloss.NewStyle().Foreground(colFg)

	styleFaint   = lipgloss.NewStyle().Foreground(colFaint)
	styleMint    = lipgloss.NewStyle().Foreground(colMint)
	styleSand    = lipgloss.NewStyle().Foreground(colSand)
	styleRose    = lipgloss.NewStyle().Foreground(colRose)
	styleSpine   = lipgloss.NewStyle().Foreground(colSpine)
	stylePanelBg = lipgloss.NewStyle().Background(colPanel)
	styleDiffAdd = lipgloss.NewStyle().Background(colDiffAddBg).Foreground(colDiffAddFg)
	styleDiffDel = lipgloss.NewStyle().Background(colDiffDelBg).Foreground(colDiffDelFg)
)
