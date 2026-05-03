# SolWhisper Release Process

End-to-end checklist for publishing a SolWhisper release. Two paths:

- **Ad-hoc** — fast iteration, testers pay the Gatekeeper / TCC tax
- **Notarized** — public-ready, TCC permissions persist across versions

Both paths run through `scripts/release.sh`. The difference is whether you
export the notarization env vars before invoking it.

---

## One-time setup

### Sparkle EdDSA keys

The release script needs an EdDSA key in your Keychain so `sign_update` can
sign each DMG. If you've never released before:

```bash
./scripts/generate-sparkle-keys.sh
```

This stores the private key in `login.keychain` under
`https://sparkle-project.org` and prints the public key. Drop the public
key into `Resources/Info.plist` under `SUPublicEDKey` if it isn't already
there. **Back up the private key somewhere safe** — losing it bricks
auto-update for everyone on the current installer.

### Apple Developer notarization (one-time, optional but recommended)

Without notarization, every install resets TCC permissions because the
CDHash changes between ad-hoc-signed builds. With notarization, the CDHash
is stable and macOS treats the app as trusted.

1. Get a Developer ID Application certificate from
   <https://developer.apple.com/account/resources/certificates>.
2. Install it into your login keychain.
3. Generate an app-specific password at <https://appleid.apple.com>.
4. Store notary credentials in Keychain:

   ```bash
   xcrun notarytool store-credentials "SolWhisperNotary" \
     --apple-id you@example.com \
     --team-id ABCDE12345 \
     --password <app-specific-password>
   ```
5. Optional: also run `scripts/setup-notarization.sh` for a guided walk-through.

### gh CLI

```bash
gh auth login
gh auth status   # confirm
```

The repo at `PhilippSolay/SolWhisper` must be **public** so testers' Sparkle
clients can fetch `appcast.xml` over `raw.githubusercontent.com`.

---

## Releasing

### Ad-hoc (fast, internal testing)

```bash
./scripts/release.sh 0.4.0-alpha.4
```

The script will:

1. Verify pre-flight (gh auth, repo public, version greater than highest
   in `appcast.xml`, tag free).
2. Bump `CFBundleShortVersionString` in `Info.plist`.
3. Build Release with auto-incremented `CFBundleVersion`.
4. Re-sign ad-hoc deeply (so Sparkle.framework's Team ID matches).
5. Package DMG, sign with Sparkle EdDSA.
6. Prepend a new `<item>` to `appcast.xml` (preserving history).
7. Commit + push to `main`.
8. Create a GitHub release with the DMG attached.
9. Verify the DMG download URL returns 200.

Testers must clear quarantine on first install:

```bash
xattr -cr /Applications/SolWhisper.app
```

### Notarized (public release)

Same command, but with three env vars set first:

```bash
export SW_TEAM_ID="ABCDE12345"
export SW_DEVELOPER_ID="Developer ID Application: Your Name (ABCDE12345)"
export SW_NOTARIZE_PROFILE="SolWhisperNotary"
./scripts/release.sh 0.4.0
```

The script will additionally:

- Sign with Developer ID + hardened runtime.
- Submit to `xcrun notarytool` and wait (1–10 min).
- Staple the notarization ticket to the bundle.

No quarantine flag, no Gatekeeper prompt, no TCC reset. Testers drag and
drop and it just works.

### With release notes (recommended)

Write release notes as HTML/markdown in a file, e.g. `notes/v0.4.0.md`:

```bash
./scripts/release.sh 0.4.0 notes/v0.4.0.md
```

The notes go into the `<description>` of the appcast item (shown in
Sparkle's "What's new?" panel) and the GitHub release body.

### What's-new feed (optional)

To prepend an entry to the in-app `Settings → Home → What's new?` feed:

```bash
export SW_WHATSNEW_TITLE="Anthropic direct routing"
export SW_WHATSNEW_BODY="You can now configure a Claude model directly in Settings → Models."
./scripts/release.sh 0.4.0 notes/v0.4.0.md
```

Without these env vars, `Resources/whats-new.json` is left untouched.

---

## After releasing

1. **Smoke-test the auto-update path** — install the previous release on a
   test Mac, click "Check for Updates…", verify Sparkle finds the new
   version, downloads + installs it, and re-launches into the new build.

2. **Verify TCC persistence** (notarized only) — confirm the test Mac
   doesn't re-prompt for Microphone / Speech / Accessibility / Automation.

3. **Bump alpha.N → next number** for the next iteration.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Sparkle.framework: different Team IDs` after auto-update | Re-sign step skipped | Run release.sh; never copy `.app` manually |
| `notarytool submit` hangs | Apple notary service backlog | Wait, or check status with `xcrun notarytool history` |
| `xcrun stapler validate` fails | Notarization rejected | Read the rejection email, fix entitlements |
| Sparkle says "you're up to date" but you just released | Stale URL cache | `rm -rf ~/Library/Caches/cloud.solay.SolWhisper` |
| Tester sees "SolWhisper.app is damaged" | Quarantine flag, ad-hoc build | `xattr -cr /Applications/SolWhisper.app` |
| `EdDSA signature missing` from script | Sparkle SPM not built | Build the project once first to fetch dependencies |
| Appcast version regression | Bumping a lower number | Edit `appcast.xml` to the highest existing version + 1 |

---

## Release checklist (printable)

- [ ] All Sprint 0–9 test-protocol items pass on a clean install
- [ ] Roadmap "Done since last release" items archived
- [ ] `Resources/whats-new.json` reflects the user-visible changes
- [ ] `appcast.xml` will end up with the new version on top after the script runs
- [ ] Tag freed (`gh release view v$VERSION` returns 404)
- [ ] If notarizing: env vars `SW_TEAM_ID`, `SW_DEVELOPER_ID`, `SW_NOTARIZE_PROFILE` exported
- [ ] Working tree clean (`git status` empty)
- [ ] Run `./scripts/release.sh <version> [notes-file]`
- [ ] Smoke-test auto-update from previous version
- [ ] Announce in #solwhisper-testers
