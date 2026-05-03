# Sub-skill: Development Session

## When to use this sub-skill

Use this when the meeting is a **working session focused on code or implementation** — pair programming, mob programming, debugging a specific issue, walking through an implementation, or working through a tricky technical problem in real time. Signals:

- Code is being read, written, or shown on screen
- Vocabulary: function, method, bug, repro, refactor, test, branch, commit, deploy
- The discussion is about *how to do something*, not *whether to do it*
- Often pair-shaped (two participants) but can be a small group

Distinct from **architectural-review** (designing, not building) and **scrum-standup** (status, not work).

## What this sub-skill adds to the universal core

A type-specific section called **Implementation Notes**, capturing the working knowledge generated during the session. The most valuable output here isn't decisions — it's the **gotchas, learnings, and TODO trail** that would otherwise be lost.

## Fields to extract

### What was being built or fixed
- `problem` — the specific thing being worked on (feature, bug, refactor)
- `repro_steps` — for bugs: the steps to reproduce, if discussed
- `root_cause` — for bugs: what was actually wrong, once found
- `approach` — the implementation approach taken; iterations if multiple

### Code-level decisions made
Inline decisions made during the session — too small for an ADR but worth recording. Each one:
- `decision` — what was chosen ("use map instead of forEach for the transform")
- `why` — the reason, briefly
- `where` — file or component, if mentioned

### Gotchas & learnings
- `gotchas` — surprises, footguns, things that didn't work as expected. These are gold — write them up clearly. Include any error messages quoted verbatim.
- `references` — docs, Stack Overflow, blog posts, internal docs that were consulted
- `tools_used` — tools, libraries, or commands that proved useful (worth knowing for next time)

### Outputs of the session
- `code_changes` — what shipped or what's in flight (PRs, branches, files modified)
- `tests_added_or_changed` — test coverage delta
- `tech_debt_noted` — things flagged as "we should clean this up later"
- `todos` — concrete follow-up tasks; these become action items
- `unresolved_issues` — things still broken at end of session, with current state of investigation

## Output format

Insert this section after **Decisions** in the universal template (or replace it if all decisions were code-level):

```markdown
## Implementation Notes

### Problem
The image upload endpoint was returning 200 but storing zero-byte files in S3 about 5% of the time. Reported by the QA team last week.

### Repro
1. Upload a JPEG >2MB via the mobile app on slow network
2. Server returns 200 with valid object key
3. S3 object exists but is 0 bytes

### Root Cause
The multipart parser was being short-circuited by an early `res.end()` in the request validation middleware when the request had a missing `X-Upload-Token` header. The validation was running *before* the body was fully read, but the response was being sent without aborting the upload — so the client thought the upload succeeded.

### Approach
1. First tried adding a buffer check after parse — didn't help, problem was upstream.
2. Traced the actual request flow with Wireshark + server logs and found the validation order issue.
3. Fix: re-ordered middleware so body parsing completes before token validation; added explicit `req.destroy()` on validation failure.

### Code-level decisions
- **Use `req.destroy()` rather than `res.status(400).end()` for early-abort cases.** Reason: `.end()` doesn't stop the inbound stream, so we still allocate buffers. Where: `src/middleware/upload.ts`.
- **Keep token validation as middleware, don't move it into the handler.** Reason: still want it short-circuited for non-multipart routes; the fix was ordering, not location.

### Gotchas
- `multer`'s default behavior is to silently drop the upload if the request stream errors during parsing — you get an empty file with no error. **Always attach an `error` handler to the multer instance.**
- Express middleware order matters more than usual when streams are involved. Logging middleware that touches `req` can subtly change parser behavior.
- Wireshark on the loopback interface needed `sudo dumpcap -i lo` plus running the local server with `127.0.0.1` binding (not `localhost`) to capture cleanly.

### References consulted
- [multer issue #498](https://github.com/expressjs/multer/issues/498) — same root cause, different framing
- Internal doc: `runbooks/upload-pipeline.md` (added a section about middleware ordering)

### Code changes
- PR #842 — middleware reorder + error handler
- PR #843 — integration test for the slow-network repro

### Tests added
- `tests/upload/slow-network.test.ts` — uses `nock` to simulate slow inbound; asserts non-zero file size in S3.

### Tech debt noted
- The whole upload pipeline could use a rewrite around a single streaming abstraction. Filed in Linear as `INFRA-228`. Not in scope today.

### Unresolved
- Mobile app reports occasional 502s on the same endpoint, possibly related, possibly separate. Not investigated today; needs a repro from the mobile team.
```

## Mini example — quick session

```markdown
## Implementation Notes

### Problem
Add a debounce to the search input so we stop hammering the API on every keystroke.

### Approach
Used `useDebounce` hook from `usehooks-ts`. 300ms delay, applied in `SearchBar.tsx`.

### Gotchas
- Storybook hot-reload was caching the old debounce timeout — had to hard-refresh to see changes work.

### Code changes
- `src/components/SearchBar.tsx` — debounce wired in
- PR #1204

### Tests
- Existing test suite still passes; no new tests added (logic is too thin to test usefully).
```

## JSON shape for `type_specific` field

```json
{
  "problem": "string",
  "repro_steps": ["string"],
  "root_cause": "string|null",
  "approach": "string",
  "code_decisions": [
    {"decision": "string", "why": "string", "where": "string|null"}
  ],
  "gotchas": ["string"],
  "references": ["string"],
  "code_changes": ["string"],
  "tests": ["string"],
  "tech_debt_noted": ["string"],
  "unresolved": ["string"]
}
```

## Quality check before output

- Gotchas are written for the next person hitting the same wall — concrete, with the actual error message or behavior, not abstracted.
- Code-level decisions don't bloat into ADRs — keep them tight (decision + why + where, one line each if possible).
- Unresolved items either become action items (with an owner) or get flagged for later. Don't leave a problem dangling without a next step.
- "Tests" should reflect reality. If no tests were added, say so — don't pad.
- The action items section pulls TODOs from this section; don't double-list.
