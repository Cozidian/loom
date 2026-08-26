# BeamAgent roadmap

Updated: 2026-08-26

This is the current product work order for growing BeamAgent into an
OTP-native alternative to coding agents such as OpenCode. It is an evolving
roadmap, not a frozen specification: completed work keeps its implementation
evidence, while later items can change as we learn from real use.

## Current baseline

BeamAgent already has durable supervised sessions, multiple LLM provider
profiles, guarded coding tools, project skills, subagents, live streaming,
approvals, a Charm-based Go TUI, and a line-oriented terminal client.

## Work order

1. [x] Context budgeting and durable compaction

   - Estimate the complete model request, including system instructions, tool
     schemas, messages, and tool results.
   - Compact only completed turns so assistant tool calls never separate from
     their tool results.
   - Keep the append-only event log canonical and persist summaries as new
     events, making the projection reconstructable after restart.
   - Fall back to the full projection if the summarizer fails.
   - Expose usage in `/status` and the TUI, plus manual `/compact` and CLI
     configuration for the window and threshold.
   - Evidence: `BeamAgent.Session.ConversationContext`, the tool-loop projection
     path, config migration version 5, and `test/conversation_context_test.exs`.

2. [ ] MCP servers

   - Start with local stdio servers owned by supervised session resources.
   - Add discovery, namespaced tools, lifecycle events, timeouts, and explicit
     capability failures.
   - Add remote transports only after the local ownership model is proven.

3. [ ] Resource-specific permissions and durable rules

   - Replace the single broad risky-tool choice with decisions scoped to a
     tool, command family, path, host, or MCP server.
   - Add an explicit durable `allow always` choice with inspectable storage and
     revocation.

4. [ ] Configurable agents and background subagents

   - Add named build, plan, review, and explore agent profiles.
   - Give every child an explicit goal, capability set, budget, lifecycle, and
     result channel while preserving supervision and cancellation semantics.

5. [ ] Stronger coding tools

   - Add patch-native edits, git-aware inspection, streamed shell execution,
     and language diagnostics.
   - Preserve observed-state checks, bounded output, workspace confinement, and
     typed durable results.

6. [ ] Runtime client/server boundary, then web UI

   - Extract the TUI controller boundary into a reusable local runtime API with
     session subscriptions, approvals, cancellation, and reconnect semantics.
   - Build a web client only after the runtime boundary is stable so terminal
     and browser clients share one orchestration core.

## Decision notes

- Context comes before MCP because instructions, tool schemas, and tool results
  all compete for the same model window.
- OTP supervision remains the organizing idea: integrations and background work
  should be owned resources, not hidden global state.
- A beautiful TUI is part of the product throughout the roadmap; visual polish
  continues incrementally instead of blocking the runtime foundations.
