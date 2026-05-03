# Decision Extraction

A decision is a moment where the group commits to a course of action. Decisions are different from discussion points (which describe what was talked about) and from action items (which describe who does what next). They're the "we will do X, not Y" moments — and they're the layer of meeting output that has the longest shelf life. Six months from now, nobody will reread the discussion, but they'll absolutely look up "why did we choose this approach?".

## What counts as a decision

A decision has three components:
1. **A choice made** — typically picking one option from several considered
2. **An explicit or strongly-implied commitment** from the group, not a single voice
3. **A change in what happens next** — if nothing changes, it wasn't really a decision

Examples that *are* decisions:
- "OK, we'll go with Postgres for the primary store and revisit if we hit scale issues."
- "Let's ship the v1 without the export feature. We'll add it in v1.1."
- "Pricing stays at $29. We're not testing $39 right now."

Examples that are *not* decisions (these go elsewhere):
- "Postgres seems like a good fit for our use case." → Discussion point.
- "We should probably ship without export." → Open question or recommendation.
- "I think $29 is the right price." → Opinion. If the group converges on it and commits, then it's a decision.

## Required fields per decision

| Field | Description |
|---|---|
| `decision` | One sentence. The choice made, in present tense. "We will use Postgres for the primary data store." |
| `rationale` | Why. The key reasons stated in the meeting. Not invented justification — only what was actually said. |
| `alternatives_considered` | What else was on the table, briefly. Omit if no alternatives were discussed. |
| `decided_by` | Who made the call. Often the group; sometimes a specific person. Use "team" or a name. |
| `revisit_when` | If the decision was made conditionally ("we'll revisit if X"), capture the trigger. Omit otherwise. |

## Deferred decisions

Sometimes the group explicitly punts a decision — "let's decide this next week after we have data X." Capture these in a separate **Deferred Decisions** subsection, not under regular Decisions. Each deferred decision needs:
- What needs to be decided
- What's blocking the decision (information needed, person needed, etc.)
- When the group plans to decide
- An action item assigned for whatever needs to happen first (this duplicates into Action Items — that's fine, it's intentional)

## Decisions made unilaterally

If one person makes a call without group buy-in (e.g. "I've decided we're going with X"), capture it as a decision but record `decided_by: <name>` rather than "team". This is honest reporting — these decisions exist and matter, but they're a different beast than consensus decisions.

## What if there's disagreement?

If the group discussed a topic but didn't converge on a decision, **do not invent one**. Put it under **Open Questions** with a note about where the discussion landed:

> **Open Question — primary database choice.** Postgres and DynamoDB were both proposed. Sarah favored Postgres for query flexibility; Mark favored DynamoDB for operational simplicity. No decision reached; deferred to next architectural review.

Same rule applies if the recording cuts off mid-discussion.

## Output format

```markdown
## Decisions

1. **We will use Postgres as the primary data store for v1.**
   *Rationale:* Team has the most operational experience with it; query flexibility outweighs the operational simplicity of DynamoDB at our scale; aligns with existing analytics tooling.
   *Alternatives considered:* DynamoDB, MongoDB.
   *Decided by:* engineering team consensus.
   *Revisit when:* write throughput approaches 10k/s sustained.

2. **Ship v1 without the CSV export feature.**
   *Rationale:* Out of scope for the launch deadline; only 2 of 30 beta users requested it.
   *Decided by:* team.

## Deferred Decisions

1. **Pricing for the team plan tier.**
   *Blocked on:* benchmarking data from Sarah's customer interview round.
   *Plan to decide:* next product sync (Mar 22).
   *Related action:* Sarah to share pricing benchmark by Mar 20.
```

## Quality check before output

- Every decision has rationale. If you can't extract rationale from the transcript, the field reads `rationale: not stated explicitly` — don't invent one.
- Decisions are stated in present-tense commitment form ("We will...") not past discussion form ("It was discussed that...").
- Deferred decisions have a real plan to decide, not "we'll figure it out". If there's no plan, it's an Open Question, not a Deferred Decision.
