# Building

The native Swift/macOS application is the primary product. The Python packaging
notes below are retained only for maintenance of the legacy cross-platform
workflow. See [Legacy Python Application](../legacy-python.md).

The native package requires Homebrew LibRaw:

```sh
brew install libraw
```

Run the native regression gate and build the app:

```sh
swift test --package-path native/FilmScanEngine
swift build --package-path native/FilmScanEngine --product FilmScanConverterMac
swift run --package-path native/FilmScanEngine FilmScanConverterMac
```

Run the GPU-vs-CPU preview comparator:

```sh
swift run --package-path native/FilmScanEngine FilmScanPreviewComparator
```

Or use the convenience launcher from the project root:

```sh
./run-swift.sh
```

Refresh frozen legacy compatibility fixtures only when intentionally changing
shared behavior:

```sh
.venv/bin/python tests/generate_native_snapshots.py
.venv/bin/python tests/generate_raw_decode_reference.py
```

## Legacy Python Packaging

### PyInstaller

PyInstaller bundles your Python app and its dependencies into a single executable.

```sh
pyinstaller --onefile --windowed "Film Scan Converter.pyw"
```

> **MacOS compatibility Warning:** This does not seem to work reliably on macos due to Tkinter. For MacOS use nuitka instead.

### Nuitka

Nuitka compiles Python code to optimized C executables, often resulting in faster and smaller binaries.

> **Compatibility Warning:** Nuitka doesn’t support every Python package or feature out of the box. Some modules may need extra setup or might not work fully.

Windows / Linux:

```sh
nuitka --onefile --standalone --enable-plugin=tk-inter "Film Scan Converter.pyw"
```

MacOS:

```sh
nuitka --standalone --macos-create-app-bundle --enable-plugin=tk-inter "Film Scan Converter.pyw"
```

### Platform Compilation and Cross Platform Compilation

You can build binaries for Windows, Linux, and macOS (both Intel and Apple Silicon) using PyInstaller or Nuitka. However, not all platforms support full cross-compilation:

- **Windows (x86, x64):**
    Can be built natively on Windows, or cross-compiled from Linux using tools like MinGW. Some features may require native Windows builds for best compatibility.

- **Linux (x86, x64, ARM):**
    Can be built natively on Linux or cross-compiled from other platforms. ARM builds (e.g., Raspberry Pi) are easiest when built natively or using Docker with the correct architecture.

- **macOS (x86_64, Apple Silicon):**
  - **x86_64:** Can be built natively on Intel Macs or cross-compiled from Linux/macOS with the right SDKs.
  - **Apple Silicon (arm64):** Native compilation on an Apple Silicon Mac is recommended due to SDK and architecture requirements. Cross-compilation is possible but more complex.

> **Tip:** For best results, build on the target platform or use Docker images that match your target architecture.
