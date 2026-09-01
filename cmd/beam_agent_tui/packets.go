package main

// Structured payloads for the tree/events/models/sessions/files tabs. These
// mirror lib/beam_agent/cli/tui/controller.ex's notify(state, {:tag, payload})
// calls exactly, after Elixir's json_safe/1 has stringified atom keys and
// values — every field here is what actually arrives over the wire, not an
// aspirational shape.

// --- tree tab ---

type treeSnapshot struct {
	Root          *goalNode               `json:"root"`
	Nodes         map[string]any          `json:"nodes"`
	Summary       treeSummary             `json:"summary"`
	Budget        *treeBudget             `json:"budget"`
	ResourcePools map[string]resourcePool `json:"resource_pools"`
	WorkspaceDiff *treeWorkspace          `json:"workspace_diff"`
	WorkBlocks    []workBlock             `json:"work_blocks"`
	Progress      *progressSnapshot       `json:"progress"`
}

type workBlock struct {
	ID             string         `json:"id"`
	WorkerID       string         `json:"worker_id"`
	State          string         `json:"state"`
	Phase          string         `json:"phase"`
	Label          string         `json:"label"`
	BlockingReason string         `json:"blocking_reason"`
	Summary        string         `json:"summary"`
	DurationMs     int64          `json:"duration_ms"`
	Counts         map[string]int `json:"counts"`
	Files          []string       `json:"files"`
	EventIDs       []string       `json:"event_ids"`
}

type progressSnapshot struct {
	Summary          progressSummary  `json:"summary"`
	Workers          []progressWorker `json:"workers"`
	CriticalWorkerID string           `json:"critical_worker_id"`
	CriticalReason   string           `json:"critical_reason"`
}

type progressSummary struct {
	Active  int `json:"active"`
	Waiting int `json:"waiting"`
	Blocked int `json:"blocked"`
	Stalled int `json:"stalled"`
}

type progressWorker struct {
	WorkerID         string `json:"worker_id"`
	State            string `json:"state"`
	Phase            string `json:"phase"`
	BlockingReason   string `json:"blocking_reason"`
	LastProgressAt   string `json:"last_progress_at"`
	SuspectedStalled bool   `json:"suspected_stalled"`
}

type goalNode struct {
	SessionID       string         `json:"session_id"`
	WorkerID        string         `json:"worker_id"`
	ParentSessionID string         `json:"parent_session_id"`
	Role            string         `json:"role"`
	State           string         `json:"state"`
	LastRouted      map[string]any `json:"last_routed"`
	LastTool        string         `json:"last_tool"`
	LastToolState   string         `json:"last_tool_state"`
	DurationMs      int64          `json:"duration_ms"`
	FailureCount    int            `json:"failure_count"`
	RestartCount    int            `json:"restart_count"`
	Children        []goalNode     `json:"children"`
}

type treeSummary struct {
	WorkerCount    int `json:"worker_count"`
	RunningCount   int `json:"running_count"`
	CompletedCount int `json:"completed_count"`
	FailedCount    int `json:"failed_count"`
	RestartCount   int `json:"restart_count"`
}

type treeBudget struct {
	GoalID      string             `json:"goal_id"`
	Allocations []budgetAllocation `json:"allocations"`
}

type budgetAllocation struct {
	AllocationID       string         `json:"allocation_id"`
	WorkerID           string         `json:"worker_id"`
	ParentAllocationID string         `json:"parent_allocation_id"`
	Limits             map[string]any `json:"limits"`
	Usage              map[string]any `json:"usage"`
	Status             string         `json:"status"`
}

type resourcePool struct {
	Active any `json:"active"`
	Limit  any `json:"limit"`
	Queued any `json:"queued"`
}

type treeWorkspace struct {
	Branch           string `json:"branch"`
	ChangedFileCount int    `json:"changed_file_count"`
	Insertions       int    `json:"insertions"`
	Deletions        int    `json:"deletions"`
}

// --- events tab ---

type eventsSnapshot struct {
	Matched             int        `json:"matched"`
	Total               int        `json:"total"`
	Returned            int        `json:"returned"`
	Cursor              int64      `json:"cursor"`
	Filters             []string   `json:"filters"`
	AvailableCategories []string   `json:"available_categories"`
	Events              []eventRow `json:"events"`
}

type eventRow struct {
	Scope         eventScope   `json:"scope"`
	Type          string       `json:"type"`
	At            string       `json:"at"`
	Category      string       `json:"category"`
	Durability    string       `json:"durability"`
	GoalSeq       int64        `json:"goal_seq"`
	Payload       eventPayload `json:"payload"`
	CorrelationID string       `json:"correlation_id"`
	CausationID   string       `json:"causation_id"`
	EventID       string       `json:"event_id"`
	Redacted      bool         `json:"redacted?"`
}

type eventScope struct {
	SessionID string `json:"session_id"`
	ProjectID string `json:"project_id"`
	GoalID    string `json:"goal_id"`
	WorkerID  string `json:"worker_id"`
	Root      bool   `json:"root?"`
}

type eventPayload struct {
	Data map[string]any `json:"data"`
	Type string         `json:"type"`
	Seq  int64          `json:"seq"`
}

// --- models tab ---

type modelsSnapshot struct {
	ActiveProfile   string          `json:"active_profile"`
	Endpoints       []modelEndpoint `json:"endpoints"`
	Evidence        modelEvidence   `json:"evidence"`
	Market          *providerMarket `json:"market,omitempty"`
	SessionSettings modelSettings   `json:"session_settings"`
}

type providerMarket struct {
	ID              string          `json:"id"`
	Purpose         string          `json:"purpose"`
	Status          string          `json:"status"`
	RequestedAwards int             `json:"requested_awards"`
	Bids            []providerBid   `json:"bids"`
	Awards          []providerAward `json:"awards"`
}

type providerBid struct {
	ID                 string         `json:"id"`
	EndpointID         string         `json:"endpoint_id"`
	Provider           string         `json:"provider"`
	Model              string         `json:"model"`
	Score              int            `json:"score"`
	Confidence         float64        `json:"confidence"`
	EstimatedLatencyMs float64        `json:"estimated_latency_ms"`
	CostTier           string         `json:"cost_tier"`
	VerifiedSamples    int            `json:"verified_samples"`
	ScoreComponents    map[string]int `json:"score_components"`
	Reason             string         `json:"reason"`
}

type providerAward struct {
	EndpointID string  `json:"endpoint_id"`
	Provider   string  `json:"provider"`
	Model      string  `json:"model"`
	BidID      string  `json:"bid_id"`
	Score      int     `json:"score"`
	Confidence float64 `json:"confidence"`
	Reason     string  `json:"reason"`
}

type modelEndpoint struct {
	ID             string         `json:"id"`
	Provider       string         `json:"provider"`
	ProviderModule string         `json:"provider_module"`
	Model          string         `json:"model"`
	Transport      any            `json:"transport"`
	Claims         map[string]any `json:"claims"`
	Measurements   map[string]any `json:"measurements"`
	Health         map[string]any `json:"health"`
}

type modelEvidence struct {
	State                  string             `json:"state"`
	RecommendedEndpointID  string             `json:"recommended_endpoint_id"`
	Reason                 string             `json:"reason"`
	Mode                   string             `json:"mode"`
	WindowDays             int                `json:"window_days"`
	MinimumVerifiedSamples int                `json:"minimum_verified_samples"`
	Endpoints              []endpointEvidence `json:"endpoints"`
	BestVerifiedSamples    int                `json:"best_verified_samples"`
}

type endpointEvidence struct {
	EndpointID              string  `json:"endpoint_id"`
	OperationalSamples      int     `json:"operational_samples"`
	OperationalSuccessRate  float64 `json:"operational_success_rate"`
	AverageLatencyMs        float64 `json:"average_latency_ms"`
	VerifiedSamples         int     `json:"verified_samples"`
	VerifiedPassRate        float64 `json:"verified_pass_rate"`
	RecencyWeightedPassRate float64 `json:"recency_weighted_pass_rate"`
	QualityLowerBound       float64 `json:"quality_lower_bound"`
	Confidence              float64 `json:"confidence"`
	Eligible                bool    `json:"eligible"`
}

type modelSettings struct {
	ApprovalMode   string `json:"approval_mode"`
	TokenBudget    int64  `json:"token_budget"`
	MCPServerCount int    `json:"mcp_server_count"`
}

// --- sessions tab ---

type sessionsSnapshot struct {
	Sessions []sessionSummary `json:"sessions"`
}

type sessionSummary struct {
	SessionID     string `json:"session_id"`
	WorkspaceRoot string `json:"workspace_root"`
	Mtime         int64  `json:"mtime"`
	Status        string `json:"status"`
}

type sessionDetail struct {
	SessionID    string `json:"session_id"`
	Provider     string `json:"provider"`
	Model        string `json:"model"`
	TurnCount    int    `json:"turn_count"`
	TotalTokens  int64  `json:"total_tokens"`
	LastActiveAt string `json:"last_active_at"`
	LastSeq      int64  `json:"last_seq"`
	GoalPreview  string `json:"goal_preview"`
}

// --- files tab (diff review) ---

type filesSnapshot struct {
	Branch    string        `json:"branch"`
	Changed   []changedFile `json:"changed"`
	InContext []contextFile `json:"in_context"`
}

type changedFile struct {
	Path       string `json:"path"`
	Status     string `json:"status"`
	Insertions int    `json:"insertions"`
	Deletions  int    `json:"deletions"`
	Binary     bool   `json:"binary"`
}

type contextFile struct {
	Path string `json:"path"`
	Tag  string `json:"tag"`
}

type fileDiff struct {
	Path       string     `json:"path"`
	Status     string     `json:"status"`
	Insertions int        `json:"insertions"`
	Deletions  int        `json:"deletions"`
	Binary     bool       `json:"binary"`
	Hunks      []diffHunk `json:"hunks"`
	RawPatch   string     `json:"raw_patch"`
}

type diffHunk struct {
	Header   string     `json:"header"`
	OldStart int        `json:"old_start"`
	OldCount int        `json:"old_count"`
	NewStart int        `json:"new_start"`
	NewCount int        `json:"new_count"`
	Lines    []diffLine `json:"lines"`
}

type diffLine struct {
	Kind    string `json:"kind"`
	OldLine int    `json:"old_line"`
	NewLine int    `json:"new_line"`
	Text    string `json:"text"`
}
