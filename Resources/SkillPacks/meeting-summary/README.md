# Meeting Summary Skill

A modular Claude skill for turning meeting recordings or transcripts into structured, action-ready briefs. Built for use in a meeting recording summary app.

## What it does

Given a meeting transcript, produces:

- **TL;DR** (2–4 sentences, conclusion-first)
- **Key discussion points**
- **Decisions** (with rationale)
- **Action items per person** (with owner, due date, confidence)
- **Type-specific extraction** (e.g. MEDDIC-lite for sales, ADRs for architecture, CAPS for 1:1s)
- **Open questions, risks, follow-ups**

Output is Markdown by default; JSON on request (schema in `shared/core-output.md`).

## Structure

```
meeting-summary/
├── SKILL.md                         # parent skill — universal core, type routing
├── README.md                        # this file
├── shared/                          # extractor logic used by every type
│   ├── action-items.md              # vague-item refusal, owner attribution, due-date inference
│   ├── decisions.md                 # decision vs discussion, rationale, deferred decisions
│   ├── attribution.md               # speaker ID, quote attribution, privacy
│   └── core-output.md               # universal output template + JSON schema
└── types/                           # per-meeting-type schemas
    ├── client-discovery.md          # vendor↔buyer, qualification (BANT/MEDDIC-lite)
    ├── architectural-review.md      # technical design, ADR-style decisions, tradeoffs
    ├── scrum-standup.md             # round-robin, blockers, escalations
    ├── development-session.md       # working code session, gotchas, TODOs
    ├── exploration.md               # open-ended analytical ideation, hypotheses, references
    ├── retrospective.md             # what went well/didn't, start-stop-continue
    ├── one-on-one.md                # CAPS framework, separated commitments, privacy
    ├── user-interview.md            # JTBD, verbatim quotes, hypothesis tracking
    ├── interview-hiring.md          # candidate evaluation, competency rubric, hire/no-hire
    └── brainstorm-creative.md       # divergent creative ideation, idea inventory, themes
```

## How it works

When the skill is invoked:

1. **Identify meeting type** — either from explicit metadata (preferred — the app should set this at recording time) or by classifying the transcript.
2. **Load shared modules** — `attribution.md`, `action-items.md`, `decisions.md`, `core-output.md`.
3. **Run universal extraction** — TL;DR, key discussion points, decisions, action items per person, open questions, risks, follow-ups.
4. **Run type-specific extraction** — load the matching `types/<type>.md` and add its fields.
5. **Assemble and quality-check** — verify confidence flags, empty-field handling, no fabrication.

The architecture is **additive**: type-specific output adds sections to the universal core, it doesn't replace it (with two narrow exceptions — `architectural-review.md` upgrades the Decisions section into ADR shape, and `scrum-standup.md` replaces Key Discussion Points with the round table).

## Invoking from the app

Recommended: pass meeting type explicitly.

```
System prompt fragment:
  Use the meeting-summary skill.
  meeting_type: client-discovery
  participants: [{"name": "Sarah Chen", "role": "PM"}, ...]
  prior_context: <last meeting summary or project brief, optional>
  format: markdown  // or json

User message:
  <transcript here>
```

If `meeting_type` is omitted, the skill will classify from the transcript. Classification is decent but not perfect — set the type at recording time when possible.

## Adding a new meeting type

1. Create `types/<your-type>.md` following the structure of an existing one. Include:
   - When to use this sub-skill (signals in the transcript)
   - What fields it adds to the universal core
   - Markdown output format with at least one mini example
   - JSON shape for the `type_specific` field
   - Quality check before output
2. Add a row to the routing table in `SKILL.md` (under "Step 1 — Identify meeting type").
3. Update this README's structure tree.
4. Test with a sample transcript of that type.

## Design principles baked in

- **Empty fields are signal, not failure.** For frameworks like MEDDIC, an empty field shows what the rep needs to learn next. The skill never fabricates.
- **Per-person action items are the highest-leverage output.** They get a dedicated section, with owner attribution rules that refuse vague items.
- **Verbatim quotes only.** Never paraphrase and present as a quote. This is enforced in the user-interview and exploration sub-skills especially.
- **Privacy by default for 1:1s.** Sensitive content is summarized at low fidelity; off-the-record content is redacted entirely.
- **Length matches the meeting.** A 7-minute standup gets a tiny summary. A 90-minute exploration gets room to breathe.
- **Type-specific extraction is opt-in, not implicit.** The universal core is always present; type sections add to it.

## Suggested next steps after install

1. **Test on a few real transcripts** — one of each type you actually run. Compare output to what you'd write yourself.
2. **Tune the routing classifier** — if auto-classification is unreliable on your data, lean harder on the app-level type tagging.
3. **Iterate on the action-item extractor** — this is where output quality lives or dies. If you find vague items slipping through, sharpen the rules in `shared/action-items.md`.
4. **Consider extractor composition (Option D)** — once you have 8+ sub-skills running, the same extractors (action items, decisions, risks) repeat across many. Refactoring toward composable extractors is the natural next architectural step.

## Possible additional sub-skill types (not built yet)

If your usage grows, these are the next types worth adding:

- `board-meeting.md` — strategic decisions, financial implications, governance, formal resolutions
- `client-status.md` — recurring client check-in, deliverables, scope, billing context
- `vendor-supplier.md` — manufacturing/supplier calls (orders, lead times, quality issues, payments) — relevant for ATMOSA
- `performance-review.md` — formal evaluation, ratings, goals, development plan
- `negotiation.md` — positions, interests, BATNA, concessions made, open terms
- `incident-postmortem.md` — incident timeline, root cause, contributing factors, action items (specialized retrospective)
