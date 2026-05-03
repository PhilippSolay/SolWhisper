# Sub-skill: Client Discovery

## When to use this sub-skill

Use this when the meeting is a **vendor exploring a buyer's problem to assess fit and scope**. Signals in the transcript:

- One side is asking most of the questions
- Topics include the buyer's current state, problems, goals, decision process
- The vendor is positioning capability without yet pitching a specific scope
- Often the first or second meeting in a sales cycle

Distinct from **user-interview** (which is research, not sales) and **exploration** (which is open-ended without a commercial subtext).

## What this sub-skill adds to the universal core

A type-specific section called **Client Context & Qualification**, inserted after Decisions. It captures what was learned about the prospect, structured as a hybrid BANT/MEDDIC-lite — enough for a services or product business to qualify the opportunity without the heaviness of full enterprise MEDDIC.

## Fields to extract

Extract only what was actually discussed. **Empty fields are the insight** — they show what the vendor needs to learn next. Do not fabricate.

### Buyer profile
- `company` — name, size (employees / revenue if mentioned), industry
- `contact` — name and role of the person(s) on the call
- `their_team` — relevant adjacent team members named
- `geography` — if relevant (timezone, jurisdiction)

### Pain & motivation
- `stated_problem` — the buyer's own words for what's wrong (verbatim quote where possible)
- `current_solution` — what they do today (tools, processes, workarounds)
- `pain_severity` — `urgent` / `important` / `nice-to-have`, with the signal that justified the rating
- `triggering_event` — what made them start looking now (often the most predictive field)

### Outcomes & success
- `desired_outcome` — what "solved" looks like for them, in their words
- `success_metrics` — quantifiable measures they mentioned (e.g. "cut onboarding time by half")
- `who_benefits` — which stakeholders feel the win

### Commercial signals
- `budget` — explicit budget, range, or signal ("we have budget for this", "we'd need to find budget"). Capture exact phrasing.
- `timeline` — when they want to decide; when they want it live; deadline drivers
- `decision_process` — who needs to approve; what their procurement looks like; competing options

### Fit & risk
- `red_flags` — things that suggest poor fit or trouble (no budget, unclear authority, "shopping" vs buying, scope creep signals)
- `green_flags` — strong-fit signals (clear pain, named champion, defined budget)
- `competitors_mentioned` — other vendors or in-house options on the table
- `objections_raised` — concerns the buyer voiced; how they were addressed

## Output format

Insert this section after **Decisions** in the universal template:

```markdown
## Client Context & Qualification

### Buyer
- **Company:** Acme Corp (~80 employees, B2B SaaS, US-based)
- **Contact:** Jane Park, Head of Operations
- **Their team:** Mentioned working with Tom (CTO) on technical decisions

### Pain
- **Problem:** > "We're spending two days a week just reconciling data between systems."
- **Current solution:** Manual exports to Excel, weekly review meetings.
- **Severity:** Urgent — Jane said this is blocking a Q3 OKR.
- **Triggering event:** New CFO joined in January and asked for clean weekly reporting.

### Outcomes
- **Desired outcome:** Automated reconciliation with same-day visibility.
- **Success metrics:** Cut reconciliation time from 16 hrs/week to <2 hrs/week. Reduce reporting errors to zero.
- **Who benefits:** Operations team (time back), CFO (clean numbers), CEO (faster decisions).

### Commercial
- **Budget:** > "We have budget allocated for this — we set aside roughly 50k for the year." (Confirmed.)
- **Timeline:** Wants a decision in 4 weeks; live within 8 weeks of kickoff.
- **Decision process:** Jane decides; Tom signs off on technical fit; CFO approves spend over $30k. Procurement requires SOC2 docs.

### Fit
- **Green flags:** Clear pain, named champion (Jane), defined budget, real triggering event (new CFO), tight timeline.
- **Red flags:** None major. Slight concern that Tom hasn't been on a call yet — technical buy-in untested.
- **Competitors mentioned:** Looking at one other vendor (name not shared); also considered building in-house but ruled it out.
- **Objections raised:** Worried about implementation timeline being aggressive — addressed by walking through our typical 4-week onboarding.
```

## Mini example — minimal extraction

When the call doesn't surface much, the section honestly reflects that:

```markdown
## Client Context & Qualification

### Buyer
- **Company:** Bayfield Inc
- **Contact:** Rohan Patel, Director of Engineering

### Pain
- **Problem:** > "We have some challenges with our deployment pipeline." (Surface-level — not yet specific.)
- **Severity:** Unclear — not enough discussed to assess.

### Outcomes
*Not discussed in depth.*

### Commercial
- **Budget:** Not discussed.
- **Timeline:** Not discussed.
- **Decision process:** Not discussed.

### Fit
- **Red flags:** No specific pain articulated; no budget signal; no timeline. This was an exploratory first conversation rather than a qualified opportunity.
- **Suggested next step:** Schedule a follow-up with a specific technical agenda before pursuing further.
```

This kind of "thin" output is more useful than a fabricated one — it tells the rep exactly what's missing.

## JSON shape for `type_specific` field

```json
{
  "buyer": {
    "company": "string",
    "company_size": "string|null",
    "industry": "string|null",
    "contact": [{"name": "string", "role": "string"}],
    "their_team": ["string"]
  },
  "pain": {
    "stated_problem": "string|null",
    "stated_problem_quote": "string|null",
    "current_solution": "string|null",
    "severity": "urgent|important|nice-to-have|unclear",
    "severity_signal": "string|null",
    "triggering_event": "string|null"
  },
  "outcomes": {
    "desired_outcome": "string|null",
    "success_metrics": ["string"],
    "who_benefits": ["string"]
  },
  "commercial": {
    "budget": "string|null",
    "budget_quote": "string|null",
    "timeline": "string|null",
    "decision_process": "string|null"
  },
  "fit": {
    "green_flags": ["string"],
    "red_flags": ["string"],
    "competitors_mentioned": ["string"],
    "objections": [{"concern": "string", "response": "string|null"}]
  }
}
```

## Quality check before output

- Verbatim quotes for pain and budget statements wherever possible — these have outsized value for the rep's CRM.
- Empty fields are explicit (`Not discussed.`) rather than omitted silently — silence loses signal.
- Severity rating has a *signal* attached, not just a label.
- Don't conflate "objections raised" with "red flags" — an objection that was answered well is a *good* sign.
