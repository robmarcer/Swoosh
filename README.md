# Swoosh

A lightweight, controller-first game launcher for Apple silicon Macs.

Swoosh turns a folder of converted Switch game apps into a fullscreen library. Browse with a controller, launch a game, and return to the library when it closes. No accounts, streaming service, or online catalogue required.

## Requirements

- An Apple silicon Mac (M-series), running macOS 14 or later.
- Converted games packaged as runnable macOS `.app` bundles, with their required data.
- An optional macOS-compatible controller with an extended gamepad layout. Keyboard and mouse navigation are also supported.

Swoosh is a launcher, not an emulator or converter. It does not include games, keys, firmware, or conversion tools. `.nsp` and `.xci` files are not playable library entries. Game compatibility and performance depend on the converted build.

## Install

1. Download and unzip the Apple silicon release.
2. Move `Swoosh.app` to Applications and open it.
3. Add converted games to `~/Games/Switch/`. Swoosh creates this folder on first launch.

The release is locally ad-hoc signed and is not notarized with an Apple Developer ID. macOS may require approval in System Settings → Privacy & Security before opening it.

## Adding games with NXnative

[NXnative](https://github.com/seedds/nxnative) is a separate open-source project for running supported Switch games natively on Apple silicon, with graphics translated to Metal. It provides the conversion and runtime; Swoosh provides the controller-driven library and launches the resulting macOS app.

Use only game data and keys you are legally entitled to obtain and use. Check the rules for backups, extraction and copy-protection circumvention in your jurisdiction; owning a game does not automatically make every extraction or conversion step lawful. For a U.S. example, see the [Copyright Office’s Section 1201 guidance](https://www.copyright.gov/1201/). Swoosh supplies no game files or keys, and converted game bundles must not be distributed without the necessary rights.

1. Start with your own lawfully obtained game backup and any required keys. Follow [NXnative’s setup instructions](https://github.com/seedds/nxnative/blob/main/README.md) and check its [per-game compatibility notes](https://github.com/seedds/nxnative/blob/main/dm/games/README.md).
2. Follow the [NXnative Mac build instructions](https://github.com/seedds/nxnative/blob/main/docs/development.md#a-mac-only-build-for-development), using its `--platform mac` target. Test the game directly before adding it to Swoosh; support depends on the game, its version and the runtime build.
3. Package the working Mac host as a macOS `.app` whose executable starts it with the correct game-data and save paths. Upstream’s Mac target is a development host and does not currently produce a ready-made Mac app, so this wrapper is an additional step. An iPhone/iPad `.ipa` cannot be added to Swoosh.
4. Put the `.app` and its required data together in an individual folder under `~/Games/Switch/`, following the layout below. Keep the app’s relative data paths intact. Swoosh will discover it automatically.

Swoosh does not obtain games, extract keys, convert archives or apply game updates. Keep source archives, keys and converted game data outside this repository.

## Library layout

```text
~/Games/Switch/
  Aurora/
    Aurora.app
    GameData/
    cover.jpg         # optional; cover.png also works
  Orbit.app           # self-contained apps can live at the top level
```

Discovery supports apps at the library root or one folder below it. It skips hidden entries, shows broken bundles and non-executable apps with setup diagnostics, and does not descend into game data. Symlinks to app bundles are supported and deduplicated. The library refreshes every two seconds and preserves the selected game when possible.

Keep any relative app/data layout required by the converted build. Swoosh does not repair bundle paths or convert games. New game folders appear automatically.

## Setup checks

Press **X** on a controller or **D** on the keyboard to inspect the selected game. Broken app metadata, missing executables and execute-permission problems block launch and stay visible in the library. Use **Recheck** after repairing the installation.

A per-game `SwooshGame.json` may declare `"requiredPaths": ["GameData/content", "GameData/profile"]`. These paths are relative to the manifest and must stay inside the individual game folder. Missing or unreadable declared paths block launch. Without declared requirements, data compatibility is explicitly unverified; Swoosh does not guess a runtime layout.

## Persistent saves and backups

Save management is opt-in per game because a launcher cannot safely infer arbitrary runtime save paths. Add a `saves` entry to the per-game `SwooshGame.json` alongside verified `titleID` and `contentVersion` metadata:

```json
{
  "titleID": "0100ABCDEF120000",
  "contentVersion": 65536,
  "saves": {
    "mode": "environment",
    "path": "~/Library/Application Support/ExampleRuntime/Orbit/save",
    "environmentVariable": "DM_SAVE"
  }
}
```

`path` explicitly identifies the existing save directory for migration. It can be absolute, start with `~/`, or be relative to the per-game manifest. The source folder must exist for the first migration; create an empty save folder explicitly for a new game. Do not point it at a game-data root or unrelated folder. A verified title ID is required; names are display labels, never save identities.

Swoosh copies and verifies the existing saves, keeping the originals, then stores authoritative saves in `<save folder>/<titleID>/live/`. The default save folder is `~/Library/Application Support/Swoosh/Saves/`. Updates, moves, removal and reinstallation of game files do not remove these saves. Reinstalling the same verified title reconnects them. Existing managed saves take precedence over a reinstalled game's initial saves; originals and conflicting copies remain recoverable.

**Environment mode requires the app wrapper to honor the supplied variable.** For NXnative, Swoosh supplies `DM_SAVE` pointing to external storage. A shell wrapper must preserve an incoming value, for example `export DM_SAVE="${DM_SAVE:-$STATE_DIR/save}"`; a wrapper that unconditionally assigns DM_SAVE would bypass protection. Test the wrapper's behavior before declaring this mode. NXnative's committed `_device` companion saves are included automatically. Other runtimes can declare `companionSuffixes` explicitly.

For runtimes that require saves at their original location, use `"mode": "copy"` and omit `environmentVariable`. Swoosh backs up the external saves, records a session, copies them into the configured folder before launch, and verifies and syncs them back after exit. Interrupted sessions are recovered before the next launch. A running game, missing recovery source, or conflicting external changes blocks preparation instead of overwriting progress. Recovery copies are retained under the title's `Recovery/` folder when manual conflict resolution is needed. Uncommitted runtime work cannot be guaranteed recoverable.

Press **X / D → Saves and backups** for backup history, total storage, location, and retention (5, 10 or 20 snapshots; default 10). Backups are always made before managed launches. Restore defaults to Cancel, verifies the selected backup, and backs up current saves before replacing them. Save operations block launch and launcher shutdown until complete; restore is unavailable while the game is running. Saves, backups and recovery copies remain local. Games without explicit save configuration continue to use their own runtime's save handling and are identified as unmanaged in the save screen.

## Artwork

Swoosh first checks Nintendo’s game catalogue for original artwork with at least 1000 pixels on each side. It verifies the downloaded dimensions and upgrades older low-resolution cache entries automatically. It falls back to Wikipedia’s [PageImages API](https://www.mediawiki.org/wiki/API:Pageimages) when an original is unavailable. Matching requires an exact game title, a unique exact Nintendo subtitle, or an explicit Wikipedia redirect; unrelated search results are ignored. Some titles may not have a matching image.

Downloads are on by default and can be disabled in Settings → Download artwork; already cached images remain visible. Only game titles are sent to Nintendo and Wikipedia; local paths, game data and saves are not uploaded. Images and source links are cached in `~/Library/Caches/Swoosh/Artwork/` so artwork remains available offline. The selected game’s **Artwork** link opens the provider’s source page. Downloaded artwork is not bundled with Swoosh releases.

Your own `cover.jpg` or `cover.png` beside an app inside its individual game folder always takes priority. Missing or unavailable artwork leaves a title card. Failed downloads back off for 15 minutes, and missing matches are cached for seven days.

## Controls

| Action | Controller | Keyboard |
| --- | --- | --- |
| Browse | D-pad / left stick | Arrow keys |
| Play / confirm | A (bottom face button) | Return / Space |
| Back / cancel | B (right face button) | Escape |
| Settings | Menu / Start | S or Command-comma |
| Check game updates | Y (top face button) | R |
| Game controls during a game | Hold View + Menu for 1.5 seconds | Switch to Swoosh and choose Quit game |

Holding the home shortcut shows progress without taking focus from the game, then opens **Resume game**, **Return to library**, and **Quit game…**. Resume is selected by default. Return to library leaves the game running with a visible resume control; another game cannot start until it exits. Quit opens a second confirmation with **Keep playing** selected by default. Save in the game before quitting. Swoosh sends a normal macOS quit request and never force-kills a game. The home chord requires a controller exposing both Menu and Options/View buttons; the foreground game also receives those buttons.

Swoosh passes `DM_FULLSCREEN=1` to launched games. NXnative builds supporting that flag start fullscreen; other apps control their own display mode. It tracks the launched application, reattaches already-running library apps after a launcher restart, and brings the library forward when a tracked game exits. It does not distinguish normal exits from crashes or resume unsaved progress.

Settings provide fullscreen, automatic artwork downloads and opt-in launch at login. Login startup requires a packaged application installed at a stable location, such as Applications. Any macOS approval remains in System Settings; Swoosh does not change login or disk-encryption settings.

Only one Swoosh instance can run on a Mac at a time, including copies launched from different folders. Opening a second copy brings the existing instance forward in the same login session. If Swoosh is running under another account, the second copy exits. A kernel lock releases automatically on exit or crash; no stale-process cleanup is needed.

## Game release checks

Games with a newer known release receive an **Update available** badge. Game cards and selection details show **Installed → Latest** versions together. Swoosh reads the active `package` and matching `build` row from NXnative `GameData/profile/<titleID>/game.tsv`; comments and macOS bundle versions are not used as game-version evidence.

Other converted builds can supply `SwooshGame.json` beside the app inside its individual game folder:

```json
{
  "titleID": "0100ABCDEF120000",
  "contentVersion": 65536,
  "displayVersion": "1.0.1"
}
```

Use verified base-title IDs and numeric Switch content versions from the converted package. Marketing version strings are for display only and must not be converted into content-version numbers by guessing. Missing or ambiguous installed metadata remains unknown.

Release checks download the [TitleDB version-history metadata](https://github.com/blawar/titledb/blob/master/versions.json) once per day and compare content revisions locally. No game names, title IDs, paths, keys, saves or game data are sent to this source. Press **Y** or **R** to request a refresh; network checks are limited to one per minute. The cache lives in `~/Library/Caches/Swoosh/Versions/` and remains usable offline.

To label the latest revision, Swoosh requests the title’s published [NXnative game profile](https://github.com/seedds/nxnative/tree/main/dm/games) from GitHub. Only an explicit `build` row matching both the title ID and exact catalogue revision is accepted. This optional lookup sends the title ID in a public profile URL; no local paths, game files, keys or saves are sent. Verified labels are cached under `Versions/Labels/` for offline use. Missing mappings are cached for a day and failures are throttled.

**Latest known** means the installed revision matches this community catalogue, not a guarantee that Nintendo has published nothing newer. Cached data is identified when over a day old. Newer local builds are never marked outdated. If no exact display label is available, **Latest revision …** shows the numeric content version instead of a guessed marketing version. Updating a game still requires a compatible converted build; Swoosh does not download or install game updates.

## Choosing a save folder

Use **Settings → Choose save folder…** to pick a directory on the Mac, an external disk or in iCloud Drive. The native macOS folder picker uses keyboard and mouse. Swoosh creates **Swoosh Saves** inside the chosen directory, or reuses that directory when it is already named Swoosh Saves. The current path is shown in Settings and remembered using a folder bookmark, including after a folder rename.

Swoosh first recovers pending sessions, copies and verifies existing saves and backups, and switches locations only after migration succeeds. The original location is retained. A conflicting title in the destination blocks migration without replacing either copy; an empty installation can reconnect an existing save folder. Storage inside the game library, nested storage roots and changes while a game is running are blocked.

For a custom location, games use a local working copy under `~/Library/Application Support/Swoosh/SaveSessions/<titleID>/`. Committed saves are verified and copied back after exit. Session journals stay local; uncommitted runtime work is not published. On a crash, recovery happens before another launch. If the stored copy changed during play, both versions are retained and launch is blocked for manual conflict resolution. Backups remain in the chosen folder.

For iCloud Drive, use Finder's [Download Now / Keep Downloaded controls](https://support.apple.com/en-gb/guide/mac-help/mchl1a02d711/mac) and allow sync to finish before playing on another Mac. Swoosh coordinates storage access with macOS, requests downloads for evicted files, and blocks operations on undownloaded, conflicting or unavailable storage. It does not silently fall back to empty local saves. iCloud controls upload timing; play on one Mac at a time. Other sync providers must keep the folder locally readable and writable. Desktop validation covers native folder selection, stored-folder persistence, save publishing, backup restore, and macOS reporting the synthetic stored file uploaded to iCloud without unresolved conflicts. Cross-Mac download propagation has not been verified.

## Launcher updates

Settings shows the installed launcher version, checks for a newer eligible release and lets you review its release notes before confirming installation. **Preview + stable** is the default channel during this early preview; choose **Stable only** to exclude prereleases. Swoosh never installs an equal or older version. Updates are optional and cannot run while a tracked game or save operation is active.

For authenticated release access, install [GitHub CLI](https://cli.github.com/) and sign in using `gh auth login` with an account that can read the repository. Swoosh uses the existing CLI authentication and never bundles or reads out tokens. The CLI is optional for playing games; Settings always links to the release page for manual downloads. Failed or offline checks leave the library usable. The release repository is configured in the app's `SwooshReleaseRepository` plist entry.

The updater downloads the matching arm64 asset and checksum file, verifies SHA-256 (including GitHub's asset digest when supplied), rejects unsafe archive paths and symlinks, and checks the extracted bundle's identity, version, minimum macOS version, architecture and signature. Current ad-hoc releases must remain validly ad-hoc signed; a Developer ID distribution must retain its signing team. Ad-hoc signing does not provide notarization or independent publisher authentication; update trust comes from authenticated access to the configured repository.

After confirmation and verification, a helper waits for Swoosh to exit, atomically exchanges the app directories and reopens it. The previous app remains as a hidden `.Swoosh-update-….app` beside the installation for recovery. A failed exchange leaves the original untouched; post-exchange verification or relaunch failure triggers rollback. Metadata, downloads and receipts are kept under `~/Library/Application Support/Swoosh/Updates/`. Game files, settings and saves are outside the replaced app. A read-only or translocated installation requires a manual update; the updater never requests elevated access.

## Build

With Xcode command-line tools and Swift 5.9 or later installed:

```sh
swift test
bash scripts/build-app.sh
open build/Swoosh.app
```

The build script produces an arm64 app bundle. There are no third-party package dependencies.

Run `bash scripts/package-release.sh` to create a signed app ZIP and SHA-256 checksum in `build/`.

With Python 3 available and no Swoosh instance running, `python3 scripts/check-single-instance.py` checks duplicate-copy rejection and restart after a simulated crash in the desktop session.

Development overrides:

```sh
SWOOSH_LIBRARY=/path/to/test-library SWOOSH_WINDOWED=1 build/Swoosh.app/Contents/MacOS/Swoosh
```

## Validation and limits

Automated tests cover discovery layouts, live add/remove scans, invalid apps, symlink deduplication, cover scoping, grid boundaries, instance locking, artwork matching, cached offline images, image validation and network backoff. Build and tests have been run on Apple silicon with macOS 26 and 27 SDKs. Runtime checks cover the native library interface, keyboard navigation, settings, broken-installation diagnostics and repairs, launch/return handling with a test app, duplicate-copy rejection, and restarting after a simulated crash. Desktop checks also cover native save-folder selection, iCloud upload status, local working saves, verified publishing after exit, backup restore with a pre-restore backup, and a complete launcher update with automatic relaunch and preserved preferences.

The background return-home chord has passed a physical-controller test, with controller disconnect/reconnection observed. The restore flow was exercised with keyboard and native controls; a complete controller-only restore walkthrough, cross-Mac cloud download propagation and login startup have not been separately validated. This remains an early preview.

## Contributing

Keep game binaries, game data, keys, saves, personal paths, machine names and local setup details out of source control, screenshots, issues and release assets.
