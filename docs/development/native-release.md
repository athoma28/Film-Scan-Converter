# Native macOS Release

This is the operational release runbook. The packager produces a self-contained
macOS app, a metadata-clean ZIP, and a matching SHA-256 file. It embeds LibRaw's
non-system dependency closure, rewrites load paths, signs dependencies in order,
embeds project and third-party license material, validates the assembled app,
then extracts and validates the exact archive users receive.

## Release modes

`native/package-release.sh` fails closed unless its mode-specific requirements
are met:

- `local` is the default development artifact. It is ad-hoc signed and permits
  a dirty worktree.
- `unsigned-beta` is the transparent technical-beta path. It requires the
  ad-hoc identity (`-`) and a clean worktree unless `ALLOW_DIRTY=1` is set for
  an explicitly non-published rehearsal.
- `public` is the normal distribution path. It requires an exact Developer ID
  Application identity and an existing `notarytool` keychain profile. It signs
  with the hardened runtime, submits to Apple, staples, validates the ticket,
  and runs Gatekeeper assessment before rebuilding the final ZIP.

The current project can publish an unsigned technical beta. It cannot claim an
Apple-notarized release until a Developer ID certificate and notary credentials
are available.

## Build the unsigned beta

Install LibRaw, start from a clean release commit, and run:

```sh
brew install libraw
RELEASE_MODE=unsigned-beta \
RELEASE_LABEL=beta.1 \
APP_VERSION=0.1.0 \
BUILD_NUMBER=1 \
native/package-release.sh
```

On an Apple Silicon build machine this creates:

- `dist/Film Scan Converter.app`
- `dist/Film-Scan-Converter-0.1.0-beta.1-apple-silicon.zip`
- `dist/Film-Scan-Converter-0.1.0-beta.1-apple-silicon.zip.sha256`

The architecture suffix is derived from the built executable; a future
two-architecture build is automatically labeled `universal`. The archive
contains the app plus copies of `LICENSE.txt`, `THIRD_PARTY_NOTICES.md`,
`RELEASE_NOTES.md`, and `BUNDLED-LIBRARIES.txt`. The same files are embedded in
the app's Resources directory, and the app exposes the notices from its menu.

Test Launch Services rather than only the SwiftPM executable:

```sh
open "dist/Film Scan Converter.app"
```

Confirm that the app becomes frontmost, has its own Dock/menu-bar identity, and
can receive a supported image through Finder's Open With command. A rehearsal
from an intentionally dirty tree may use `ALLOW_DIRTY=1`; never publish such an
artifact.

`SKIP_BUILD=1` is only for packaging iteration after both release executables
have already been built. Do not use it for a release candidate.

## Build, notarize, and assess a public artifact

List available identities:

```sh
security find-identity -v -p codesigning
```

Store notary credentials once in the login keychain:

```sh
xcrun notarytool store-credentials film-scan-notary \
  --apple-id "developer@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Then run the complete gated path:

```sh
RELEASE_MODE=public \
RELEASE_LABEL=beta.1 \
APP_VERSION=0.1.0 \
BUILD_NUMBER=1 \
SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
NOTARY_PROFILE=film-scan-notary \
native/package-release.sh
```

The script submits the first ZIP, staples and assesses the accepted app, then
recreates and revalidates the ZIP so the distributed copy contains the ticket.
Any signing, notarization, stapling, Gatekeeper, dependency-closure, license,
signature, or archived-copy failure stops the build.

## Release checks

Before attaching artifacts to a GitHub prerelease:

1. Run the native and legacy test suites and require green GitHub Actions runs.
2. Confirm the source commit is the commit represented by the release tag.
3. Verify the checksum with `shasum -a 256 -c <artifact>.sha256`.
4. Inspect the ZIP for unexpected `._`/AppleDouble files and confirm all four
   release documents exist at archive root and inside the app.
5. Reopen TIFF, JPEG, PNG, and DNG fixtures. TIFF/JPEG/PNG must report named
   sRGB profiles; DNG must validate its output-referred linear-sRGB metadata.
6. Exercise import, preview, correction, crop/perspective/frame, preset,
   multi-file export, cancellation, collision, and relaunch paths.
7. Make the GitHub release a **prerelease**, include the known limitations, and
   attach both the ZIP and checksum.

## Independent-Mac smoke check

The final distribution proof uses a supported Mac without the source checkout
or Homebrew LibRaw:

1. Download the GitHub asset and verify its checksum.
2. Expand it, move the app to Applications, and launch it using the documented
   path. An unsigned beta uses Control-click **Open** once; a notarized artifact
   must pass Gatekeeper without a bypass.
3. Import a standard image and representative camera RAW, compare corrected
   preview orientation to reopened full-resolution output, and exercise Fit,
   pan, zoom, Original comparison, and the preview-source badge.
4. Export and reopen TIFF, JPEG, PNG, and DNG. Confirm dimensions, orientation,
   depth, metadata, and color interpretation.
5. Confirm cancellation/failure leaves no misleading partial output, camera
   permission text appears when needed, and settings/presets persist after
   relaunch.

Record macOS version, Mac model/architecture, app version/build, artifact hash,
signing mode, notary submission ID when applicable, and results in the release
notes or release discussion.
