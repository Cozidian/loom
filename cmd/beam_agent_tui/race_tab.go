package main

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
)

// raceArena is a presentation projection of durable OTP runtime events for
// both quality tournaments and first-admissible races. The runtime remains the
// sole authority for winners and cancellation.
type raceArena struct {
	AnchorID        string
	AuctionID       string
	RaceID          string
	TournamentID    string
	Mode            string
	Phase           string
	Status          string
	EligibleCount   int
	RequestedAwards int
	CandidateCount  int
	Bids            []raceBid
	Candidates      []raceCandidate
	WinnerID        string
	WinnerEndpoint  string
	SelectionSource string
}

type raceBid struct {
	ID                 string
	EndpointID         string
	Provider           string
	Model              string
	Score              int
	Confidence         float64
	EstimatedLatencyMs float64
	CostTier           string
	Reason             string
	Awarded            bool
}

type raceCandidate struct {
	ID                 string
	WorkerID           string
	EndpointID         string
	Provider           string
	Model              string
	Status             string
	VerificationStatus string
	Activity           string
}

func (m *model) applyRaceProjection(event map[string]any, hydrating bool) {
	payload := asMap(event["payload"])
	scope := asMap(event["scope"])
	m.applyRaceEvent(
		asString(payload["type"]),
		asMap(payload["data"]),
		asString(scope["session_id"]),
		asBool(scope["root?"]),
		hydrating,
	)
}

// applyRaceEvent returns true when the event belongs to a provider race and
// should be represented by the grouped arena instead of a flat transcript
// line. Non-race provider auctions keep their existing transcript treatment.
func (m *model) applyRaceEvent(eventType string, data map[string]any, sessionID string, root, hydrating bool) bool {
	switch eventType {
	case "provider_auction_started":
		purpose := asString(data["purpose"])
		if purpose != "provider_race" && purpose != "provider_tournament" {
			return false
		}
		auctionID := asString(data["auction_id"])
		arena := m.ensureRace(auctionID, "")
		if purpose == "provider_tournament" {
			arena.Mode = "tournament"
		} else {
			arena.Mode = "race"
		}
		arena.Phase = "bidding"
		arena.Status = "collecting provider bids"
		arena.EligibleCount = intValue(data["eligible_count"])
		arena.RequestedAwards = intValue(data["requested_awards"])
		m.ensureRaceAnchor(arena.AnchorID)
		m.markRaceUnseen(hydrating)
		return true

	case "provider_bid_submitted":
		arena := m.raceByAuction(asString(data["auction_id"]))
		if arena == nil {
			return false
		}
		bid := raceBid{
			ID:                 asString(data["id"]),
			EndpointID:         asString(data["endpoint_id"]),
			Provider:           asString(data["provider"]),
			Model:              asString(data["model"]),
			Score:              intValue(data["score"]),
			Confidence:         floatValue(data["confidence"]),
			EstimatedLatencyMs: floatValue(data["estimated_latency_ms"]),
			CostTier:           asString(data["cost_tier"]),
			Reason:             asString(data["reason"]),
		}
		arena.putBid(bid)
		return true

	case "provider_auction_awarded":
		arena := m.raceByAuction(asString(data["auction_id"]))
		purpose := asString(data["purpose"])
		if arena == nil || (purpose != "provider_race" && purpose != "provider_tournament") {
			return false
		}
		arena.Phase = "awarded"
		arena.Status = "provider leases awarded"
		for _, raw := range asSlice(data["awards"]) {
			award := asMap(raw)
			endpointID := asString(award["endpoint_id"])
			arena.markAwarded(endpointID)
			arena.putCandidate(raceCandidate{
				EndpointID: endpointID,
				Provider:   asString(award["provider"]),
				Model:      asString(award["model"]),
				Status:     "leased",
				Activity:   "waiting for worker",
			})
		}
		return true

	case "race_started":
		arena := m.ensureRace(asString(data["provider_auction_id"]), asString(data["race_id"]))
		// Historical race events were quality tournaments. The selection policy
		// makes new first-finish events unambiguous during durable replay.
		if asString(data["selection_policy"]) == "first_admissible" {
			arena.Mode = "race"
		} else {
			arena.Mode = "tournament"
		}
		arena.Phase = "running"
		arena.Status = "independent candidates running"
		arena.CandidateCount = intValue(data["candidate_count"])
		m.ensureRaceAnchor(arena.AnchorID)
		m.markRaceUnseen(hydrating)
		return true

	case "tournament_started":
		arena := m.ensureRace(asString(data["provider_auction_id"]), asString(data["tournament_id"]))
		arena.TournamentID = asString(data["tournament_id"])
		arena.RaceID = ""
		arena.Mode = "tournament"
		arena.Phase = "running"
		arena.Status = "independent candidates running"
		arena.CandidateCount = intValue(data["candidate_count"])
		m.ensureRaceAnchor(arena.AnchorID)
		m.markRaceUnseen(hydrating)
		return true

	case "race_candidate_started", "tournament_candidate_started":
		arena := m.competitionByID(firstNonEmpty(asString(data["race_id"]), asString(data["tournament_id"])))
		if arena == nil {
			return false
		}
		arena.putCandidate(raceCandidate{
			ID:         asString(data["candidate_id"]),
			WorkerID:   asString(data["worker_id"]),
			EndpointID: asString(data["endpoint_id"]),
			Provider:   asString(data["provider"]),
			Model:      asString(data["model"]),
			Status:     "running",
			Activity:   "starting model",
		})
		return true

	case "race_candidate_completed", "tournament_candidate_completed":
		arena := m.competitionByID(firstNonEmpty(asString(data["race_id"]), asString(data["tournament_id"])))
		if arena == nil {
			return false
		}
		candidate := arena.ensureCandidate(asString(data["candidate_id"]), asString(data["endpoint_id"]))
		candidate.WorkerID = firstNonEmpty(asString(data["worker_id"]), candidate.WorkerID)
		candidate.Provider = firstNonEmpty(asString(data["provider"]), candidate.Provider)
		candidate.Model = firstNonEmpty(asString(data["model"]), candidate.Model)
		candidate.Status = "submitted"
		if arena.Mode == "race" {
			candidate.Activity = "crossed finish line · validating"
		} else {
			candidate.Activity = "awaiting independent judgment"
		}
		candidate.VerificationStatus = asString(data["verification_status"])
		if arena.Mode != "race" && arena.allCandidatesSubmitted() {
			arena.Phase = "judging"
			arena.Status = "comparing evidence and results"
		}
		m.markRaceUnseen(hydrating)
		return true

	case "race_winner_selected", "tournament_winner_selected":
		arena := m.competitionByID(firstNonEmpty(asString(data["race_id"]), asString(data["tournament_id"])))
		if arena == nil {
			return false
		}
		arena.WinnerID = asString(data["winner_id"])
		arena.WinnerEndpoint = asString(data["winner_endpoint_id"])
		arena.SelectionSource = asString(data["selection_source"])
		if arena.Mode == "race" {
			arena.Phase = "stopping"
			arena.Status = "first admissible finisher selected · stopping other lanes"
		} else {
			arena.Phase = "selected"
			arena.Status = "winner selected from result evidence"
		}
		m.markRaceUnseen(hydrating)
		return true

	case "tournament_judgment_requested":
		arena := m.competitionByID(asString(data["tournament_id"]))
		if arena == nil {
			return false
		}
		arena.Phase = "judging"
		arena.Status = "parent judge comparing completed candidates"
		arena.SelectionSource = "parent_judgment"
		m.markRaceUnseen(hydrating)
		return true

	case "race_settled", "race_collapsed", "tournament_collapsed":
		arena := m.competitionByID(firstNonEmpty(asString(data["race_id"]), asString(data["tournament_id"])))
		if arena == nil {
			return false
		}
		arena.Phase = "selected"
		if eventType == "tournament_collapsed" {
			arena.discardTournamentLosers()
		}
		return true

	case "race_inconclusive", "tournament_inconclusive":
		arena := m.competitionByID(firstNonEmpty(asString(data["race_id"]), asString(data["tournament_id"])))
		if arena == nil {
			return false
		}
		arena.Phase = "inconclusive"
		arena.Status = "no deterministic winner · independent judgment needed"
		arena.stopRunningCandidates()
		m.markRaceUnseen(hydrating)
		return true

	case "tournament_judgment_unresolved":
		arena := m.competitionByID(asString(data["tournament_id"]))
		if arena == nil {
			return false
		}
		arena.Phase = "inconclusive"
		arena.Status = "parent judgment did not identify exactly one candidate"
		m.markRaceUnseen(hydrating)
		return true

	case "race_candidate_cancelled":
		arena := m.raceByRace(asString(data["race_id"]))
		if arena == nil {
			return false
		}
		candidate := arena.ensureCandidate(asString(data["candidate_id"]), "")
		candidate.Status = "cancelled"
		candidate.Activity = "stopped after another lane won"
		return true

	case "race_candidate_rejected":
		arena := m.raceByRace(asString(data["race_id"]))
		if arena == nil {
			return false
		}
		candidate := arena.ensureCandidate(asString(data["candidate_id"]), "")
		candidate.Status = "rejected"
		candidate.Activity = "finish was not admissible"
		return true

	case "provider_auction_settled":
		arena := m.raceByAuction(asString(data["auction_id"]))
		purpose := asString(data["purpose"])
		if arena == nil || (purpose != "provider_race" && purpose != "provider_tournament") {
			return false
		}
		if arena.WinnerEndpoint == "" {
			arena.WinnerEndpoint = asString(data["winner_endpoint_id"])
		}
		if arena.Phase != "selected" && arena.Phase != "inconclusive" {
			arena.Phase = asString(data["status"])
		}
		return true
	}

	// Child runtime events enrich their lane and stay available in the Events
	// tab, without flooding the main transcript with candidate internals.
	if candidate := m.raceCandidateByWorker(sessionID); candidate != nil && !root {
		handled := false
		switch eventType {
		case "model_response_started":
			candidate.Activity = "model reasoning"
			handled = true
		case "tool_called":
			candidate.Activity = "using " + firstNonEmpty(asString(data["name"]), "tool")
			handled = true
		case "tool_result":
			if asBool(data["is_error"]) {
				candidate.Activity = "tool failed · recovering"
			} else {
				candidate.Activity = "tool result received"
			}
			handled = true
		case "verification_started":
			candidate.Activity = "verifying result"
			handled = true
		case "verification_finished":
			candidate.Activity = "verification " + asString(data["status"])
			handled = true
		case "model_response_failed", "turn_failed":
			candidate.Status = "failed"
			candidate.Activity = "candidate failed"
			handled = true
		}
		return handled
	}
	return false
}

func (m *model) ensureRace(auctionID, raceID string) *raceArena {
	if arena := m.raceByAuction(auctionID); arena != nil {
		if arena.RaceID == "" {
			arena.RaceID = raceID
		}
		return arena
	}
	if arena := m.raceByRace(raceID); arena != nil {
		if arena.AuctionID == "" {
			arena.AuctionID = auctionID
		}
		return arena
	}
	anchor := firstNonEmpty(auctionID, raceID)
	m.races = append(m.races, raceArena{AnchorID: anchor, AuctionID: auctionID, RaceID: raceID})
	return &m.races[len(m.races)-1]
}

func (m *model) ensureRaceAnchor(anchorID string) {
	for i := range m.entries {
		if m.entries[i].Kind == "race" && m.entries[i].ID == anchorID {
			m.entries[i].Role = spineSystem
			return
		}
	}
	m.entries = append(m.entries, entry{Kind: "race", ID: anchorID, Role: spineSystem})
}

func (m *model) markRaceUnseen(hydrating bool) {
	if !hydrating && m.tab != tabRace {
		m.unseen[tabRace]++
	}
}

func (m *model) raceByAuction(id string) *raceArena {
	if id == "" {
		return nil
	}
	for i := range m.races {
		if m.races[i].AuctionID == id {
			return &m.races[i]
		}
	}
	return nil
}

func (m *model) raceByRace(id string) *raceArena {
	if id == "" {
		return nil
	}
	for i := range m.races {
		if m.races[i].RaceID == id {
			return &m.races[i]
		}
	}
	return nil
}

func (m *model) competitionByID(id string) *raceArena {
	if arena := m.raceByRace(id); arena != nil {
		return arena
	}
	for i := range m.races {
		if id != "" && m.races[i].TournamentID == id {
			return &m.races[i]
		}
	}
	return nil
}

func (m *model) raceByAnchor(id string) *raceArena {
	for i := range m.races {
		if m.races[i].AnchorID == id {
			return &m.races[i]
		}
	}
	return nil
}

func (m *model) latestRace() *raceArena {
	if len(m.races) == 0 {
		return nil
	}
	return &m.races[len(m.races)-1]
}

func (m *model) raceCandidateByWorker(workerID string) *raceCandidate {
	if workerID == "" {
		return nil
	}
	for i := len(m.races) - 1; i >= 0; i-- {
		for j := range m.races[i].Candidates {
			if m.races[i].Candidates[j].WorkerID == workerID {
				return &m.races[i].Candidates[j]
			}
		}
	}
	return nil
}

func (a *raceArena) putBid(next raceBid) {
	for i := range a.Bids {
		if a.Bids[i].EndpointID == next.EndpointID {
			next.Awarded = a.Bids[i].Awarded
			a.Bids[i] = next
			return
		}
	}
	a.Bids = append(a.Bids, next)
}

func (a *raceArena) markAwarded(endpointID string) {
	for i := range a.Bids {
		if a.Bids[i].EndpointID == endpointID {
			a.Bids[i].Awarded = true
		}
	}
}

func (a *raceArena) putCandidate(next raceCandidate) {
	for i := range a.Candidates {
		candidate := &a.Candidates[i]
		if (next.ID != "" && candidate.ID == next.ID) || (next.EndpointID != "" && candidate.EndpointID == next.EndpointID) {
			candidate.ID = firstNonEmpty(next.ID, candidate.ID)
			candidate.WorkerID = firstNonEmpty(next.WorkerID, candidate.WorkerID)
			candidate.EndpointID = firstNonEmpty(next.EndpointID, candidate.EndpointID)
			candidate.Provider = firstNonEmpty(next.Provider, candidate.Provider)
			candidate.Model = firstNonEmpty(next.Model, candidate.Model)
			candidate.Status = firstNonEmpty(next.Status, candidate.Status)
			candidate.Activity = firstNonEmpty(next.Activity, candidate.Activity)
			return
		}
	}
	a.Candidates = append(a.Candidates, next)
}

func (a *raceArena) ensureCandidate(id, endpointID string) *raceCandidate {
	a.putCandidate(raceCandidate{ID: id, EndpointID: endpointID})
	for i := range a.Candidates {
		if (id != "" && a.Candidates[i].ID == id) || a.Candidates[i].EndpointID == endpointID {
			return &a.Candidates[i]
		}
	}
	return nil
}

func (a raceArena) allCandidatesSubmitted() bool {
	expected := a.CandidateCount
	if expected == 0 {
		expected = len(a.Candidates)
	}
	if expected == 0 || len(a.Candidates) < expected {
		return false
	}
	for _, candidate := range a.Candidates {
		if candidate.Status != "submitted" && candidate.Status != "failed" {
			return false
		}
	}
	return true
}

func (a *raceArena) stopRunningCandidates() {
	for i := range a.Candidates {
		if a.Candidates[i].Status == "running" || a.Candidates[i].Status == "leased" {
			a.Candidates[i].Status = "stopped"
			a.Candidates[i].Activity = "race ended without selection"
		}
	}
}

func (a *raceArena) discardTournamentLosers() {
	for i := range a.Candidates {
		if a.Candidates[i].ID != a.WinnerID && a.Candidates[i].Status == "submitted" {
			a.Candidates[i].Status = "discarded"
			a.Candidates[i].Activity = "not selected by the judge"
		}
	}
}

func (m model) renderCompactRace(arena raceArena) string {
	width := max(24, m.width-7)
	header := joinEdges(arenaTitle(arena), strings.ToUpper(arena.Phase), width)
	lines := []string{
		styleMint.Bold(true).Render(header),
		styleFaint.Render(arenaStageRail(arena)),
	}
	if len(arena.Candidates) == 0 {
		lines = append(lines, mutedStyle.Render(fmt.Sprintf("collecting bids · %d/%d received", len(arena.Bids), arena.EligibleCount)))
	} else {
		for _, candidate := range arena.Candidates {
			lines = append(lines, m.renderRaceLane(arena, candidate, width, false))
		}
	}
	if arena.Mode == "race" {
		lines = append(lines, styleFaint.Render("first admissible finish wins · other lanes stop · 7 inspect"))
	} else {
		lines = append(lines, styleFaint.Render("quality and evidence decide · 7 inspect"))
	}
	return strings.Join(lines, "\n")
}

func raceStageRail(phase string) string {
	stages := []string{"BID", "LEASE", "RUN", "JUDGE", "DECIDE"}
	active := racePhaseIndex(phase)
	parts := make([]string, len(stages))
	for i, stage := range stages {
		switch {
		case phase == "selected" && i <= active:
			parts[i] = styleMint.Render("● " + stage)
		case phase == "inconclusive" && i == active:
			parts[i] = styleRose.Render("× " + stage)
		case i < active:
			parts[i] = styleMint.Render("● " + stage)
		case i == active:
			parts[i] = styleSand.Render("◉ " + stage)
		default:
			parts[i] = styleFaint.Render("○ " + stage)
		}
	}
	return strings.Join(parts, styleFaint.Render(" ─ "))
}

func arenaStageRail(arena raceArena) string {
	if arena.Mode != "race" {
		return raceStageRail(arena.Phase)
	}

	stages := []string{"BID", "LEASE", "RUN", "WIN", "STOP"}
	active := speedRacePhaseIndex(arena.Phase)
	parts := make([]string, len(stages))
	for i, stage := range stages {
		switch {
		case arena.Phase == "selected" && i <= active:
			parts[i] = styleMint.Render("● " + stage)
		case arena.Phase == "inconclusive" && i == active:
			parts[i] = styleRose.Render("× " + stage)
		case i < active:
			parts[i] = styleMint.Render("● " + stage)
		case i == active:
			parts[i] = styleSand.Render("◉ " + stage)
		default:
			parts[i] = styleFaint.Render("○ " + stage)
		}
	}
	return strings.Join(parts, styleFaint.Render(" ─ "))
}

func speedRacePhaseIndex(phase string) int {
	switch phase {
	case "bidding":
		return 0
	case "awarded":
		return 1
	case "running":
		return 2
	case "stopping":
		return 3
	default:
		return 4
	}
}

func racePhaseIndex(phase string) int {
	switch phase {
	case "bidding":
		return 0
	case "awarded":
		return 1
	case "running":
		return 2
	case "judging":
		return 3
	default:
		return 4
	}
}

func (m model) renderRaceLane(arena raceArena, candidate raceCandidate, width int, selected bool) string {
	marker, state := "○", candidate.Status
	style := mutedStyle
	switch {
	case candidate.ID != "" && candidate.ID == arena.WinnerID:
		marker, state, style = "★", "selected", styleMint
	case candidate.Status == "running":
		marker, style = "◉", styleSand
	case candidate.Status == "submitted":
		marker, state, style = "✓", "submitted · awaiting judgment", bodyStyle
	case candidate.Status == "failed" || candidate.Status == "stopped" || candidate.Status == "cancelled" || candidate.Status == "rejected" || candidate.Status == "discarded":
		marker, style = "×", styleRose
	}
	label := firstNonEmpty(candidate.EndpointID, candidate.Provider, candidate.ID, "candidate")
	left := fmt.Sprintf("%s %-18s", marker, label)
	if arena.Mode == "race" {
		lane := "♞ ───────▶"
		switch {
		case candidate.ID != "" && candidate.ID == arena.WinnerID:
			lane = "★ ━━━━━━━│"
		case candidate.Status == "cancelled" || candidate.Status == "stopped":
			lane = "× ━━━    │"
		case candidate.Status == "failed" || candidate.Status == "rejected" || candidate.Status == "discarded":
			lane = "× ──     │"
		}
		left = fmt.Sprintf("%s %-14s", lane, label)
	}
	line := truncateToWidth(joinEdges(left, state, width), width)
	if selected {
		return lipgloss.NewStyle().Foreground(colPanel).Background(colMint).Bold(true).Width(width).Render("› " + truncateToWidth(line, max(1, width-2)))
	}
	return style.Render(line)
}

func (m model) renderRaceTab() string {
	arena := m.latestRace()
	if arena == nil {
		return lipgloss.NewStyle().Padding(2, 2).Foreground(colDim).
			Render("No provider competition yet.\n\nUse /race GOAL for first-finish speed or /tournament GOAL for quality selection.")
	}

	width := max(28, m.width-4)
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", styleMint.Bold(true).Render(arenaTitle(*arena)))
	if arena.Mode == "race" {
		fmt.Fprintf(&b, "%s\n", bodyStyle.Render("First admissible terminal result wins. Remaining worker trees are cancelled."))
	} else {
		fmt.Fprintf(&b, "%s\n", bodyStyle.Render("Parallel proposals, then independent judgment. Finishing first does not win."))
	}
	fmt.Fprintf(&b, "%s\n\n", arenaStageRail(*arena))

	fmt.Fprintf(&b, "%s\n", styleFaint.Render("CANDIDATE LANES"))
	if len(arena.Candidates) == 0 {
		fmt.Fprintf(&b, "%s\n", mutedStyle.Render("Waiting for provider leases…"))
	} else {
		selected := min(m.raceTab.selected, len(arena.Candidates)-1)
		for i, candidate := range arena.Candidates {
			fmt.Fprintf(&b, "%s\n", m.renderRaceLane(*arena, candidate, width, i == selected))
		}
		m.raceTab.selected = selected
	}

	if len(arena.Bids) > 0 {
		bidHeading := "PROVIDER BIDS · ROUTING FIT, NOT RACE POSITION"
		if arena.Mode != "race" {
			bidHeading = "PROVIDER BIDS · ROUTING FIT, NOT TOURNAMENT RANKING"
		}
		fmt.Fprintf(&b, "\n%s\n", styleFaint.Render(bidHeading))
		for _, bid := range arena.Bids {
			marker := "○"
			style := mutedStyle
			lease := "not leased"
			if bid.Awarded {
				marker, style, lease = "◆", styleMint, "leased"
			}
			line := fmt.Sprintf("%s %-18s score %d · %.0f%% confidence", marker, bid.EndpointID, bid.Score, bid.Confidence*100)
			fmt.Fprintf(&b, "%s\n", style.Render(truncateToWidth(joinEdges(line, lease, width), width)))
		}
	}

	stateTitle := "RACE STATE"
	if arena.Mode != "race" {
		stateTitle = "TOURNAMENT STATE"
	}
	fmt.Fprintf(&b, "\n%s\n", styleFaint.Render(stateTitle))
	fmt.Fprintf(&b, "%s\n", bodyStyle.Render(arena.Status))
	if arena.WinnerEndpoint != "" {
		selection := "selected by evaluator  "
		if arena.Mode == "race" {
			selection = "first admissible finish  "
		} else if arena.SelectionSource == "parent_judgment" {
			selection = "selected by parent judge  "
		}
		fmt.Fprintf(&b, "%s\n", styleMint.Render(selection+arena.WinnerEndpoint))
	}

	if len(arena.Candidates) > 0 {
		candidate := arena.Candidates[min(m.raceTab.selected, len(arena.Candidates)-1)]
		fmt.Fprintf(&b, "\n%s\n", styleFaint.Render("FOCUSED CANDIDATE"))
		fmt.Fprintf(&b, "%s\n", bodyStyle.Render(raceCandidateIdentity(candidate)))
		fmt.Fprintf(&b, "%s\n", mutedStyle.Render("activity      "+firstNonEmpty(candidate.Activity, "waiting")))
		fmt.Fprintf(&b, "%s\n", mutedStyle.Render("verification  "+firstNonEmpty(candidate.VerificationStatus, "not reported yet")))
		if bid := arena.bidFor(candidate.EndpointID); bid != nil {
			fmt.Fprintf(&b, "%s\n", mutedStyle.Render(fmt.Sprintf("bid evidence  score %d · %.0f%% confidence · %s", bid.Score, bid.Confidence*100, firstNonEmpty(bid.CostTier, "cost unknown"))))
			if m.raceTab.expanded {
				latency := "routing latency estimate unavailable"
				if bid.EstimatedLatencyMs > 0 {
					latency = fmt.Sprintf("routing latency estimate %.0f ms", bid.EstimatedLatencyMs)
				}
				fmt.Fprintf(&b, "%s\n", styleFaint.Render(latency+" · this is not race progress"))
				if bid.Reason != "" {
					fmt.Fprintf(&b, "%s\n", styleFaint.Render(truncateToWidth("bid rationale  "+bid.Reason, width)))
				}
			}
		}
	}

	fmt.Fprintf(&b, "\n%s", styleFaint.Render("↑/↓ focus lane · enter evidence · esc chat"))
	return lipgloss.NewStyle().Padding(1, 2).Render(b.String())
}

func (m model) updateRaceTab(key string) (tea.Model, tea.Cmd) {
	arena := m.latestRace()
	if arena == nil || len(arena.Candidates) == 0 {
		return m, nil
	}
	switch key {
	case "up", "k":
		m.raceTab.selected = (m.raceTab.selected - 1 + len(arena.Candidates)) % len(arena.Candidates)
	case "down", "j":
		m.raceTab.selected = (m.raceTab.selected + 1) % len(arena.Candidates)
	case "enter":
		m.raceTab.expanded = !m.raceTab.expanded
	}
	return m, nil
}

func (a raceArena) bidFor(endpointID string) *raceBid {
	for i := range a.Bids {
		if a.Bids[i].EndpointID == endpointID {
			return &a.Bids[i]
		}
	}
	return nil
}

func raceCandidateIdentity(candidate raceCandidate) string {
	providerModel := strings.Trim(strings.Join([]string{candidate.Provider, candidate.Model}, "/"), "/")
	if providerModel == "" || providerModel == candidate.EndpointID {
		return firstNonEmpty(candidate.EndpointID, candidate.ID, "candidate")
	}
	return firstNonEmpty(candidate.EndpointID, candidate.ID, "candidate") + " · " + providerModel
}

func arenaTitle(arena raceArena) string {
	if arena.Mode == "race" {
		return "SPEED RACE"
	}
	return "QUALITY TOURNAMENT"
}

func intValue(value any) int {
	if n, ok := number(value); ok {
		return int(n)
	}
	return 0
}

func floatValue(value any) float64 {
	if n, ok := number(value); ok {
		return n
	}
	return 0
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
