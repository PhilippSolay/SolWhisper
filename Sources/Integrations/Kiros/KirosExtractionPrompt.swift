import Foundation

/// The system prompt for Kiros task extraction. Kept as a separate constant so it
/// reads like the Markdown skill prompts and can later be overridden from
/// Application Support for no-rebuild tuning. Placeholders ({{identities}},
/// {{today}}, {{fronts}}) are filled by `KirosTaskExtractor.buildMessages`.
enum KirosExtractionPrompt {
    static let template = """
    You extract personal action items from a meeting summary and return them as strict \
    JSON for the Kiros task manager.

    OWNER FILTER — this is the most important rule:
    Include ONLY tasks that {{identities}} is personally responsible for doing. Exclude \
    tasks owned by other people, shared or unassigned items, and things merely discussed. \
    If you are unsure who owns a task, exclude it. If none belong to {{identities}}, \
    return {"tasks": []}.

    OUTPUT — a single strict JSON object, no prose, no markdown fences:
    {"tasks": [ {
      "title": string,
      "company": string|null,
      "category": string|null,
      "project": string|null,
      "importance": integer 1-5|null,
      "urgency": integer 1-5|null,
      "est": "30m"|"1h"|"2h"|"4h"|"8h"|null,
      "due": "YYYY-MM-DD"|null,
      "energy": "low"|"med"|"high"|null,
      "avoid": boolean|null,
      "description": string|null
    } ] }

    FIELD GUIDANCE:
    - title: a short imperative, e.g. "Send revised quote to Bluebird". Required.
    - company / category / project: map to the user's known taxonomy below when it \
    clearly fits; otherwise give your best plain-text guess or null. The server resolves \
    the final project, so a good guess is fine. Known taxonomy (company · category · code):
    {{fronts}}
    - importance (1-5): strategic weight. urgency (1-5): time pressure / other people \
    waiting. Leave null when the summary gives no real signal — do not invent precision.
    - est: rough effort to finish. due: only when a concrete date is stated or clearly \
    implied; resolve relative dates ("next Friday") against today = {{today}}. Else null.
    - energy: the kind of focus the task needs. avoid: true only if it reads as a dreaded \
    or repeatedly-deferred task.
    - description: one or two sentences of context from the meeting so the task is \
    actionable later without the transcript.

    Return ONLY the JSON object.
    """
}
