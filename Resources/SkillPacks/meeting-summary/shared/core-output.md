# Core Output Template

This is the universal output structure used for every meeting type. Type-specific sections (defined in `types/*.md`) insert into this template at the marked positions.

## Section ordering

The output sections, in order:

1. **Metadata** (top of doc)
2. **TL;DR** (the most important section — readers may stop here)
3. **Key discussion points**
4. **Decisions** (and Deferred Decisions if any)
5. **Type-specific sections** ← inserted here, see `types/<type>.md`
6. **Action Items per Person**
7. **Action Items (all, by date)**
8. **Open Questions**
9. **Risks & Blockers**
10. **Follow-ups & Next Steps**
11. **Notes** (footer — caveats, ambiguities, redactions)

## Markdown template

```markdown
# Meeting Summary — [Title]

**Type:** [client-discovery | architectural-review | scrum-standup | development-session | exploration | retrospective | one-on-one | user-interview | unclassified]
**Date:** YYYY-MM-DD
**Duration:** [HHh MMm]
**Attendees:** [names, comma-separated]
**Absent:** [if any expected attendees missed]

---

## TL;DR

[2–4 sentences. Conclusion first. A reader who reads only this should know:
1. What the meeting was about
2. The most important outcome
3. What's expected of them, if anything]

---

## Key Discussion Points

[Substantive topics covered, in topical (not chronological) order. Each point is 1–3 sentences. Aim for 3–7 points; collapse trivial ones. This is *not* a play-by-play.]

- **[Topic 1]:** [What was discussed — the substance, not the back-and-forth.]
- **[Topic 2]:** [...]

---

## Decisions

[See shared/decisions.md for format. Numbered list with rationale.]

## Deferred Decisions

[Only if applicable. Otherwise omit the section entirely.]

---

[TYPE-SPECIFIC SECTION INSERTS HERE — see types/<type>.md]

---

## Action Items per Person

[See shared/action-items.md for format. Grouped by owner.]

## Action Items (all, by date)

[Same items, flat table view, sorted by due date.]

---

## Open Questions

[Things raised but not resolved. These are *not* action items — they're questions whose answers don't have an owner yet.]

- [Question 1]: [brief context]
- [Question 2]: [brief context]

---

## Risks & Blockers

[Things that could prevent progress, surfaced for escalation. Different from open questions: these are known threats, not unknowns.]

- **[Risk 1]:** [what it is, who/what it threatens, who raised it]

---

## Follow-ups & Next Steps

- **Next meeting:** [date/time if scheduled, or "TBD" with owner of scheduling]
- **Prep needed:** [what attendees should review/prepare before next time]
- **Waiting on:** [external inputs or other meetings that block progress]

---

## Notes

[Footer for caveats: type ambiguity, attribution issues, redactions, transcript quality issues. Omit the section if there are none.]
```

## Length guidance

A summary should respect the reader's time. As rough targets:

| Meeting length | Summary target | Cap |
|---|---|---|
| <15 min (standup) | 150 words | 250 |
| 15–30 min | 250 words | 400 |
| 30–60 min | 400 words | 600 |
| 60–90 min | 500 words | 800 |
| >90 min | 600 words | 1000 |

Action item details and decision rationale don't count against the cap — those are reference material. The cap applies to TL;DR + Key Discussion + Open Questions + Risks + Follow-ups.

If the meeting was empty (e.g. a standup where everyone said "no updates"), produce a 50-word note saying so. Don't pad.

## Empty section handling

- If a section has no content, **omit the entire section** (heading included), except for the required ones: Metadata, TL;DR, and one of Key Discussion Points or Action Items must be present (otherwise this isn't a meeting summary).
- For the type-specific section, omit fields that weren't discussed. **Empty fields are signal, not failure** — see e.g. MEDDIC where empty fields show qualification gaps.

## JSON output

If the calling app requests `format: json`, output a single JSON object with the same field names. Schema:

```json
{
  "metadata": {
    "title": "string",
    "type": "client-discovery | architectural-review | ... | unclassified",
    "date": "YYYY-MM-DD",
    "duration_minutes": 45,
    "attendees": ["Sarah Chen", "Mark Tanaka"],
    "absent": []
  },
  "tldr": "string",
  "key_discussion_points": [
    {"topic": "string", "summary": "string"}
  ],
  "decisions": [
    {
      "decision": "string",
      "rationale": "string",
      "alternatives_considered": ["string"],
      "decided_by": "string",
      "revisit_when": "string|null"
    }
  ],
  "deferred_decisions": [],
  "type_specific": {
    // shape defined per types/<type>.md
  },
  "action_items": [
    {
      "owner": "string|null",
      "task": "string",
      "due_date": "YYYY-MM-DD|null",
      "success_criteria": "string|null",
      "dependencies": ["string"],
      "confidence": "high|medium|low",
      "note": "string|null"
    }
  ],
  "open_questions": [
    {"question": "string", "context": "string"}
  ],
  "risks": [
    {"risk": "string", "raised_by": "string", "impact": "string"}
  ],
  "follow_ups": {
    "next_meeting": "string|null",
    "prep_needed": "string|null",
    "waiting_on": ["string"]
  },
  "notes": "string|null"
}
```

The `type_specific` field's shape is defined in each `types/<type>.md` file. Apps can rely on the rest of the schema being stable across types.
