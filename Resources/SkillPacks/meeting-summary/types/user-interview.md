# Sub-skill: User Interview

## When to use this sub-skill

Use this when the meeting is a **research conversation with a user, customer, or prospect to understand their behavior, problem, or workflow** — *not* a sales conversation. Signals:

- One side asks open-ended questions; the other describes their experience
- The interviewer rarely pitches anything
- Vocabulary: how do you currently, walk me through, what would you, can you tell me about
- Often part of a research round (multiple similar interviews scheduled)

Distinct from **client-discovery** (commercial intent) and **exploration** (co-thinking with peers, not extracting from a participant).

## What this sub-skill adds to the universal core

A type-specific section called **Research Findings**, organized for synthesis across multiple interviews. The output prioritizes **verbatim quotes** and **hypothesis tracking** because these are the artifacts that survive into product decisions weeks or months later.

This sub-skill mostly **replaces** the universal Decisions and Action Items sections at the level of the interview — researcher action items still get captured, but the main "what's actionable" output is the synthesizable findings. A single interview rarely produces decisions; a round of 5–8 of them does.

## Fields to extract

### Participant context
- `participant` — first name or pseudonym (often interviews are anonymized — respect that)
- `segment` — the segment they represent (e.g. "small-team PM", "solo consultant", "enterprise IT lead")
- `relevant_attributes` — what makes them representative or interesting for this round (tools they use, scale, role, geography)
- `recruitment_source` — how they got into the study (existing customer, recruited, referral, cold)

### Their world
- `jtbd` — the job they're trying to get done (in their own framing)
- `current_workflow` — step-by-step how they do it today; capture detail
- `tools_used` — specific products/tools mentioned, with what they use each for
- `frequency_and_volume` — how often they do this, scale (per day, per week, items/sprint, etc.)

### Pain points
For each pain point:
- `pain` — what they described
- `quote` — verbatim, attributed
- `severity` — how acute it is for them (`urgent` / `chronic` / `mild` / `tolerated`); base on signals, not a flat "they said it"
- `workaround` — what they currently do to cope
- `cost` — what it costs them in time, money, errors, frustration (concrete where stated)

### Surprises
Things that didn't match the team's prior model:
- `surprise` — what was unexpected
- `previous_assumption` — what we thought
- `revised_understanding` — what we now think (carefully — one interview is one data point)

### Quotes to keep
A separate verbatim section. These are the ones that capture an idea so well they belong in the synthesis deck, the strategy doc, or pinned on the wall:
- `quote` — verbatim
- `attribution` — participant pseudonym
- `topic` — what it's about
- `why_it_matters` — one line on why it stood out

### Hypotheses
For research rounds, this is the through-line:
- `validated` — hypotheses we came in with that this interview supports (with evidence from the conversation)
- `invalidated` — hypotheses this interview pushes against (with evidence)
- `complicated` — hypotheses this interview complicates rather than cleanly validates or invalidates
- `new_raised` — new hypotheses this interview raised that we should test in subsequent ones

### New questions
- `for_next_interview` — questions this interview surfaced that should be asked of subsequent participants
- `for_synthesis` — questions to revisit when synthesizing across the round

### Researcher action items
Action items the researcher took on (follow-ups, next interview prep, etc.) — these flow into the universal Action Items section as normal.

## Output format

Insert this section after **Decisions** (which will usually be empty for interviews) in the universal template:

```markdown
## Research Findings

### Participant
- **Pseudonym:** P4
- **Segment:** Solo founder, 12-person team, B2B SaaS
- **Relevant attributes:** Uses Linear + Notion + Slack; leads product themselves; ships weekly
- **Recruitment:** Existing user, opted into research panel

### Their world

**Job-to-be-done:** Translate weekly customer feedback into prioritized product changes that get communicated back to customers.

**Current workflow:**
1. Skim Slack #customer-feedback channel daily (~10 min)
2. Tag interesting items with emoji as a casual flag
3. Friday: pull tagged items into a Notion "feedback inbox" page
4. Group by theme manually; pick 1–2 things to commit to next week
5. Reply to customers in Slack with what's planned
6. Update Linear with new tickets

**Tools used:**
- Slack — primary inbound channel for feedback
- Notion — synthesis space, weekly review
- Linear — engineering execution
- Loom — used to send context-rich replies for ~20% of feedback items

**Frequency:** Daily skim; weekly synthesis. Volume ~30–50 items/week. Roughly 4 hours/week total on this loop.

### Pain points

**1. Synthesis is the bottleneck.**
> "I spend like an hour on Friday just trying to remember which Slack message goes with which actual problem. Half the time I lose context." — P4
*Severity:* chronic. Mentioned as the part they dread most about the week.
*Workaround:* The emoji-tagging during the week is itself a workaround for not having a synthesis tool.
*Cost:* ~1.5 hours/week on the synthesis step alone; estimates losing 20% of feedback to context-loss.

**2. Customer comms loop is brittle.**
> "If I forget to ping someone back about their feedback, they think we ignored them. I've lost two customers over this." — P4
*Severity:* urgent — has had concrete commercial cost.
*Workaround:* Personal reminder system in Things 3.
*Cost:* Two churned customers cited explicitly.

**3. Hard to see patterns across feedback.**
*Severity:* mild — flagged but framed as "would be nice".
*Workaround:* None active.

### Surprises
- **Loom is doing more work than expected.** We assumed text replies were the norm; P4 uses video for ~20% of replies and said it's the most-thanked thing they do. *Previous assumption:* text-first. *Revised:* video may be a meaningful share of "good replies".
- **Friday synthesis is dreaded.** We assumed the in-the-moment Slack triage was the painful part. P4 said the in-the-moment part is fine — it's the synthesis that hurts.

### Quotes to keep

> "I spend like an hour on Friday just trying to remember which Slack message goes with which actual problem." — P4
*Topic:* Synthesis pain. *Why it matters:* perfectly captures the context-loss problem we keep hearing.

> "If I forget to ping someone back about their feedback, they think we ignored them. I've lost two customers over this." — P4
*Topic:* Loop closure cost. *Why it matters:* concrete commercial cost — strongest evidence yet that the loop-closure problem is severe.

### Hypotheses

**Validated by this interview:**
- *H2: Synthesis is more painful than triage.* P4's "Friday is the dreaded part" comment supports this. (Now 3 of 4 interviews support; P2 was ambiguous.)
- *H4: Loop closure to the customer matters as much as internal triage.* P4's "two churned customers" data point is the strongest support so far.

**Complicated by this interview:**
- *H1: PMs want a single inbox across channels.* P4 doesn't want a single inbox — they like Slack as the inbox and want help with what comes after. This is the second interview pushing back on H1; worth discussing.

**Not addressed:** H3 (anything about pricing).

**New hypotheses raised:**
- *H7: Video replies are an under-served part of the feedback loop.* Worth probing in P5 and P6.

### Questions for next interview
- Ask explicitly about Friday/end-of-week synthesis — is this a pattern?
- Ask about video vs text replies — anyone else doing this?
- Probe on what "loop closure" looks like in their flow.

### Questions for synthesis
- The H1 pushback now has two data points. At what point do we adjust the framing?
- Loom-as-reply pattern — is this product-specific (P4 has a Loom subscription) or generalizable?
```

## Mini example — short interview

```markdown
## Research Findings

### Participant
- **Pseudonym:** P2
- **Segment:** Mid-market designer

### Their world
**JTBD:** Keep design system tokens in sync between Figma and the codebase.

**Current workflow:** Manual exports + a homemade script.

**Pain points:**
- **Token drift between Figma and code.** *Severity:* chronic.
  > "Every two weeks I find another place where they're different." — P2
  *Workaround:* manual audit every sprint.
  *Cost:* ~3 hrs every two weeks.

### Surprises
- The audit happens by tooling-output-eyeballing, not by a diff tool. We assumed people had built diff tooling. They haven't.

### Quotes to keep
> "Every two weeks I find another place where they're different." — P2

### Hypotheses
**Validated:** H1 (token drift is real and chronic).

### Questions for next interview
- Ask P3 if they've tried any diffing approach.
```

## JSON shape for `type_specific` field

```json
{
  "participant": {
    "pseudonym": "string",
    "segment": "string",
    "relevant_attributes": ["string"],
    "recruitment_source": "string|null"
  },
  "their_world": {
    "jtbd": "string",
    "current_workflow": ["string"],
    "tools_used": [{"tool": "string", "purpose": "string"}],
    "frequency": "string|null",
    "volume": "string|null"
  },
  "pain_points": [
    {
      "pain": "string",
      "quote": "string|null",
      "severity": "urgent|chronic|mild|tolerated",
      "severity_signal": "string",
      "workaround": "string|null",
      "cost": "string|null"
    }
  ],
  "surprises": [
    {
      "surprise": "string",
      "previous_assumption": "string|null",
      "revised_understanding": "string|null"
    }
  ],
  "quotes_to_keep": [
    {"quote": "string", "attribution": "string", "topic": "string", "why_it_matters": "string"}
  ],
  "hypotheses": {
    "validated": [{"id": "string", "evidence": "string"}],
    "invalidated": [{"id": "string", "evidence": "string"}],
    "complicated": [{"id": "string", "evidence": "string"}],
    "new_raised": [{"statement": "string", "test_proposal": "string|null"}]
  },
  "questions_for_next_interview": ["string"],
  "questions_for_synthesis": ["string"]
}
```

## Quality check before output

- Quotes are verbatim and attributed. **Never paraphrase and present as a quote.** This is the one rule that, if broken, makes the whole output untrustworthy for downstream synthesis.
- Severity ratings have a *signal* attached, not just a label.
- Don't generalize from N=1. The summary is *this interview*; cross-interview patterns belong in synthesis, not here. Phrase findings as "P4 said X" rather than "users want X".
- "Hypotheses validated" should cite evidence from this specific interview; don't borrow from prior ones.
- Keep participant identification at the level of pseudonym + segment unless the user explicitly says it's OK to use names. Default to research-ethics caution.
