#!/usr/bin/env python3
"""Share identical study image data with independent macOS copy-on-write files.

Dry-run is the default. Only an explicitly named ignored directory below this
checkout's dist/ is accepted. Keep the study idle while using --apply. Every
asset path and byte remains available; no hardlinks or lossy encoders are used.
The byte estimate is logical data that can be shared, not measured disk space.
"""

from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
import errno
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from collections import defaultdict


ROOT = Path(__file__).resolve().parent.parent
EXTENSIONS = {".png", ".jpg", ".jpeg", ".npy", ".bgr16"}
MINIMUM_BYTES = 1024 * 1024
MAC_LIBRARY = None
PROVENANCE_ATTRIBUTE = "com.apple.provenance"


class CompactError(Exception):
    pass


class MetadataMismatch(CompactError):
    """An original asset has metadata that cannot safely share this source."""


@dataclass
class Asset:
    path: Path
    original: os.stat_result
    sha256: str = ""


def identity(value: os.stat_result) -> tuple[int, ...]:
    # Reads may update atime. ctime catches writes and metadata changes even if
    # another process puts mtime back to its original value.
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns, getattr(value, "st_flags", 0))


def no_symlinks(path: Path) -> None:
    for entry in (path, *path.parents):
        if entry.is_symlink():
            raise CompactError(f"Symlink path refused: {entry}")


def checked_stat(asset: Asset) -> os.stat_result:
    no_symlinks(asset.path)
    current = asset.path.lstat()
    if not stat.S_ISREG(current.st_mode) or identity(current) != identity(asset.original):
        raise CompactError(f"Asset changed while inspecting it: {asset.path}")
    return current


def digest(asset: Asset) -> str:
    checked_stat(asset)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(asset.path, flags)
    with os.fdopen(descriptor, "rb") as stream:
        if identity(os.fstat(stream.fileno())) != identity(asset.original):
            raise CompactError(f"Asset changed before reading it: {asset.path}")
        result = hashlib.sha256()
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            result.update(chunk)
        if identity(os.fstat(stream.fileno())) != identity(asset.original):
            raise CompactError(f"Asset changed while reading it: {asset.path}")
    checked_stat(asset)
    return result.hexdigest()


def git(*arguments: str, input_bytes: bytes | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *arguments], input=input_bytes,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)


def validate_study(argument: str) -> Path:
    study = Path(os.path.abspath(argument))
    no_symlinks(study)
    try:
        relative = study.relative_to(ROOT / "dist")
    except ValueError as error:
        raise CompactError("Choose a study directory inside this checkout's dist/.") from error
    if not relative.parts or not study.is_dir():
        raise CompactError("Name an existing study directory below dist/, not dist/ itself.")
    relative_name = str(study.relative_to(ROOT))
    ignored = git("check-ignore", "-q", "--", relative_name)
    if ignored.returncode != 0:
        raise CompactError(f"Study directory is not Git-ignored: {study}")
    tracked = git("ls-files", "-z", "--", ":(literal)" + relative_name)
    if tracked.returncode != 0:
        raise CompactError(tracked.stderr.decode(errors="replace").strip())
    if tracked.stdout:
        raise CompactError("Study contains tracked paths; compaction refused.")
    return study


def collect(study: Path) -> tuple[list[Asset], int]:
    assets = []
    skipped_linked = 0
    for directory, names, filenames in os.walk(study, followlinks=False):
        parent = Path(directory)
        no_symlinks(parent)
        names[:] = sorted(name for name in names if not (parent / name).is_symlink())
        for name in sorted(filenames):
            path = parent / name
            value = path.lstat()
            if (not stat.S_ISREG(value.st_mode) or path.suffix.lower() not in EXTENSIONS
                    or value.st_size < MINIMUM_BYTES):
                continue
            # Leave existing hardlinks alone, including groups sharing an inode.
            if value.st_nlink != 1:
                skipped_linked += 1
                continue
            assets.append(Asset(path, value))
    if assets:
        paths = b"".join(os.fsencode(str(asset.path.relative_to(ROOT))) + b"\0" for asset in assets)
        ignored = git("check-ignore", "--stdin", "-z", input_bytes=paths)
        if ignored.returncode not in (0, 1):
            raise CompactError(ignored.stderr.decode(errors="replace").strip())
        if set(ignored.stdout.split(b"\0")) - {b""} != set(paths.split(b"\0")) - {b""}:
            raise CompactError("Study includes an eligible asset that is not Git-ignored.")
    return assets, skipped_linked


def duplicate_groups(assets: list[Asset]) -> list[list[Asset]]:
    by_size = defaultdict(list)
    for asset in assets:
        by_size[asset.original.st_size].append(asset)
    groups = []
    for candidates in by_size.values():
        if len(candidates) < 2:
            continue
        by_hash = defaultdict(list)
        for asset in candidates:
            asset.sha256 = digest(asset)
            by_hash[asset.sha256].append(asset)
        groups.extend(sorted(group, key=lambda asset: str(asset.path))
                      for group in by_hash.values() if len(group) > 1)
    return sorted(groups, key=lambda group: str(group[0].path))


def xattrs(path: Path) -> dict[str, bytes]:
    library = MAC_LIBRARY
    encoded = os.fsencode(path)
    size = library.listxattr(encoded, None, 0, 1)  # XATTR_NOFOLLOW
    if size < 0:
        raise CompactError(f"Cannot inspect extended attributes: {path}")
    names = ctypes.create_string_buffer(size)
    if library.listxattr(encoded, names, size, 1) < 0:
        raise CompactError(f"Extended attributes changed while inspecting: {path}")
    result = {}
    for name in filter(None, names.raw.split(b"\0")):
        length = library.getxattr(encoded, name, None, 0, 0, 1)
        if length < 0:
            raise CompactError(f"Cannot inspect extended attribute: {path}")
        value = ctypes.create_string_buffer(length)
        if library.getxattr(encoded, name, value, length, 0, 1) != length:
            raise CompactError(f"Extended attribute changed while inspecting: {path}")
        result[os.fsdecode(name)] = value.raw
    return result


def matching_attributes(original: dict[str, bytes], cloned: dict[str, bytes]) -> bool:
    # macOS may attach security provenance to a new clone. It is not always
    # removable, and does not alter image/array content. Existing attributes,
    # including existing provenance, must retain their exact values.
    return (all(cloned.get(name) == value for name, value in original.items())
            and cloned.keys() - original.keys() <= {PROVENANCE_ATTRIBUTE})


def has_acl(path: Path) -> bool:
    library = MAC_LIBRARY
    ctypes.set_errno(0)
    acl = library.acl_get_file(os.fsencode(path), 0x100)  # ACL_TYPE_EXTENDED
    if not acl:
        # macOS returns ENOENT when an existing file has no extended ACL.
        if ctypes.get_errno() == errno.ENOENT and path.exists():
            return False
        raise CompactError(f"Cannot inspect ACL permissions: {path}")
    try:
        # Refuse even an explicitly stored empty ACL rather than interpreting
        # its entries or changing custom permissions.
        return True
    finally:
        library.acl_free(acl)


def clone_api():
    global MAC_LIBRARY
    if sys.platform != "darwin":
        raise CompactError("--apply requires macOS with clonefile support (normally APFS).")
    library = ctypes.CDLL(None, use_errno=True)
    try:
        clone = library.clonefile
    except AttributeError as error:
        raise CompactError("This macOS runtime does not provide clonefile.") from error
    clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
    clone.restype = ctypes.c_int
    library.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    library.listxattr.restype = ctypes.c_ssize_t
    library.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                                ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    library.getxattr.restype = ctypes.c_ssize_t
    library.removexattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    library.removexattr.restype = ctypes.c_int
    library.acl_get_file.argtypes = [ctypes.c_char_p, ctypes.c_int]
    library.acl_get_file.restype = ctypes.c_void_p
    library.acl_free.argtypes = [ctypes.c_void_p]
    library.acl_free.restype = ctypes.c_int
    MAC_LIBRARY = library
    return clone


def check_idle(study: Path) -> None:
    result = subprocess.run(["/usr/sbin/lsof", "-n", "-P", "-Fp", "+D", str(study)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.stdout:
        raise CompactError("An open file or process uses this study; close it before --apply.")
    if result.returncode not in (0, 1) or result.stderr:
        raise CompactError("Unable to confirm the study is idle with lsof; compaction refused.")


def clone_duplicate(source: Asset, destination: Asset, clone) -> bool:
    checked_stat(source)
    checked_stat(destination)
    if source.original.st_dev != destination.original.st_dev:
        raise CompactError("Clone source and destination are on different filesystems.")
    if ((source.original.st_uid, source.original.st_gid)
            != (destination.original.st_uid, destination.original.st_gid)
            or getattr(source.original, "st_flags", 0)
            or getattr(destination.original, "st_flags", 0)):
        raise MetadataMismatch(f"Different ownership or file flags: {destination.path}")
    original_attributes = xattrs(destination.path)
    if xattrs(source.path) != original_attributes:
        raise MetadataMismatch(f"Different extended attributes: {destination.path}")
    if has_acl(source.path) or has_acl(destination.path):
        raise MetadataMismatch(f"Custom ACL permissions: {destination.path}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=".compact-study-", dir=destination.path.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    temporary.unlink()  # clonefile requires a new destination path.
    try:
        # Unlike cp -c, clonefile never silently falls back to an ordinary copy.
        if clone(os.fsencode(source.path), os.fsencode(temporary), 1) != 0:
            number = ctypes.get_errno()
            raise CompactError(f"Copy-on-write clone failed ({os.strerror(number)}); "
                               f"destination kept: {destination.path}")
        value = temporary.lstat()
        if (not stat.S_ISREG(value.st_mode) or value.st_nlink != 1
                or value.st_ino in (source.original.st_ino, destination.original.st_ino)
                or value.st_size != destination.original.st_size):
            raise CompactError(f"Unexpected clone layout: {destination.path}")
        temporary_asset = Asset(temporary, value)
        if digest(temporary_asset) != destination.sha256:
            raise CompactError(f"Clone content verification failed: {destination.path}")
        # Restore unexpected attributes on the temporary clone only. macOS
        # security provenance may be newly added and cannot always be removed.
        cloned_attributes = xattrs(temporary)
        for name in cloned_attributes.keys() - original_attributes.keys():
            if name == PROVENANCE_ATTRIBUTE:
                continue
            if MAC_LIBRARY.removexattr(os.fsencode(temporary), os.fsencode(name), 1) != 0:
                raise CompactError(f"Cannot restore clone extended attributes: {destination.path}")
        cloned_attributes = xattrs(temporary)
        if not matching_attributes(original_attributes, cloned_attributes):
            raise CompactError(f"Clone extended attribute verification failed: {destination.path}")
        os.chmod(temporary, stat.S_IMODE(destination.original.st_mode))
        os.utime(temporary, ns=(destination.original.st_atime_ns, destination.original.st_mtime_ns))
        value = temporary.lstat()
        if (stat.S_IMODE(value.st_mode) != stat.S_IMODE(destination.original.st_mode)
                or value.st_atime_ns != destination.original.st_atime_ns
                or value.st_mtime_ns != destination.original.st_mtime_ns
                or (value.st_uid, value.st_gid) != (destination.original.st_uid, destination.original.st_gid)
                or not matching_attributes(original_attributes, xattrs(temporary)) or has_acl(temporary)):
            raise CompactError(f"Clone metadata verification failed: {destination.path}")
        checked_stat(source)
        checked_stat(destination)
        os.replace(temporary, destination.path)
        return PROVENANCE_ATTRIBUTE in cloned_attributes and PROVENANCE_ATTRIBUTE not in original_attributes
    finally:
        if temporary.exists() or temporary.is_symlink():
            temporary.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("study", help="Explicit ignored study directory below this checkout's dist/")
    parser.add_argument("--apply", action="store_true", help="Atomically replace duplicates with independent clones")
    parser.add_argument("--report", type=Path, help="Write a new JSON report; existing files are never overwritten")
    options = parser.parse_args()
    report = {"mode": "apply" if options.apply else "dry-run", "status": "failed",
              "applied": [], "clonedLogicalBytes": 0, "skippedMetadata": []}
    try:
        if options.report:
            options.report = Path(os.path.abspath(options.report))
            no_symlinks(options.report)
            if options.report.exists():
                raise CompactError("Report already exists; choose a fresh JSON report path.")
            if not options.report.parent.is_dir():
                raise CompactError("The report's parent directory must already exist.")
        study = validate_study(options.study)
        report["study"] = str(study)
        if options.apply:
            clone = clone_api()
            check_idle(study)
        assets, linked = collect(study)
        groups = duplicate_groups(assets)
        shared_bytes = sum(group[0].original.st_size * (len(group) - 1) for group in groups)
        report.update(eligibleFiles=len(assets), skippedHardlinkFiles=linked,
                      identicalGroups=len(groups), potentialSharedLogicalBytes=shared_bytes,
                      estimate="Logical identical data; existing APFS sharing and freed disk space are not measured.",
                      metadataPolicy="Original extended attributes are preserved exactly; macOS may add com.apple.provenance when absent.",
                      groups=[{"bytes": group[0].original.st_size, "sha256": group[0].sha256,
                               "paths": [str(asset.path) for asset in group]} for group in groups])
        print(f"{len(assets)} eligible assets; {len(groups)} identical groups; {linked} existing hardlink files skipped.")
        print(f"{shared_bytes:,} logical bytes ({shared_bytes / 1024**3:.3f} GiB) can share copy-on-write data.")
        print("This estimates shared logical data, not newly freed disk space; existing APFS sharing is unknown.")
        if options.apply:
            check_idle(study)
            for group in groups:
                source = group[0]
                previous_applied = len(report["applied"])
                for destination in group[1:]:
                    try:
                        provenance_added = clone_duplicate(source, destination, clone)
                    except MetadataMismatch as error:
                        report["skippedMetadata"].append({"path": str(destination.path), "reason": str(error)})
                        continue
                    report["applied"].append({"source": str(source.path), "destination": str(destination.path),
                                              "bytes": destination.original.st_size, "sha256": destination.sha256,
                                              "filesystemProvenanceAdded": provenance_added})
                    report["clonedLogicalBytes"] += destination.original.st_size
                # Preserve the retained source's original access time as well.
                if len(report["applied"]) > previous_applied:
                    checked_stat(source)
                    if source.path.stat().st_atime_ns != source.original.st_atime_ns:
                        os.utime(source.path, ns=(source.original.st_atime_ns, source.original.st_mtime_ns))
            print(f"Replaced {len(report['applied'])} duplicate assets with independent clones; all content retained.")
            print(f"Cloned {report['clonedLogicalBytes']:,} logical bytes; "
                  f"skipped {len(report['skippedMetadata'])} assets to preserve incompatible original metadata.")
        else:
            print("Dry-run only. Keep the study idle, then use --apply to compact it.")
        report["status"] = "complete"
    except (CompactError, OSError) as error:
        report["error"] = str(error)
        print(f"Compaction refused: {error}", file=sys.stderr)
    finally:
        if options.report:
            try:
                no_symlinks(options.report)
                with options.report.open("x") as stream:
                    json.dump(report, stream, indent=2)
                    stream.write("\n")
                print(f"Report: {options.report}")
            except (CompactError, OSError) as error:
                print(f"Unable to write report: {error}", file=sys.stderr)
                report["status"] = "failed"
    return 0 if report["status"] == "complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
