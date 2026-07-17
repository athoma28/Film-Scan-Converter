# Installation

The native Swift/macOS application is the primary product. The legacy Python
application is maintenance-only and remains available for workflows the native
app has not replaced, primarily applied dust removal and cross-platform legacy
use. See
[Native macOS Development](development/native-macos.md) for the active product
and [Legacy Python Application](legacy-python.md) for the retirement policy.

## Native Swift/macOS Application

### Install the public beta

The current binary beta supports Apple Silicon Macs running macOS 14 or later.

1. Download the newest prerelease ZIP and matching `.sha256` file from
   [GitHub Releases](https://github.com/athoma28/Film-Scan-Converter/releases).
2. In Terminal, verify the download from your Downloads folder:

    ```sh
    shasum -a 256 -c Film-Scan-Converter-*.zip.sha256
    ```

3. Unzip the archive and move **Film Scan Converter.app** to Applications.
4. Because this beta is ad-hoc signed rather than Apple-notarized,
   Control-click the app, choose **Open**, then confirm **Open**. This approves
   only this app. Do not disable Gatekeeper or remove quarantine attributes.

The archive includes the GPL license, third-party notices, release notes, and
an exact manifest of bundled libraries. Report problems with the
[bug-report template](https://github.com/athoma28/Film-Scan-Converter/issues/new?template=bug_report.yml).

### Build from source

#### Prerequisites

- macOS 14 or later
- Xcode Command Line Tools or Xcode
- [Homebrew](https://brew.sh)

#### Build and Run

1. Install the required system library:

    ```sh
    brew install libraw
    ```

2. Clone or download the repository.

3. Build and run the native application:

    ```sh
    # Run the default regression suite (performance benchmark skipped)
    swift test --package-path native/FilmScanEngine --no-parallel

    # Build the app
    swift build --package-path native/FilmScanEngine --product FilmScanConverterMac

    # Run the app
    swift run --package-path native/FilmScanEngine FilmScanConverterMac
    ```

4. Or use the provided launcher script from the project root:

    ```sh
    ./run-swift.sh
    ```

To assemble a self-contained local app and ZIP, run
`native/package-release.sh`. See the
[native release guide](development/native-release.md) for the explicit
unsigned-beta and signed/notarized release modes.

## Legacy Python Application (Maintenance Only)

This section installs the maintenance-only legacy Python application.

### Installation from Binaries

Download a legacy build, when available, from
[Film Scan Converter Releases](https://github.com/athoma28/Film-Scan-Converter/releases).

If no binary exists for your platform yet, please use the manual installation.

## Manual Installation

1. Install Python 3.10 or newer from [python.org](https://www.python.org/downloads/).

2. Download the source files from the repository using one of the following methods:
    - Download ZIP:
      Click the "Code" button on the repository page and select "Download ZIP". Extract the downloaded archive.
    - Clone with Git:
      Run the following command in your terminal: `git clone https://github.com/athoma28/Film-Scan-Converter.git`

3. Open the `source` folder in the terminal.

4. Install the required libraries by running the following command in the terminal:

    ```bash
    pip install -r requirements.txt
    ```

5. Run the application by executing the following command in the terminal:

    ```bash
    python "Film Scan Converter.pyw"
    ```

## Manual Installation in Python venv

1. Install Python 3.10 or newer from [python.org](https://www.python.org/downloads/).

2. Download the source files from the repository using one of the following methods:
    - Download ZIP:
      Click the "Code" button on the repository page and select "Download ZIP". Extract the downloaded archive.
    - Clone with Git:
      Run the following command in your terminal: `git clone https://github.com/athoma28/Film-Scan-Converter.git`

3. Open the `source` folder in the terminal.

4. Create and activate a virtual environment:

    ```bash
    python -m venv venv
    # On macOS/Linux (bash):
    source venv/bin/activate
    # On Linux (fish):
    source venv/bin/activate.fish
    # On Windows:
    venv\Scripts\activate
    ```

5. Install the required libraries:

    ```bash
    pip install -r requirements.txt
    ```

6. Run the application:

```bash
python "Film Scan Converter.pyw"
```

## Note on tkinter

The application requires `tkinter` for the GUI. On some platforms this may not
be installable in a venv or through pip.

- On **macOS**, install it with Homebrew:

    ```bash
    brew install python-tk
    ```

- On **Linux** (Debian/Ubuntu):

    ```bash
    sudo apt-get install python3-tk
    ```

- On **Linux** (Arch):

    ```bash
    sudo pacman -S tk
    ```

- On **Windows**, `tkinter` is usually included with the standard Python installer. If you encounter issues, ensure you installed Python from [python.org](https://www.python.org/downloads/).
