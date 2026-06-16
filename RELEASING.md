# Releasing Vara

Vara ships as a Developer ID–signed DMG and auto-updates via **Sparkle**.
Existing installs poll `https://vara.dk/appcast.xml` (the `SUFeedURL`) and offer
the user any newer version listed there.

## One-time setup

1. **Developer ID Application cert** — already installed (Team `3B7KHK6C9K`).
2. **EdDSA signing key** — already generated; the private key lives in the login
   keychain (service *"Private key for signing Sparkle updates"*), the public
   key is `SUPublicEDKey` in `project.yml`.
   - ⚠️ **Back it up now.** If lost, no future update can be signed in a way
     existing installs accept — you'd lose the ability to update users.
     Export: `…/Sparkle/bin/generate_keys -x sparkle_private_key.pem` and store
     it somewhere safe (a password manager / offline), **never** in a repo.
3. **Notarytool profile** (still TODO) — without it `build-dmg.sh` produces an
   un-notarized DMG (Gatekeeper warns on download). Set up once:
   ```sh
   xcrun notarytool store-credentials vara-notary \
       --apple-id "you@example.com" --team-id 3B7KHK6C9K --password <app-specific-pw>
   ```

## Per release

1. **Bump the version** in `project.yml` (`info.properties`), then
   `xcodegen generate`:
   - `CFBundleShortVersionString` — marketing version (e.g. `0.2.0`)
   - `CFBundleVersion` — build number, **must strictly increase** (this is
     Sparkle's `<sparkle:version>`; updates are detected by it)
2. **Build + sign + notarize + appcast item:**
   ```sh
   bash scripts/build-dmg.sh
   ```
   With the notarytool profile present it notarizes, staples, EdDSA-signs the
   final DMG, and **prints a ready-to-paste `<item>`**.
3. **Publish on vara.dk** (the `~/Projekter/vara-www` repo):
   - Copy the DMG to `public/download/Vara-<version>.dmg`
   - Paste the printed `<item>` at the top of `public/appcast.xml`
   - Deploy vara-www to dgx-spark
4. Done — existing Sparkle installs pick it up on their next scheduled check (or
   via **Vara menu → Check for Updates…**).

## How the pieces connect

| Piece | Where |
|---|---|
| Updater + "Check for Updates…" | `App/VaraApp.swift`, `App/CheckForUpdates.swift`, `App/MenuBarContent.swift` |
| Feed URL + public key | `project.yml` → `SUFeedURL`, `SUPublicEDKey` (baked into `App/Info.plist`) |
| Signing + appcast item | `scripts/build-dmg.sh` |
| Hosted feed + DMG | `vara-www/public/appcast.xml`, `vara-www/public/download/` → `https://vara.dk/` |
