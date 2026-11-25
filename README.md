# Release Desk

A native macOS app for shipping mobile apps to App Store Connect (and next, Google Play): every account and team kept apart, every app, build, TestFlight group and version in one place, and a release pipeline you launch with one button and watch step by step.

## Run it

```bash
scripts/build-app.sh --open
```

That builds `build/Release Desk.app` (release configuration), draws its icon, signs it with your first *Apple Development* identity (so Keychain access survives rebuilds), and opens it. Set `SIGN_IDENTITY` to pick another identity. Needs macOS 26 and Xcode 26 or later.

For development, `swift build` and `swift test` work as usual; `open Package.swift` opens it in Xcode.

## What it does today

- **Accounts → teams → apps.** Connect an App Store Connect API key per team (Connect sheet: it finds `AuthKey_*.p8` files in `~/.appstoreconnect/private_keys`, `~/private_keys` and `~/Downloads`, verifies the key against Apple and detects the team id before anything is saved). The private key goes to the login Keychain (service `app.releasedesk.credentials`); the rest lives in `~/Library/Application Support/Release Desk/workspace.json`.
- **Overview.** Every app of every team with its real icon (from the latest build), latest build and a five-light lane: uploaded → processed → internal → beta review → external.
- **App page.** Builds as tickets (state, groups, days left), TestFlight groups (tester counts, public link), App Store versions, the What to Test of any build.
- **Ship.** Link the source folder once (Flutter projects under `~/Developer` that build the same bundle id are found for you). Compose: version, build number (next after App Store Connect's highest), tester groups, What to Test per locale (Arabic right-to-left), commits since the last upload, beta review on/off, rehearsal mode. Then launch and watch:

  1. Prepare: checks the project's bundle id, Flutter and Xcode, that the build number is free, writes `version: X+N` to `pubspec.yaml` (optional; never in a rehearsal).
  2. Archive: `flutter build ipa --release --no-codesign --build-name --build-number`.
  3. Pre-sign: ad-hoc signs frameworks and the app with the project's entitlements.
  4. Export & sign: `xcodebuild -exportArchive -allowProvisioningUpdates` with the API key, so Apple's cloud signing makes the distribution signature (works for teams with no registered devices).
  5. Upload: `xcrun altool --upload-app` with the key.
  6. Apple processing: polls until the build is `VALID`.
  7. What to Test: updates the localizations Apple copied from the last build, creates missing ones.
  8. TestFlight groups: adds the build (build-side endpoint, retrying Apple's early 404s every 60 s; internal groups with every build get it on their own).
  9. Beta review: submits when an external group is chosen.
  10. Live for testers: waits for `IN_BETA_TESTING`.

  A rehearsal runs 1–4 and stops with the IPA. Logs are kept per run in `~/Library/Application Support/Release Desk/Logs`. The API key is written to a private temp file only for the run and deleted after.
- **Menu bar and Dock.** Runs in flight show in the menu bar extra and as a Dock badge; a notification says when one lands or stops.

## Command line

`rdesk` reads the same API for scripts and quick checks:

```bash
swift run rdesk apps --key-id KEY_ID --issuer ISSUER_ID
```

Also `builds`, `groups`, `versions` (with `--app APP_ID`) and `team`. It reads the key from `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` or `--key-file`.

## Next

- Google Play: service account per developer account, apps and tracks (internal, closed, open, production), upload AAB, roll out to a track, release notes.
- More than one team at once is already modelled; Play developer accounts slot in under the same accounts.
- New app wizard: register the bundle id and capabilities, create the App Store Connect record, create the Play app, first upload on both stores.
- App Store review: version metadata checks and submit for review.

## Layout

- `Sources/ReleaseKit` — App Store Connect client (JWT ES256 with CryptoKit, JSON:API), Keychain, workspace, Flutter project reader, the release pipeline. No UI.
- `Sources/ReleaseDesk` — the SwiftUI app.
- `Sources/rdesk` — the command line front end.
- `scripts/` — app bundle and icon builders.
