#!/usr/bin/env python3
"""Plan, preflight, or reproduce the paired color studies. See color-evaluation.md.

This runner builds the production renderer, executes the ordered stages, and
guards resumes with content hashes. It never imports presets into the app.
"""
import argparse
import hashlib
import importlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
PACKAGE = ROOT / 'native/FilmScanEngine'
BINARY = PACKAGE / '.build/release/FilmScanLookbook'
CHECKPOINTS = ROOT / 'docs/development/color-preference-checkpoints.json'
STATE = 'color-study-run.json'


def stages(workflow, full=False):
    steps = [('paired-reference-study.py', s) for s in
             ['inventory', 'preferences', 'fit', 'report', 'basic', 'refine', 'transfer', 'automatic', 'report', 'crop']]
    if full:
        steps += [('paired-reference-study.py', 'full')]
    if workflow in ('proimage', 'skin'):
        steps += [('proimage-color-study.py', s) for s in ['fit', 'report']]
        if full:
            steps += [('proimage-color-study.py', 'full'), ('proimage-color-study.py', 'report')]
    if workflow == 'skin':
        steps += [('skin-color-study.py', s) for s in
                  ['segment', 'jacobians', 'fit', 'red_jacobians', 'red_fit', 'red_shared',
                   'joint_proimage', 'joint_proimage_rgb', 'joint_proimage_regions', 'report', 'publish']]
        if full:
            steps += [('skin-color-study.py', 'full'), ('skin-color-study.py', 'publish')]
        # Refresh cross-links after the skin gallery exists.
        steps += [('proimage-color-study.py', 'report')]
    return steps


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def paired_module():
    spec = importlib.util.spec_from_file_location('paired_study', HERE / 'paired-reference-study.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def preflight(workflow, output):
    if sys.version_info < (3, 11):
        raise ValueError('Use Python 3.11+; see requirements-color-study.txt and the runbook.')
    if platform.system() != 'Darwin':
        raise ValueError('The production renderer requires macOS; use the runbook to inspect saved reports elsewhere.')
    versions = {}
    for name in ['numpy', 'cv2', 'PIL']:
        try:
            versions[name] = importlib.import_module(name).__version__
        except ImportError as error:
            raise ValueError(f'Missing {name}; use .venv/bin/python and requirements-color-study.txt.') from error
    if not hasattr(importlib.import_module('cv2'), 'SIFT_create'):
        raise ValueError('OpenCV must provide SIFT_create for registration.')
    for name in ['swift', 'swiftc', 'pkg-config']:
        if not shutil.which(name):
            raise ValueError(f'Missing {name}; see the runbook prerequisites.')
    versions['libraw_r'] = subprocess.check_output(['pkg-config', '--modversion', 'libraw_r'], text=True).strip()
    versions['swift'] = subprocess.check_output(['swift', '--version'], text=True, stderr=subprocess.STDOUT).strip()
    versions['python'] = sys.version
    versions['platform'] = platform.platform()
    frames, incomplete = paired_module().discover(output)
    if not frames:
        raise ValueError('No complete RAF/XMP/JPEG triplets in sample-raw/. The private corpus is not shipped in git.')
    available = {f['stock'] + '/' + f['stem'] for f in frames}
    required = set()
    if workflow in ('proimage', 'skin'):
        required |= {'proimage/DSCF5800', 'proimage/DSCF5809'}
        required |= {f['stock'] + '/' + f['frame'] for f in read(CHECKPOINTS)['frames']}
        extra = {k for k in available if k.startswith('proimage/')} - {'proimage/DSCF5800', 'proimage/DSCF5809'}
        if extra:
            raise ValueError('Adapt the Pro Image patch coordinates/CHOICES for new frames first: ' + ', '.join(sorted(extra)))
    if workflow == 'skin':
        required |= set(read(HERE / 'skin-regions.json')['frames'])
    if required - available:
        raise ValueError('This study uses named frames and annotations. Missing triplets: ' + ', '.join(sorted(required - available)))
    print(f'{len(frames)} complete triplets; {len(incomplete)} incomplete; dependencies available.', flush=True)
    if incomplete:
        print('Excluded: ' + ', '.join(incomplete), flush=True)
    return frames, versions


def provenance(frames, versions, renderer=None):
    sources = set((PACKAGE / 'Sources').rglob('*'))
    sources |= set(PACKAGE.glob('Package.*'))
    sources |= {p for p in HERE.iterdir() if p.suffix in ('.py', '.swift', '.json', '.txt')}
    sources.add(CHECKPOINTS)
    inputs = {Path(f[key]) for f in frames for key in ('raw', 'target', 'xmp')}
    available = {f['stock']+'/'+f['stem'] for f in frames}
    for frame in read(CHECKPOINTS).get('frames', []):
        if frame['stock']+'/'+frame['frame'] in available:
            inputs.add(ROOT / 'dist/camera-raw-study' / frame['stock'] / frame['frame'] / 'metadata.json')
    # Include unpaired XMPs: repairing one changes the discovered cohort.
    inputs |= set((ROOT / 'sample-raw').rglob('*.xmp'))
    hashes = lambda paths: {str(p.relative_to(ROOT)): digest(p) for p in sorted(paths) if p.is_file()}
    return dict(root=str(ROOT), versions=versions, sources=hashes(sources),
                inputs=hashes(inputs), rendererSHA256=digest(renderer or BINARY))


def freeze_renderer(output, previous=None):
    """Use one executable even if an unrelated Swift build replaces .build/."""
    renderer = output / 'renderer' / 'FilmScanLookbook'
    if previous:
        if not renderer.is_file() or digest(renderer) != previous['provenance']['rendererSHA256']:
            raise ValueError('Missing or modified pinned renderer; choose a fresh --output.')
    else:
        renderer.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(BINARY, renderer)
    return renderer


def resume_state(output, resume, workflow, full):
    path = output / STATE
    if path.exists():
        if not resume:
            raise ValueError('Output already has a run. Use --resume with unchanged inputs, or choose a new --output.')
        state = read(path)
        if state.get('schemaVersion') != 1 or state.get('workflow') != workflow or state.get('full') != full:
            raise ValueError('Resume requires the same workflow and --full setting. Choose a new --output.')
        return state
    if resume:
        raise ValueError('No runner provenance to resume. Legacy outputs cannot be adopted; choose a fresh directory.')
    if output.exists() and any(output.iterdir()):
        raise ValueError('Output must be empty. Keep existing study artifacts and choose a new --output.')
    return None


def require_same_provenance(old, current):
    changed = [key for key in current if old.get(key) != current[key]]
    if changed:
        raise ValueError('Cannot resume: changed ' + ', '.join(changed) + '. Use a new --output; do not mix cached renders.')


def check_registration(output):
    report = read(output / 'aligned-inventory.json')
    if not report['frames']:
        raise ValueError('No registered frames; inspect aligned-inventory.json.')
    if report['skipped']:
        print('REGISTRATION EXCLUSIONS: ' + json.dumps(report['skipped']), flush=True)
    for frame in report['frames']:
        a = read(Path(frame['directory']) / 'alignment.json')
        if not (a['inliers'] >= 20 and a['coverage'] >= .35 and a['medianResidualPixels'] <= 1.5):
            raise ValueError(f'Invalid alignment for {frame["stock"]}/{frame["stem"]}')


def check_preferences(output):
    checked = paired_module().check_preferences(output)
    print(f'{len(checked)} fresh preference snapshots match the ledger.', flush=True)


def run(options):
    output = options.output.resolve()
    old = resume_state(output, options.resume, options.workflow, options.full)
    frames, versions = preflight(options.workflow, output)
    env = os.environ.copy()
    env.setdefault('CLANG_MODULE_CACHE_PATH', '/tmp/fsc-clang-cache')
    env.setdefault('SWIFTPM_MODULECACHE_OVERRIDE', '/tmp/fsc-swiftpm-cache')
    print('Building the production release renderer…', flush=True)
    subprocess.run(['swift', 'build', '--disable-sandbox', '-c', 'release', '--package-path',
                    str(PACKAGE), '--product', 'FilmScanLookbook'], check=True, env=env)
    renderer = freeze_renderer(output, old)
    env['FSC_STUDY_RENDERER'] = str(renderer)
    print('Hashing sources, renderer, and source triplets for cache provenance…', flush=True)
    current = provenance(frames, versions, renderer=renderer)
    if old:
        require_same_provenance(old['provenance'], current)
    state = old or dict(schemaVersion=1, workflow=options.workflow, full=options.full,
                        provenance=current, completed=[], status='running')
    output.mkdir(parents=True, exist_ok=True)
    sequence = stages(options.workflow, options.full)
    labels = [f'{i:02d}-{Path(script).stem}-{stage}' for i, (script, stage) in enumerate(sequence, 1)]
    if state['completed'] != labels[:len(state['completed'])]:
        raise ValueError('Recorded stages are not a prefix of this workflow; use a new --output.')
    try:
        for label, (script, stage) in zip(labels, sequence):
            if label in state['completed']:
                continue
            print(label, flush=True)
            state.update(status='running', activeStage=label)
            write(output / STATE, state)
            with (output / (label + '.log')).open('w') as log:
                subprocess.run([sys.executable, str(HERE / script), stage, '--output', str(output)],
                               check=True, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
            if script == 'paired-reference-study.py' and stage == 'fit':
                check_registration(output)
                if options.workflow != 'paired' and read(output / 'aligned-inventory.json')['skipped']:
                    raise ValueError('Resolve registration exclusions before the named-frame follow-ups.')
            if script == 'paired-reference-study.py' and stage == 'preferences':
                check_preferences(output)
            state['completed'].append(label)
            write(output / STATE, state)
        state.update(activeStage='clipboard-probe', status='running')
        write(output / STATE, state)
        print('Validating corrections through the app parser…', flush=True)
        with (output / 'control-probe.json').open('w') as report:
            subprocess.run([sys.executable, str(HERE / 'run-tonality-probe.py'), '--paired-recipes', str(output)],
                           check=True, stdout=report)
        # Reject mixed-source/input results even when the caller never resumed.
        require_same_provenance(current, provenance(frames, versions, renderer=renderer))
        state.update(status='complete', activeStage=None)
        write(output / STATE, state)
    except (Exception, KeyboardInterrupt):
        state['status'] = 'interrupted'
        write(output / STATE, state)
        raise
    gallery = {'paired': 'index.html', 'proimage': 'proimage-review.html', 'skin': 'skin-review.html'}[options.workflow]
    print(f'Complete: {output / gallery}\nReview exclusions, masks, images, and transfer failures before recommending a profile.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['plan', 'doctor', 'run'])
    parser.add_argument('--workflow', choices=['paired', 'proimage', 'skin'], default='paired',
                        help='Cumulative: proimage includes paired; skin includes both.')
    parser.add_argument('--output', type=Path, required=True, help='Fresh artifact directory; use dist/ to keep scans out of git.')
    parser.add_argument('--full', action='store_true', help='Also run the study-specific full-resolution export checks.')
    parser.add_argument('--resume', action='store_true', help='Resume a runner-created directory with identical provenance and options.')
    options = parser.parse_args()
    if options.resume and options.command != 'run':
        parser.error('--resume only applies to run')
    try:
        if options.command == 'plan':
            print('Build FilmScanLookbook (release); fingerprint inputs; then run sequentially:')
            for script, stage in stages(options.workflow, options.full):
                print(shlex.join([sys.executable, str(HERE / script), stage, '--output', str(options.output.resolve())]))
            print(shlex.join([sys.executable, str(HERE / 'run-tonality-probe.py'), '--paired-recipes', str(options.output.resolve())]))
        elif options.command == 'doctor':
            _, versions = preflight(options.workflow, options.output.resolve())
            print(json.dumps(versions, indent=2))
            print('Preflight only; renderer freshness, alignment, and image quality are checked during the run/review.')
        else:
            run(options)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Color study: {error}\nSee docs/development/color-evaluation.md and the active stage log, if created.\n')


if __name__ == '__main__':
    main()
