# Building And Testing

The native package requires macOS 14 or later, Swift 6 (Xcode or Command Line
Tools), and Homebrew LibRaw plus `pkg-config`. Commands below run from the
repository root.

```sh
brew install libraw pkg-config
bash native/test-raw-compatibility.sh
swift format lint --strict --recursive native/FilmScanEngine/Package.swift native/FilmScanEngine/Sources native/FilmScanEngine/Tests
swift test --package-path native/FilmScanEngine --no-parallel
swift build --package-path native/FilmScanEngine --product FilmScanConverterMac
swift run --package-path native/FilmScanEngine FilmScanConverterMac
```

`./run-swift.sh` is a convenience launcher. Development launch does not prove
Launch Services, bundled dependencies, signing, or the distributed ZIP. Use the
[release runbook](native-release.md) for packaged-app validation.

The native CI workflow runs the C/C++ compatibility gate, Swift regression with
coverage, and app build on macOS 14 and 15. Its macOS 15 job also checks formatting
and assembles/validates an unsigned beta. It does not supply private RAW inputs,
run the standalone comparator, or enable the performance and representative-roll
tests. The [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md)
separates default coverage, local-corpus checks, and opt-in measurements.

## Graphics And Release Checks

Run AppKit/Core Image/Metal tests with normal macOS graphics/window access.
A restricted process may fail to create thumbnails, render, or lay out native
views even when CPU-only tests pass. `--disable-sandbox` affects SwiftPM's own
sandbox; it does not grant an external runner access to graphics services.

For release-mode regression with temporary module caches:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release \
  --package-path native/FilmScanEngine --no-parallel
```

After building, use `--skip-build` to run the same binaries again. The standalone
CPU/Metal comparator is an additional opt-in check:

```sh
swift run -c release --package-path native/FilmScanEngine FilmScanPreviewComparator
```

The default comparator runs both the historical grid and current Film Base /
LookRecipe matrix. Pass `--suite=current` or `--suite=legacy` after the executable
name for a focused rerun. Require Metal, checked/expected case counts to match,
zero render failures, and maximum GPU RGB channel error at most 2/255. Flat
density inputs verify explicit CPU routing, counted separately from GPU
comparisons. Bitmap layout and dimension failures also fail the gate. See the
[verification summary](native-macos.md#verification-summary) for recorded results
and the limits of synthetic coverage.

The [test guide](https://github.com/athoma28/Film-Scan-Converter/blob/main/tests/README.md) describes local RAW corpus requirements,
opt-in roll tests, and independent-reader checks. [Native package documentation](https://github.com/athoma28/Film-Scan-Converter/blob/main/native/README.md)
lists benchmark commands. [Analysis](../performance/preview-analysis.md) and
[export](../performance/40mp-export.md) reports define comparable workloads.

The [RAW upgrade compatibility note](raw-decode-compatibility.md) explains the
narrow X-T5 adapter that preserves the frozen 0.21.4 source contract with
LibRaw 0.22.2. Its C/C++ boundary checks run in CI; exact RAW pixel checks also
require the local corpus. Review both when changing LibRaw.

For the active Camera Raw/film-color investigation, use the
[color evaluation runbook](color-evaluation.md) for dependencies, preflight,
fresh production renders, and preference checkpoints. Its Python runner tests
are separate from Swift and legacy regression discovery:

```sh
.venv/bin/python -m unittest discover -s native/diagnostics \
  -p 'test_color_study.py' -v
```

Those tests validate orchestration and input contracts; they do not refresh the
dated color reports or establish CPU/Metal parity.

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
