# Sub-skill: One-on-One

## When to use this sub-skill

Use this when the meeting is a **two-person check-in** that mixes work, growth, morale, and personal topics. Signals:

- Two participants only
- Mix of tactical updates, project discussion, career/growth conversation, and personal context
- Vocabulary: how are you, growth, blockers, support, feedback, career, manager
- Often recurring (weekly, biweekly)

This includes manager↔report 1:1s, peer-to-peer 1:1s, mentor↔mentee, and skip-level meetings. The sub-skill applies to all of them.

Distinct from **performance review** (formal, evaluative) — though performance topics may surface in a 1:1.

## Privacy first

1:1s often contain sensitive content: morale, frustrations, career intent, personal life context, health, family, interpersonal friction. **Default to lower fidelity** in the summary than for other meeting types:

- Don't reproduce verbatim quotes about personal/health/family topics unless explicitly requested.
- Summarize sensitive disclosures at the level needed for action items to make sense; flag with `[sensitive]` rather than detailing.
- If the report says "this stays between us" about anything, that content is redacted from the summary entirely. The summary can note `[redacted at participant's request]` if context is needed for downstream items.
- If the meeting touches on potential HR-relevant content (harassment, discrimination, distress), the summary should note its presence at high level but not repeat content. Flag with `[note: may need HR-appropriate handling]`.

## What this sub-skill adds to the universal core

A type-specific section called **1:1 Notes**, structured around the **CAPS** framework (Connect, Align, Progress, Support). The action items section is **split** into two: things the manager committed to, and things the report committed to. This is a high-leverage structural choice — without it, action items routinely drift to the report and the manager's commitments get forgotten.

## Fields to extract

### Connect
How the person is doing — energy, mood, broader context. This is *the* most-skipped section in 1:1 notes and one of the most valuable to capture (lightly).
- `wellbeing` — high-level read on how the person is doing. *Lightly.* "Sounded energized." "Mentioned feeling stretched." Don't transcribe personal details.
- `personal_context` — only if explicitly relevant to work (vacation upcoming, family commitments affecting capacity). Skip otherwise.

### Align
Priorities and direction.
- `priorities_this_period` — what they're focused on
- `priorities_clarification` — anything they raised about being unclear on direction or priorities
- `goals_growth` — career goals, growth conversations, anything about where they're heading
- `feedback_given` — feedback the manager gave (briefly; the substance matters more than the wording)
- `feedback_received` — feedback the report gave to the manager (capture this carefully — it's gold)

### Progress
What's moving and what's stuck.
- `wins` — things that went well, things they shipped, recognition moments
- `blockers` — what's in their way; what kind of help they need
- `concerns_raised` — things they're worried about (project, person, system)
- `risks_flagged` — risks they want the manager aware of

### Support
What they need from the manager / from the org.
- `asks` — explicit asks for support, resources, intros, time, decisions
- `manager_to_unblock` — things the manager committed to handle on their behalf

### Splitting commitments
- `manager_commitments` — every action item the manager took on
- `report_commitments` — every action item the report took on

These flow into the Action Items section, but keep them visually separated there too.

## Output format

Insert this section after **Decisions** in the universal template:

```markdown
## 1:1 Notes — [Manager] ↔ [Report]

### Connect
Sounded steady. Mentioned the holiday next week — back on Monday Mar 18.

### Align
- **Current priorities:** v2 onboarding (primary), API cleanup (secondary).
- **Priority ambiguity raised:** Wasn't sure whether the export feature is still expected this sprint or moved out. *Resolved in the meeting:* moved to Sprint 24.
- **Growth:** wants more architectural exposure; would like to lead the next architectural review.
- **Feedback given (manager → report):** PR descriptions have been excellent — keep doing that; would like to see more proactive comms when timelines slip.
- **Feedback received (report → manager):** Reported feeling that mid-sprint scope changes are happening too often. Wanted manager aware. [sensitive — surfaced gently]

### Progress
- **Wins:** Auth refactor merged; positive feedback from QA on the new error handling.
- **Blockers:** Waiting on schema review from Tom — second day. Manager to nudge.
- **Concerns:** CI is slow enough that it's affecting their ability to do small iterative PRs. Brought this up at last retro too.

### Support
- **Asks:** Wants to be looped into the architectural review for the streaming pipeline (lead opportunity).
- **Manager to unblock:** schema review delay; CI slowness escalation.

### Manager Commitments
- Loop them into the streaming pipeline architectural review (Manager → invite by Mon Mar 11).
- Nudge Tom on schema review (Manager → today).
- Raise CI slowness with the platform team this week (Manager → by Fri Mar 15).
- Talk to Jane about scope-change pattern from the retro (Manager → by Wed Mar 13).

### Report Commitments
- Send the auth refactor postmortem doc by Wed Mar 13.
- Draft a one-pager for the export feature deferral so Jane has context (by Tue Mar 12).
```

## Mini example — light 1:1

```markdown
## 1:1 Notes — Philipp ↔ Brian

### Connect
Both feeling good about the week. No personal context flagged.

### Align
- **Priorities:** Hermes agent fix-brief; Coach OS skill-creator processing.
- **Growth:** Brian wants more reps on routing decisions; suggested he lead the next exploration on H1.

### Progress
- **Wins:** Cura MCP server stable for the past week.
- **Blockers:** None active.

### Support
- **Asks:** Brian wants Philipp's review on the routing eval design before running the test.

### Manager Commitments
*(peer 1:1, no manager hierarchy — using "Philipp commitments" instead)*
- Review Brian's eval design draft by Wed.

### Report Commitments
*(using "Brian commitments")*
- Share eval design draft by Tue.
- Lead the H1 hypothesis test setup.
```

## JSON shape for `type_specific` field

```json
{
  "connect": {
    "wellbeing": "string|null",
    "personal_context_relevant_to_work": "string|null"
  },
  "align": {
    "priorities_this_period": ["string"],
    "priority_clarifications": [{"item": "string", "resolved": "boolean", "resolution": "string|null"}],
    "goals_growth": "string|null",
    "feedback_given": ["string"],
    "feedback_received": ["string"]
  },
  "progress": {
    "wins": ["string"],
    "blockers": ["string"],
    "concerns": ["string"],
    "risks_flagged": ["string"]
  },
  "support": {
    "asks": ["string"],
    "manager_to_unblock": ["string"]
  },
  "manager_commitments": [
    {"task": "string", "due_date": "YYYY-MM-DD|null"}
  ],
  "report_commitments": [
    {"task": "string", "due_date": "YYYY-MM-DD|null"}
  ],
  "redactions": [
    {"reason": "off_the_record|sensitive|hr_relevant"}
  ]
}
```

## Quality check before output

- Manager and report commitments are visually separate in the action items area, not commingled.
- Sensitive content is summarized at low fidelity. The summary is going somewhere — assume it could be read by people other than the two participants.
- Feedback received (report→manager) is captured carefully. This is the rarest and most valuable signal in 1:1 notes; don't lose it.
- "Connect" stays light. A 1:1 summary that reproduces a personal disclosure is a privacy failure, even if extracted faithfully from the transcript.
- If anything was marked off-the-record, it's redacted entirely — including from action items derived from it. If a derived action item can't stand on its own without context, it gets a `[note: context redacted at participant's request]` tag.
