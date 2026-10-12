#!/usr/bin/env python3
"""Preview or remove recognized, rebuildable Swift caches; retain study evidence."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
        return digest.hexdigest()


def refuse_symlink_path(root: Path, path: Path) -> None:
    relative = path.relative_to(root)
    for part in (path, *path.parents):
        if part == root:
            break
        if part.is_symlink():
            raise ValueError(f"Refusing a symlinked cleanup path: {relative}")


def validate_cache(root: Path, path: Path) -> None:
    relative = path.relative_to(root)
    refuse_symlink_path(root, path)
    if not path.is_dir():
        raise ValueError(f"Cache is not a directory: {relative}")
    tracked = subprocess.check_output(
        ["git", "--literal-pathspecs", "ls-files", "-z", "--", str(relative)], cwd=root
    )
    if tracked:
        raise ValueError(f"Cache contains tracked files: {relative}")
    ignored = subprocess.run(
        ["git", "check-ignore", "-q", "--", str(relative)], cwd=root
    )
    if ignored.returncode != 0:
        raise ValueError(f"Cache is not ignored: {relative}")


def study_cache(study: Path) -> Path | None:
    """Only the X-T5 runner's scratch builds with separate pinned renderers."""
    manifest = study / "study.json"
    cache = study / "build"
    if not manifest.is_file() or not cache.exists():
        return None
    root = study.parent.parent
    refuse_symlink_path(root, manifest)
    state = json.loads(manifest.read_text())
    if not isinstance(state, dict):
        raise ValueError(f"Invalid study manifest: {study.name}")
    if state.get("candidateDefine") != "FSC_DIAGNOSTIC_UPSTREAM_XT5_MATRIX":
        return None
    if state.get("status") not in ("render-complete", "interrupted") or not state.get("completed"):
        raise ValueError(f"Study has not reached resumable rendered output: {study.name}")
    hashes = state.get("rendererHashes", {})
    if not isinstance(hashes, dict) or set(hashes) != {"baseline", "matrix"}:
        raise ValueError(f"Study has no complete pinned renderer pair: {study.name}")
    for arm, expected in hashes.items():
        renderer = study / "renderer" / arm / "XT5MatrixProbe"
        refuse_symlink_path(root, renderer)
        if not renderer.is_file() or renderer.is_symlink() or sha256(renderer) != expected:
            raise ValueError(f"Pinned renderer missing or changed: {renderer}")
    snapshot_package = study / "snapshot" / "FilmScanEngine" / "Package.swift"
    refuse_symlink_path(root, snapshot_package)
    if not snapshot_package.is_file():
        raise ValueError(f"Study source snapshot is missing: {study.name}")
    return cache


def candidates(root: Path) -> list[Path]:
    result = []
    native = root / "native" / "FilmScanEngine" / ".build"
    if native.exists() or native.is_symlink():
        result.append(native)
    dist = root / "dist"
    if dist.is_symlink():
        raise ValueError("Refusing a symlinked dist directory")
    if dist.is_dir():
        for study in sorted(dist.iterdir()):
            if study.is_dir() and not study.is_symlink():
                cache = study_cache(study)
                if cache is not None:
                    result.append(cache)
    for path in result:
        validate_cache(root, path)
    return result


def cache_size(path: Path) -> int:
    seen = set()
    allocated = 0
    for directory, _, names in os.walk(path, followlinks=False):
        for name in names:
            info = (Path(directory) / name).lstat()
            key = (info.st_dev, info.st_ino)
            if key not in seen:
                seen.add(key)
                allocated += info.st_blocks * 512
    return allocated


def require_idle(path: Path) -> None:
    lsof = shutil.which("lsof")
    if lsof is None:
        raise ValueError("lsof is required for --apply; stop all builds and studies first")
    result = subprocess.run(
        [lsof, "-t", "+D", str(path)], capture_output=True, text=True, timeout=30
    )
    if result.stdout.strip():
        raise ValueError(f"Cache has open files; stop its app/build/study first: {path}")
    if result.returncode not in {0, 1} or result.stderr.strip():
        raise ValueError(f"Could not check open files for {path}: {result.stderr.strip()}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Remove the listed caches after checking open files")
    options = parser.parse_args()
    paths = candidates(ROOT)
    rows = [{"path": str(path.relative_to(ROOT)), "allocatedBytes": cache_size(path)} for path in paths]
    for row in rows:
        print(f"{row['allocatedBytes'] / 1024**3:.3f} GiB  {row['path']}")
    print(f"Total rebuildable caches: {sum(row['allocatedBytes'] for row in rows) / 1024**3:.3f} GiB")
    if not options.apply:
        print("Dry run. Stop builds/studies, then use --apply. All galleries, scans, renderers and source snapshots stay in place.")
        return
    # Check the complete plan before removing anything. No arbitrary paths or
    # generic dist/build glob is accepted; baseline objects can be evidence.
    for path in paths:
        require_idle(path)
    receipt = ROOT / "dist" / "cleanup-receipts" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + ".json")
    refuse_symlink_path(ROOT, receipt)
    receipt.parent.mkdir(parents=True, exist_ok=True)
    record = {"schemaVersion": 1, "caches": rows, "removed": []}
    receipt.write_text(json.dumps(record, indent=2) + "\n")
    for path in paths:
        validate_cache(ROOT, path)
        shutil.rmtree(path)
        record["removed"].append(str(path.relative_to(ROOT)))
        receipt.write_text(json.dumps(record, indent=2) + "\n")
    print(f"Removed {len(paths)} caches. Next native build must compile again; standalone probes need a rebuild first.")
    print(f"Receipt: {receipt.relative_to(ROOT)}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"Cleanup refused: {error}")
