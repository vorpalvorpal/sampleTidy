name: tdd-plan
description: >
  Orchestrates a multi-agent TDD engineering workflow: collaborative design, exhaustive
  implementation plans with correctness criteria, a test suite written before any code,
  cost-tiered implementation (cheap models write, expensive models judge), an adversarial
  compliance audit, and checkpointed sub-agents that survive session limits. Use this
  whenever the user wants to build a non-trivial feature, tool, or module from a spec or
  idea — anything phrased like "implement this spec" or "use TDD".

# TDD Plan Orchestrator

A language-agnostic multi-agent workflow for robust Test-Driven Development. You (the
orchestrator, typically the most capable model in the room) own judgement: design,
adjudication, and verdicts. Sub-agents own volume: research, writing, and mechanical
execution.

## The cost model (read this first — it drives every delegation choice)

Output tokens cost roughly **5× input tokens**, and model tier multiplies that again.
So the two golden rules:

1. **Cheap models write; expensive models read and rule.** Bulk artifact production
   (tests, implementation, boilerplate) goes to the cheapest model that can execute the
   plan. Expensive models (Fable/Opus-class) are reserved for read-heavy, terse-output roles:
   auditing, verifying, adjudicating. An expensive model that writes 2,000 lines is the
   single most wasteful allocation this workflow can make; an expensive model that reads
   2,000 lines and emits a 30-line defect list is the single most valuable.
2. **Write once.** Never have one model draft an artifact and another rewrite it
   wholesale — two writes cost more than one, even when the first is cheap. Reviewers
   emit *delta lists* (file:line + one-line fix); a cheap model applies them. Where
   fragments must be merged, concatenate with file tools rather than having a model
   re-type content it has already read.

This only works if the plans are explicit enough for a weaker model to execute without
ambiguity — which is why Phase 2 is where the orchestrator spends its own tokens
generously. Plan explicitness is the cheapest rework-insurance you can buy.

## Cross-cutting protocols (apply to every phase)

- **[CHECKPOINT]** Sub-agents die: session limits, user interrupts, crashes. Every
  sub-agent must therefore (a) write work products to disk *incrementally* as it goes,
  never holding finished artifacts only in context, and (b) size its mission to finish
  well within a session budget — prefer two small agents over one long one. A dead agent
  whose work is on disk costs almost nothing; a dead agent with everything in context is
  a total loss.
- **[SALVAGE]** When an agent dies or is interrupted, inventory its on-disk artifacts
  *before* deciding how to continue. Usually a fresh, cheap agent reading the artifacts
  beats resuming the transcript (a resume reloads the entire transcript uncached). Only
  resume when the lost context is genuinely irreplaceable.
- **[CONTEXT SHIELD]** Never let long tool output (test logs, stack traces, build noise)
  into an expensive context. Every sub-agent report gets an explicit word budget
  (300–600 words) and must condense errors into short bullets. The orchestrator's
  history is the most expensive real estate in the system — protect it.
- **[MEASURE TWICE]** Any empirical claim that a design decision will rest on (a
  benchmark, a byte-comparison, a round-trip property) must be reproduced through a
  second, unfiltered path before it is written into a plan. Output-condensing wrappers
  and proxies can silently misreport; a wrong "fact" baked into plans propagates into
  tests and implementation, and the correction cascade costs far more than the
  double-check.
- **[NO SILENT DEVIATION]** Sub-agents may not quietly diverge from plan or tests. If a
  plan is wrong or unimplementable, they finish what they can and file a plan-change
  request in their report. You adjudicate each request on its technical merits — verify
  the claim yourself when it is load-bearing; never rubber-stamp. Trivial test bugs
  (typos, obviously wrong literals) may be fixed inline with a one-line note.

## Phases

### Phase 1: High-Level Design
Collaborate with the user on the architecture. Think critically and push back on flawed
or fragile ideas; suggest elegant reframes; identify unknowns that need spikes.
Dispatch spikes to cheap sub-agents with narrow, self-contained instructions, and
require them to leave their experiments and raw results **on disk** — a spike's
artifacts should let anyone re-derive its verdict ([SALVAGE] applies; a dead spike with
artifacts is nearly free to finish). Apply [MEASURE TWICE] to every spike conclusion
before it becomes a design commitment.

### Phase 2: Plan Elaboration
Translate the settled design into step-by-step implementation plans, written by you.
Requirements:
- Granular enough for a **weaker model** to execute without ambiguity, in any language.
- Every requirement carries **explicit correctness criteria** — the blueprint the test
  suite will encode.
- Also produce a one-page **CONTRACT digest**: pinned module APIs, file layout,
  conventions, gates, and adjudicated decisions. Workers read the digest plus their own
  plan section *quoted inline in their prompt* — never the whole plan corpus. (Without
  this, every agent re-reads everything: at eight agents that is ~150k tokens of pure
  re-ingestion.)
- Record adjudications in the digest as they accumulate across later phases; it is the
  single source of truth when plans and tests disagree.
Delegate localized edge-case research to cheap sub-agents where useful.

### Phase 3: Sanity Check
Re-read the plans with fresh, critical eyes for internal consistency and architectural
validity. Make minor adjustments yourself; escalate design-impacting changes to the
user.

### Phase 4: Write the Test Suite (cheap model, once)
A **Sonnet-class** agent writes the complete failing test suite directly from the plans
and CONTRACT digest — full tests, real assertions, fixtures, helpers, one write. (Do
not draft stubs for later expansion: that doubles the writing. Phase 2 already
guarantees the plans are executable by this tier.) Instructions to the agent: tests
import production modules from the exact planned paths (unresolved imports are the
expected red state); every correctness criterion gets a recognisably-named test; where
a plan is ambiguous, take the best reading and file a plan-change request rather than
inventing semantics; deliver a criterion→test coverage map; [CHECKPOINT] applies —
files land on disk as written.

### Phase 5: Test Audit (expensive model, read-only)
An **Opus-class** agent audits the suite against the plans without writing files: does
every criterion have a test that asserts what the plan actually says (not something
weaker)? Are assertions objectively verifiable? It emits a terse delta list plus any
plan-change requests. You adjudicate; a cheap agent applies the deltas. Then verify the
red/green state yourself: every failure must be TDD-red (missing modules/exports), the
pre-existing suite must still pass, and the harness (fixtures, helpers) must hold.

### Phase 6: Orchestrated Implementation
A **Sonnet** orchestrator coordinates; **Haiku** workers implement individual, isolated
files. The plans + tests are the executable contract; where they conflict, the tests
win pending your adjudication.
- One file (or one tightly-coupled pair) per worker, with a narrow self-contained
  prompt: the relevant plan section verbatim, the CONTRACT digest, the exact test files
  that define done.
- **Parallel agents require a pre-declared file-disjoint partition** (design the module
  layout so packages own separate files — e.g. per-command modules behind a thin
  dispatcher). If a clean partition doesn't exist, run sequentially; merge conflicts
  cost more than serialization.
- Sonnet takes over a file *early* when a worker is out of its depth (subtle
  algorithms, git plumbing) — don't burn worker loops first.
- **[CIRCUIT BREAKER]** If the same failure survives 3 remediation attempts, stop work
  on that item, preserve state, and escalate to you with a condensed diagnosis.
- Gates: per-package test gates as work lands, then the full suite + typecheck/build at
  the end. Run test suites from the correct working directory / config — a wrong-cwd
  run produces phantom mass failures.

### Phase 7: Compliance Audit (expensive model, read-only)
An **Opus-class** agent performs an adversarial differential audit of implementation vs
plans — historically the highest-ROI spend in the whole workflow, precisely because it
is read-heavy with a terse verdict. Goals, in priority order: requirements coverage
(spot-check that coverage-map claims are true and tests aren't weaker than the plan);
silent deviations; scope creep; atomicity/failure-path tracing (throw-after-partial-
write is where real defects hide); output/exit-code discipline. It must not re-flag
already-adjudicated deviations (list them in its prompt). Output: a numbered
delta-remediation list — severity, category, defect, file:line, one-line fix — with
each deviation classified as improvement or regression.

### Phase 8: Adjudicate and Remediate
Review the audit list item by item on technical merits — you may overrule the auditor
in either direction (verify load-bearing claims yourself). Feed the refined checklist
to a **Sonnet** remediation agent with the rule: every accepted fix lands *with its
test*, the full suite stays green, and items that prove wrong as written are skipped
and reported, not improvised around. Documentation-only remediations (recording an
accepted deviation in the plans) you do yourself.

### Phase 9: Final Quality Sign-off
Sweep the result yourself: spot-verify the most severe audit fix by reading the code,
run the final gates, reconcile any project docs the change obsoletes (handoffs,
READMEs), and update memory. Perform trivial edits directly; delegate anything heavy.
Report to the user: what was built, the final gate results, and **every place the plans
moved along the way** (adjudications, accepted deviations, corrected assumptions) — the
plan-drift log is as much a deliverable as the code.