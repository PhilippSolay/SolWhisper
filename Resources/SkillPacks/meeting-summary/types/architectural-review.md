# Sub-skill: Architectural Review

## When to use this sub-skill

Use this when the meeting is a **technical design discussion**: a system or component is under review, the group is comparing approaches, weighing tradeoffs, and making (or deferring) design decisions. Signals:

- Diagrams referenced (whiteboard, Figma, Excalidraw)
- "Should we do X or Y" framing
- Vocabulary: latency, throughput, schema, contract, coupling, tradeoff, scaling
- Technical roles dominate the conversation (engineers, architects, tech leads)

Distinct from **development-session** (working on code right now) and **exploration** (no specific design under review).

## What this sub-skill adds to the universal core

A type-specific section called **Architecture & Tradeoffs**, structured to be the seed of an ADR (Architecture Decision Record). The decisions captured here are **upgraded** versions of the universal Decisions section — they include the technical detail an ADR needs.

This sub-skill effectively replaces the universal Decisions section with a richer one. Cross-reference the IDs so action items can still link to specific decisions.

## Fields to extract

### System context
- `system_under_review` — what's being designed (component, service, feature, refactor)
- `requirements` — functional and non-functional, separated. Latency targets, throughput, availability, security, compliance, etc.
- `constraints` — what's fixed (existing systems we can't change, deadlines, headcount, budget)
- `assumptions` — explicit assumptions called out during discussion

### Approach & alternatives
- `proposed_approach` — the leading design at end of meeting (if any)
- `alternatives_considered` — other options on the table, with one-line summary each
- `tradeoffs` — explicit pros/cons matrix, where stated. Don't invent — only what was discussed.

### Decisions (ADR-style)
For each decision made, capture:
- `decision` — present-tense statement
- `context` — why this came up (the forcing function)
- `options_considered` — list with brief evaluation
- `chosen_option` — which one, and why
- `consequences` — what this enables, what it costs, what it locks us into
- `revisit_when` — conditions that would warrant reopening the decision

### Risks & dependencies
- `technical_risks` — things that could break or surprise us; severity if discussed
- `dependencies` — other systems, teams, or external services this design depends on
- `unknowns` — explicit "we don't know X yet" — these often become spike action items
- `non_goals` — things explicitly out of scope ("we are *not* solving X here")

### Open technical questions
- `open_questions` — technical questions raised but unresolved; what data/spike would resolve them

## Output format

Insert this section in place of the universal **Decisions** section:

```markdown
## Architecture & Tradeoffs

### System under review
**Context:** Real-time event processing pipeline for user activity. Replacing the existing batch ETL because dashboards are too stale (24h lag).

**Requirements:**
- *Functional:* ingest events from web/mobile, transform, write to analytics store
- *Non-functional:* p95 end-to-end latency <60s; 50k events/sec peak; 99.9% availability; PII compliance (no email/IP in analytics store)

**Constraints:**
- Must integrate with existing Postgres analytics store (no migration in scope)
- 6-week delivery window
- 1.5 engineers available

**Assumptions:**
- Event volume will not exceed 100k/sec in next 12 months (Sarah to confirm with growth team)
- We can introduce a new piece of infrastructure if it has team operational expertise

### Proposed approach
**Kafka (managed, e.g. Confluent Cloud) → stream processor (Flink) → Postgres sink.**

### Alternatives considered

| Option | Pros | Cons |
|---|---|---|
| Kafka + Flink (proposed) | Battle-tested, team has experience, mature ecosystem | Cost; ops overhead even for managed |
| Kinesis + Lambda | Fully managed AWS-native; less infra to run | Lambda cold starts; harder local dev; lock-in |
| Postgres LISTEN/NOTIFY + worker pool | Zero new infra; simple | Doesn't meet 50k/sec target; Postgres becomes bottleneck |

### Decisions

**ADR-1: Use managed Kafka + Flink for the streaming pipeline.**
- *Context:* Need a streaming pipeline that meets latency and throughput targets within 6 weeks.
- *Options considered:* Kafka+Flink, Kinesis+Lambda, Postgres LISTEN/NOTIFY.
- *Chosen:* Kafka+Flink. Team has prior experience; meets targets with headroom; managed offering keeps ops cost down.
- *Consequences:* Adds two new pieces of infra to the stack; introduces Confluent vendor relationship; Flink learning curve for two team members.
- *Revisit when:* event volume sustained above 200k/sec, or Confluent costs exceed $X/month.

**ADR-2: PII scrubbing happens in the stream processor, not at ingestion.**
- *Context:* Compliance requires no PII in analytics store.
- *Options considered:* scrub at SDK, scrub at ingestion, scrub in stream processor.
- *Chosen:* stream processor. Centralizes scrubbing logic; SDK can stay simple; ingestion stays a thin pass-through.
- *Consequences:* All PII passes through Kafka briefly. Need short retention on the raw topic (24h max). Need to document the threat model.
- *Revisit when:* compliance audit raises concerns about Kafka retention.

### Deferred Decisions

**Whether to use Flink SQL or DataStream API.**
- *Blocked on:* Tom to spike both for the user-activity transform; report back next week.
- *Action item:* (linked) Tom — Flink API spike, due Mar 22.

### Risks
- **Flink learning curve** (medium): only Tom has shipped Flink to production; mitigation: pair Sarah on the spike.
- **Confluent cost overrun** (low–medium): need to size cluster correctly; mitigation: cost-model spreadsheet before commit.
- **Postgres sink throughput** (medium): 50k events/sec → ~5k row inserts/sec at expected aggregation; mitigation: confirm with load test before week 4.

### Dependencies
- Growth team needs to confirm event volume forecast (Sarah)
- Security team needs to review PII scrubbing approach (Mark to schedule)
- Existing analytics-store schema team needs to be looped in for sink contract

### Non-goals
- Replacing the existing batch ETL for historical backfills (keep both pipelines initially)
- Real-time alerting on event streams (separate project)

### Open Technical Questions
- **Schema evolution strategy** — Avro with a schema registry, or Protobuf? Sarah to draft a recommendation by next review.
- **Event ordering guarantees per user** — strict per-key ordering or relaxed? Affects partitioning strategy. Tom to investigate.
```

## Mini example — small/quick review

```markdown
## Architecture & Tradeoffs

### System under review
**Context:** Adding rate-limiting to the public API.

**Requirements:** Limit per API key. Sane defaults; per-customer overrides.

### Proposed approach
**Token bucket per API key, stored in Redis, checked at the API gateway layer.**

### Alternatives considered

| Option | Pros | Cons |
|---|---|---|
| Token bucket in Redis (proposed) | Distributed; fast; well-understood | Adds Redis dependency for the gateway path |
| In-memory per-instance | Simple; no infra | Inaccurate across instances; doesn't scale |
| Cloud provider rate limit | Zero code | Can't do per-customer overrides |

### Decisions

**ADR-1: Implement token bucket in Redis at the gateway.**
- *Chosen:* Redis token bucket. Meets requirements; dependency is acceptable.
- *Consequences:* Gateway gains a hot-path Redis dependency — needs failover plan.
- *Revisit when:* Redis becomes a bottleneck.

### Risks
- **Redis as gateway dependency** (medium): mitigation — fail-open with logging; alert on Redis latency.

### Open Technical Questions
- Default rate per tier — needs product input from Jane.
```

## JSON shape for `type_specific` field

```json
{
  "system_under_review": {
    "context": "string",
    "requirements_functional": ["string"],
    "requirements_non_functional": ["string"],
    "constraints": ["string"],
    "assumptions": ["string"]
  },
  "proposed_approach": "string|null",
  "alternatives": [
    {"name": "string", "pros": ["string"], "cons": ["string"]}
  ],
  "decisions_adr": [
    {
      "id": "ADR-1",
      "decision": "string",
      "context": "string",
      "options_considered": ["string"],
      "chosen_option": "string",
      "consequences": ["string"],
      "revisit_when": "string|null"
    }
  ],
  "risks": [
    {"risk": "string", "severity": "low|medium|high", "mitigation": "string|null"}
  ],
  "dependencies": ["string"],
  "non_goals": ["string"],
  "open_technical_questions": [
    {"question": "string", "needs": "string"}
  ]
}
```

## Quality check before output

- Each decision is in proper ADR shape: context → options → chosen → consequences. If you can't fill one of those, the field is `not discussed`, not invented.
- Tradeoffs reflect what was actually discussed. Do not generate plausible-sounding pros/cons that didn't come up.
- Risks have severity ratings only when severity was discussed; otherwise leave unrated.
- Open Technical Questions should each have a "what would resolve this" pointer (a spike, a doc, a stakeholder input).
