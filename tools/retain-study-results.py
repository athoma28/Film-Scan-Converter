#!/usr/bin/env python3
"""Retire completed dist galleries; retain bounded reports and replay inputs.

Dry-run by default. Stop all studies before --apply. Private sample-raw inputs
and production source are outside this tool's scope. Restore an archived report
with --restore-results dist/<study>/<report>.json.gz before reading it in tools.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MIB = 1024 * 1024
XT5 = 'xt5-matrix-study-2026-10-03'
BUFFERS = frozenset(f'camera-raw-study/{stock}/{frame}/scan.bgr16' for stock, frames in (
    ('fuji400-fresh', ('DSCF2833', 'DSCF2892', 'DSCF3115')),
    ('harmanphoenixii', ('DSCF3079', 'DSCF3086', 'DSCF3091')),
    ('proimage', ('DSCF5800', 'DSCF5809')),
) for frame in frames)
BULK = {'.png', '.jpg', '.jpeg', '.bgr16', '.npy', '.u8', '.html', '.pyc',
        '.o', '.swiftmodule', '.swiftdoc', '.swiftsourceinfo'}
REPORTS = {'.json', '.jsonl', '.csv', '.txt', '.log', '.md', '.gz', '.xml', '.svg'}
SOURCE = {'.swift', '.py', '.cpp', '.c', '.h', '.inc', '.before', '.patch', '.diff',
          '.toml', '.plist', '.entitlements', '.modulemap', '.linkfilelist', '.asm', '.sha256', '.bin'}
MACHO = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
         b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(MIB), b''):
            h.update(block)
    return h.hexdigest()


def identity(path: Path) -> tuple[int, ...]:
    s = path.lstat()
    return s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns


def no_symlinks(root: Path, path: Path) -> None:
    path.relative_to(root)
    for ancestor in (path, *path.parents):
        if ancestor == root:
            break
        if ancestor.is_symlink():
            raise ValueError(f'Refusing symlink: {ancestor}')


def validate_scope(root: Path, path: Path) -> None:
    no_symlinks(root, path)
    relative = path.relative_to(root)
    if not relative.parts or relative.parts[0] != 'dist' or '..' in relative.parts:
        raise ValueError('Retention is restricted to dist')
    if subprocess.check_output(['git', '--literal-pathspecs', 'ls-files', '-z', '--', str(relative)], cwd=root):
        raise ValueError(f'Tracked files in retention scope: {relative}')
    if subprocess.run(['git', 'check-ignore', '-q', '--', str(relative)], cwd=root).returncode != 0:
        raise ValueError(f'Retention scope is not ignored: {relative}')


def action(relative: Path, path: Path) -> str:
    parts = relative.parts
    # These complete subtrees contain resources or frozen link inputs, even
    # when filenames look like ordinary generated images/build objects.
    if parts[:2] == (XT5, 'snapshot') or parts[:2] == (XT5, 'renderer'):
        return 'keep'
    if parts[:2] == ('performance-implementation-2026-10-02', 'baseline-build'):
        return 'keep'
    if parts[0].startswith('release-') or relative.as_posix() in BUFFERS:
        return 'keep'
    suffix = path.suffix.lower()
    if path.name.endswith('mask.png') or path.name == 'fixed-masks.npz':
        return 'keep'
    if suffix == '.json' and path.stat().st_size > MIB and path.name not in {'manifest.json', 'study.json', 'metadata.json'}:
        return 'compress'
    if suffix in REPORTS or suffix in SOURCE:
        return 'keep'
    if suffix in BULK or path.name == '.DS_Store':
        return 'remove'
    if not suffix:
        with path.open('rb') as stream:
            if stream.read(4) in MACHO:
                return 'remove'
    # Unknown formats never qualify for deletion.
    return 'unknown'


def check_inputs(root: Path) -> None:
    dist = root / 'dist'
    tone = dist / 'tone-response-separated-final-2026-09-25/manifest.json'
    if tone.exists():
        inputs = json.loads(tone.read_text())['inputs']
        for relative in sorted(BUFFERS):
            for name in ('scan.bgr16', 'metadata.json'):
                p = dist / Path(relative).with_name(name)
                no_symlinks(root, p)
                if not p.is_file() or digest(p) != inputs.get(str(p.relative_to(root))):
                    raise ValueError(f'Missing or changed historical harness input: {p}')
    study = dist / XT5 / 'study.json'
    if study.exists():
        state = json.loads(study.read_text())
        for relative, expected in state['snapshotSources'].items():
            p = study.parent / 'snapshot/FilmScanEngine' / relative
            no_symlinks(root, p)
            if not p.is_file() or digest(p) != expected:
                raise ValueError(f'Missing or changed snapshot source: {p}')
        for relative, expected in state['diagnosticHashes'].items():
            p = study.parent / 'snapshot/diagnostics' / relative
            no_symlinks(root, p)
            if not p.is_file() or digest(p) != expected:
                raise ValueError(f'Missing or changed snapshot diagnostic: {p}')
        for arm, expected in state['rendererHashes'].items():
            p = study.parent / 'renderer' / arm / 'XT5MatrixProbe'
            no_symlinks(root, p)
            if not p.is_file() or digest(p) != expected:
                raise ValueError(f'Missing or changed pinned renderer: {p}')
        capsule = study.parent / 'supplemental/reproduction-inputs'
        manifest = json.loads((capsule / 'manifest.json').read_text())
        if manifest['sha256'].get('native/diagnostics/xt5-matrix-state.cpp') != state['matrixState']['sourceSHA256']:
            raise ValueError('Matrix-state source must be retained in reproduction capsule')
        for relative, expected in manifest['sha256'].items():
            p = capsule / relative
            no_symlinks(root, p)
            if not p.is_file() or digest(p) != expected:
                raise ValueError(f'Missing or changed reproduction input: {p}')
        if not (study.parent / 'snapshot/FilmScanEngine/Package.swift').is_file():
            raise ValueError('X-T5 engine snapshot is missing')


def make_plan(root: Path, max_mib: float = 250) -> dict:
    if not math.isfinite(max_mib) or max_mib <= 0:
        raise ValueError('Retention budget must be a finite positive number')
    dist = root / 'dist'
    validate_scope(root, dist)
    check_inputs(root)
    rows = []
    for directory, dirs, names in os.walk(dist, followlinks=False):
        for name in dirs:
            no_symlinks(root, Path(directory) / name)
        for name in sorted(names):
            p = Path(directory) / name
            no_symlinks(root, p)
            if not stat.S_ISREG(p.lstat().st_mode):
                raise ValueError(f'Nonregular file in dist: {p}')
            relative = p.relative_to(dist)
            choice = action(relative, p)
            restored_copy = False
            if choice == 'compress' and p.with_name(p.name + '.gz').exists():
                archive = p.with_name(p.name + '.gz')
                no_symlinks(root, archive)
                try:
                    archived_digest = hashlib.sha256(gzip.decompress(archive.read_bytes())).hexdigest()
                except (OSError, EOFError) as error:
                    raise ValueError(f'Archive destination already exists with invalid data: {archive}') from error
                if archived_digest != digest(p):
                    raise ValueError(f'Archive destination already exists with different content: {archive}')
                # A restored working copy is redundant only after proving its
                # original bytes still exist in the retained lossless archive.
                choice = 'remove'
                restored_copy = True
            row = {'path': str(p.relative_to(root)), 'action': choice,
                   'bytes': p.stat().st_size, 'identity': identity(p)}
            if restored_copy:
                row['reason'] = 'temporary plain report matches retained archive exactly'
            if choice == 'compress':
                row['retainedBytes'] = len(gzip.compress(p.read_bytes(), compresslevel=9, mtime=0))
            else:
                row['retainedBytes'] = 0 if choice == 'remove' else row['bytes']
            if choice != 'remove':
                row['sha256'] = digest(p)
            rows.append(row)
    # Reserve room for the compressed receipt. Its size is bounded by the
    # uncompressed inventory size plus removed-file hashes and gzip overhead.
    receipt_reserve = len(json.dumps(rows).encode()) + len(rows) * 80 + MIB
    kept = sum(row['retainedBytes'] for row in rows)
    if kept + receipt_reserve > max_mib * MIB:
        raise ValueError(f'Plan retains {(kept + receipt_reserve) / MIB:.2f} MiB including receipt reserve; budget is {max_mib:g} MiB. Nothing changed.')
    return {'schemaVersion': 1, 'createdAtUTC': datetime.now(timezone.utc).isoformat(),
            'policy': 'completed studies: results and reproduction inputs; rerender galleries on demand',
            'maxMiB': max_mib, 'beforeBytes': sum(row['bytes'] for row in rows),
            'retainedBytes': kept, 'receiptReserveBytes': receipt_reserve, 'files': rows}


def require_idle(dist: Path) -> None:
    lsof = shutil.which('lsof')
    if not lsof:
        raise ValueError('lsof is required before --apply')
    result = subprocess.run([lsof, '-t', '+D', str(dist)], capture_output=True, text=True, timeout=30)
    if result.stdout.strip() or result.stderr.strip() or result.returncode not in {0, 1}:
        raise ValueError(f'Cannot retire studies with open files or failed idle check: {result.stdout.strip()} {result.stderr.strip()}')


def apply_plan(root: Path, plan: dict) -> Path:
    dist = root / 'dist'
    validate_scope(root, dist)
    require_idle(dist)
    check_inputs(root)
    expected_paths = {row['path'] for row in plan['files']}
    actual_paths = set()
    for directory, dirs, names in os.walk(dist, followlinks=False):
        for name in dirs:
            no_symlinks(root, Path(directory) / name)
        for name in names:
            p = Path(directory) / name
            no_symlinks(root, p)
            if not stat.S_ISREG(p.lstat().st_mode):
                raise ValueError(f'Nonregular file in dist: {p}')
            actual_paths.add(str(p.relative_to(root)))
    if actual_paths != expected_paths:
        raise ValueError('dist inventory changed after planning; nothing changed')
    for row in plan['files']:
        if row['action'] == 'compress':
            archive = (root / row['path']).with_name(Path(row['path']).name + '.gz')
            no_symlinks(root, archive)
            if archive.exists():
                raise ValueError(f'Archive destination appeared after planning: {archive}')
    # Complete all content/race checks before the first write or removal.
    for row in plan['files']:
        p = root / row['path']
        no_symlinks(root, p)
        if identity(p) != tuple(row['identity']):
            raise ValueError(f'File changed after planning: {p}')
        actual = digest(p)
        if row.get('sha256', actual) != actual:
            raise ValueError(f'Content changed after planning: {p}')
        row['sha256'] = actual
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    receipt = dist / 'cleanup-receipts' / f'results-retention-{stamp}.json.gz'
    no_symlinks(root, receipt)
    receipt.parent.mkdir(parents=True, exist_ok=True)
    # Persist the full pre-removal inventory first, including every output hash.
    plan['status'] = 'retiring'
    receipt.write_bytes(gzip.compress((json.dumps(plan, indent=2) + '\n').encode(), mtime=0))
    for row in plan['files']:
        if row['action'] not in {'remove', 'compress'}:
            continue
        p = root / row['path']
        no_symlinks(root, p)
        # Unlinking another retained/planned hardlink changes this inode's
        # ctime. Device/inode/length/mtime still guard replacement or edits;
        # the full digest was checked before any mutation.
        if identity(p)[:-1] != tuple(row['identity'])[:-1]:
            raise ValueError(f'File changed during retirement: {p}; see receipt')
        if row['action'] == 'compress':
            data = p.read_bytes()
            packed = gzip.compress(data, compresslevel=9, mtime=0)
            if hashlib.sha256(gzip.decompress(packed)).hexdigest() != row['sha256']:
                raise ValueError(f'Archive verification failed: {p}')
            target = p.with_name(p.name + '.gz')
            with target.open('xb') as stream:
                stream.write(packed)
            shutil.copystat(p, target)
        p.unlink()
    for row in plan['files']:
        if row['action'] in {'keep', 'unknown', 'compress'}:
            p = root / row['path']
            actual = hashlib.sha256(gzip.decompress(p.with_name(p.name + '.gz').read_bytes())).hexdigest() if row['action'] == 'compress' else digest(p)
            if actual != row['sha256']:
                raise ValueError(f'Retained content verification failed: {p}')
    total = sum(p.stat().st_size for p in dist.rglob('*') if p.is_file())
    if total > plan['maxMiB'] * MIB:
        raise ValueError(f'Final retention budget exceeded: {total / MIB:.2f} MiB')
    plan['status'] = 'complete'
    plan['finishedAtUTC'] = datetime.now(timezone.utc).isoformat()
    plan['verifiedRetainedFiles'] = sum(row['action'] != 'remove' for row in plan['files'])
    plan['afterBytes'] = total
    receipt.write_bytes(gzip.compress((json.dumps(plan, indent=2) + '\n').encode(), mtime=0))
    return receipt


def restore_results(root: Path, relative: str) -> Path:
    archive = root / relative
    validate_scope(root, archive)
    if not archive.name.endswith('.json.gz'):
        raise ValueError('Restore accepts a single .json.gz report')
    target = archive.with_suffix('')
    no_symlinks(root, target)
    if target.exists():
        raise ValueError(f'Restore destination already exists: {target}')
    data = gzip.decompress(archive.read_bytes())
    json.loads(data)
    # Leave the archive present; the plain report is temporary working data.
    with target.open('xb') as stream:
        stream.write(data)
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Retire generated outputs after complete preflight')
    parser.add_argument('--max-mib', type=float, default=250, help='Total retained dist budget including releases/receipts (default 250)')
    parser.add_argument('--restore-results', metavar='PATH', help='Restore one losslessly archived JSON report for temporary inspection')
    options = parser.parse_args()
    if options.restore_results:
        if options.apply:
            parser.error('--restore-results and --apply are mutually exclusive')
        print(f'Restored temporary report: {restore_results(ROOT, options.restore_results)}')
        return
    if options.max_mib <= 0:
        parser.error('--max-mib must be positive')
    plan = make_plan(ROOT, options.max_mib)
    counts = Counter(row['action'] for row in plan['files'])
    print(f"Before: {plan['beforeBytes'] / 1024**3:.3f} GiB; retained: {plan['retainedBytes'] / MIB:.2f} MiB; budget: {options.max_mib:g} MiB")
    print('Files: ' + ', '.join(f'{k}={v}' for k, v in sorted(counts.items())))
    for row in plan['files']:
        if row['action'] == 'unknown':
            print(f"Kept unknown format: {row['path']}")
    if not options.apply:
        print('Dry run. Use --apply to remove generated galleries/rasters and archive large reports losslessly. Source snapshots, original inputs and results stay.')
        return
    receipt = apply_plan(ROOT, plan)
    print(f'Retired outputs; verified retained content. Receipt: {receipt.relative_to(ROOT)}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f'Retention refused: {error}')
