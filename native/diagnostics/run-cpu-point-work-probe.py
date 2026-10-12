#!/usr/bin/env python3
"""Build, freeze and run the bounded CPU point-work probe on one RAW file.

Each run measures up to seven fixed RAW cases and hashes 72 untimed synthetic
branch cases. It does not run test suites, exports, color studies or a RAW corpus.
Use separate fresh outputs for each source revision and counterbalanced A/B runs,
without concurrent native builds or tests.
"""

import argparse
from datetime import datetime, timezone
import hashlib
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
PACKAGE = ROOT / "native/FilmScanEngine"
PROBE = HERE / "CPUPointWorkProbe.swift"
CASE_NAMES = ("colorC41", "colorCyanMask", "blackAndWhite", "straighten-viewport",
              "perspective-viewport", "slide", "calibrated-color")


class ProvenanceChanged(ValueError):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def hashes(paths):
    return {str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path):
            sha256(path) for path in sorted(set(paths))}


def source_hashes():
    paths = [path for path in (PACKAGE / "Sources").rglob("*") if path.is_file()]
    paths += [path for path in PACKAGE.glob("Package.*") if path.is_file()]
    paths += [PROBE, Path(__file__).resolve()]
    return hashes(paths)


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def capture(command):
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=True)
    return {"command": command, "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}


def hardware_metadata():
    command = ["system_profiler", "SPHardwareDataType", "-json"]
    try:
        result = subprocess.run(command, text=True, capture_output=True, timeout=30)
        if result.returncode != 0:
            raise ValueError("system_profiler could not read hardware metadata")
        hardware = json.loads(result.stdout)["SPHardwareDataType"][0]
        keys = ("machine_model", "chip_type", "number_processors", "physical_memory")
        return {"command": command, "values": {key: hardware[key] for key in keys if key in hardware}}
    except (OSError, ValueError, KeyError, IndexError, subprocess.TimeoutExpired) as error:
        return {"command": command, "architecture": platform.machine(), "unavailable": str(error)}


def case_filter(value):
    names = value.split(",")
    if len(set(names)) != len(names) or any(name not in CASE_NAMES for name in names):
        raise argparse.ArgumentTypeError("Use known, nonempty, unique comma-separated case names: "
                                         + ",".join(CASE_NAMES))
    return tuple(name for name in CASE_NAMES if name in names)


def preflight(args):
    raw, output = args.raw.resolve(), args.output.resolve()
    if not raw.is_file():
        raise ValueError("--raw must name an existing RAW file")
    if not output.is_relative_to(ROOT / "dist") or output == ROOT / "dist":
        raise ValueError("--output must be a new child directory inside ignored dist/")
    if output.exists():
        raise ValueError("Choose a fresh --output; existing directories are never reused")
    ignored = subprocess.run(["git", "check-ignore", "--quiet", "--",
                              str(output.relative_to(ROOT)) + "/"], cwd=ROOT)
    if ignored.returncode != 0:
        raise ValueError("--output must be ignored by Git")
    if platform.system() != "Darwin":
        raise ValueError("The production Swift engine requires macOS")
    for tool in ("swift", "swiftc", "pkg-config"):
        if not shutil.which(tool):
            raise ValueError(f"Missing {tool}; see docs/development/building.md")
    versions = {
        "python": sys.version, "platform": platform.platform(),
        "swift": capture(["swift", "--version"]),
        "swiftc": capture(["swiftc", "--version"]),
        "libraw_r": capture(["pkg-config", "--modversion", "libraw_r"]),
        "macOS": capture(["sw_vers"]),
        "hardware": hardware_metadata(),
    }
    return raw, output, versions


def require_unchanged(sources, raw, raw_hash):
    if source_hashes() != sources or sha256(raw) != raw_hash:
        raise ProvenanceChanged("Source or RAW input changed during this run; reject these results "
                                "and choose a fresh --output")


def production_objects(build):
    link_file = build / "FilmScanConverterMac.product/Objects.LinkFileList"
    objects = [Path(path) for path in shlex.split(link_file.read_text())
               if Path(path).parent.name in ("FilmScanEngine.build", "CLibRawShim.build")]
    if (not objects or any(not path.is_file() for path in objects)
            or {path.parent.name for path in objects}
            != {"FilmScanEngine.build", "CLibRawShim.build"}):
        raise ValueError("Production link list has missing engine/shim objects; rebuild before linking")
    return link_file, objects


def logged(command, log, env):
    with log.open("w") as stream:
        subprocess.run(command, cwd=ROOT, env=env, stdout=stream,
                       stderr=subprocess.STDOUT, check=True)


def run(args):
    raw, output, versions = preflight(args)
    cases = args.cases or CASE_NAMES
    sources, raw_hash = source_hashes(), sha256(raw)
    if args.preflight_only:
        print(json.dumps({"raw": str(raw), "rawSHA256": raw_hash, "output": str(output),
                          "mode": args.mode, "timedCases": cases, "untimedBranchCases": 72,
                          "versions": versions, "buildStarted": False}, indent=2))
        return
    output.mkdir(parents=True, exist_ok=False)
    manifest_path = output / "manifest.json"
    manifest = {
        "schemaVersion": 1, "status": "building",
        "startedAtUTC": datetime.now(timezone.utc).isoformat(),
        "root": str(ROOT), "revision": capture(["git", "rev-parse", "HEAD"]),
        "workingTree": capture(["git", "status", "--short"]), "versions": versions,
        "sources": sources, "raw": str(raw), "rawSHA256": raw_hash,
        "rawBytes": raw.stat().st_size, "mode": args.mode, "timedCases": cases,
        "untimedBranchCases": 72, "commands": {},
        "scope": "Warmed CPU correction on one one-pass RAW preview source; no export, "
                 "bitmap packing, app publication or screen-presentation timing.",
        "environment": {name: os.environ.get(name) for name in
                        ("FSC_UNPACK_WORKERS", "FSC_XTRANS_WORKERS")},
    }
    write_json(manifest_path, manifest)
    env = os.environ.copy()
    env.setdefault("CLANG_MODULE_CACHE_PATH", "/tmp/film-scan-clang-cache")
    env.setdefault("SWIFTPM_MODULECACHE_OVERRIDE", "/tmp/film-scan-swiftpm-cache")
    try:
        build_command = ["swift", "build", "--disable-sandbox", "-c", "release", "--jobs", "2",
                         "--package-path", str(PACKAGE), "--product", "FilmScanConverterMac"]
        manifest["commands"]["build"] = build_command
        write_json(manifest_path, manifest)
        print("Building ordinary production release FilmScanConverterMac…", flush=True)
        logged(build_command, output / "build.log", env)
        require_unchanged(sources, raw, raw_hash)

        build = PACKAGE / ".build/release"
        link_file, objects = production_objects(build)
        object_hashes = hashes(objects)
        build_inputs = [link_file, build / "Modules/FilmScanEngine.swiftmodule",
                        build / "CLibRawShim.build/module.modulemap"]
        build_hashes = hashes(build_inputs)
        shutil.copy2(link_file, output / "Objects.LinkFileList")
        frozen_source = output / PROBE.name
        shutil.copy2(PROBE, frozen_source)
        libraries = shlex.split(subprocess.check_output(
            ["pkg-config", "--libs-only-L", "libraw_r"], text=True))
        executable = output / "CPUPointWorkProbe"
        link_command = ["swiftc", "-O", "-module-cache-path", str(build / "ModuleCache"),
                        "-I", str(build / "Modules"), "-Xcc",
                        "-fmodule-map-file=" + str(build / "CLibRawShim.build/module.modulemap"),
                        "-I", str(PACKAGE / "Sources/CLibRawShim/include"), str(frozen_source),
                        *map(str, objects), *libraries, "-lraw_r", "-lc++", "-o", str(executable)]
        manifest.update(status="linking", objects=object_hashes, buildInputs=build_hashes,
                        probeSourceSHA256=sha256(frozen_source))
        manifest["commands"]["link"] = link_command
        write_json(manifest_path, manifest)
        print("Linking and freezing the CPU probe…", flush=True)
        logged(link_command, output / "link.log", env)
        if hashes(objects) != object_hashes or hashes(build_inputs) != build_hashes:
            raise ProvenanceChanged("Production objects/modules changed while linking; choose a fresh run")
        require_unchanged(sources, raw, raw_hash)

        binary_hash = sha256(executable)
        result_path = output / "results.json"
        command = [str(executable), str(raw), str(result_path), args.mode]
        if args.cases:
            command.append(",".join(args.cases))
        manifest.update(status="running", executable=str(executable), binarySHA256=binary_hash)
        manifest["commands"]["run"] = command
        write_json(manifest_path, manifest)
        print("Running fixed cases sequentially; see probe.log for progress…", flush=True)
        logged(command, output / "probe.log", env)
        require_unchanged(sources, raw, raw_hash)
        if sha256(executable) != binary_hash or sha256(frozen_source) != manifest["probeSourceSHA256"]:
            raise ProvenanceChanged("Frozen probe changed during execution; reject this run")
        result = json.loads(result_path.read_text())
        native_raw_hash = result["rawSHA256"].removeprefix("SHA256 digest: ").lower()
        if Path(result["raw"]).resolve() != raw or native_raw_hash != raw_hash:
            raise ProvenanceChanged("Probe report RAW path/hash does not match the pinned input")
        if ([case["name"] for case in result["cases"]] != list(cases)
                or len(result["branchOracles"]) != 72 or result["mode"] != args.mode
                or any([sample["exposureEV"] for sample in case["samples"]] != [.2, -.2, .4]
                       for case in result["cases"])):
            raise ValueError("Probe report has an incomplete or unexpected case set")
        manifest.update(status="complete", completedAtUTC=datetime.now(timezone.utc).isoformat(),
                        resultsSHA256=sha256(result_path))
        write_json(manifest_path, manifest)
        print(f"Complete: {result_path}")
    except (Exception, KeyboardInterrupt) as error:
        manifest.update(status="rejected" if isinstance(error, ProvenanceChanged) else "failed",
                        error=str(error), finishedAtUTC=datetime.now(timezone.utc).isoformat())
        write_json(manifest_path, manifest)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path, required=True, help="One private RAW input; never modified")
    parser.add_argument("--output", type=Path, required=True, help="Fresh child directory inside ignored dist/")
    parser.add_argument("--mode", choices=("full", "proxy"), required=True,
                        help="Full-sensor one-pass source or its bounded 2048px proxy")
    parser.add_argument("--cases", type=case_filter,
                        help="Comma-separated timed case subset; 72 untimed branch checks always run. "
                             + ",".join(CASE_NAMES))
    parser.add_argument("--preflight-only", action="store_true",
                        help="Validate paths, names, tools and fingerprints; no build, run or output")
    args = parser.parse_args()
    try:
        run(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"CPU point-work probe failed: {error}\n")


if __name__ == "__main__":
    main()
