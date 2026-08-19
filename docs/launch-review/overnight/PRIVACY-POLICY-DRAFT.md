# SolWhisper Privacy Policy — DRAFT

> **Draft for Philipp's review.** This describes what the code *actually does* as of the
> launch baseline. Verify each claim against your final shipping config, fill the
> bracketed blanks, have a lawyer glance at it if you can, then host at a stable URL and
> link it from onboarding + your site. Not legal advice.

**Last updated: [DATE] · Applies to: SolWhisper for macOS v[X.Y]**

## The short version

SolWhisper is a menu-bar app that runs on your Mac. Your recordings, transcripts, and
notes are stored **locally on your Mac** by default. SolWhisper has no backend server of
its own — we (the developer) never receive your audio, transcripts, or personal data.

Some features send data to **third-party services you choose and configure** (cloud
transcription, AI summarization, and integrations). When you enable those, your data goes
to those providers under *their* privacy policies. You can run SolWhisper fully on-device
(Apple Speech + WhisperKit + a local Ollama model) and send nothing to the cloud.

## What SolWhisper accesses on your Mac, and why

| Permission | Why | Prompted when |
|---|---|---|
| Microphone | Record your voice for dictation and meetings | First dictation/meeting |
| Speech Recognition | On-device Apple transcription | First Apple-Speech dictation |
| Screen Recording | Capture system/other-participant audio in meetings | First meeting with system audio |
| Accessibility | Paste transcribed text into the app you're using | First paste |
| Apple Events | Paste + optional automation | As needed |
| Calendar | Match meetings to calendar events (optional) | Only if you enable it |

All processing tied to these happens locally unless you've turned on a cloud feature below.

## Where your data lives

- Recordings, transcripts, summaries, and speaker profiles are stored as files under
  `~/Library/Application Support/SolWhisper/` on your Mac.
- API keys you enter are stored in the **macOS Keychain**, not in plain files.
- Nothing is uploaded to any server operated by the developer. There is no SolWhisper account.

## Third-party services (only when you enable and configure them)

You provide your own API keys for these; your data flows directly from your Mac to the
provider you chose:

- **Cloud transcription:** Deepgram, AssemblyAI — receive your audio to transcribe it.
- **AI / LLM features** (summaries, cleanup, translation fallback, task extraction):
  OpenRouter, Anthropic, OpenAI, Groq, Google, or your local Ollama — receive transcript
  text to process it.
- **Integrations** (optional outbound): Kiros, Hermes, Obsidian, and any custom webhook
  *you* configure — receive the transcript/summary content you route to them.
- **Software updates:** Sparkle checks an update feed hosted at
  [`appcast URL`] and downloads signed updates. This reveals your app version and IP to
  the host, like any update check.

Each provider handles your data under its own privacy policy and terms. SolWhisper does
not add itself as a recipient. If you use only Apple Speech + WhisperKit + Ollama, no
transcript or audio leaves your Mac.

## Recording other people

Meeting recording captures audio from your Mac, which may include other participants.
**You are responsible for obtaining any consent required by the laws of your and the
other participants' locations.** SolWhisper shows an in-app consent reminder, but the
legal obligation is yours.

## Data you can delete

Everything is local — delete a meeting/transcript in-app, or remove the files under
`~/Library/Application Support/SolWhisper/`. Removing a provider's API key stops all data
flow to that provider. Uninstalling the app leaves your data files until you delete them.

## Children

SolWhisper is not directed to children under [13 / 16 per your target market].

## Changes & contact

We'll update this page and bump the date above for material changes. Questions:
**[support email / URL]**.

---

*Developer: [legal/trading name]. Jurisdiction: [country/region]. If you target the EU/UK
(GDPR) or California (CCPA), add the required controller identity, legal-basis, and
data-subject-rights sections — since data is local + user-configured, you are largely a
data processor at most, but confirm this for your setup.*
