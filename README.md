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

## Library layout

```text
~/Games/Switch/
  Aurora/
    Aurora.app
    GameData/
    cover.jpg         # optional; cover.png also works
  Orbit.app           # self-contained apps can live at the top level
```

Discovery supports apps at the library root or one folder below it. It skips hidden entries, broken bundles and non-executable apps, and does not descend into game data. Symlinks to app bundles are supported and deduplicated. The library refreshes every two seconds and preserves the selected game when possible.

Keep any relative app/data layout required by the converted build. Swoosh does not relocate saves, repair bundle paths, or convert games. New game folders appear automatically.

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
| Return-home confirmation during a game | Hold View + Menu for 1.5 seconds | Switch to Swoosh and choose Quit game |

The home confirmation defaults to **Keep playing**. Move right to select **Quit game**, then confirm. Save in the game before quitting. Swoosh sends a normal macOS quit request and never force-kills a game. The home chord requires a controller exposing both Menu and Options/View buttons; the foreground game also receives those buttons.

Swoosh passes `DM_FULLSCREEN=1` to launched games. NXnative builds supporting that flag start fullscreen; other apps control their own display mode. It tracks the launched application and brings the library forward when it exits. It does not distinguish normal exits from crashes or resume unsaved progress.

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

Automated tests cover discovery layouts, live add/remove scans, invalid apps, symlink deduplication, cover scoping, grid boundaries, instance locking, artwork matching, cached offline images, image validation and network backoff. Build and tests have been run on Apple silicon with macOS 26 and 27 SDKs. Runtime checks cover the native library interface, keyboard navigation, settings, launch/return handling with a test app, duplicate-copy rejection, and restarting after a simulated crash.

Physical controller reconnection, the background return-home chord and login startup still need hands-on validation. This first release is an early preview.

## Contributing

Keep game binaries, game data, keys, saves, personal paths, machine names and local setup details out of source control, screenshots, issues and release assets.
