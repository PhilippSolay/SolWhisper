# Sub-skill: Interview (Hiring)

## When to use this sub-skill

Use this when the meeting is a **hiring interview** — a candidate is being evaluated for a role. Signals:

- Two clear sides: interviewer(s) and candidate
- Vocabulary: experience, role, level, team, salary, "tell me about a time when…"
- STAR-style answers (Situation, Task, Action, Result)
- Questions probe specific competencies (technical, behavioral, leadership)
- Often ends with logistics — next round, references, timeline

Distinct from **user-interview** (the participant describes a *workflow* for product research, not their own qualifications).

## What this sub-skill adds to the universal core

A type-specific section called **Hiring Assessment**, structured to feed an interview-debrief or hiring-committee discussion. The summary is **non-disposable** — it gets read by people who weren't in the room and who may decide on this candidate.

**Bias guardrails are baked into the rules:** capture observed behavior and quoted answers, not inferences about personality. Where the interviewer made a judgment, attribute it ("Sarah felt the answer lacked depth on …") rather than presenting it as fact.

## Fields to extract

### Candidate context
- `candidate_name` — as referenced in the conversation
- `role` — what they're being interviewed for
- `level_signal` — junior / mid / senior / staff / principal, if discussed
- `interviewer_names` — present interviewers (use `shared/attribution.md` rules)
- `format` — behavioral / technical / system design / coding / values / hybrid

### Per-competency signals
For each competency the conversation actually covered:
- `competency` — e.g. "Communication", "Problem-solving", "Ownership", "Team collaboration", "Technical depth: backend"
- `prompts_asked` — what the interviewer probed for (one-line each)
- `evidence` — what the candidate said in response (verbatim quotes for the strongest moments, paraphrased for filler)
- `signal` — `positive` | `mixed` | `concern` | `not_assessed`. **Do not infer signal that wasn't expressed.** If the interviewer didn't react or didn't comment, mark `not_assessed`.

### Strengths and concerns
- `strengths` — what the candidate clearly demonstrated; back each with a specific moment from the transcript
- `concerns` — gaps, missed depth, or red flags raised by the interviewer (not the model's opinion)
- `unknowns` — competencies needed for the role that didn't get explored — flag for the next round

### Recommendation
- `recommendation` — `strong_hire` | `hire` | `lean_hire` | `lean_no_hire` | `no_hire` | `not_stated`. **Only fill if the interviewer actually voiced a recommendation.** Empty is the right answer most of the time.
- `level_recommendation` — same rule
- `rationale` — why, in the interviewer's words

### Follow-ups
- `references_to_check` — names + relationship the candidate offered
- `topics_to_revisit_next_round` — what to push harder on next time
- `logistics` — salary range discussed, start-date constraints, visa / location notes
- `compensation_signals` — only if explicitly mentioned

## Output format

Insert this section between the universal **Decisions** and **Action Items per Person** sections:

```markdown
## Hiring Assessment

### Candidate
- **Name:** Jamie Chen
- **Role:** Senior Backend Engineer
- **Level signal discussed:** Senior (likely L5)
- **Format:** Behavioral + system design

### Per-Competency Signals

| Competency | Signal | Evidence |
|---|---|---|
| Ownership | positive | Drove the migration from monolith to event-driven across 3 teams; "I owned the rollback plan and the comms. Both teams paged me directly during cutover." |
| System design | mixed | Strong on storage tradeoffs (Postgres vs DynamoDB rationale was clear); thinner on cache invalidation and back-pressure. Interviewer paused once to redirect. |
| Communication | positive | Quoted: "I'd want to know what the SLA target is before I commit to an architecture." Asked clarifying questions throughout. |
| Conflict resolution | not_assessed | Topic didn't come up. |

### Strengths
- **Direct ownership of cross-team rollouts** — multiple specific examples with timeline + impact
- **Asks pointed clarifying questions** — surfaced 3 hidden requirements during the system design portion

### Concerns
- **System design depth** — handled storage well but lighter on cache + back-pressure (Sarah noted she had to redirect once)
- **No senior-level scope examples on people management** — likely fine for an IC role but flag if the level discussion lands at Staff

### Unknowns (push next round)
- Behavior under conflicting priorities from multiple stakeholders
- Mentorship / has-mentored experience
- Post-incident retrospective ownership

### Recommendation
- **Stated:** Lean hire (Sarah). Mark made no explicit recommendation in this transcript.
- **Rationale:** "I'd want one more senior IC to verify the system design depth, but ownership signal is strong and that's the bigger gap on our team."

### Follow-ups
- **References:** former manager at Acme (Priya Shah); peer at Bigco (Tom Liu)
- **Logistics:** Comp range $X-$Y discussed; candidate flagged a 3-week notice period; remote OK
- **Next round:** System design loop with Diego; values panel with Tara

```

## Mini example — 30-min behavioral screen

```markdown
## Hiring Assessment

### Candidate
- **Name:** Alex
- **Role:** Product Manager
- **Format:** Behavioral screen

### Per-Competency Signals

| Competency | Signal | Evidence |
|---|---|---|
| Stakeholder management | positive | Ran a 4-team launch with weekly sync; quoted: "I made a single source of truth doc and we cut review meetings in half." |
| Prioritization | mixed | Frameworks were generic (RICE); concrete examples thinner |

### Strengths
- Clear narrative for the Acme launch — outcome and tradeoffs both surfaced

### Concerns
- Prioritization framework was textbook; no story where they pushed back against a strong stakeholder

### Recommendation
- **Stated:** not_stated (interviewer said "I'll write up after I check with Tom")

### Follow-ups
- **Topics for next round:** A time they killed an initiative; how they handle loud-but-wrong stakeholders
```

## JSON shape for `type_specific` field

```json
{
  "candidate": {
    "name": "string",
    "role": "string",
    "level_signal": "junior|mid|senior|staff|principal|not_stated",
    "interviewers": ["string"],
    "format": "string"
  },
  "competencies": [
    {
      "competency": "string",
      "prompts": ["string"],
      "evidence": "string",
      "signal": "positive|mixed|concern|not_assessed"
    }
  ],
  "strengths": ["string"],
  "concerns": ["string"],
  "unknowns": ["string"],
  "recommendation": {
    "rating": "strong_hire|hire|lean_hire|lean_no_hire|no_hire|not_stated",
    "level": "string|null",
    "rationale": "string|null",
    "stated_by": "string|null"
  },
  "follow_ups": {
    "references": ["string"],
    "topics_next_round": ["string"],
    "logistics": "string|null",
    "compensation": "string|null"
  }
}
```

## Quality check before output

- Every signal in the table has a quoted or paraphrased evidence cell. Empty evidence = `not_assessed`.
- Recommendations are only filled when an interviewer actually voiced one. **Most transcripts will have this empty** — that's correct.
- Strengths and concerns name specific moments; no abstract personality claims ("seems confident", "bad culture fit") — those are bias amplifiers.
- Quotes are verbatim; paraphrased lines are clearly framed ("Sarah noted that …", not " ").
- If compensation was discussed, surface it in `logistics` only — don't repeat numbers in other sections.
- No section editorializes the candidate's race, gender, age, accent, or any non-job-relevant attribute. Interviewers' explicit observations about *job-relevant* communication style are kept and attributed.
