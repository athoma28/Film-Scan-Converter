# Native macOS Release

This is the operational release runbook. Release scope and priority belong in
the [product roadmap](../improvements/MacOS-Native-Roadmap.md); current evidence
and blockers belong in [Native macOS Development Status](native-macos.md).

The native release path produces a self-contained macOS app bundle and ZIP.
It embeds LibRaw and its non-system Homebrew dependencies, rewrites their load
paths to the app bundle, applies hardened-runtime signing, validates the bundle
contract and signature, then extracts the ZIP and repeats bundle/signature
validation against the archived copy.

## Current Status

Bundle assembly, local ad-hoc signing, ZIP creation, extracted-archive
validation, app-icon and document-registration validation, and local packaged
launch are implemented and verified. A Developer ID certificate and Apple
notary credentials are still required to complete notarization, Gatekeeper
validation, and clean-machine installation. Do not describe the app as
generally distributable until those gates pass.

Run Developer ID/notarization and the final clean-machine gate against a
release candidate that has already passed the representative packaged-app
correctness and essential editing-workflow gates. Local packaging checks should
continue throughout development; the final distribution proof should not be
spent on a knowingly incomplete intermediate build.

## Build a Local Validation Artifact

Install LibRaw, then run the packager from the repository root:

```sh
brew install libraw
native/package-release.sh
```

The default build uses version `0.1.0`, build `1`, and an ad-hoc signature. It
creates:

- `dist/Film Scan Converter.app`
- `dist/Film-Scan-Converter-0.1.0.zip`

Test the actual Launch Services path rather than the SwiftPM executable:

```sh
open "dist/Film Scan Converter.app"
```

The bundle includes the app icon, standard macOS application menus, and image
and camera-RAW document registration. Confirm that the app becomes frontmost,
uses its own Dock/menu-bar identity, and can receive a supported file through
Finder's Open With command.

Override release metadata through the environment:

```sh
APP_VERSION=0.2.0 BUILD_NUMBER=42 native/package-release.sh
```

`SKIP_BUILD=1` is available only for iterating on packaging after both release
executables have already been built. Normal release work must not use it.

## Build a Developer ID Artifact

List available identities with `security find-identity -v -p codesigning`, then
pass the exact Developer ID Application identity:

```sh
APP_VERSION=0.2.0 \
BUILD_NUMBER=42 \
SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
native/package-release.sh
```

The script signs embedded libraries before signing the app with the hardened
runtime and camera entitlement. It then runs the native bundle validator and
`codesign --verify --deep --strict` before creating the ZIP, extracts the ZIP,
and repeats both checks against the archived app.

## Notarize and Staple

Store credentials once in the login keychain:

```sh
xcrun notarytool store-credentials film-scan-notary \
  --apple-id "developer@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Submit the Developer ID-signed ZIP and wait for the result:

```sh
xcrun notarytool submit dist/Film-Scan-Converter-0.2.0.zip \
  --keychain-profile film-scan-notary \
  --wait
```

After acceptance, staple the ticket to the app, validate it, and recreate the
ZIP so the distributed archive contains the stapled app:

```sh
xcrun stapler staple "dist/Film Scan Converter.app"
xcrun stapler validate "dist/Film Scan Converter.app"
spctl --assess --type execute --verbose=2 "dist/Film Scan Converter.app"
rm dist/Film-Scan-Converter-0.2.0.zip
ditto -c -k --keepParent \
  "dist/Film Scan Converter.app" \
  dist/Film-Scan-Converter-0.2.0.zip
```

Apple requires `notarytool` for the current notary service; `altool` is not a
supported fallback.

## Clean-Machine Release Gate

Validate the final ZIP on a supported Mac that does not have Homebrew LibRaw or
the source checkout:

1. Download or copy the ZIP as a user would and expand it.
2. Move the app to `/Applications`.
3. Confirm the first launch passes Gatekeeper without a bypass.
4. Import and preview one standard image and representative supported RAWs;
   verify provisional-to-authoritative replacement does not change orientation.
5. Exercise the default power-law path, density/flat-field path, crop,
   perspective, frame, preset, and copy/paste behavior.
6. Export TIFF, JPEG, PNG, and DNG outputs and reopen them. Verify dimensions,
   orientation, pixels, profile, and metadata as applicable.
7. Exercise cancellation, destination collisions, and an unwritable
   destination; confirm no misleading partial file remains.
8. Confirm camera permission text appears when live preview is opened.
9. Relaunch the app and verify per-file settings and named presets persist.

Record the macOS version, hardware architecture, app version/build, signing
identity, notarization submission ID, and results in the release notes.
