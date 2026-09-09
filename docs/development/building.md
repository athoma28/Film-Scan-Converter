# Building And Testing

The native package requires macOS 14 or later, Swift 6 (Xcode or Command Line
Tools), and Homebrew LibRaw. Commands below run from the repository root.

```sh
brew install libraw
swift format lint --strict --recursive native/FilmScanEngine/Package.swift native/FilmScanEngine/Sources native/FilmScanEngine/Tests
swift test --package-path native/FilmScanEngine --no-parallel
swift build --package-path native/FilmScanEngine --product FilmScanConverterMac
swift run --package-path native/FilmScanEngine FilmScanConverterMac
```

`./run-swift.sh` is a convenience launcher. Development launch does not prove
Launch Services, bundled dependencies, signing, or the distributed ZIP. Use the
[release runbook](native-release.md) for packaged-app validation.

## Graphics And Release Checks

Run AppKit/Core Image/Metal tests with normal macOS graphics/window access.
A restricted process may fail to create thumbnails, render, or lay out native
views even when CPU-only tests pass. `--disable-sandbox` affects SwiftPM's own
sandbox; it does not grant an external runner access to graphics services.

For release-mode regression with temporary module caches:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache swift test --disable-sandbox -c release   --package-path native/FilmScanEngine --no-parallel
```

After building, use `--skip-build` to run the same binaries again. The standalone
CPU/Metal comparator is an additional opt-in check:

```sh
swift run -c release --package-path native/FilmScanEngine FilmScanPreviewComparator
```

Require Metal availability, 2,725 completed comparisons, zero render failures,
and maximum channel error at most 2/255. See the
[verification summary](native-macos.md#verification-summary) for recorded results.

The [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md) describes local RAW corpus requirements,
opt-in roll tests, and independent-reader checks. [Native package documentation](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md)
lists benchmark commands. [Analysis](../performance/preview-analysis.md) and
[export](../performance/40mp-export.md) reports define comparable workloads.

## Documentation

Build the documentation with MkDocs and the Material theme:

```sh
python3 -m venv /tmp/film-scan-docs-venv
/tmp/film-scan-docs-venv/bin/python -m pip install mkdocs-material
/tmp/film-scan-docs-venv/bin/mkdocs build --strict --site-dir /tmp/film-scan-docs-site
```

## Legacy Python

Set up dependencies using [Installation](../installation.md#legacy-python).
Run the maintenance regression suite from the repository root:

```sh
.venv/bin/python -m unittest discover -s tests -p 'test_*.py'
```

Fixture generators may be run only for an intentional shared-behavior change;
see the [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md). Python packaging is a separate,
platform-specific maintenance task. Build on the target platform and validate
its Tkinter/native dependencies; it is not part of native macOS packaging.
