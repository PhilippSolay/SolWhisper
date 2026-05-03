# Attribution Rules

Attribution is about getting *who said what* right. Bad attribution turns useful summaries into liability — "the client said they'd accept $80k" with the wrong client name on it is worse than no summary.

## Speaker identification

### When the transcript has speaker labels

Most modern transcription tools label speakers (`Speaker 1`, `Speaker 2`, or named: `Sarah Chen`). Use the labels as-is. If the labels are generic (`Speaker 1`), and the conversation contains self-identification ("Hi, I'm Sarah"), map the speaker labels to real names and use real names from then on.

### When the transcript has no speaker labels

Identify speakers from contextual cues:
- Direct address ("Sarah, what do you think?" → next speaker is likely Sarah)
- Self-reference ("I'm the lead engineer on this", combined with role context)
- Topic continuity (the same voice continues a thread)

If you can't identify a speaker confidently, use a stable pseudonym (`Participant A`, `Participant B`) consistently throughout the output. Never assign a real name based on guesswork.

### When the app provides a participant list

If the system prompt or call metadata includes a `participants` field (e.g. `[{name: "Sarah Chen", role: "PM"}, {name: "Mark Tanaka", role: "Engineer"}]`), use those names. Cross-reference role mentions in the transcript against the role field to disambiguate ("the PM said..." → Sarah).

## Quote attribution

When using a verbatim quote in the output:
- Always attribute: `> "We need to ship this by Q2." — Sarah Chen`
- Never paraphrase and present as a quote. If the speaker said "we kinda need to wrap this up by like, summer", don't quote it as "We need to ship by Q2".
- If unsure who said it, attribute to `Unknown speaker` or `Participant A` rather than guessing.

## Pronoun and reference resolution

Watch for ambiguous pronouns: "He said he'd handle it" — when there are multiple men in the meeting, who's *he*?

Resolution priority:
1. Most recent named referent in the same speaker's turn
2. Most recent named referent in the conversation
3. If neither resolves it, leave the ambiguity in the output and flag it: `[unclear which "he" — possibly Mark or Tom]`

## Action item ownership

See `action-items.md` for the full rules. Summary: never assign action items to people who weren't in the meeting unless they were explicitly named as a delegate, and never guess at owners — `unassigned` is the honest answer when ownership wasn't stated.

## Privacy and discretion

Some meetings contain content that shouldn't be reproduced verbatim:
- Personal/medical information shared in passing
- Salary, compensation, or other employee-specific financial info (unless the meeting is explicitly about compensation)
- Mental health disclosures
- Off-the-record asides ("don't put this in the notes")

Rules:
- Never reproduce verbatim text that is clearly off-the-record. If a speaker says "this stays between us", treat it as a redaction request.
- For sensitive disclosures that *are* relevant to the action items or decisions, summarize at the lowest fidelity needed for the output to make sense, and add a `[sensitive: <category>]` tag.
- For 1:1s and performance reviews, see the additional privacy rules in `types/one-on-one.md`.

## Names in the output

- Use full names on first reference, first names thereafter, unless the same first name is shared by multiple participants (then keep using last names).
- Match the spelling and capitalization the participants use about themselves. If the participant list says "Phillip" but the transcript shows "Philipp Solay", use "Philipp Solay".
- Don't add titles ("Mr.", "Dr.") unless they appear in the transcript or participant list.

## When attribution is genuinely impossible

Bad audio, overlapping speakers, untagged transcripts with no contextual cues — sometimes attribution just can't be done at the per-utterance level. In those cases:
- Aggregate at the group level: "the team agreed", "the room raised concerns about X"
- Skip per-person action items and produce a flat list, with a note at the top: `Note: per-person attribution unavailable for this transcript; action items listed without owners.`
- Don't pretend you know who said what.
