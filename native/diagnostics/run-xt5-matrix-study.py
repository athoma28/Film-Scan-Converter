#!/usr/bin/env python3
"""Isolated, fixed-recipe production A/B for the existing LibRaw X-T5 matrix.

Copies the working production sources; never changes the application's decoder.
Uses color-study.py preflight/provenance and the native XT5MatrixProbe.
"""
import argparse
import difflib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
PACKAGE = ROOT / 'native/FilmScanEngine'
DEFINE = 'FSC_DIAGNOSTIC_UPSTREAM_XT5_MATRIX'
VARIANTS = ('natural', 'clean', 'automatic')


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), HERE / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def read(path):
    return json.loads(path.read_text())


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def source_hashes(package):
    paths = [package / 'Package.swift', *sorted((package / 'Sources').rglob('*'))]
    return {str(p.relative_to(package)): digest(p) for p in paths if p.is_file()}


def environment():
    env = os.environ.copy()
    env.setdefault('CLANG_MODULE_CACHE_PATH', '/tmp/fsc-xt5-clang')
    env.setdefault('SWIFTPM_MODULECACHE_OVERRIDE', '/tmp/fsc-xt5-swift')
    return env


def snapshot(output):
    if output.exists():
        raise ValueError('Use a fresh output directory; existing snapshots are never replaced.')
    snap = output / 'snapshot/FilmScanEngine'
    snap.mkdir(parents=True)
    shutil.copytree(PACKAGE / 'Sources', snap / 'Sources')
    # SwiftPM resolves every declared target even when building one product.
    shutil.copytree(PACKAGE / 'Tests', snap / 'Tests')
    shutil.copy2(PACKAGE / 'Package.swift', snap / 'Package.swift')
    header = snap / 'Sources/CLibRawShim/RawDecodeCompatibility.h'
    original = header.read_text()
    needle = 'static inline void fsc_restore_legacy_raw_color(libraw_data_t *raw) {'
    if original.count(needle) != 1:
        raise ValueError('Compatibility helper changed; review the candidate before adapting it.')
    insertion = ('\n#if defined(' + DEFINE + ')\n'
                 '    // Isolated experiment only: retain LibRaw color state, preserve geometry.\n'
                 '    (void)raw;\n    return;\n#endif')
    header.write_text(original.replace(needle, needle + insertion))
    (output / 'snapshot-color-policy.patch').write_text(''.join(difflib.unified_diff(
        original.splitlines(True), header.read_text().splitlines(True),
        fromfile='production/RawDecodeCompatibility.h', tofile='snapshot/RawDecodeCompatibility.h')))
    state = dict(schemaVersion=1, status='preparing',
                 localHead=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                 productionSources=source_hashes(PACKAGE), snapshotSources=source_hashes(snap),
                 candidateDefine=DEFINE, completed=[],
                 primary='clean; same baseline public parameters in both arms, fresh decode analysis',
                 additional=['natural', 'automatic fixed from baseline', 'five historical preference snapshots'],
                 cohort='All discovered complete pairs; all pairs full resolution both arms',
                 scoring='Blur sigma1.2, RGB MAE in 0-255 levels; shared baseline registration; equal-frame means',
                 acceptance='No promotion from average alone. Flag >1 RGB level or >10% regressions; '
                 'preserve preferred looks. Require matching geometry/unpacked mosaic, full exports, '
                 'exact app parser replay and supported GPU parity <=2/255.')
    save(output / 'study.json', state)
    (output / 'working-tree-at-start.txt').write_text(
        subprocess.check_output(['git', 'status', '--short'], cwd=ROOT, text=True))


def check_sources(output, state):
    if source_hashes(PACKAGE) != state['productionSources']:
        raise ValueError('Production sources changed during the experiment; choose a fresh study.')
    if source_hashes(output / 'snapshot/FilmScanEngine') != state['snapshotSources']:
        raise ValueError('Snapshot sources changed; refuse mixed-source results.')
    for name, expected in state.get('diagnosticHashes', {}).items():
        if digest(HERE / name) != expected:
            raise ValueError('Diagnostic changed after build: ' + name)
        if digest(output / 'snapshot/diagnostics' / name) != expected:
            raise ValueError('Pinned diagnostic changed: ' + name)
    for arm, expected in state.get('rendererHashes', {}).items():
        if digest(output / 'renderer' / arm / 'XT5MatrixProbe') != expected:
            raise ValueError('Renderer changed: ' + arm)


def build(output, state):
    check_sources(output, state)
    snap = output / 'snapshot/FilmScanEngine'
    commands = []
    for arm in ('baseline', 'matrix'):
        scratch = output / 'build' / arm
        command = ['swift', 'build', '--disable-sandbox', '-c', 'release', '--jobs', '3',
                   '--package-path', str(snap), '--scratch-path', str(scratch),
                   '--product', 'FilmScanPreviewComparator']
        if arm == 'matrix':
            command += ['-Xcc', '-D' + DEFINE + '=1']
        commands.append(command)
        subprocess.run(command, check=True, env=environment())
    diagnostic = output / 'snapshot/diagnostics'
    diagnostic.mkdir(exist_ok=True)
    for name in ('XT5MatrixProbe.swift', 'score-xt5-matrix.py', 'run-xt5-matrix-study.py'):
        shutil.copy2(HERE / name, diagnostic / name)
    probe_hashes = {name: digest(diagnostic / name) for name in
                    ('XT5MatrixProbe.swift', 'score-xt5-matrix.py', 'run-xt5-matrix-study.py')}
    for arm in ('baseline', 'matrix'):
        release = output / 'build' / arm / 'release'
        objects = [p for p in shlex.split((release / 'FilmScanPreviewComparator.product/Objects.LinkFileList').read_text())
                   if any('/' + target + '.build/' in p for target in
                          ('FilmScanEngine', 'CLibRawShim', 'FilmScanPreviewRenderer'))]
        if not objects or any(not Path(p).is_file() for p in objects):
            raise ValueError('Incomplete production link objects')
        binary = output / 'renderer' / arm / 'XT5MatrixProbe'
        binary.parent.mkdir(parents=True, exist_ok=True)
        libraries = shlex.split(subprocess.check_output(['pkg-config', '--libs-only-L', 'libraw_r'], text=True))
        command = ['swiftc', '-O', '-Xfrontend', '-disable-access-control',
                   '-module-cache-path', str(release / 'ModuleCache'),
                   '-I', str(release / 'Modules'), '-Xcc',
                   '-fmodule-map-file=' + str(release / 'CLibRawShim.build/module.modulemap'),
                   '-I', str(snap / 'Sources/CLibRawShim/include'),
                   str(diagnostic / 'XT5MatrixProbe.swift'),
                   str(snap / 'Sources/FilmScanConverterMac/CorrectionSettings.swift'),
                   *objects, *libraries, '-lraw_r', '-lc++', '-o', str(binary)]
        commands.append(command)
        subprocess.run(command, check=True, env=environment())
    state['buildCommands'] = commands
    state['diagnosticHashes'] = probe_hashes
    state['rendererHashes'] = {arm: digest(output / 'renderer' / arm / 'XT5MatrixProbe')
                               for arm in ('baseline', 'matrix')}
    state['status'] = 'built'
    save(output / 'study.json', state)


def prepare_inputs(output, state):
    runner = module('color-study')
    frames, versions = runner.preflight('skin', output)
    _, incomplete = module('paired-reference-study').discover(output)
    ledger = read(ROOT / 'docs/development/color-preference-checkpoints.json')
    for entry in ledger['frames']:
        path = ROOT / 'dist/camera-raw-study' / entry['stock'] / entry['frame'] / 'metadata.json'
        if not path.is_file() or not read(path).get('medians'):
            raise ValueError('Missing historical preference medians: ' + str(path))
    provenance = runner.provenance(frames, versions, output / 'renderer/baseline/XT5MatrixProbe')
    selected = dict(versions=versions, inputs=provenance['inputs'], diagnosticSources=provenance['sources'])
    if 'inputProvenance' in state and state['inputProvenance'] != selected:
        raise ValueError('Inputs or environment changed; refuse resume.')
    state['inputProvenance'] = selected
    state['inventory'] = [{k: f[k] for k in ('stock', 'stem', 'raw', 'target', 'xmp', 'monochrome')}
                          for f in frames]
    save(output / 'inventory.json', dict(frames=state['inventory'], incomplete=incomplete))
    save(output / 'study.json', state)
    return state['inventory']


def recipes_for(output, frame):
    base = output / 'baseline/preview' / frame['stock'] / frame['stem']
    return [dict(name=name, parameters=read(base / (name + '.json'))) for name in VARIANTS]


def matrix_state(output, state):
    check_sources(output, state)
    frames = prepare_inputs(output, state)
    includedir = subprocess.check_output(['pkg-config', '--variable=includedir', 'libraw_r'], text=True).strip()
    libdir = subprocess.check_output(['pkg-config', '--variable=libdir', 'libraw_r'], text=True).strip()
    binary = output / 'renderer/xt5-matrix-state'
    source = HERE / 'xt5-matrix-state.cpp'
    command = ['clang++', '-std=c++14', '-Wall', '-Wextra', '-Werror', '-I', includedir,
               str(source), '-L', libdir, '-lraw_r', '-o', str(binary)]
    subprocess.run(command, check=True)
    with (output / 'matrix-state.json').open('w') as stream:
        subprocess.run([str(binary), *[f['raw'] for f in frames]], check=True, stdout=stream)
    state['matrixState'] = dict(sourceSHA256=digest(source), binarySHA256=digest(binary),
                               reportSHA256=digest(output / 'matrix-state.json'), compileCommand=command)
    save(output / 'study.json', state)


def run_frame(output, state, arm, tier, group, frame, recipes=None):
    key = frame['stock'] + '/' + frame['stem']
    label = arm + '/' + group + '/' + key
    directory = output / arm / group / key
    record = output / 'completion' / (label + '.json')
    if label in state['completed']:
        hashes = read(record)
        if any(not (directory / p).is_file() or digest(directory / p) != h for p, h in hashes.items()):
            raise ValueError('Completed artifact changed: ' + label)
        print('verified ' + label, flush=True)
        return
    job = dict(key=key, raw=frame['raw'], target=frame['target'], directory=str(directory),
               stock=frame['stock'], monochrome=frame['monochrome'])
    if recipes is not None:
        job['recipes'] = recipes
    request = output / 'jobs' / (label + '.json')
    save(request, dict(arm=arm, tier=tier, frames=[job]))
    log = output / 'logs' / (label + '.log')
    log.parent.mkdir(parents=True, exist_ok=True)
    state.update(status='running', activeStage=label)
    save(output / 'study.json', state)
    print('render ' + label, flush=True)
    started = time.time_ns()
    with log.open('w') as stream:
        result = subprocess.run([str(output / 'renderer' / arm / 'XT5MatrixProbe'), str(request)],
                                env=environment(), stdout=stream, stderr=subprocess.STDOUT)
    metadata = directory / 'metadata.json'
    if not metadata.is_file() or metadata.stat().st_mtime_ns < started:
        raise ValueError('Native probe did not finalize metadata: ' + label)
    # A finalized render with failed validation remains useful failure evidence.
    # Continue the declared cohort, without treating those checks as passed.
    if result.returncode != 0 or read(metadata).get('status') != 'passed':
        state.setdefault('validationFailures', {})[label] = read(metadata).get('failures', [])
    save(record, {str(p.relative_to(directory)): digest(p) for p in sorted(directory.iterdir()) if p.is_file()})
    state['completed'].append(label)
    save(output / 'study.json', state)


def render(output, state):
    check_sources(output, state)
    for arm, expected in state['rendererHashes'].items():
        if digest(output / 'renderer' / arm / 'XT5MatrixProbe') != expected:
            raise ValueError('Renderer changed: ' + arm)
    frames = prepare_inputs(output, state)
    gate = output / 'matrix-state.json'
    if not gate.is_file() or not read(gate).get('allFramesMatched') or len(read(gate)['frames']) != len(frames):
        raise ValueError('Run xt5-matrix-state.cpp over this exact inventory before rendering.')
    if {str(Path(f['path']).resolve()) for f in read(gate)['frames']} != {f['raw'] for f in frames}:
        raise ValueError('Matrix gate used a different source inventory.')
    if digest(gate) != state['matrixState']['reportSHA256'] or digest(HERE / 'xt5-matrix-state.cpp') != state['matrixState']['sourceSHA256']:
        raise ValueError('Matrix metadata gate changed after validation.')
    for frame in frames:
        run_frame(output, state, 'baseline', 'preview', 'preview', frame)
        recipes = recipes_for(output, frame)
        run_frame(output, state, 'matrix', 'preview', 'preview', frame, recipes)
    ledger = read(ROOT / 'docs/development/color-preference-checkpoints.json')
    preferences = []
    for entry in ledger['frames']:
        frame = next(f for f in frames if f['stock'] == entry['stock'] and f['stem'] == entry['frame'])
        historical = ROOT / 'dist/camera-raw-study' / entry['stock'] / entry['frame'] / 'metadata.json'
        medians = read(historical)['medians']
        recipes = [dict(name=c['variant'], parameters=c['parameters'], measuredMedians=medians,
                        captureRecipe=False) for c in entry['candidates']]
        preferences.append((frame, recipes))
        for arm in ('baseline', 'matrix'):
            run_frame(output, state, arm, 'preview', 'preferences', frame, recipes)
    for frame in frames:
        recipes = recipes_for(output, frame)
        for arm in ('baseline', 'matrix'):
            run_frame(output, state, arm, 'full', 'full', frame, recipes)
    for frame, recipes in preferences:
        for arm in ('baseline', 'matrix'):
            run_frame(output, state, arm, 'full', 'full-preferences', frame, recipes)
    check_sources(output, state)
    # Rehash inputs after rendering too, not just before resuming.
    prepare_inputs(output, state)
    state.update(status='render-complete', activeStage=None)
    save(output / 'study.json', state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'build', 'matrix-state', 'render', 'score'))
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    output = options.output.resolve()
    if options.command == 'prepare':
        snapshot(output)
        return
    state = read(output / 'study.json')
    try:
        if options.command == 'build':
            if state['completed']:
                raise ValueError('Cannot replace renderers after rendering begins.')
            build(output, state)
        elif options.command == 'render':
            render(output, state)
        elif options.command == 'matrix-state':
            matrix_state(output, state)
        else:
            if state.get('status') != 'render-complete':
                raise ValueError('Complete the entire rendering cohort before scoring.')
            check_sources(output, state)
            prepare_inputs(output, state)
            for label in state['completed']:
                directory = output / label
                for p, h in read(output / 'completion' / (label + '.json')).items():
                    if not (directory / p).is_file() or digest(directory / p) != h:
                        raise ValueError('Render artifact changed before scoring: ' + label + '/' + p)
            subprocess.run([sys.executable, str(HERE / 'score-xt5-matrix.py'), '--output', str(output)], check=True)
    except BaseException:
        state['status'] = 'interrupted'
        save(output / 'study.json', state)
        raise


if __name__ == '__main__':
    main()
