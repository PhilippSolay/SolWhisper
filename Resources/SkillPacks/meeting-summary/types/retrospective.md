# Sub-skill: Retrospective

## When to use this sub-skill

Use this when the meeting is **looking backward at a sprint, project, incident, or period** to learn from it. Signals:

- "What went well", "what didn't", "what should we change" framing
- Sprint number, project name, or incident referenced
- Team-level reflection rather than individual status
- Vocabulary: retro, post-mortem, lessons learned, start-stop-continue
- Often emotional content — frustration, pride, relief

Distinct from **scrum-standup** (forward-looking status) and **one-on-one** (individual, not team).

## What this sub-skill adds to the universal core

A type-specific section called **Retrospective**, structured around the team's actual reflection. The output preserves dissenting views — not everyone agrees on what went well, and that disagreement is itself signal.

## Fields to extract

### Scope of the retro
- `period_under_review` — sprint number, project, time range, or specific event
- `outcome` — what shipped / what happened (one sentence; this is context, not the retro itself)
- `format` — what format the retro followed if explicit (Start/Stop/Continue, 4Ls, mad/sad/glad, etc.)

### What went well
For each item:
- `item` — the thing that worked
- `raised_by` — who said it
- `agreement` — `consensus` (everyone agreed) / `partial` (some agreed, some didn't or didn't comment) / `single_voice` (one person said it, no echo)

### What didn't go well
Same shape as above:
- `item`, `raised_by`, `agreement`
- Plus `category` (process / tooling / communication / scope / external / interpersonal)

### Patterns
- `systemic_issues` — items that recurred or that the team explicitly flagged as not-the-first-time
- `one_offs` — items the team explicitly said were unusual ("this was a weird sprint")
- This distinction matters: systemic issues need different responses than one-offs.

### Team health signals
Watch for these even if not explicitly raised:
- `morale` — energy in the room, what the team said about how they felt
- `trust` — comments about feeling safe/unsafe to raise issues
- `sustainability` — burnout signals, weekend work mentioned, capacity concerns
- `psychological_safety` — willingness to disagree openly, surface mistakes, ask for help

Only extract what was actually said or strongly implied. Don't psychoanalyze the transcript.

### Actions
- `start_doing` — new practices or behaviors to adopt
- `stop_doing` — things to stop
- `continue_doing` — explicitly affirmed practices to keep
- `experiment` — things to try for one sprint and revisit

Each action item gets an owner and a measurable success criterion (or "we'll know at next retro").

## Output format

Insert this section after **Decisions** in the universal template:

```markdown
## Retrospective

### Scope
**Sprint 23 retro** (Mar 4 – Mar 15). Outcome: shipped the v2 onboarding and 3 of 5 minor improvements; export feature slipped to Sprint 24.

**Format:** Start / Stop / Continue.

### What went well
- **The pair-programming on the auth refactor (consensus)** — Sarah and Tom both highlighted; team agreed it accelerated learning.
- **PR review turnaround stayed under 24h all sprint (consensus)** — first time in 6 sprints.
- **The Tuesday async-only block (partial)** — Mark and Sarah loved it; Tom felt out-of-the-loop on Wednesdays.

### What didn't go well
- **Scope creep on the onboarding feature (consensus, systemic)** — Jane added two flows mid-sprint; team feels this happens nearly every sprint. *Category: scope.*
- **CI slowness (consensus, systemic)** — third sprint in a row this came up. *Category: tooling.*
- **Unclear handoff between design and engineering for the v2 onboarding (partial)** — Tom raised it; Sarah pushed back, noted the spec was clearer than usual. *Category: communication.*
- **Friday deploy froze production for 40 minutes (consensus, one-off)** — addressed in the post-mortem; included here for completeness. *Category: process.*

### Patterns
- **Systemic:** scope creep, CI slowness — both recurring across multiple sprints.
- **One-off:** Friday deploy incident — flagged as unusual, post-mortem already done.

### Team health
- Energy was good — first sprint in a while where the team didn't mention weekend work.
- Sarah commented that "it felt like we had real time to think this sprint" — worth preserving whatever made that possible.
- Tom raised that he sometimes hesitates to push back on Sarah's design decisions. Worth noting.

### Start
- **Block out architectural-review time for major features before sprint planning** — Sarah owns. Goal: catch scope ambiguity before sprint starts. Measure at next retro.
- **Have a 15-min design↔eng kickoff call for any feature touching UI** — Tom owns scheduling.

### Stop
- **Adding mid-sprint scope without team agreement** — team agreement; Sarah to communicate this to Jane. *This depends on Jane's buy-in.*

### Continue
- **Pair programming on tricky refactors** — keep doing.
- **Sub-24h PR review SLA** — keep doing; Mark to add a Slack reminder bot for stale PRs.

### Experiment (1 sprint, revisit)
- **No new tickets after sprint Day 3** — try for Sprint 24, revisit at next retro. Owner: Sarah.
- **Move the Tuesday async-only block to all-day async on Wednesday** — try; revisit. Owner: team.

### Open questions raised
- Is CI slowness a tooling problem or a code-volume problem? Different fixes. Tom to investigate by Sprint 25.
- Should we be doing post-mortems for *all* deploy incidents, or only ones that affect users? Defer.
```

## Mini example — incident retro

```markdown
## Retrospective

### Scope
**Post-mortem: API outage on Mar 8** (45 minutes, partial degradation). Caused by a misconfigured load balancer rule deployed during routine maintenance.

### What went well
- **Detection was fast (consensus)** — Datadog alerted within 90 seconds.
- **Rollback procedure worked (consensus)** — first time we used the new runbook; it held up.

### What didn't go well
- **The misconfig made it through review (consensus, systemic)** — second config-related incident in 3 months. *Category: process.*
- **Status page wasn't updated until 15 minutes in (consensus, one-off)** — owner of status updates wasn't on call. *Category: process.*

### Patterns
- **Systemic:** config changes bypassing real review. Need stronger gates.
- **One-off:** status page lag — owner's on-call rotation was wrong this week.

### Start
- **Require config changes to have an explicit reviewer (not implicit "approve" from the same person who wrote it)** — Tom to update the deploy checklist by Mar 22.
- **Add an automated check that the on-call rotation is correct in PagerDuty + status page tooling** — Mark by Mar 25.

### Continue
- **Datadog alerting** — keep tuning, working well.
```

## JSON shape for `type_specific` field

```json
{
  "scope": {
    "period": "string",
    "outcome": "string|null",
    "format": "string|null"
  },
  "went_well": [
    {"item": "string", "raised_by": "string", "agreement": "consensus|partial|single_voice"}
  ],
  "didnt_go_well": [
    {
      "item": "string",
      "raised_by": "string",
      "agreement": "consensus|partial|single_voice",
      "category": "process|tooling|communication|scope|external|interpersonal|other"
    }
  ],
  "patterns": {
    "systemic": ["string"],
    "one_off": ["string"]
  },
  "team_health": {
    "morale": "string|null",
    "trust": "string|null",
    "sustainability": "string|null",
    "psychological_safety": "string|null"
  },
  "start": [{"action": "string", "owner": "string", "measure": "string|null"}],
  "stop": [{"action": "string", "owner": "string|null", "depends_on": "string|null"}],
  "continue": [{"action": "string"}],
  "experiment": [{"action": "string", "duration": "string", "revisit": "string", "owner": "string"}]
}
```

## Quality check before output

- Preserve disagreement. If two people disagreed about whether something went well, capture both views — don't pick a side.
- The systemic-vs-one-off distinction must be based on what was actually said in the meeting (e.g. "this happens every sprint", "this was unusual"). Don't infer.
- Team health observations come only from explicit signals. Don't speculate about morale from tone.
- Every Start / Stop / Experiment item has an owner. Continue items often don't need one.
- Don't sanitize. If the team said "this sprint sucked", reflect that — softening it loses information the team will want next time.
