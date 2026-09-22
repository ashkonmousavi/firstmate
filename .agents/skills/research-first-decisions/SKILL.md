---
name: research-first-decisions
description: >-
  Agent-only procedure for selecting a tool, library, framework, service, vendor, or approach from candidates.
  Use before commissioning or consuming research that will pick one option over others, and before recording such a selection as decided.
  Also use before adopting, configuring, upgrading, or integrating a library, SDK, API, CLI, framework, or service, or before debugging version-sensitive usage - Context7 verification is mandatory there regardless of whether a selection is under way.
  Owns the predeclared frozen query plan, the search and challenge workflow, the primary-source hierarchy, the decision-packet form, the external-query privacy rule, the Context7 version-verification procedure, and the boundary between research that selects and local proof that only verifies.
user-invocable: false
metadata:
  internal: true
---

# research-first-decisions

Load this before any selection among candidates: a tool, library, framework, service, vendor, protocol, data source, or approach.
It is the single owner of that selection procedure.
Selection happens once and is expensive to reverse, so the evidence that drives it is gathered against a plan written before the searching starts, not assembled afterwards to fit a preference.

The order is fixed: freeze the plan, search, challenge and expand, verify against primary sources, then write the decision packet.
Skipping to a candidate and researching to confirm it is the failure this procedure exists to prevent.

## 1. Predeclared frozen query plan

Write the plan before running a single query, and freeze it.
It records:

- **Question** - the decision in one sentence, stated so a wrong answer is recognisable.
- **Decision criteria, in priority order** - what actually decides this, ranked before any candidate is known.
  Unranked criteria let the winner pick its own rubric.
- **Candidate set** - the options entering the comparison, including the incumbent and the do-nothing option where either is real.
- **Exclusions** - what is deliberately out and why, so a silent omission cannot pass as an absence of options.
- **Planned queries** - the searches to run, including the ones expected to be unflattering.
- **Negative-search populations** - where disconfirming evidence would live if it existed: deprecation notices, migration guides, abandonment and maintenance signals, incident and outage records, security advisories, and the accounts of people who moved off the candidate.
- **Stop rules** - what makes the research finished, and what makes it abort early.

Amend the frozen plan only by recording the amendment and its reason in the packet.
An unrecorded mid-research change of criteria is how a predetermined answer gets laundered into a finding.

## 2. Search, then challenge and expand

Run the planned queries with web search first, then use Exa to do the work a plain search will not.
Both passes are required; the second is where the plan earns its value.

- **Challenge** - search for the case against each candidate, using the negative-search populations named above.
  A candidate with no located criticism has not been challenged, it has been under-searched.
- **Expand** - search for candidates the plan missed.
  Selection quality is bounded by the candidate set, and the frozen set is a starting point, not a closed one.
  Record every late candidate and either admit it to the comparison or record its exclusion reason.

Stop when the stop rules are met, and record which rule fired.
Diminishing returns is a valid stop; running out of patience is not, and neither is finding an answer you like.
Where English sources are thin on a candidate, promote - but do not require - searches in other languages, including Chinese, Russian, German, French, Spanish, Korean, Japanese, and others; write every finding entering the packet in English, cite its original language and title, and save nothing in another language.

## 3. Source hierarchy

Primary sources are the only authority.
Official documentation, the source repository, release notes, changelogs, specifications, issue and advisory trackers, licences, and the vendor's own current terms decide a claim.

Secondary sources are leads, never authority.
Blog posts, comparison articles, benchmarks by third parties, forum answers, aggregator summaries, and model recollection point at a claim worth checking; they never settle it.
Trace every load-bearing claim to a primary source before it enters the packet, and mark any claim that could not be traced as unverified rather than promoting it.
Prefer the current version of a primary source over a dated one, and record the version or date a claim was read at, because a true-in-2023 fact presented undated is a future wrong answer.
Among primary sources, modern academic papers, current standards, and current methods outrank older ones on the same claim.

## 4. Decision packet

The deliverable is a packet, not a recommendation sentence.
It carries the frozen plan and its amendments, the evidence per candidate with primary-source citations, and:

- **A disposition for every candidate**, one of:
  - **ADOPT** - selected, with the criteria it won on and what it costs.
  - **BENCHMARK FURTHER** - not selected; a named decision criterion remains unresolved after primary-source research, with the missing evidence or public measurement stated.
    Continue research, route the ambiguity to the captain, or record the bounded local comparison that can resolve it.
  - **REJECT** - out, with the specific disqualifying evidence.
  - **DEFER** - not now, with what would reopen it.
  No candidate may be left without a disposition; an unaccounted candidate reads as an unexamined one.
- **Invalidation triggers** - the concrete events that would void this selection: a version bump past a named release, a licence change, a maintenance or ownership change, a named benchmark landing differently, a requirement changing.
  Without these the packet silently expires into a false claim.
- **Consumption records** - which task consumed this packet, named explicitly.
  A selection nobody records consuming gets re-researched or, worse, quietly re-decided.
  The research that produced a finding files it in the project's own findings record as part of the packet, never as a later task, in whatever form that record's owner prescribes: in XAUUSD that is that project's own `docs/ssot/research/README.md`, which routes the finding by provenance and owns the dated section, lookup heading, and last-reviewed line.
  Where a project keeps no such record, the packet is the record; do not create a research log to hold it.

Keep the packet's reasoning summary concise and material.
Record what decided it, not a transcript of the search.

## 5. Privacy of external queries

An external query is a disclosure.
Never put private code, private data, internal paths, host names, credentials, customer or captain identifiers, unreleased product facts, or repository-specific identifiers into a web or Exa search.
Ask the question in generic, public terms: the shape of the problem, not the instance of it.
If a question cannot be asked without disclosing private material, it is not a research question; answer it locally instead.

## 6. Selection versus proof

Research ordinarily selects.
Only an ADOPT option is selected unless a packet records how a bounded local comparison resolved a material criterion that primary-source research left unresolved.
Bounded local proof after selection verifies an ADOPT option's named integration-specific feasibility or budget claim, such as whether it builds here or speaks the protocol this system speaks.

Where primary-source research leaves a material criterion unresolved, the packet may authorize a bounded local comparison before selection.
It compares every candidate against identical inputs, versions, conditions, and predeclared criterion.
Preserve the inputs, versions, conditions, result, and the decision it changed in the packet.
The comparison may rank candidates and change a disposition only for that unresolved criterion.
It does not replace the primary-source record or permit a preference-driven bake-off.
The captain's resource-approval boundary remains unchanged, and this skill does not authorize a run, spend, account, credential, or external service.

Keep proof of an ADOPT option bounded to its named integration claim, and record its result back into the packet.
If that proof fails, record the failed integration claim and return the decision to research or the captain; the proof does not select a replacement or change a disposition itself.

Open-source libraries, and the ways other good applications solve the same problem, are legitimate candidates and sources; referencing or copying their code is allowed when its licence permits and its origin is cited, and copied code is localized to the project's conventions, contracts, and tests rather than pasted.

## 7. Context7 version-documentation verification

This duty is mandatory and applies independently of the selection procedure above.
It is standing captain preference, recorded in `data/captain.md`, and originates in the captain's instruction of 2026-09-08 and the advisor reconciliation at `/mnt/c/Users/Tegri/Downloads/p_transfers/Check_FirstMates_Work/WORK_RECONCILIATION.md` section 13.2.2; `data/captain.md` is the in-home authority and that document is its provenance.
It fires whenever an agent adopts, configures, upgrades, or integrates a library, SDK, API, CLI, framework, or service, or debugs version-sensitive usage, whether or not a candidate is being chosen.
It is not required for unrelated business-logic edits or for every tool invocation.

- **Resolve** - use Context7's `resolve-library-id` (or its CLI form where the MCP tool is absent) to find the library's Context7 ID from its name.
- **Query** - use `query-docs` (or the CLI form) against that ID for the specific behavior or configuration in question, not a general skim.
- **Version match** - match the returned documentation to the installed or proposed version; where Context7 lists several versions, pick the one that matches, and note the mismatch if none does.
- **Verify** - confirm the critical behavior against that versioned documentation, falling back to the primary source (the project's own repository, release notes, or changelog) when Context7's answer is ambiguous.
- **Receipt** - record, in the task's own preparation (a status line, prep note, or packet), the library ID, the version checked, the date, the sources consulted, and the resulting implementation decision.
- **Reuse rule** - a fresh receipt covering the identical version and API surface may be reused; a new API question, a changed version, or conflicting output requires a new lookup.
- **Fallback** - if Context7 errors, is unavailable, or does not carry the library or the exact pinned version, or its content is stale, record that limitation explicitly and verify against the primary source instead; when the primary source is not directly reachable, use Exa (`mcp exa web search` or fetch) or ordinary web search to reach the official versioned documentation for that exact version. Context7 stays the mandatory first stop, and a fallback never replaces checking the exact version. The receipt records the tool actually used, the URL, the version, and the date. Never substitute recalled API behavior or a fabricated tool-use claim.

Reviewers check that the behavior actually used is supported by what was found, not merely that a Context7 call occurred.
Keep private identifiers, code, and paths out of Context7 queries, under the same external-query privacy rule as section 5.

## Boundaries

This skill owns the selection procedure and the Context7 version-verification duty only.
Whether to commission a scout at all, and the ship-versus-scout classification, stay with `AGENTS.md` section 7.
Diagnosing a reported bug is `diagnostic-reasoning`, not a candidate selection.
Choosing a harness, model, or dispatch profile for a task is owned by `AGENTS.md` section 4 and `harness-adapters`; this research procedure does not overrule that intake contract.
Do not build a research tracker, registry, scoring engine, or template checker for any of the above; the packet is a document.
