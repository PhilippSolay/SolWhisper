# SolWhisper → Kiros task ingest — dev plan

**Status:** proposed · **Owner:** Philipp · **Scope:** Kiros backend only (Python).
**Companion:** SolWhisper emits structured tasks and POSTs them here (Route 2). This
doc specifies *everything Kiros must build*; the SolWhisper side is out of scope (see
"Hand-off" at the end).

## Goal

When a SolWhisper transcription yields action items that are *Philipp's*, they land in
the Kiros **inbox** at `https://kairos.solay.cloud`, with as many fields filled as the
extractor could infer (company/category/project, importance, urgency, effort, due,
energy) and the meeting context as the task description. Unmappable tasks still land in
the inbox — that's what the inbox is *for* (raw lane, triaged weekly).

## Design decisions (made, not open)

1. **Bearer-token auth, stored hashed.** A per-user API token, `Authorization: Bearer
   <token>`. Stored as `sha256` (like sessions/resets in `auth.py`), *not* raw like
   `ics_token`. Raw token shown once on creation.
2. **Ingest is CSRF-exempt and session-independent.** It authenticates by bearer alone,
   handled *before* the cookie/CSRF gate in `do_POST`. CSRF only matters for cookie auth,
   so there is no CSRF risk on a bearer endpoint.
3. **Ingest never mutates the taxonomy.** It will not create companies or fronts. An LLM
   guess must not pollute the `## 🏢 Companies` / `## 🎯 Fronts` registry. Unmatched →
   task goes to inbox with the project preserved as `group` + in the description.
4. **Tasks land in the inbox lane only.** Structured (`- [ ] (CODE) title · meta`), so
   they appear in the Manage table's inbox column and round-trip through `parse_task`.
5. **Idempotent by `url`.** Each task carries `url:solwhisper:<meeting_id>:<idx>`.
   Re-POSTing the same meeting skips tasks whose url already exists on the board.
6. **Response envelope matches Kiros**, not the global `{success,data,error}` — i.e.
   `{"ok": true, ...}`, to read like every other handler in `kiros_web.py`.

## API contract

### `POST /api/ingest/tasks`  (Bearer)

Request:
```json
{
  "source": "solwhisper",
  "meeting_id": "8f1c…",            // required — idempotency key
  "meeting_title": "Client call — Bluebird",
  "captured_at": "2026-06-29T10:00:00Z",
  "tasks": [
    {
      "idx": 0,                     // required — position; part of the url key
      "title": "Send revised quote to Bluebird",   // required
      "company":  "Acme Studio",    // → front.surface
      "category": "Sales",          // → front.name  (Design/Sales/App…)
      "project":  "Bluebird Café",  // → task.group  (client / sub-project)
      "front":    "AS-SALE",        // optional explicit code; wins if it exists
      "importance": 4,              // 1–5 or null → inherit front
      "urgency":    5,              // 1–5 or null → inherit front
      "est":  "30m",                // EST_EFFORT key; else normalized to "1h"
      "due":  "2026-07-02",         // ISO date or null
      "energy": "low",              // low|med|high or ""
      "avoid": false,
      "description": "Client pushed back on price; include the 3-tier option."
    }
  ]
}
```

Response `200`:
```json
{
  "ok": true, "created": 2, "skipped": 1,
  "results": [
    {"idx":0,"status":"created","front":"AS-SALE","url":"solwhisper:8f1c…:0"},
    {"idx":1,"status":"duplicate","url":"solwhisper:8f1c…:1"},
    {"idx":2,"status":"created","front":"","note":"no front match — inbox + group"}
  ]
}
```
Errors: `401` bad/absent token · `413` body > 1 MiB or > `MAX_INGEST_TASKS` · `429`
rate-limited · `400` malformed / no `tasks` / no `meeting_id`.

### `GET /api/ingest/fronts`  (Bearer)

Lets SolWhisper feed the live taxonomy into its extraction prompt (precision upgrade)
and lets its settings panel show "connected · N companies".
```json
{ "ok": true,
  "companies": ["Acme Studio","Northwind","Personal"],
  "fronts": [ {"code":"AS-SALE","name":"Sales","company":"Acme Studio","importance":4} ] }
```

### `POST /api/token/create`  (session + CSRF) → `{"ok":true,"token":"<raw, shown once>"}`
Regenerating replaces the stored hash (old token instantly invalid).
### `POST /api/token/revoke` (session + CSRF) → `{"ok":true}`
### `GET /api/me` — add `"hasApiToken": <bool>` (never return the token).

## Field → `kiros.Task` mapping

| Ingest field | Task field | Notes |
|---|---|---|
| `title` | `title` | required; `_oneline`'d + `·`→`-` by `format_task_line` |
| resolved code | `front` | see resolution below |
| `project` | `group` | client / sub-project |
| `importance` | `importance` | `int 1–5` or `None` → inherits `front.importance` in `score_task` |
| `urgency` | `urgency` | `int 1–5` or `None` |
| `est` | `est` | `normalize_est()` → falls back to `EFFORT_DEFAULT` ("1h") |
| `due` | `due` | `date.fromisoformat` or `None` |
| `energy` | `energy` | `{low,med,high}` else "" |
| `avoid` | `avoid` | bool |
| `idx`+`meeting_id` | `url` | `solwhisper:<meeting_id>:<idx>` (opaque key; non-clickable like `kiros:local:`) |
| (today) | `added` | `date.today()` for avoidance/aging |
| `description` | — | written to `descriptions.json` via `save_description`, keyed by `url` |

Build the line with the **existing** path: `task_from_fields`-style construction →
`kiros.format_task_line(task)` → `kiros.add_task_line(bp, "inbox", line)`, all inside
`board_guard(uid)`. No new file-writing code; the `_oneline` guard already protects the
write boundary.

## Front resolution (new pure helper in `kiros.py`)

```
resolve_front(board, explicit_front, company, category) -> code|"":
  1. explicit_front in board.fronts            → explicit_front
  2. normalized (surface==company, name==category) exact match → that code
  3. company matches exactly one front          → that code
  4. otherwise                                   → ""   (unmapped: inbox + group + desc)
```
Normalization = `strip().casefold()`. Conservative on purpose — deterministic, no LLM,
never auto-creates. Unit-tested as a pure function (no I/O).

## Validation & security (server-side; never trust the payload)

- `tasks`: list, `1 ≤ len ≤ MAX_INGEST_TASKS` (50). Else `413`/`400`.
- `title`: required, non-empty after strip, ≤ 500 chars.
- `importance`/`urgency`: coerce to int; keep only if `1–5`, else `None`.
- `est`: `normalize_est` (already exists). `due`: strict ISO or `None`. `energy`: enum or "".
- `description`: str, ≤ 5000 chars; lives in JSON sidecar (json-escaped, never the `.md`).
- `company`/`category`/`project`: str, ≤ 120 chars.
- Newline / `## ` / `·` injection into KIROS.md → **already neutralized** by `_oneline`
  + `·`→`-` in `format_task_line` (kiros.py:390-450). A test will assert this holds.
- Bearer: hash the presented token, look it up; reject inactive users. Raw secret is
  never string-compared. Token is hashed at rest. Scope strictly to the token's `uid`
  (preserves the "path derives only from a verified uid" golden rule).
- Reuse `MAX_BODY` (1 MiB). Rate-limit ingest via `RATE.allow("ingest:" + token_hash)`.
- TLS terminates at Traefik (requests reach the app as http) — HTTPS is enforced at the
  proxy, not the app; note in DEPLOY.md, don't try to enforce in-process.

## Phases (each independently shippable & testable with `curl`)

- **K1 — token plumbing.** `store.py`: add `api_token_hash` column (+ lightweight
  `__init__` migration: `PRAGMA table_info` → `ALTER TABLE … ADD COLUMN` if missing),
  methods `set_api_token_hash`, `get_user_by_api_token_hash`, `clear_api_token`.
  `kiros_web.py`: `_api_user()` helper, `/api/token/create|revoke`, `/api/me` flag.
  Minimal Settings UI affordance (mirror the ics-token row in `web/app.js`).
- **K2 — `resolve_front`.** Pure helper + unit tests. No HTTP.
- **K3 — `POST /api/ingest/tasks`.** Validation → resolve → dedupe → `board_guard`
  write → `save_description`. Dispatched **before** the session/CSRF block in `do_POST`.
- **K4 — `GET /api/ingest/fronts`.** Bearer-authed taxonomy read.
- **K5 — docs.** DEPLOY.md (token setup, Traefik note) + this contract frozen for the
  SolWhisper side.

## Testing (`test_ingest.py`, mirrors existing test files; target ≥80%)

- token: create→hash stored, lookup by hash, revoke, inactive user rejected.
- ingest happy path: task appears in inbox lane; fields filled; description saved.
- resolution: (company+category) exact; company-only-unique; no-match→group kept, front "".
- validation: missing title `400`; bad `est` normalized; importance out of range dropped;
  `>50` tasks rejected; body too large `413`.
- idempotency: same `meeting_id:idx` re-POST → `duplicate`, board unchanged.
- injection: title with `\n`, `## `, `·` → one safe line; board still parses to the same
  section structure.
- isolation: token A only ever writes under user A's uid.
- CSRF-exemption: ingest succeeds with no CSRF cookie; a session endpoint still needs it.
- rate limit: `MAX+1` calls → `429`.

## Open decision (genuinely yours)

- **Unmapped tasks:** default = land in inbox with `project`→`group` + description (fits
  weekly triage). Alternative = an opt-in "auto-create front from company/category"
  toggle. Recommend shipping the default; add the toggle only if triage proves noisy.

## Hand-off (SolWhisper side — not built here)

1. New skill-Markdown block emits the `tasks[]` JSON above, filtered to "me" (configurable
   name/aliases). Tune in Markdown — no Swift rebuild.
2. `KirosIntegration.swift` (mirror `HermesIntegration.swift`): base URL + bearer token in
   Keychain; POST on fanout; surface errors. Optional: pre-fetch `/api/ingest/fronts` to
   enrich the prompt.
3. Optional polish: register a `solwhisper://meeting/<id>` URL scheme so the task `url`
   becomes a clickable jump-back instead of an opaque key.
