# Sub-skill: Scrum Standup

## When to use this sub-skill

Use this when the meeting is a **short, structured, recurring team check-in** following the standard standup pattern. Signals:

- Round-robin format (each person reports in turn)
- Short duration (typically 5–20 minutes)
- Vocabulary: yesterday, today, blockers, sprint, ticket, PR, deploy
- The same set of people recurs across meetings

This sub-skill is **lighter** than most. Standups don't usually generate meaty decisions or rich discussion — they're a status sync. The output should match: short, scannable, focused on what changed and what's stuck.

## What this sub-skill adds to the universal core

A type-specific section called **Standup Round**, which replaces the universal Key Discussion Points (those don't fit the format). Decisions, action items, and the rest stay as-is.

The summary should be **as terse as possible while still being useful** — most standup summaries should be readable in 30 seconds.

## Fields to extract

### Per-person status
For each attendee:
- `name`
- `yesterday` — what they reported completing or working on
- `today` — what they plan to do
- `blockers` — anything in their way; if none stated, write `none`

### Cross-team signals
- `escalations` — anything raised that needs attention beyond this standup (decisions to make elsewhere, help needed from outside the team)
- `dependencies` — things one person is waiting on from another, on or off team
- `risks_to_sprint` — slip signals: items pushed for the second day in a row, scope expansion, blockers older than 24h

### Sprint context (when discussed)
- `sprint_progress` — any explicit progress signals ("we're at 60% with 2 days left")
- `done_today` — items finished or shipped (worth surfacing)

## Output format

Replace the universal **Key Discussion Points** section with this:

```markdown
## Standup Round

| Person | Yesterday | Today | Blockers |
|---|---|---|---|
| Sarah | Wrapped onboarding flow PR; reviewed Mark's API changes | Pair with Tom on auth refactor; ship feature flag rollout | None |
| Mark | API endpoint cleanup; merged 2 PRs | Start work on the export ticket | Waiting on schema review from Tom |
| Tom | Schema design draft | Review session with Mark; continue auth refactor | None |

### Cross-team / Escalations
- **Mark blocked on Tom's schema review** — second day. Tom to prioritize this morning.
- **Question for product:** does the export feature need CSV + JSON or just CSV? Sarah to ask Jane.

### Sprint Signals
- 4 of 8 sprint items in progress, 1 done, 3 not yet started — on track but tight.
- Auth refactor has slipped from yesterday's plan; not yet a slip risk but watch tomorrow.
```

## Mini example — all-clear standup

When nothing eventful happens, the output should reflect that and stay short:

```markdown
## Standup Round

| Person | Yesterday | Today | Blockers |
|---|---|---|---|
| Sarah | Continued onboarding flow work | More onboarding flow | None |
| Mark | API tests | Review PRs; start on export feature | None |
| Tom | Schema draft | Finalize schema; review with Mark | None |

### Cross-team / Escalations
None.

### Sprint Signals
On track. No risks raised.
```

## Mini example — empty standup

Some days there's nothing to summarize. Don't pad.

```markdown
## Standup Round

Brief check-in: 4 minutes. No blockers raised. Everyone continuing yesterday's work. No escalations.
```

## Action items in standups

Standups occasionally generate action items (someone agrees to escalate, ask a question, schedule a meeting). Capture them per the universal rules in `shared/action-items.md`. But don't manufacture them — most standup items are just continuations of ongoing work, not new commitments.

If the most "action item" you can extract is "everyone continues their current sprint work," produce an empty Action Items section with the standard "no action items committed" note.

## JSON shape for `type_specific` field

```json
{
  "standup_round": [
    {
      "name": "string",
      "yesterday": "string",
      "today": "string",
      "blockers": "string|null"
    }
  ],
  "escalations": ["string"],
  "dependencies": [
    {"who": "string", "waiting_on_what": "string", "from_whom": "string"}
  ],
  "risks_to_sprint": ["string"],
  "sprint_progress": "string|null"
}
```

## Quality check before output

- Length should match the meeting. A 7-minute standup gets a tiny summary.
- Don't fabricate blockers when none were stated. `none` is a valid and common answer.
- The escalations section is for things that need attention *outside* this standup — not for re-listing the blockers row.
- Sprint signals come only from things actually said. Don't infer "on track" from absence of complaints.
