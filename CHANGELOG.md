# Changelog

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
