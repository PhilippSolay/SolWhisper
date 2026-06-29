# SolWhisper → Kiros integration — build plan (SolWhisper side)

**Status:** ready to build · **Owner:** Philipp · **Scope:** SolWhisper (Swift) only.
**Backend:** owned by the Kiros dev team, built against the frozen contract in
`Kiros/docs/solwhisper-ingest.md`. That contract is our fixed interface — we build and
test against it, mocking the endpoint until the real one is live.

## Goal

After a transcription, extract the action items that are **Philipp's**, turn them into
structured Kiros tasks (fields filled where inferable), and POST them to
`https://kairos.solay.cloud/api/ingest/tasks`. They auto-land in the Kiros inbox.

## The interface we build against (frozen)

- `POST /api/ingest/tasks` — `Authorization: Bearer <token>`; body `{source, meeting_id,
  meeting_title, captured_at, tasks:[{idx,title,company,category,project,front?,
  importance,urgency,est,due,energy,avoid,description}]}` → `{ok,created,skipped,results[]}`.
- `GET /api/ingest/fronts` — Bearer; returns `{companies[], fronts[{code,name,company,importance}]}`.
- Idempotency key = `solwhisper:<meeting_id>:<idx>`; resend is safe (server dedupes).

## How it slots into the existing app (code-grounded)

- **Entry point:** `IntegrationFanout.send(meeting:transcriptMarkdown:summaryMarkdown:audioFileURL:)`
  (`Sources/Integrations/IntegrationFanout.swift:50`). Add a Kiros call in the fanout loop
  and to `enabledNames` (`:37-45`). No protocol — integrations are static structs.
- **Template:** `HermesIntegration` (`Sources/Integrations/HermesIntegration.swift:19-48`)
  — mirror its `isEnabled` + `static func send(...) async throws -> Int` shape.
- **HTTP:** reuse `OutboundWebhook(url:secret:extraHeaders:)`
  (`Sources/Integrations/OutboundWebhook.swift:7-36`) with
  `extraHeaders: ["Authorization": "Bearer \(token)"]`, `secret: nil` (no HMAC — Kiros
  uses bearer). `post(body:)` returns the HTTP status `Int`.
- **Secret:** `KeychainStore.set/string(forKey:)`
  (`Sources/Security/KeychainStore.swift`), key `"kiros.bearerToken"`.
- **"Me" filter:** reuse `@AppStorage("userDisplayName")`
  (`Sources/Settings/PeopleSettingsView.swift:17`); add `kirosIdentities` for aliases.
- **LLM:** reuse the existing client/model resolution that `SummaryGenerator` uses
  (`AnthropicClient` / `LLMResolver`). The extraction prompt lives in a **Markdown
  resource** so it tunes without a rebuild.
- **JSON contract reuse:** the skill spec already defines a `format: json` action-items
  schema (`Resources/SkillPacks/meeting-summary/.../core-output.md:129-181`). Base the
  extractor prompt on it, extended with Kiros fields (company/category/project,
  importance, urgency, est, energy).

## New files (small, focused — KISS, <400 lines each)

| File | Responsibility |
|---|---|
| `Sources/Integrations/Kiros/KirosModels.swift` | `Codable` `KirosTask`, `KirosIngestRequest/Response`, `KirosFront`. Immutable structs. |
| `Sources/Integrations/Kiros/KirosClient.swift` | `fetchFronts()`, `postTasks(meetingId:title:tasks:)`. Bearer from Keychain. Injectable `URLSession` for tests. |
| `Sources/Integrations/Kiros/KirosTaskExtractor.swift` | LLM pass: summary(+optional transcript) + identity + fronts → `[KirosTask]`. Decodes JSON; validates/normalizes fields. Injectable LLM client. |
| `Sources/Integrations/KirosIntegration.swift` | `isEnabled` + `send(...)`: extractor → client.postTasks → status. Error handling. |
| `Resources/.../kiros-task-extraction.md` | The tunable extraction prompt (no rebuild to edit). |
| `Tests/KirosClientTests.swift` etc. | See Testing. |

Edits: `IntegrationFanout.swift` (wire in), `IntegrationsSettingsView.swift` (Kiros card).

## Extraction design

A dedicated Kiros pass, not a change to the shared summary skill (keeps the summary
generic; keeps Kiros logic tunable and isolated). Prompt directs the LLM to:
- emit **only** tasks the user (`userDisplayName` + aliases) is personally on the hook for;
- output a JSON array matching `KirosTask` (title required; company/category/project +
  importance/urgency/est/energy/due best-effort, null when unknown);
- map company/category against the fetched fronts taxonomy when available (else free text;
  Kiros resolves server-side and unmatched tasks still land in the inbox).
Swift side strictly validates/normalizes after decode (never trusts LLM output): title
non-empty, importance/urgency ∈ 1–5 else null, est ∈ allowed set, due ISO-or-null.

## Constraints (must hold)

- **Minimize app launches (TCC pain).** Unsigned builds re-prompt permissions ~5×/launch.
  So: all logic is unit-tested via `xcodebuild test` with a **mocked `URLSession`
  (URLProtocol)** and **recorded LLM responses** — zero app launches in S0–S3. Prompt
  tuning = edit Markdown + re-run extractor tests against transcript fixtures (no rebuild).
  Exactly **one** app launch, at S4, for the real end-to-end smoke.
- **Immutability** — new structs, no in-place mutation.
- **Boundaries validated** — every LLM/HTTP value validated before use.
- **No secrets in code** — bearer only in Keychain. **Error handling** — surface failures
  in the integration result/UI, never silently swallow.

## Testing (TDD; target ≥80%)

- `KirosModelsTests` — JSON encode/decode round-trips; tolerant decode of partial/nullable.
- `KirosTaskExtractorTests` — recorded summary fixtures → expected `[KirosTask]`; "me"
  filter (drops others' items); validation (out-of-range importance, bad est, empty title);
  no live LLM (inject a stub returning recorded JSON).
- `KirosClientTests` — URLProtocol mock: correct URL/method/headers (`Authorization: Bearer`),
  body shape, idempotency key; response mapping (created/skipped/duplicate); 401/429/timeout.
- `KirosIntegrationTests` — orchestration with stubbed extractor+client; `isEnabled` logic.
- S4 manual: real transcription → tasks appear in a staging/mock Kiros; resend → deduped.

## Phases (loop milestones; each = TDD → code review → atomic commit; no app launch S0–S3)

- **S0 — Models + Client.** `KirosModels`, `KirosClient` with injected `URLSession`.
  *Done when:* `KirosClientTests` + `KirosModelsTests` green via `xcodebuild test`.
- **S1 — Extractor.** Prompt Markdown + `KirosTaskExtractor` with injected LLM stub.
  *Done when:* extractor turns recorded fixtures into validated `[KirosTask]`, "me" filter
  passes.
- **S2 — Integration + fanout wiring.** `KirosIntegration` + `IntegrationFanout` edit.
  *Done when:* `KirosIntegrationTests` green; fanout includes Kiros when enabled.
- **S3 — Settings UI.** Kiros card (enable, URL, bearer via `APIKeyField`+Keychain,
  identities, "Test connection" → `fetchFronts`). *Done when:* builds; token round-trips
  through Keychain; test-connection works against mock.
- **S4 — End-to-end smoke (one launch).** Real meeting → tasks in staging Kiros; verify
  fields + idempotency. *Done when:* tasks land correctly and resend dedupes.

## Open items to confirm before/at S1

- Extraction model: reuse the summary model, or a cheaper/faster one for this pass?
- Include transcript in the extraction prompt, or summary-only (cheaper, usually enough)?
- Fetch `/api/ingest/fronts` to enrich the prompt, or send free-text and let Kiros resolve?
  (Plan assumes optional fetch with graceful fallback to free-text.)
