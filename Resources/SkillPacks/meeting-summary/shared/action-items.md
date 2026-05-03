# Action Item Extraction

This is the most consequential output of any meeting summary. Vague action items ("someone should follow up") are the #1 failure mode of meeting tools. The rules here exist to make that failure impossible.

## What counts as an action item

An action item is a **concrete task someone committed to do** during the meeting. It is not:
- A discussion point ("we talked about the API")
- An aspiration ("we should really improve onboarding")
- An idea raised but not committed ("maybe we could try X")

Linguistic signals that an action item is being created:
- Explicit commitment: "I'll [verb]", "I'm going to [verb]", "I can have that ready by [date]"
- Direct assignment: "[Name], can you [verb] by [date]?", followed by acknowledgment
- Decision + ownership: "Let's do X. Sarah, you own it."

Linguistic signals that something is **not** yet an action item:
- "Someone should..." (no owner)
- "Maybe we could..." (no commitment)
- "We need to figure out..." (problem, not task)
- "It would be good to..." (aspiration)

If you find one of these without a follow-up that converts it into a commitment, do **not** invent an owner. Record it under **Open questions** or **Parking lot** instead.

## Required fields per action item

Every action item must have:

| Field | Description | If missing |
|---|---|---|
| `owner` | Single person responsible. Full name preferred; first name acceptable. | Mark `unassigned` and flag `confidence: low` |
| `task` | A specific verb-led action. "Send the contract revisions to Acme" — not "follow up with Acme" | Don't extract; it's not actionable |
| `due_date` | Specific date, or relative date pinned to meeting date ("by Friday Mar 15") | Mark `no date stated` and flag `confidence: medium` |
| `success_criteria` | How we'll know it's done. Often implicit in the task. Make explicit if the meeting clarified it. | Omit |
| `dependencies` | What this depends on. Other action items, external inputs, decisions. | Omit if none |
| `confidence` | `high` if owner + task + date are all clearly stated. `medium` if one is fuzzy. `low` if owner or task is unclear. | Default `high` |

## Owner attribution rules

1. Use the speaker's stated name when they commit ("I'll do X" → speaker name).
2. Use the addressed name when they're assigned and acknowledge ("Sarah, can you...?" "Yeah, I got it" → Sarah).
3. If a person is mentioned by role only ("the designer will handle this") and the role maps unambiguously to a known participant, use their name and flag `confidence: medium`.
4. If a person is mentioned by role only and ambiguous, mark `unassigned` with the role in a `note` field — never guess.
5. Never assign action items to people who weren't in the meeting unless they were explicitly named as a delegate ("I'll get Mark to handle the deploy" → owner: Mark, note: "delegated by [speaker]").

## Due date inference

Pin all relative dates to the meeting date. Examples:
- Meeting on Mon Mar 11. "By Friday" → Fri Mar 15.
- Meeting on Mon Mar 11. "End of next week" → Fri Mar 22.
- Meeting on Mon Mar 11. "By the next sync" → use the next-meeting date if stated; else `no date stated, confidence: medium`.
- "ASAP" → `no date stated, confidence: medium, note: "marked ASAP"`.
- "Eventually" / "soon" / "when I get to it" → `no date stated, confidence: low`.

## Per-person grouping

In the output, group action items **per person** (a single section called "Action Items per Person") rather than as one flat list. This is the structure users actually need — they want to see "what am I on the hook for". Within each person's group, list items in date order.

Also produce a flat **Action Items (all)** section right after, sorted by date, for users who want the full picture. The grouping should be a view, not a duplication — same data, two cuts.

When there are unassigned items, put them in a final group called "Unassigned" with a note about why each is unassigned.

## Output format

```markdown
## Action Items per Person

### Sarah Chen
- [ ] **Send revised contract draft to Acme** — due Fri Mar 15. Confidence: high.
- [ ] **Schedule kickoff call with Acme legal team** — due Wed Mar 20. Confidence: high. Depends on: contract draft sent.

### Mark Tanaka
- [ ] **Review Q4 forecast assumptions** — due Tue Mar 12. Confidence: high. Success criteria: comments back to Sarah by EOD.

### Unassigned
- [ ] **Update the deal stage in HubSpot** — due Wed Mar 13. Confidence: low. Note: ownership not stated; likely Sarah but not confirmed.

## Action Items (all, by date)

| Due | Owner | Task | Confidence |
|---|---|---|---|
| Mar 12 | Mark Tanaka | Review Q4 forecast assumptions | high |
| Mar 13 | Unassigned | Update HubSpot deal stage | low |
| Mar 15 | Sarah Chen | Send revised contract draft | high |
| Mar 20 | Sarah Chen | Schedule kickoff with Acme legal | high |
```

## What to refuse

If the entire transcript yields no extractable action items (some meetings genuinely don't produce any — pure exploration, status reads), say so explicitly:

> No action items were committed during this meeting. See **Open questions** and **Follow-ups** for items that may need owners assigned later.

Do not pad the section with weak items to make it look productive. An empty action items section is honest and useful.
