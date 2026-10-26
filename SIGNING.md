# Developer ID release distribution

Preview builds are ad-hoc signed by default. They are not notarized and do not authenticate a publisher independently of the release repository.

For a notarized distribution, the build Mac needs Xcode command-line tools, a valid **Developer ID Application** certificate with its private key in the keychain, and an existing `notarytool` keychain profile. Create and manage those credentials using Apple’s [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). Keep passwords, private keys and API credentials out of this repository and release assets.

```sh
export SWOOSH_SIGN_IDENTITY='Developer ID Application: Example Organisation (TEAMID)'
export SWOOSH_NOTARY_PROFILE='Swoosh'
bash scripts/notarize-release.sh
```

The pipeline checks the existing profile, builds with hardened runtime and a secure timestamp, verifies the Developer ID signature, submits the ZIP and waits for acceptance. It then staples and validates the ticket, runs Gatekeeper assessment, and recreates the ZIP and SHA-256 checksum. Publish only after the complete script succeeds. The submission receipt remains in ignored `build/notarization-result.json`; use its submission ID with `notarytool log` to investigate a rejection.

To produce a signed build without submitting it, set only `SWOOSH_SIGN_IDENTITY` and run `scripts/package-release.sh`. A signed-only build must not be described as notarized. Omitting the identity produces an ad-hoc preview.

## Moving from ad-hoc previews

The updater preserves signing-team identity and rejects an automatic transition from ad-hoc signing to Developer ID, or between different teams. Install the first Developer ID release manually. Settings, registered games and saves remain outside the app bundle. Subsequent Developer ID updates must use the same team; the updater’s checks are not weakened for the transition.

## Validation status

The ad-hoc packaging path and missing-credential failures can be checked without an Apple Developer account. A successful real submission, stapled archive and Gatekeeper assessment still need validation with the publisher’s certificate and notarization profile before a notarized release is published.
