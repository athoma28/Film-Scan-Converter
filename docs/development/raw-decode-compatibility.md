# RAW Decoder Upgrade Compatibility

## September 14, 2026: X-T5 On LibRaw 0.22.2

The Homebrew upgrade from LibRaw 0.21.4 to 0.22.2 changed the source supplied to
existing X-T5 film looks and saved geometry. The frozen camera-scan test failed
at the demosaiced-image boundary; the unpacked sensor mosaic still matched.
The full-resolution correction reference also failed all five scenarios.
Neither fixture was regenerated.

Comparing the old packaged 0.21.4 library with the installed 0.22.2 library on
`fuji400-fresh/DSCF2833.RAF` identified two changes:

| Decoder metadata | 0.21.4 | 0.22.2 default |
|---|---|---|
| Unpacked sensor | 7872 × 5196 | 7872 × 5196 |
| Active origin (left, top) | (60, 6) | (0, 6) |
| Active size | 7752 × 5184 | 7752 × 5178 |
| Camera-to-XYZ matrix | Absent | X-T5 matrix present |
| Color conversion | Camera WB, identity camera channels | Camera WB plus the new matrix |

The new active-area override is in LibRaw's
[0.22.2 camera identification table](https://github.com/LibRaw/LibRaw/blob/0.22.2/src/metadata/identify.cpp).
The release also lists X-T5 support among its
[camera changes](https://github.com/LibRaw/LibRaw/blob/0.22.2/Changelog.txt).
This is an application compatibility issue: preserving established negative
conversion output does not establish that the old camera-space rendering is a
calibrated positive-camera rendering or that it is photographically preferable
to the new matrix.

## Application Contract

`CLibRawShim/RawDecodeCompatibility.h` preserves the established source for the
verified, uncropped X-T5 layout. Geometry restoration runs after open and before
unpack or metadata size adjustment, updating both LibRaw geometry copies.
Color restoration runs after unpack and before mosaic binning/processing,
because unpack saves the internal color-conversion flag. It restores the
legacy identity conversion and multipliers while retaining camera WB, black
levels, sensor pixels, and the selected processing profile.

Both the C compatibility decoder and the C++ camera-scan decoder use the same
helper. Thus draft, inspect, full-sensor preview, three-pass export, and output
dimension prediction retain one source coordinate system. The adapted X-Trans
export interpolator and its worker scheduling are unchanged.

The helper checks camera maker/model, X-Trans CFA, non-DNG input, generation-four
RAF metadata, no camera crop, the known sensor and metadata dimensions, and the
specific active-area layout. Color restoration additionally checks the exact
new matrix. Other cameras, converted DNGs, sports/electronic-shutter crops,
different layouts keep LibRaw's behavior; an unrecognized matrix keeps LibRaw's
color processing. Already compatible 0.21.4 metadata is unchanged. This does
not promise general byte identity for arbitrary future LibRaw upgrades.

Existing settings contain no decoder version. Edits created with the temporary,
unadapted 0.22.2 source may need photographic review; there is no reliable basis
for automatically migrating their crop or tone values.

## Legacy RawPy Path

The broader suite exposed two additional issues in `rawPyCompatibility`:

- The stock 0.22 X-Trans interpolator differs from the frozen 0.21.4 one-pass
  output. This profile now reuses the existing vendored interpolator with one
  pass and one worker. Its processing parameters and Bayer path are unchanged.
- In the OpenMP build, the stock `copy_bayer` row loop races when X-Trans
  half-size packing maps adjacent source samples to the same output channel.
  Repeated decodes produced different hashes. The compatibility decoder now
  copies those pixels in serial source order, preserving black subtraction,
  maximum tracking, and the original last-write rule. Other copy paths still
  use LibRaw's implementation. A one-worker Fuji unpack calls the strips
  serially, because delegating to LibRaw's default loop can enter OpenMP even
  when the application requested one worker. This also makes the camera-scan
  serial oracle single-worker on OpenMP builds.

Stage probes located the half-size divergence before color scaling and the
full-size divergence at interpolation. After the repairs, the direct half/full
compatibility outputs match the original packaged 0.21.4 library. A new test
repeats the half-size decode three times against the committed pixel hash.
The app's staged camera-scan preview continues to use its existing bounded
mosaic-binning path.

## Verification

The full release suite reported 626 tests: 615 passed and 11 opt-in benchmarks
were skipped, in 248.012 seconds. It includes all unchanged RAW/correction
references and the real three-frame roll workflow. The final one-worker unpack
hardening subsequently passed all ten focused RAW/roll tests in 79.517 seconds.
The local app and extracted ZIP (0.2.0 build 20260914.2) both pass bundle and
ad-hoc signature validation; artifact provenance is in development status.

The initial six-test camera/correction run reproduced 13 failed assertions in
two tests. A direct production-shim probe after the repair restored 7752 × 5184
metadata and output, with all four C/C++ stage hashes equal to the unchanged
fixture (mosaic, demosaic, processed image, post-ISO image). Compiling the same
production shim against the original 0.21.4 headers and packaged library also
reproduced all four hashes and dimensions.

Synthetic boundary checks compile and run as both C11 and C++14 against LibRaw
0.22.2 and 0.21.4 headers. They verify exact restoration, idempotence, retained
WB/black/orientation metadata, and exclusion of cropped, DNG, other-camera,
incomplete, and changed-layout/matrix inputs. The native CI workflow runs these
checks without requiring the private RAW corpus:

```sh
bash native/test-raw-compatibility.sh
```

Run the native RAW references with the local corpus and normal macOS graphics
access:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/film-scan-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/film-scan-swiftpm-cache \
swift test --disable-sandbox -c release --package-path native/FilmScanEngine \
  --jobs 2 --no-parallel \
  --filter 'CameraScanByteIdentityTests|CorrectionScenarioReferenceTests|RawImageDecoderTests'
```

The full-sensor one-pass preview test now requires exact agreement with metadata
dimensions on both axes. See [current development status](native-macos.md) for
the complete suite and roll-workflow results. Photographic assessment, real
repeated-capture quality, and independent-Mac distribution acceptance remain
open under the [roadmap](../improvements/MacOS-Native-Roadmap.md).
