# Release Spookky

Public binaries require Developer ID signing, notarization, complete dependency notices, and installation/update evidence. The website shows the source until verified release metadata is published.

## One-time setup

Enroll in the Apple Developer Program or use an existing membership. Add the account in Xcode and create a Developer ID Application certificate. Keep its private key and backup outside Git.

The Sparkle public key is in `release.json`. Its matching private key is stored in the maintainer's login Keychain under the Sparkle account `dev.spookky.app`. Back it up through Sparkle's `generate_keys` export workflow to private storage. Do not paste it into chat, issues, or logs.

Store notarization authentication with `xcrun notarytool store-credentials`. Use a local Keychain profile. CI uses a temporary Keychain, protected environment secrets, and the same update key.

Configure the GitHub `release` environment with maintainer approval. Variables are `APPLE_TEAM_ID` and `DEVELOPER_ID_IDENTITY`. Secrets are `DEVELOPER_ID_CERTIFICATE` (base64 p12), `DEVELOPER_ID_PASSWORD`, `KEYCHAIN_PASSWORD`, `SPARKLE_PRIVATE_KEY`, `NOTARY_APPLE_ID`, and `NOTARY_PASSWORD`. None belong in Git.

## Prepare a draft

Update the version, increasing build number, and channel in `release.json`. Regenerate the Xcode project. Add release notes under `docs/releases/`. Commit the reviewed changes through a PR. Use a clean main checkout whose source and native checks pass.

The **Prepare signed release** workflow builds, signs inside out, notarizes the app and DMG, validates packaged paths, signs the Sparkle feed, and creates a draft release. It preserves existing published releases. It does not publish a binary.

For local preparation, install the pinned build tools in an isolated environment. Use actual identity, team, profile, and tool locations:

```sh
python3 -m venv .cache/release-tools
.cache/release-tools/bin/pip install --require-hashes -r scripts/release-requirements.txt
.cache/release-tools/bin/python scripts/prepare_release.py --help
```

Sparkle tools come from the pinned Xcode package artifact. `SPOOKKY_ED_KEY_FILE` may select a private exported key for CI. Without it, the tools use the `dev.spookky.app` Keychain account. The public key and private signing key must match.

## Installation and updater gates

Test two signed builds through a private staging feed before publication. Keep the staging feed and any transport exceptions confined to QA builds. Re-sign and notarize those builds after changing their feed configuration. Public builds must retain the production HTTPS feed and signed-feed requirement.

Verify browser download, Gatekeeper, drag-to-Applications installation, first launch, both supported Applications locations, and startup from the mounted DMG. Use a clean Mac without Homebrew or Xcode. Verify fresh production metadata and preservation of development and historical data.

Verify manual checks, consent, automatic checks/downloads, Preview selection, disabled updates, offline and interrupted downloads, invalid signatures, save failures, and a postponed restart. Confirm drafts, viewport state, shell process identities, and live reattachment after the actual Sparkle update. A normal app restart is not updater proof.

Record the tested source commit, artifact SHA-256, build numbers, OS/architecture, result, and sanitized evidence in the release notes. Keep raw logs, session content, source paths, and debugging symbols private.

Preview requires signed installation, actual signed update delivery, and supported-OS checks. Stable additionally requires the remaining acceptance gates, including the full eight-hour continuity workload, human input/accessibility, providers, sleep/wake, reboot, and resource measurements.

## Publish verified assets

Inspect the draft's complete asset set. Enable immutable releases before publishing. Publish through GitHub only after the required gates pass. Do not replace assets or reuse a build number.

Download the public DMG again and verify its checksum, signatures, notarization ticket, and install behavior. Then copy the prepared signed `appcast.xml` and `release-manifest.json` into `website/` through a PR. Verify every new enclosure URL against the public release and preserve existing feed entries. Never edit a signed feed without signing it again.

The Pages workflow stages a filtered static site. It updates the download button and feed only after the assets are public. Keep prior release notes, installers, and checksums available.

## Public launch limits

Apple signing credentials and hands-on checks require the maintainer. Do not substitute ad hoc public installers, quarantine overrides, or an unsupported minimum-OS claim. Prepare a Homebrew cask only after Stable verification. Announcements and upstream submissions are separate actions.
