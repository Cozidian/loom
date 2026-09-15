# Repository Observatory

The Observatory is a full-page, read-only view of a workspace's software model.
Open **Repository Observatory** from a Desk session. The same runtime snapshot is
available to agents and authenticated API clients. No provider is invoked by
opening the page, changing a lens or preparing a brief.

## Understand → investigate → rehearse → act

- **Understand:** an atlas groups files into inferred components and six layers.
  The overview shows up to four components per layer, prioritized by resolved
  consumer count and sampled touches. Explore a layer to expand it; the index
  and search retain access to all modeled files. Arrows point from consumers to dependencies. Directory grouping and architectural
  roles are hypotheses, not service discovery or validated domain boundaries.
  Understand has its own four lenses: **Architecture** (the static import graph),
  **Integrations** (unresolved import names matched by name against the declared
  dependency inventory — "declared" or "unrecognized", never a real resolver),
  **Interactions** (commit co-change: files or components touched together in the
  sampled history, drawn as dashed, undirected links — correlation only, never
  promoted to a dependency), and **Protocols** (regex heuristics for HTTP/RPC
  route declarations across Phoenix/Plug, Express-style JS, Flask/FastAPI and
  Django conventions — not a live route table). Selecting a file drills one level
  further: a **Source** panel fetches and shows the file's full current text,
  read live from the workspace on demand, capped at 200 KB with a truncation
  notice past that — independent of the model's own bounded source sample.
- **Investigate:** change pressure, test filename evidence and security-sensitive
  path names illuminate the same map — Investigate has its own three lenses,
  distinct from Understand's. Select a component, follow relationships,
  then select a file for reference locations and contribution history. The
  reference-path tracer finds a shortest observed import chain to a destination
  component, without claiming it is a runtime UI-to-database request trace. The
  evidence dialog distinguishes measured facts, heuristics and missing signals.
- **Rehearse a change:** select a component or file. Reverse static imports trace
  potentially affected consumers up to 12 hops. Candidate tests and sensitive
  paths accompany the result. Free-text intent is included in the handoff; it
  does **not** make the graph estimate semantically understand that change.
- **Act:** prepare an editable investigation brief, download/copy it for another
  coding tool, or append it to a session draft. Preparing a brief does not start
  a turn. Existing drafts are preserved. The initial brief requests investigation,
  not implementation; the developer can revise its scope before submission.

The time lens highlights actual sampled commits on the **current worktree map**.
It does not reconstruct historical topology, estimate historical file size, or
predict the repository's direction. Playback is explicitly started and stops
when the page is hidden. Reset and zoom controls recover the map after exploration.

## Shared intelligence contract

`BeamAgent.Project.Observatory.snapshot/2` returns legacy report fields plus a
versioned `model` containing components, files, typed edges, co-change edges,
unresolved references, timeline, dimensions, investigations, coverage, integration
states and limitations. Each file additionally carries `external_touchpoints`
(unresolved import names matched against the declared dependency inventory),
`co_change` (its top commit co-change partners) and `protocols` (detected
route/RPC declarations); components aggregate the same three signals.
`ObservatoryIntelligence.impact/2` is the reusable runtime projection for impact.
The browser implements the same bounded reverse-import traversal over that model;
it owns only exploration state, never execution or permissions.

`BeamAgent.Project.Observatory.read_file/2` is a separate, on-demand read: given
a project and a relative path, it returns that file's full current text (capped
at 200 KB, contained with `Workspace.resolve/2`, rejecting credential-shaped
paths) for the Understand lens's code/text drill-down. It is not part of the
bounded model sample and re-reads the workspace live on each call.

The `repository_intelligence` read tool supports:

```json
{"action":"overview"}
{"action":"inspect","target":"src/auth"}
{"action":"impact","target":"src/auth/login.ts"}
{"action":"trace","target":"src/ui","destination":"src/data"}
```

Use exact component IDs or file paths returned by overview/inspection. The tool
uses its existing project context and normal runtime tool policy. Unknown targets
return an error rather than a fabricated analysis.

Authenticated HTTP clients can read `/api/v1/observatory` on a session's runtime
or `/api/v1/sessions/:id/observatory` on the catalog. Desk exposes the same report
at `/sessions/:id/observatory/data` (or `/observatory/data` for a single-session
server). These carry the existing session authentication and workspace scope.
The file drill-down uses the equivalent `/api/v1/observatory/file?path=...`
(runtime), `/api/v1/sessions/:id/observatory/file?path=...` (catalog) and
`/observatory/file` / `/sessions/:id/observatory/file` (Desk) routes.

## Evidence and limits

- Up to 600 non-credential-path files from the repository index, prioritized by
  sampled churn and then path. Omission counts are visible. A repository without
  Git still gets a source model.
- Source reads are contained with `Workspace.resolve/2`, restricted to supported
  extensions and 200 KB per file, with a 12 MB aggregate source budget.
- Lexical JS/TS imports, Elixir alias/use/import module references and Python
  from-imports are matched to known files. Only unique matches become edges.
  Aliases, grouped aliases, dynamic imports, runtime calls, RPC and generated
  wiring may remain unresolved or absent. Go/Rust and other source files can
  appear without dependency analysis. No package code or manifests are executed.
- Up to 4,000 resolved edges. Unresolved references are separately counted; the
  exported detail list contains up to 300. External dependencies are not assumed
  to be missing internal files.
- Up to 200 non-merge commits, with an eight-second Git deadline and a 2 MB output
  cap. Unavailable/truncated history yields an empty history sample. Large commits
  are excluded from the legacy co-change ranking, not silently treated as evidence
  of a dependency. The history lens is explicitly a sample.
- Test filename matches are **not coverage**. Security-sensitive filenames are
  **not vulnerability findings**. File touches and size are **not complexity**.
  Author counts are **not ownership authority**. No composite health score or
  churn-based rewrite recommendation appears in the cockpit.
- Root inventory reads reject symlink files and cap individual files at 1 MB.
  Workflow discovery is workspace-contained and capped at 40 definitions.
- Dependency inventory and workflow configuration do not establish vulnerability
  status, passing builds or safe deployments. Telemetry, cloud inventory,
  deployment/incident history and scanner results are currently not connected.
- Co-change links count commits that touched two modeled files together (large,
  noisy commits are excluded). This is **correlation**, never a runtime
  dependency or shared ownership, and is capped at 2,000 edges.
- External touchpoints match unresolved, non-relative import names against the
  declared dependency manifests **by name only**. An unmatched name may be
  undeclared, a bundler path alias, or an internal file outside this model's
  600-file limit — "unrecognized" is not a claim that a dependency is missing.
- Protocol matches are regex heuristics for common framework conventions
  (Phoenix/Plug, Express-style, Flask/FastAPI, Django). They are **not** a live
  route table: dynamic registration, mounted sub-routers and macros can hide or
  misattribute real endpoints.
- The code/text drill-down reads the workspace file live and is capped at
  200 KB; content past that is truncated with a visible notice, not silently
  dropped.

## Extension points

Add new evidence sources to the runtime model with provenance, scope, timestamp,
confidence and explicit unavailable/partial states. Preserve distinct relationship
kinds (imports, runtime calls, co-change, tests, deployments); never turn correlation
into a dependency edge. A future historical snapshot or external integration can
join this model without adding a second execution engine to the browser.

## Verification

```sh
mix test test/observatory_test.exs test/observatory_intelligence_test.exs
cd cmd/beam_agent_web
mix test test/observatory_test.exs
npm test -- --config playwright.observatory.config.js
```

The dedicated browser fixture uses an isolated commerce repository with actual
source imports and dated Git commits, an echo runtime, and no real credentials.
Screenshots are written to the web project's ignored `test-results` directory.
