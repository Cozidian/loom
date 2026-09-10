# BeamAgent — evolving vision

Last discussed: 2026-09-10.

This is shared knowledge for people and agents, distilled from the owner's
vision interview. It is **not a specification**, a frozen requirements list,
or permission to act. Preferences, decisions and plans can change as we learn.
Current user intent governs the task; code, tests and observed artifacts help
establish what actually works. If this document disagrees with new evidence,
surface the disagreement and revise the understanding rather than defending
the document.

## The experience we want

Give the harness a feature, an app, an analysis, a document task or a longer-term
goal. It takes responsibility for making useful progress through to a usable,
verified result. It should feel automatic, not like supervising a hundred tiny
decisions. It asks when genuinely unsure and when the user's judgment changes
the outcome, not merely because work contains ordinary implementation choices.

The owner normally handles `git push` and other publication steps personally,
but can explicitly delegate them. Independence in doing the work is not blanket
authorization to publish, deploy, spend against a new account, or edit unrelated
work. The precise product permissions still need to be designed and tested;
this paragraph is not evidence of an existing publication guard.

The first audience is the owner. Other people with similar working habits may
find it useful; team administration or a broad platform market is not the
reason to delay making the personal workflow excellent.

## General purpose, grounded in real use

Coding and code analysis are the main use cases. Working with documents is
equally a real use case, not a hypothetical extension. The broader ambition is
general-purpose work, but it should earn that claim through delivered results
rather than an ever-growing list of possible integrations.

“Complete” means ready for actual use:

- For a web app: implement it, run it, exercise the relevant behavior, inspect
  it visually, and report failures or limitations. Passing unit tests alone
  does not establish a working user experience.
- For a Word document: make the intended edit, preserve unrelated content and
  document integrity, render and inspect the result, and hand over a file that
  opens correctly. Successfully writing a file is not enough.
- For analysis: distinguish findings, supporting evidence, uncertainty and
  remaining questions. Analysis is not an implicit request to modify the source.

These are current expectations to explore with representative work, not fixed
test cases that prevent changing the product. Integrity checks remain useful
evidence even while the desired result evolves.

## What makes it worth using

The owner identified efficient use of intelligence, reliability and visibility
as make-or-break qualities. There is no settled numeric ranking among them.

Use deterministic operations where no inference is needed. Reuse relevant
evidence rather than repeatedly rediscovering it. Route appropriate work to
eligible cheaper or local models and keep demanding work with capable models.
Judge the whole outcome—including retries, coordination and verification—not
just the price or token count of an individual call.

The quota clarification matters: the owner's example concerned personal Codex
hourly/weekly limits, **not an allowance necessarily assigned to this harness
or its agents**. Do not infer shared credentials, a per-agent quota model, or a
quota-control product requirement from that example. Which accounts and limits
matter to a deployed harness, and what can be measured reliably, remain open.
Missing usage data is unknown usage, not zero-cost work.

## Models are resources; agents own work

OTP and the actor model remain central to the architectural direction.
Independently supervised agents can own goals, context, capabilities and
lifecycles, while models provide intelligence. A useful team may contain many
instances of the same model, several providers, or just one worker.

Team size follows useful independent work and available capacity, not a fixed
cast of helpers. More agents are not automatically more effective. Capacity
queues, cancellation and shared-file coordination matter more than showing a
large actor count. Cheap process creation does not make inference free.

Races, tournaments, reviews and other execution paths remain worth exploring
and keeping where they help. No particular strategy is the default answer to
every task. Current depth and authority safeguards are implementation facts,
not a declaration that the eventual organization model is settled.

## Workspaces and a personal control center

Two complementary experiences emerged from the interview:

1. Open a harness in a repository or document folder and work there directly.
2. Open a personal control center that sees work across many such workspaces.

A user might leave missions running in three repositories and four document
folders, then inspect all of them centrally. Local workspace work should still
make sense on its own. The personal center is its own product surface; a TUI,
web interface or other client should not become a second owner of runtime state.

Background workers report to a main or coordinating harness. The exact division
between workspace coordinators and personal coordination is still a design
question, not a fixed process tree. Cross-machine workers remain part of the
longer-term ambition, with trust, artifact exchange and recovery still to prove.

## Background missions, not unsolicited interference

The user may launch persistent missions such as keeping documentation current,
watching for regressions, or investigating a workspace and proposing new goals.
Even a goal-discovery mission reports back to its coordinator; discovering an
idea does not automatically authorize every action needed to pursue it.

The harness should coexist with people and other tools. If another tool is
implementing a feature, missing documentation may simply be unfinished work.
Observation should therefore be inexpensive, coalesced and selective. Meaningful
checkpoints, completed work or quiet periods are promising triggers; exact
heuristics are not settled. A quiet period is evidence to assess, not proof that
someone else has finished.

Proactive edits belong in isolated changes, not surprise mutations to another
tool's active working tree. Recheck their relevance against current work before
reporting or integrating them. Avoid redundant analysis, stale proposals and
repeated suggestions the user already rejected. How integration is approved
and which mission modes can act without further permission remain open.

## Visibility: overview first, evidence underneath

The primary view answers:

- What changed?
- Why were these decisions made?
- What is unfinished, blocked or uncertain?

Drill down into individual agents to see their assignment, model/provider,
actions, results, verification and handoffs. “Reasoning” here means useful
decision explanations and available summaries grounded in observable activity;
it is not a promise of access to every provider's internal reasoning.

A quiet model call should not make the interface look abandoned. Show real
activity and distinguish inference, tool execution, queue waits, user decisions
and suspected stalls. Avoid fabricated progress or noise added merely to look busy.

## Knowledge must stay alive

Remember goals, architectural choices, preferences, investigations, rejected
suggestions and why they were rejected. Prefer readable project files that
people and other tools can inspect and use. The exact storage layout can evolve.

Never turn that knowledge into specifications. Record evidence and uncertainty,
keep the reason behind a decision, and welcome a better explanation. A previously
rejected idea can become useful when its circumstances change. Mark an older
belief superseded instead of pretending it was always the new belief.

This flexibility does not mean ignoring live permissions or changing tests just
to manufacture success. Knowledge describes what we currently understand;
runtime authority governs actions; verification provides evidence about results.

## The first moment of trust

Start with one real coding project and one real document edit. The owner has
chosen those experiences as the first proof, but not yet the exact fixtures.
Observe where babysitting, waste, failed verification or unusable artifacts
occur. Improve those paths before expanding the surrounding platform.

See [ROADMAP.md](ROADMAP.md) for a proposed sequence of trials and follow-up work.
It is an editable set of bets, not a contract or implementation authorization.

## Interview trail and unresolved choices

The following captures the 2026-09-10 discussion and corrects earlier framing:

- **Broadened:** software development is the primary use, not the boundary of
  the product. Document work belongs in the first real-world trials.
- **Clarified:** both workspace-local harnesses and a separate personal control
  center are wanted; their coordination protocol is not yet designed.
- **Clarified:** proactive changes should be isolated. Background work should
  avoid spending intelligence on things that are merely not finished yet.
- **Corrected:** personal Codex quota pressure was an example of waste the
  owner cares about, not a decision to allocate that quota to harness workers.
- **Emphasized:** memory, vision and roadmaps are revisable knowledge, never specs.

Still open: exact first trials; mission modes and integration permissions;
cross-workspace knowledge/privacy boundaries; applicable provider accounts and
resource measurements; control-center interface and packaging; trusted-machine
enrollment; and the order of later work after the first two trials.
