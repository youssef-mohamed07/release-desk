# Release Desk for Windows and Linux

The Windows and Linux version of Release Desk, written in Flutter. Like the macOS app in the root of this repository, it ships mobile apps to **App Store Connect / TestFlight** and **Google Play**: accounts and teams kept apart, every app, build, tester group and Play track in one place, and a launch console that shows each step of a release as it runs.

It uses the same GitHub Actions workflows as the macOS app (`release-desk-ios.yml`, `release-desk-android.yml`, the same inputs, secret names and `release-desk-aab` artifact), so a project set up from one app works from the other.

## Install

**Windows** (10 or later, x64)

1. Download `ReleaseDesk-windows-x64.zip` from [Releases](../../../releases/latest) and unzip it anywhere.
2. Run `ReleaseDesk\release_desk.exe`. The app is not signed yet, so SmartScreen may stop it the first time: choose **More info → Run anyway**.

Keys and sign-ins are encrypted with Windows DPAPI for your user account.

**Linux** (x64, GTK 3)

1. Download `ReleaseDesk-linux-x64.tar.gz` from [Releases](../../../releases/latest).
2. Unpack and run it:
   ```bash
   tar -xzf ReleaseDesk-linux-x64.tar.gz
   ./ReleaseDesk/release_desk
   ```
3. It needs GTK 3, libsecret and a keyring service. On Ubuntu or Debian:
   ```bash
   sudo apt install libgtk-3-0 libsecret-1-0 gnome-keyring
   ```
   KDE's KWallet works too, through its Secret Service support.

## What needs a Mac, and what doesn't

| | Windows / Linux |
|---|---|
| See App Store Connect apps, builds, TestFlight groups and versions | Yes |
| Ship iOS to TestFlight | Yes, built on **GitHub Actions** (a GitHub macOS runner archives, signs and uploads; this computer then writes What to Test, adds the build to groups, submits for beta review and waits until testers can install it) |
| Build iOS on this computer | No. Apple's tools only run on macOS. Use the macOS app for local iOS builds |
| See Google Play apps and tracks | Yes |
| Ship Android to Play | Yes, built on this computer (Flutter, Android SDK and Java) **or** on GitHub Actions (a Linux runner builds the bundle; this computer downloads it and releases it on Play) |

## Set up

**App Store Connect.** In App Store Connect go to Users and Access → Integrations → App Store Connect API and create a key with the App Manager or Admin role. In Release Desk choose **Connect → App Store Connect**, pick the `AuthKey_….p8` file (the Key ID is read from its name), paste the Issuer ID, and press **Verify**. Release Desk lists the apps the key sees and reads the team ID, then **Connect** saves it.

**Google Play.** Release Desk signs in with an OAuth client that you own:

1. In Google Cloud, create a project and turn on the **Google Play Android Developer API** and the **Google Play Developer Reporting API**.
2. Set up the OAuth consent screen (Audience: External) and add your Google account as a test user.
3. Create an OAuth client of type **Desktop app** and download its `client_secret_….json`.
4. In Release Desk choose **Connect → Google Play**, give it that file, then **Sign in with Google**. Your browser opens; after you allow access it returns to a one-time listener on `127.0.0.1` (OAuth for installed apps with PKCE).

Apps come from the Reporting API. If it does not list them yet, add package names by hand on the account page.

**GitHub Actions builds.** Install the [GitHub CLI](https://cli.github.com) and sign in with `gh auth login`. Release Desk uses its token, or a token you save in Release Desk (**Use a token…** on the Ship screen). The **Build on GitHub** checklist then:

- writes the workflow into your project (`.github/workflows/release-desk-ios.yml` or `release-desk-android.yml`). Commit and push it to the default branch;
- sets the repository secrets with `gh secret set`, from the team's App Store Connect key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`) or from `android/key.properties` (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`).

macOS minutes on private repositories cost more than Linux minutes.

**Android builds on this computer** need Flutter, the Android SDK, Java (`keytool`, found through `JAVA_HOME`, Android Studio's JBR or `PATH`) and an `android/key.properties` with your upload key. Release Desk refuses a debug-signed bundle, except in a rehearsal.

## Using it

- **Overview** shows every app of every team with a five-light lane: uploaded, processed, internal testers, beta review, external testers.
- **Ship** links the Flutter project once, suggests the next build number, and keeps release notes as drafts. **Rehearsal** builds without uploading.
- The **launch console** shows each step with its time and a live log. A stopped iOS release resumes from Apple processing once GitHub has uploaded the build.
- **Ctrl+K** (⌘K on macOS) jumps to any app, team or action. **Ctrl+Shift+P** turns on privacy mode, which blurs names, ids, emails, paths, notes and logs for screen sharing. **Ctrl+R** refreshes.

## Where things are kept

- Accounts, teams, project links and run history (no secrets): `%APPDATA%\Release Desk\workspace.json` on Windows, `~/.config/release-desk/workspace.json` on Linux.
- Keys, Google sign-ins, the OAuth client and a saved GitHub token: the system keychain (DPAPI on Windows, the Secret Service through libsecret on Linux).
- Run logs: the `Logs` folder next to `workspace.json`.

Nothing leaves your computer except calls to Apple, Google and GitHub.

## Build from source

```bash
cd desktop
flutter pub get
flutter test
flutter build windows --release   # on Windows
flutter build linux --release     # on Linux
```

Linux builds need `clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev`. The macOS target exists only to develop the app on a Mac; use the native macOS app there.

The `Desktop (Windows and Linux)` workflow in `.github/workflows/desktop.yml` builds both on GitHub Actions, by hand or on a `v*` tag, and attaches `ReleaseDesk-windows-x64.zip` and `ReleaseDesk-linux-x64.tar.gz` to that tag's release.

`flutter test` covers the App Store Connect ES256 token (the signature checks against the key's public point), the workflows (identical to the macOS app's), Google's PKCE and loopback sign-in, project reading, the workspace file, and renders every screen with sample data. `RD_SHOTS=<folder> flutter test test/ui_smoke_test.dart` also saves a picture of each screen.
