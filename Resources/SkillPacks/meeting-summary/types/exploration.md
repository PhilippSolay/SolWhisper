# Sub-skill: Exploration

## When to use this sub-skill

Use this when the meeting is **open-ended ideation, brainstorming, or research-mode discussion**. Signals:

- No defined outcome going in (different from a review or a working session)
- "What if..." framing dominates
- References to papers, products, tools, frameworks, prior art
- Wide-ranging — multiple threads, often returning to same themes
- Often happens early in a project, in research phases, or as a "let's think about X" session

Distinct from **architectural-review** (a specific system under review) and **user-interview** (one party is providing data, not co-thinking).

## What this sub-skill adds to the universal core

A type-specific section called **Exploration**, which captures the **divergent thinking** of the meeting in a way that doesn't compress it prematurely. The summary's job here is *not* to converge — it's to faithfully record the surface area of ideas, with enough texture that the participants can pick up the thread later.

This is the one meeting type where **more text in the summary is often correct**. Compressing a 2-hour exploration session into 200 words destroys the value.

## Fields to extract

### Framing
- `central_question` — the question or topic being explored (often phrased as a question even if it didn't come up that way)
- `motivation` — why this exploration is happening now (what's driving it)
- `participants_perspectives` — who came in with what initial leaning, if relevant

### Threads explored
For each meaningful thread (aim for 4–8):
- `thread` — short title
- `summary` — what was said, including dissenting views; preserve disagreement rather than collapsing it
- `key_quotes` — verbatim statements that captured an idea well, with attribution
- `analogies_used` — useful framings or metaphors that emerged

### Hypotheses
- `hypotheses_raised` — claims or guesses about how something works or what would happen, even if speculative
- `evidence_for` — what we have that supports each
- `evidence_against` — what argues against each
- `tests_proposed` — ways to actually find out (research, spike, prototype, experiment)

### References
- `references_mentioned` — papers, tools, products, books, prior projects cited during discussion. Capture name + a one-line "what it is" if context was given.
- `prior_art` — things that have already tried to solve this or adjacent problems

### Surprises & insights
- `surprises` — moments where someone said "huh, I didn't expect that" or "wait, that's interesting"
- `reframings` — moments where the question itself shifted ("we keep asking X but maybe the real question is Y")
- `tensions` — productive disagreements that didn't resolve and probably shouldn't be forced to

### Where it landed
- `convergence` — anything the group actually converged on, even loosely. Often this is "we should pursue X next" rather than a hard decision.
- `divergence` — what's still wide open
- `next_actions` — what to do to advance the thinking (a spike, a doc, a reading, another session)

## Output format

Insert this section after **Decisions** (which will often be empty for explorations) in the universal template:

```markdown
## Exploration

### Central question
**Should our coaching app rely on a single LLM, or should it route between specialized models per task?**

### Motivation
Cost is rising as we scale. Quality varies by task. Both Brian and Philipp have been independently bumping into the same routing question. Time to think about it deliberately.

### Threads explored

**1. Cost vs. quality is task-dependent.**
For habit-tracking nudges, the cheapest model is fine — output is short and templated. For inner-work reflection prompts, model quality clearly matters: Brian's tests showed users dropping out of weak responses within two messages.

**2. The "one model" simplification has real value.**
> "Every router I've ever built ended up being a worse model with more failure modes." — Philipp
Single-model setups debug easier, evaluate easier, and don't have routing-failure bugs (where a query goes to the wrong model). The complexity tax is real and underestimated.

**3. Routing might be necessary not for cost but for capability.**
Some tasks need tool use, some need long-context, some need vision. Even setting cost aside, no current model is the best at *everything*. So a router might be a capability layer, not a cost optimization.

**4. The user-perceived experience changes when latency varies.**
If the cheap model returns in 800ms and the smart model takes 6s, users feel the inconsistency. Either always go slow (cap at the smart model's speed) or always go fast (mask with optimistic UI).

### Hypotheses raised
- **H1:** A two-tier router (cheap-fast for templated tasks, smart-slow for everything else) reduces cost by 40–60% with no quality drop.
  *Evidence for:* anecdotal — both Brian and Philipp have seen this work in their own setups.
  *Evidence against:* every routing layer adds bugs; the savings might disappear in maintenance.
  *Test proposed:* 2-week A/B with routing on vs. all-smart, on a test cohort. Measure cost + retention.
- **H2:** Users prefer consistent latency over variable latency, even if the variable case is sometimes faster.
  *Evidence for:* design pattern in the literature; intuitive.
  *Evidence against:* nothing direct.
  *Test proposed:* perception test — show two prototypes to 5 users.

### References mentioned
- *RouteLLM* (paper) — Berkeley project on learned routing between LLMs. Brian read it last month, said the eval methodology is good.
- *LangChain RouterChain* — built-in but Philipp finds the abstraction leaky.
- *Claude Haiku + Opus pattern* — Anthropic's own example pattern for tiering. Worth re-reading.

### Surprises
- We started arguing about cost and ended up convinced that **capability routing matters more than cost routing** at our current scale. That reframe is probably the most important takeaway.
- Brian thought he was pro-router, Philipp thought he was anti-router; turns out we agreed about ~80% of cases.

### Tensions (productive, unresolved)
- **Build the router ourselves vs. adopt one.** Philipp leaning build (because the existing ones are leaky); Brian leaning adopt (because we don't need another infra to maintain). Probably revisit after the H1 test.

### Convergence
- Worth running H1 (the routing A/B test) — modest investment, clear signal either way.
- The framing has shifted from "should we route to save money" to "should we route to compose capabilities". Future discussions should use the new framing.

### Still open
- What the routing logic actually looks like (heuristics, embedding-based, LLM-as-router, learned).
- Whether to build vs. adopt.
- Evaluation methodology for routing quality.

### Next actions
- Spike H1 test on the existing test cohort — Brian, by next exploration session.
- Read the RouteLLM paper for next session — both.
- Reframe the problem in the project doc — Philipp, by Friday.
```

## Mini example — short exploration

```markdown
## Exploration

### Central question
**Is there a version of our onboarding that doesn't require an account upfront?**

### Threads explored
1. **Anonymous-first onboarding** — let people use it for 5 minutes, then prompt to save. Removes the biggest drop-off.
2. **Save-state friction** — even if we let them in, the save prompt has to feel earned, not nagging.
3. **Anonymous → real account migration** — non-trivial; need to design the data model upfront.

### Hypotheses
- **H1:** Anonymous-first reduces top-of-funnel drop-off by >25%. *Test:* prototype + measure.

### References
- Linear's onboarding flow.
- Notion's "use without account" mode.

### Convergence
Worth a one-week prototype. Philipp to scope, decision next week.

### Next actions
- Philipp to write a one-pager scope by Friday.
- Both to revisit at next sync with the scope.
```

## JSON shape for `type_specific` field

```json
{
  "central_question": "string",
  "motivation": "string|null",
  "threads": [
    {
      "title": "string",
      "summary": "string",
      "key_quotes": [{"quote": "string", "attribution": "string"}],
      "analogies": ["string"]
    }
  ],
  "hypotheses": [
    {
      "id": "H1",
      "statement": "string",
      "evidence_for": ["string"],
      "evidence_against": ["string"],
      "test_proposed": "string|null"
    }
  ],
  "references": [
    {"name": "string", "type": "paper|tool|product|book|other", "context": "string|null"}
  ],
  "surprises": ["string"],
  "reframings": ["string"],
  "tensions": [{"tension": "string", "perspectives": ["string"]}],
  "convergence": ["string"],
  "still_open": ["string"]
}
```

## Quality check before output

- Don't compress to consensus when there wasn't any. Tensions, divergent views, and surprises are the highest-signal output of an exploration — preserve them.
- Quotes should be verbatim. If a phrase captures an idea perfectly, quote it; don't paraphrase and call it a quote.
- Hypotheses without proposed tests are weaker — flag any that have no test proposed and consider whether one is worth suggesting.
- The "convergence" section should be honestly small if convergence was small. Don't manufacture decisions to make the meeting "productive" on paper.
