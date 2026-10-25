# Changelog

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
