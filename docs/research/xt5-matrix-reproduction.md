# Reproducing the X-T5 color-policy experiment

The [October 3 results](xt5-matrix-study-2026-10-03.md) are the canonical account
of the completed experiment. The local compact bundle is
`dist/xt5-matrix-study-2026-10-03/`. Scores, settings, validation reports, logs,
hashes, pinned renderers and source/input snapshots remain; generated galleries, numeric image
caches and exports are retired. Reproduction creates fresh temporary outputs.
The original compact bundle cannot be resumed or rescored without its pixels.
Large reports, including `analysis/scores.json.gz`, are losslessly compressed;
use the [restoration command](../development/building.md#local-generated-data)
when a reader requires plain JSON.

## Inputs and environment

The original experiment used 40 complete RAF/XMP/edited-JPEG triplets across
eight stocks: 34 color and six monochrome frames. Lucky DSCF5671 and DSCF5676
had incomplete references and were excluded. `inventory.json` records the
selected inputs; `study.json` records 125 input hashes: 120 triplet files, two
unpaired XMPs and three historical median metadata files. Keep the authorized
private originals in `sample-raw/`; they are not distributed with the repository.

Preference replay requires the unchanged tracked ledger and the original
`dist/camera-raw-study/<stock>/<frame>/metadata.json` for Fuji DSCF3115 and Phoenix
DSCF3079/DSCF3086. These medians are retained in the reproduction-input bundle.
Freshly measured medians do not reproduce the historical preferred looks.

The recorded environment was macOS 15.7.9 arm64, Swift 6.1.2, LibRaw 0.22.2,
Python 3.12.7, NumPy 2.2.1, OpenCV 4.10.0 and Pillow 11.1.0. Use the
[color runbook](../development/color-evaluation.md#reproduce-a-study) for setup.
Normal macOS graphics access is required for actual Metal comparisons.
Changing source, inputs, decoder/tool versions or environment creates new
evidence; matching source alone does not guarantee identical PNG/JPEG bytes.

## Replay the method on the current engine

From the repository root, choose an unused output directory. The runner copies
the current working production sources, including uncommitted changes. It does
not rebuild historical HEAD. Run these stages in order:

```sh
.venv/bin/python native/diagnostics/color-study.py doctor \
  --workflow skin --output dist/xt5-matrix-next
.venv/bin/python native/diagnostics/run-xt5-matrix-study.py prepare \
  --output dist/xt5-matrix-next
.venv/bin/python native/diagnostics/run-xt5-matrix-study.py build \
  --output dist/xt5-matrix-next
.venv/bin/python native/diagnostics/run-xt5-matrix-study.py matrix-state \
  --output dist/xt5-matrix-next
.venv/bin/python native/diagnostics/run-xt5-matrix-study.py render \
  --output dist/xt5-matrix-next
.venv/bin/python native/diagnostics/run-xt5-matrix-study.py score \
  --output dist/xt5-matrix-next
```

Use one renderer process per output. Repeating `render` resumes only when
sources, inputs, environment and completed artifact hashes still match. Scoring
requires the full cohort and verifies completion hashes. The original candidate
was rejected: its retained registration gates made scoring exit 1 after all
renders completed, and the runner marked `study.json` interrupted. Read the
written `analysis/scores.json` and completion counts; a nonzero exit is not
permission to omit difficult frames or delete a provenance guard.

## Reconstruct the recorded historical source

Historical HEAD was `2b4da0930df3ccebc08c1e3197a8ec242df448ac` plus a dirty working
tree. Checking out that commit alone is insufficient. The retained
`snapshot/FilmScanEngine/` contains the exact package sources, tests and fixtures,
with the isolated candidate guard added. `supplemental/reproduction-inputs/`
contains archived diagnostic sources, annotations, the ledger and median inputs.
Its `manifest.json` records their hashes; the matrix-state C++ source is pinned
separately by `study.json` and included in that bundle.

Assemble a disposable isolated tree without replacing current application files.
The following preparation verifies the retained bundle, removes only the
diagnostic guard, checks all original production/diagnostic/input hashes and
copies the private corpus as APFS clones. The input files must be real files in
the isolated tree: a `sample-raw` symlink fails the runner's resolved-path matrix
gate. Ordinary copying can replace `cp -cR` on a filesystem without clones.

```sh
python3 - <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path.cwd()
bundle = repo / 'dist/xt5-matrix-study-2026-10-03'
state = json.loads((bundle / 'study.json').read_text())
capsule = bundle / 'supplemental/reproduction-inputs'
manifest = json.loads((capsule / 'manifest.json').read_text())['sha256']

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

for relative, expected in manifest.items():
    assert sha(capsule / relative) == expected, relative

replay = Path(tempfile.mkdtemp(prefix='fsc-xt5-history-'))
package = replay / 'native/FilmScanEngine'
shutil.copytree(bundle / 'snapshot/FilmScanEngine', package)
header = package / 'Sources/CLibRawShim/RawDecodeCompatibility.h'
guard = ('#if defined(FSC_DIAGNOSTIC_UPSTREAM_XT5_MATRIX)\n'
         '    // Isolated experiment only: retain LibRaw color state, preserve geometry.\n'
         '    (void)raw;\n    return;\n#endif\n')
text = header.read_text()
assert text.count(guard) == 1
header.write_text(text.replace(guard, '', 1))
for relative, expected in state['productionSources'].items():
    assert sha(package / relative) == expected, relative

for relative in manifest:
    target = replay / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(capsule / relative, target)
cpp = replay / 'native/diagnostics/xt5-matrix-state.cpp'
assert sha(cpp) == state['matrixState']['sourceSHA256']
for relative, expected in state['inputProvenance']['diagnosticSources'].items():
    assert sha(replay / relative) == expected, relative

subprocess.run(['cp', '-cR', str(repo / 'sample-raw'),
                str(replay / 'sample-raw')], check=True)
for relative, expected in state['inputProvenance']['inputs'].items():
    assert sha(replay / relative) == expected, relative
(replay / '.venv').symlink_to(repo / '.venv', target_is_directory=True)
subprocess.run(['git', 'init', '-q', str(replay)], check=True)
subprocess.run(['git', '-C', str(replay), 'add', 'native', 'docs'], check=True)
subprocess.run(['git', '-C', str(replay), '-c', 'user.name=FSC reproduction',
                '-c', 'user.email=reproduction@localhost',
                '-c', 'commit.gpgSign=false', 'commit', '-qm',
                'Restore recorded X-T5 experiment sources'], check=True)
print(replay)
PY
```

Change to the printed directory and run the ordered commands above, using its
fresh `dist/xt5-matrix-next` output. Verify the environment against the recorded
versions before claiming a historical replay. The new temporary Git commit and
absolute paths intentionally produce different manifest provenance; compare
source/input hashes, pixels and scores rather than expecting `study.json` to be
byte-identical. The candidate guard will be added again by `prepare` in the new
snapshot, leaving the isolated production source intact.

## Independent validation and photographic review

The runner emits native parser/CPU checks, actual 900px Metal comparisons,
decode-stage hashes and full-JPEG metadata. To repeat independent JPEG
decompression and source/fixture checks, copy the retained
`supplemental/export-validation/validate.py` into the same relative directory
inside the fresh output, then run:

```sh
.venv/bin/python dist/xt5-matrix-next/supplemental/export-validation/validate.py --final
```

For the independent full-registration sensitivity, copy only the retained
`supplemental/full-registration/check.py` and `score-sensitivity.py` into that
relative directory inside the fresh output. In those disposable copies replace
the hard-coded `ROOT` and `STUDY` assignments with:

```python
ROOT = Path(__file__).resolve().parents[4]
STUDY = Path(__file__).resolve().parents[2]
```

Record this path-only script change in the rerun's provenance, then run `check.py`
followed by `score-sensitivity.py` with the same Python. Do not copy old generated
registration reports into the new output; their cached hashes bind old pixels.

Inspect registration, all individual skin/control masks, all full Clean pairs
and saved preferences, and representative decompressed 1:1 JPEG crops. The
original inspection records remain historical evidence; a new render requires
its own visual review. Full outputs are 7752 × 5184; 900px GPU comparisons do not
prove full-resolution Metal equality or app interaction performance.

After recording fresh results, failures and review findings, compact the output
under the [retention policy](../development/documentation-maintenance.md#keeping-evidence-available).
Temporary full exports and build products can use gigabytes during reproduction;
they do not belong in the permanent report bundle. Remove the disposable tree
when its results and required inputs have been retained.
