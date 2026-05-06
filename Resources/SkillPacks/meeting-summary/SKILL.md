---
name: meeting-summary
description: Summarize meeting recordings or transcripts into a structured brief with TL;DR, decisions, per-person action items, follow-ups, risks, and open questions. Use this skill whenever a meeting transcript, recording, or audio file is provided and the user wants notes, a recap, minutes, action items, or a summary — even if they just say "summarize this call" or paste a transcript without using the word "meeting." Routes to a specialized sub-skill based on meeting type (client discovery, architectural review, scrum standup, development session, exploration, retrospective, one-on-one, user interview, hiring interview, creative brainstorm) for type-specific extraction (e.g. MEDDIC fields for sales discovery, ADR-style decisions for architectural reviews, CAPS for 1:1s, competency rubrics for hiring loops, idea inventory for creative brainstorms).
---

# Meeting Summary

Turn a meeting transcript into a structured, action-ready brief. The skill is composed of three layers:

1. **This file (parent)** — universal extraction, type routing, output assembly.
2. **`shared/`** — extractor logic that's identical across every meeting type (action items, decisions, output format, attribution).
3. **`types/`** — per-meeting-type schemas and templates that add type-specific fields on top of the universal core.

## Workflow

Run these steps in order. Don't skip step 1 even if the meeting type seems obvious.

### Step 1 — Identify meeting type

If the user (or app metadata) specifies the meeting type, use it directly. Otherwise, classify the transcript into one of the supported types below by reading the first 10–20% of the transcript. Look at: who's speaking, what they're trying to accomplish, what artifacts they reference, and what the natural rhythm of the conversation is.

| Type | Signal in transcript | Sub-skill |
|---|---|---|
| Client discovery | Vendor explores buyer's problem, scope, fit; one side asks most of the questions | `types/client-discovery.md` |
| Architectural review | Technical design under discussion, tradeoffs, "should we do X or Y", system diagrams referenced | `types/architectural-review.md` |
| Scrum standup | Round-robin yesterday/today/blockers; short, structured, recurring cadence | `types/scrum-standup.md` |
| Development session | Working through code or implementation, often pair-programming, bugs and design decisions inline | `types/development-session.md` |
| Exploration | Open-ended ideation, "what if", references to papers/tools/products, no defined outcome going in | `types/exploration.md` |
| Retrospective | Looking backward at a sprint/project; what went well, what didn't, what to change | `types/retrospective.md` |
| One-on-one | Two people, manager↔report or peer↔peer, mix of work + personal, growth/career/morale themes | `types/one-on-one.md` |
| User interview | Participant describes their workflow/problem; researcher asks open questions; verbatim quotes matter | `types/user-interview.md` |
| Hiring interview | Candidate is being evaluated for a role; STAR-style answers; competency probing; logistics + recommendation at end | `types/interview-hiring.md` |
| Creative brainstorm | Divergent ideation for naming/design/marketing; "what if", "yes-and"; many ideas in quick succession | `types/brainstorm-creative.md` |

If the transcript clearly doesn't fit any of these (e.g. a board meeting, a workshop, a negotiation), produce just the universal core from step 3 and flag the type as `unclassified` in the output metadata.

If genuinely ambiguous (e.g. could be discovery or could be exploration), pick the closest match and note the ambiguity in a `notes:` field at the bottom of the output.

### Step 2 — Load shared extractors

Read these in order. They define behavior used in every output:

1. `shared/attribution.md` — how to identify speakers, attribute quotes, and handle unnamed participants.
2. `shared/action-items.md` — the rules for extracting per-person to-dos. **This is the highest-value output and the most common failure point.** Read carefully.
3. `shared/decisions.md` — how to distinguish a decision from a discussion and capture rationale.
4. `shared/core-output.md` — the universal output template and section ordering.

### Step 3 — Run universal extraction

Every meeting summary, regardless of type, contains these sections (defined in detail in `shared/core-output.md`):

- **Metadata** — title, date, duration, attendees, type.
- **TL;DR** — 2–4 sentences, conclusion-first (Pyramid Principle). A reader who only reads this should know what happened and what's expected of them.
- **Key discussion points** — the substantive topics, not a play-by-play.
- **Decisions** — what was actually decided, with rationale.
- **Action items per person** — owner, task, due date, confidence flag if anything is fuzzy.
- **Open questions** — raised but not resolved.
- **Risks & blockers** — surfaced for escalation.
- **Follow-ups & next steps** — including next meeting and prep needed.

### Step 4 — Run type-specific extraction

Read the matching `types/<type>.md` and run its additional extractors. Each type file specifies:
- Type-specific fields to extract (e.g. MEDDIC for sales discovery, Start/Stop/Continue for retros)
- Where those fields go in the output (usually a new section between "Decisions" and "Action items")
- Type-specific examples

Type-specific output is **additive**, not replacement. The universal core is always present.

### Step 4.5 — Robustness rules (do not refuse)

The transcript is the source of truth. The user's context (background, type pre-selection, participant list) is **hints**, not constraints. When something looks off, **summarize what's actually there** plus a note explaining the mismatch — never refuse to produce a summary.

Specifically:

- **Single-speaker transcripts are normal for imported files.** SolWhisper only does speaker diarization for live meeting recordings, not file imports. If you only see one stream, treat the speaker as "Speaker" and proceed; don't conclude "this isn't a meeting." Note it once in the `Notes` footer (e.g. "Imported transcript — speaker labels not available") and move on.
- **The transcript content doesn't match the user's context.** Don't refuse. Summarize what the transcript actually contains. Add a `Notes` line explicitly flagging the mismatch ("User context mentioned an architectural review with Pierre, Ricardo, and Didi, but the transcript covers different content. Possible file mix-up or transcription error — please verify.").
- **The transcript content doesn't match the user's selected type.** Same rule: produce the universal core (TL;DR, key discussion points, action items if any) rather than the type-specific framework, and note that the type was overridden because the content didn't fit. The user's pre-selection is a hint, not a contract.
- **The transcript is too short, too noisy, or too fragmentary to summarize meaningfully.** Produce a truthful TL;DR ("This transcript is fragmentary; clearest content was about X."), surface any specific concrete moments you can extract, and add a footer note recommending a higher-accuracy STT model if the audio was speech-rich but the text reads garbled.

The single hard refusal case: the transcript is genuinely empty (zero substantive words). Then say so plainly in the TL;DR and stop.

### Step 5 — Assemble and check

Before returning the output:

- Every action item has an owner and a due date (or an explicit `confidence: low` flag and `unassigned` / `no date stated`).
- The TL;DR doesn't repeat content from later sections — it's the high-altitude take.
- For type-specific frameworks (MEDDIC, CAPS, etc.), **leave fields empty when they weren't actually discussed.** Do not fabricate. The empty fields are the insight.
- Quotes are verbatim and attributed. Don't reword and present as a quote.
- No sensitive content (medical, mental health, legal exposure) is reproduced beyond what's strictly necessary; flag with a `[redacted: <reason>]` placeholder if needed.

## Triggers — when to use this skill

Use this skill whenever:
- A meeting transcript or recording is provided
- The user says "summarize this call / meeting / recording / transcript / sync / standup"
- The user pastes dialogue with multiple speakers and asks for notes, recap, minutes, or action items
- A file at `/mnt/user-data/uploads/` ends in `.txt`, `.vtt`, `.srt`, `.json` (transcript export), or audio formats and the request is about extracting meeting content
- The app sends a transcript with a `meeting_type` field

Do **not** use this skill for:
- Single-speaker monologues (use a regular summarization approach)
- General document summarization
- Voice memos that aren't multi-party conversations

## Output format

By default, output Markdown matching the template in `shared/core-output.md`. If the calling app requests JSON (via a `format: json` instruction or system prompt), output the same fields as a single JSON object — same field names, same nesting.

## Notes for app integration

If this skill is being invoked by Philipp's meeting recording summary app:
- The app should pass `meeting_type` when known (set at recording time, not after) — this is more reliable than transcript classification.
- The app may pass a `participants` list with names and roles — use it for attribution rather than guessing from the transcript.
- The app may pass a `prior_context` blob (previous meeting summary, project brief) — read it before extracting and use it to disambiguate references.
