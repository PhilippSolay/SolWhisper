# Sub-skill: Brainstorm (Creative)

## When to use this sub-skill

Use this when the meeting is **divergent creative ideation** — design, marketing, naming, campaign, product concept generation. Signals:

- Many ideas thrown out in quick succession; few are deeply analyzed in the moment
- Vocabulary: "what if", "yes-and", "could we…", "wild idea but…"
- Visual/affective references (mood boards, "feels like X", "vibes of Y")
- Explicit divergent-then-converge structure, or the group agrees to defer evaluation
- Output is a list of candidates to take forward, not a decision

Distinct from **exploration** (analytical / research-flavored open-ended discussion) and from **architectural-review** (technical tradeoffs with concrete decisions).

## What this sub-skill adds to the universal core

A type-specific section called **Idea Inventory**, structured to feed the next-step convergence stage. The summary captures *all* ideas raised — even bad ones — because in creative work, a "bad" idea is often the seed of a good one a week later.

Two replacement notes vs the universal core:
- The **Decisions** section is usually thin or empty for a brainstorm; that's correct. If the group did pick a direction, capture it in the universal Decisions section as normal.
- The universal **Key Discussion Points** section becomes terse — the substance is the idea inventory below.

## Fields to extract

### Frame
- `prompt` — what the group was ideating around (one or two sentences)
- `constraints` — known constraints called out at the start ("must ship Q4", "B2B audience", "no new infra")
- `inspiration` — references / examples / mood boards mentioned

### Idea inventory
For each distinct idea raised:
- `title` — a short, evocative label (3-8 words). Use the speaker's framing if they used one.
- `description` — 1-3 sentences capturing the core
- `proposed_by` — speaker (use `shared/attribution.md` rules; "anonymous" if not clearly attributable in a fast-moving session)
- `built_on` — name of an earlier idea this riffs on, when there's a clear line ("yes-and Idea 3")
- `signal` — `enthusiastic` (multiple +1s, "ooh", laughter, immediate yes-and) | `mixed` (someone pushed back) | `neutral` (raised, not engaged with) — based on observed reactions, not the model's judgment

### Themes
Group ideas into 3-6 emergent clusters. Don't force structure that wasn't there — if the session was scattered, write fewer clusters and say so.
- `theme` — short label
- `idea_titles` — which ideas belong here

### Top picks (only if explicitly surfaced)
- `top_picks` — ideas the group voted up, starred, or explicitly said "let's pursue this". **If no convergence happened, this section is empty.** Don't pick favorites for them.

### Parking lot
- `deferred` — ideas explicitly tabled with a reason ("good for v2", "too expensive", "wrong audience")
- `wild_cards` — ideas that got laughs but no real engagement, surfaced for completeness because they're often unexpectedly fertile later

### Next steps for convergence
- `who_will_pick` — name + when, if specified
- `evaluation_criteria` — how the group plans to choose between ideas
- `prototyping_actions` — sketches, mockups, prototypes someone agreed to make

## Output format

Insert in place of the universal **Key Discussion Points** section, immediately before **Decisions**:

```markdown
## Idea Inventory

### Frame
**Prompt:** Naming for the new compliance product launching Q1.

**Constraints:** B2B SaaS audience; .com or .ai available; not too on-the-nose ("compliance"-y); two-syllable or short.

**Inspiration:** Notion (everyday word + tech feel); Linear (linguistic, sharp); Stripe (concrete, tactile)

### Ideas

| Title | Description | Proposed by | Built on | Signal |
|---|---|---|---|---|
| Sentry | Watchful, protective. Available .com? Sarah to check. | Mark | — | enthusiastic |
| Lighthouse | Guides you through compliance fog. | Tara | — | mixed (Sarah: "feels too saved-by-the-light") |
| Vellum | Ancient document feel + soft sound. | Sarah | yes-and on Lighthouse's "old-meets-new" angle | enthusiastic |
| Spelunk | Adventure into your compliance cave. | Mark | — | neutral (laughs, no follow-up) |
| Verdict | Decisive, legal-flavored. | Tara | — | mixed (Mark: "too final — feels like end state") |
| Glyph | Symbolic, tech-y, unique. | Sarah | — | enthusiastic |

### Themes
- **Watchful / protective:** Sentry, Lighthouse
- **Document / artifact:** Vellum, Glyph
- **Outcome-flavored:** Verdict
- **Adventure / discovery:** Spelunk

### Top picks
The group landed on three for next-round evaluation: **Sentry, Vellum, Glyph**. Verdict and Lighthouse explicitly out (too "end-state" / cliché). Spelunk parked.

### Parking lot
- **Verdict** — Mark felt it implies finality; doesn't fit ongoing-monitoring positioning
- **Lighthouse** — Sarah felt overplayed in fintech
- **Spelunk** — wild card; not pursued but kept for the file

### Next steps
- **Sarah** — domain availability check on Sentry, Vellum, Glyph (.com + .ai), trademark scan, by Friday
- **Tara** — sketch one logo direction per pick by next session
- **Group** — reconvene Thursday to converge to one
```

## Mini example — quick "name this thing" session

```markdown
## Idea Inventory

### Frame
**Prompt:** What to call the internal weekly retro Slack channel.

### Ideas

| Title | Description | Proposed by | Signal |
|---|---|---|---|
| #the-mirror | Reflect on the week | Tom | enthusiastic |
| #monday-blues | On the nose | Mark | mixed |
| #postmortem-no | Joke entry | Sarah | wild card |

### Top picks
**#the-mirror** picked unanimously.

### Next steps
- Tom — create channel today
```

## JSON shape for `type_specific` field

```json
{
  "frame": {
    "prompt": "string",
    "constraints": ["string"],
    "inspiration": ["string"]
  },
  "ideas": [
    {
      "title": "string",
      "description": "string",
      "proposed_by": "string",
      "built_on": "string|null",
      "signal": "enthusiastic|mixed|neutral"
    }
  ],
  "themes": [
    {"theme": "string", "idea_titles": ["string"]}
  ],
  "top_picks": ["string"],
  "parking_lot": [
    {"title": "string", "reason": "string"}
  ],
  "wild_cards": ["string"],
  "next_steps": {
    "who_will_pick": "string|null",
    "evaluation_criteria": ["string"],
    "prototyping_actions": [
      {"owner": "string", "action": "string", "due": "string|null"}
    ]
  }
}
```

## Quality check before output

- Every idea is in the inventory, even the bad ones. The point is the breadth of options, not a curated highlight reel.
- Signals come from observed reactions in the transcript, never from the model's taste. If two people +1'd, it's `enthusiastic`. If nobody reacted, it's `neutral` — don't promote it just because it was clever.
- Themes are emergent. If the session was scattered, three themes is plenty. Forcing six won't help.
- Top picks are **only** filled when the group explicitly surfaced winners. If the meeting ended without convergence, this section is empty — don't pick favorites for them.
- Wild cards stay in the file with their original framing — including the laughter. Do not editorialize ("though clearly impractical").
- Next steps don't get fabricated. If the group didn't agree on who picks, leave `who_will_pick` empty.
