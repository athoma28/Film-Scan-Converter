# Installation

## Published Beta

The latest published download is
[Film Scan Converter 0.2.0 Beta 1](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.1),
released August 14, 2026 for Apple Silicon Macs running macOS 14 or later.
It predates the current source's inspector and several documented features.
Use a source build for the application described in [How to Use](how-to-use.md).

1. Download the ZIP and matching `.sha256` file from that release.
2. From the download folder, verify the archive:

    ```sh
    shasum -a 256 -c Film-Scan-Converter-0.2.0-beta.1-apple-silicon.zip.sha256
    ```

3. Unzip it and move **Film Scan Converter.app** to Applications.
4. The beta is ad-hoc signed, not Apple-notarized. Use the normal macOS
   per-application [Open confirmation](https://support.apple.com/en-us/102445). Depending on macOS, use Control-click
   **Open**, or attempt launch and then use **System Settings > Privacy & Security >
   Open Anyway** if that option is offered. Do not disable Gatekeeper globally.

The archive includes licensing, notices, release notes, and its bundled-library
manifest. Its [release page](https://github.com/athoma28/Film-Scan-Converter/releases/tag/v0.2.0-beta.1)
owns the binary-specific feature list and limitations.

## Current Source

Requires macOS 14 or later, Swift 6 through Xcode/Command Line Tools, and Homebrew.
Intel source builds are outside the distributed Apple Silicon test matrix.

```sh
brew install libraw
git clone https://github.com/athoma28/Film-Scan-Converter.git
cd Film-Scan-Converter
swift run --package-path native/FilmScanEngine FilmScanConverterMac
```

For an existing checkout, run the final command or `./run-swift.sh` from its root.
To create a local self-contained app:

```sh
RELEASE_MODE=local native/package-release.sh
```

The result is `dist/Film Scan Converter.app` plus an archive. A local build is
not a published or notarized release. See [Building](development/building.md)
for tests and the [release runbook](development/native-release.md) for release
modes and final-artifact verification.

## Legacy Python

The Python/Tkinter application is maintenance-only and retains applied dust
removal and cross-platform/ART use. See [legacy policy](legacy-python.md) and
[legacy usage](legacy-usage.md).

Install Python 3.10 or newer and Tkinter for the chosen interpreter. On macOS,
Homebrew supplies Python/Tk packages; on Linux, use the distribution's Tkinter
package. The Windows Python installer can include Tcl/Tk.

From the repository root, create and activate a virtual environment, then run:

```sh
python -m venv .venv
# macOS/Linux: source .venv/bin/activate
# Windows PowerShell: .venv\Scripts\Activate.ps1
python -m pip install -r source/requirements.txt
cd source
python "Film Scan Converter.pyw"
```

Tkinter is an interpreter/system dependency, not a pip-installed package.
Report installation problems with the app version, platform, interpreter, and
error through the [bug template](https://github.com/athoma28/Film-Scan-Converter/issues/new?template=bug_report.yml).
