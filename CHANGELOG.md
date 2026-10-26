# Changelog

## 0.7.3

- Replace the original letter mark with a dimensional mint-and-lime folded ribbon icon.
- Package the selected artwork into standard and Retina Dock icon sizes.

## 0.7.2

- Keep updater rollback tests from launching mock apps under the production bundle identity.

- Load the bundled icon directly into the running app’s Dock tile.
- Refresh app registration at startup and the bundle timestamp during packaging to improve icon refresh after upgrades.

## 0.7.1

- Add a native dark-and-lime Dock icon with an original flowing S mark.
- Generate all standard and Retina icon sizes during app packaging.

## 0.7.0

- Choose save storage in Settings, including a folder in iCloud Drive or on an external disk.
- Remember the chosen folder with a bookmark and verify migrations while retaining originals.
- Use local working saves for custom locations, then publish committed progress after exit with conflict checks.
- Keep session journals local, recover interrupted sessions, and block unavailable or undownloaded storage instead of creating empty replacements.

## 0.6.0

- Reattach running library games after launcher restarts so saves and updates stay protected.

- Show launcher release checks, installed/latest versions and release notes in Settings.
- Support explicit preview/stable channels and authenticated private-repository downloads through GitHub CLI.
- Verify release checksums, safe archive layout, app identity, version, arm64 architecture and signing identity.
- Stage updates before quitting, atomically exchange app bundles, retain the previous app and roll back installation failures.
- Keep manual updates available when authentication, connectivity or folder permissions prevent automatic installation.

## 0.5.0

- Store managed saves outside game installations, keyed by verified title IDs.
- Support direct runtime save paths and journaled copy-in/copy-back recovery.
- Verify migrations and snapshots, preserve conflicting copies, and block unsafe launches.
- Add controller-accessible backups, confirmed restore, storage totals and configurable retention.
- Preserve NXnative device saves alongside primary saves when using DM_SAVE.

## 0.4.0

- Keep broken installations visible with actionable, controller-accessible setup checks.
- Validate declared required data paths and recheck repairs without restarting.

- Add controller home controls for resume, return to library, and confirmed normal quit.
- Show non-activating hold progress above fullscreen games.
- Keep the running game visible in the library and prevent overlapping launches.
- Require neutral controller input after focus changes and reconnections.

## 0.3.1

- Show installed and latest known versions together on game cards and in selection details.
- Resolve marketing version labels from exact title/revision build rows in published NXnative profiles.
- Cache verified labels for offline use and link to the mapping source.
- Fall back to the latest numeric content revision when no exact display label is available.

## 0.3.0

- Flag games with a newer known release directly on their covers.
- Show installed game versions from explicit manifests or the active NXnative package/build rows.
- Compare numeric content revisions against the TitleDB release catalogue, without guessing marketing version numbers.
- Cache release metadata for offline use and check automatically once a day.
- Add Y / R to check game updates manually, with request throttling.
- Show unknown, cached and newer-than-catalogue states without false update claims.

## 0.2.1

- Prefer original Nintendo catalogue artwork with at least 1000 pixels on each side, verifying downloaded dimensions.
- Upgrade existing low-resolution artwork caches automatically, with Wikipedia as a fallback.
- Show the correct artwork provider in source links.
- Preserve cached images when offline or when a higher-resolution source is unavailable.

## 0.2.0

- Download artwork automatically from matching Wikipedia video game pages, without an API key.
- Cache downloaded artwork and its source for offline use.
- Preserve local cover overrides and leave unmatched games as title cards.
- Add an artwork-download setting and a source link for downloaded images.
- Match explicit redirects, reject unrelated search results, and back off after network failures or missing artwork.
- Add tests for matching, image validation, offline caching and retry suppression.

## 0.1.0

Initial Apple silicon preview.

- Native fullscreen library with visible controller selection and optional cover artwork.
- Automatic discovery and refresh of converted macOS game bundles in `~/Games/Switch/`.
- Controller and keyboard navigation with A to confirm and B to cancel.
- Direct app launch and return to the library when the game exits.
- Confirmed return-home action using View + Menu; normal quit requests only.
- Fullscreen preferences and opt-in launch at login.
- Machine-wide single-instance enforcement, with activation of the existing window.
- Discovery and navigation tests, an app packaging script, and macOS CI.

Physical controller and login-startup validation remain pending. The app is ad-hoc signed, not Developer ID signed or notarized.
