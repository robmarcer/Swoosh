# Changelog

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
