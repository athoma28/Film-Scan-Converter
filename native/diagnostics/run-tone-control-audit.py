"""Build and probe the production engine; keep all generated/private artifacts in dist/."""

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

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True, help="A new, empty directory under dist/")
parser.add_argument("--timing-only", action="store_true",
                    help="One RAW, split render/consumer timing and memory; no ramps or image files")
args = parser.parse_args()
output = args.output.resolve()
if not output.is_relative_to(ROOT / "dist"):
    parser.error("Output must be under ignored dist/")
if output.exists() and any(output.iterdir()):
    parser.error("Choose a fresh output directory; old audit evidence is never overwritten")
output.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, CLANG_MODULE_CACHE_PATH="/tmp/fsc-tone-audit-clang",
           SWIFTPM_MODULECACHE_OVERRIDE="/tmp/fsc-tone-audit-swift")


def sha256(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def capture(command):
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    return {"command": command, "returncode": result.returncode,
            "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}


source = Path(__file__).with_name("ToneControlAudit.swift")
sources = [p for p in (ROOT / "native/FilmScanEngine/Sources").rglob("*") if p.is_file()]
sources += [source, Path(__file__).resolve(), ROOT / "native/FilmScanEngine/Package.swift"]
inputs = [ROOT / "sample-raw/fuji400-fresh/DSCF2833.RAF"]
if not args.timing_only:
    for frame in ["fuji400-fresh/DSCF2833", "proimage/DSCF5800", "harmanphoenixii/DSCF3079",
                  "fuji400-fresh/DSCF2892", "proimage/DSCF5809", "harmanphoenixii/DSCF3091"]:
        inputs.extend(ROOT / "dist/camera-raw-study" / frame / name
                      for name in ["metadata.json", "scan.bgr16"])
missing = [str(p.relative_to(ROOT)) for p in inputs if not p.is_file()]
if missing:
    parser.error("Missing required inputs: " + ", ".join(missing))
source_hashes = {str(p.relative_to(ROOT)): sha256(p) for p in sorted(sources)}
input_hashes = {str(p.relative_to(ROOT)): sha256(p) for p in inputs}
environment = {name: capture(command) for name, command in {
    "macos": ["sw_vers"], "swift": ["swift", "--version"],
    "xcode": ["xcodebuild", "-version"], "developerDirectory": ["xcode-select", "-p"],
    "libraw": ["pkg-config", "--modversion", "libraw_r"],
    "graphics": ["system_profiler", "SPDisplaysDataType", "-json"],
    "memory": ["vm_stat"], "memoryPressure": ["memory_pressure", "-Q"],
    "power": ["pmset", "-g", "batt"], "thermal": ["pmset", "-g", "therm"],
}.items()}
hardware = capture(["system_profiler", "SPHardwareDataType", "-json"])
if hardware["returncode"] == 0:
    # Keep model/capacity, not machine serial numbers or hardware UUIDs.
    environment["hardware"] = [{k: v for k, v in row.items() if k in {
        "machine_model", "machine_name", "chip_type", "number_processors", "physical_memory"}}
        for row in json.loads(hardware["stdout"])["SPHardwareDataType"]]
else:
    environment["hardware"] = hardware
environment["diskFreeBytesBeforeBuild"] = shutil.disk_usage(ROOT).free
build_command = ["swift", "build", "--disable-sandbox", "-c", "release", "--package-path",
                 str(ROOT / "native/FilmScanEngine"), "--product", "FilmScanPreviewComparator"]
with (output / "build.log").open("w") as log:
    subprocess.run(build_command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
build = ROOT / "native/FilmScanEngine/.build/release"
link_file = build / "FilmScanPreviewComparator.product/Objects.LinkFileList"
objects = [p for p in shlex.split(link_file.read_text()) if any(
    part in p for part in ["/FilmScanEngine.build/", "/CLibRawShim.build/", "/FilmScanPreviewRenderer.build/"])]
# Timing reports stay compact; keep their generated executable in the ignored
# build tree, fingerprinted below. Full audits retain their historical layout.
executable = build / "ToneControlTimingProbe" if args.timing_only else output / "probe"
libraries = shlex.split(subprocess.check_output(["pkg-config", "--libs-only-L", "libraw_r"], text=True))
compile_command = ["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(build / "ModuleCache"),
                "-I", str(build / "Modules"), "-Xcc", "-fmodule-map-file=" + str(build / "CLibRawShim.build/module.modulemap"),
                "-I", str(ROOT / "native/FilmScanEngine/Sources/CLibRawShim/include"), str(source),
                *objects, *libraries, "-lraw_r", "-lc++", "-o", str(executable)]
with (output / "build.log").open("a") as log:
    subprocess.run(compile_command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
if source_hashes != {str(p.relative_to(ROOT)): sha256(p) for p in sorted(sources)}:
    raise RuntimeError("Source changed during build; choose a fresh output and rerun")
probe_command = [str(executable), str(ROOT), str(output)]
if args.timing_only:
    probe_command.append("--timing-only")
manifest = {
    "collectedAtUTC": datetime.now(timezone.utc).isoformat(),
    "mode": "timing-only" if args.timing_only else "full-audit",
    "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
    "workingTree": subprocess.check_output(["git", "status", "--short"], cwd=ROOT, text=True),
    "platform": platform.platform(),
    "swift": subprocess.check_output(["swift", "--version"], text=True),
    "libraw": subprocess.check_output(["pkg-config", "--modversion", "libraw_r"], text=True).strip(),
    "sources": source_hashes,
    "inputs": input_hashes,
    "environment": environment,
    "buildCommand": build_command,
    "compileCommand": compile_command,
    "probeCommand": probe_command,
    "linkedObjects": {str(Path(p).relative_to(ROOT)): sha256(Path(p)) for p in objects},
    "executable": str(executable.relative_to(ROOT)),
    "executableSHA256": sha256(executable),
    "photographScope": ("One full-sensor one-pass C-41 + Clean Invert RAW and 2048px proxy; "
                        "timing and separate untimed memory/hash passes only. No disk images."
                        if args.timing_only else
                        "Fresh production CPU/Metal renders of six archived 900px decoded scan inputs; explicit current FilmBase + Clean Invert; not an ACR fit or current app automatic classification."),
    "cacheConditions": "Filesystem cache uncontrolled; inputs hashed before run; no caches purged.",
    "status": "running",
}
(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
try:
    with (output / "probe.log").open("w") as log:
        subprocess.run(probe_command, stdout=log, stderr=subprocess.STDOUT, check=True)
    if (source_hashes != {str(p.relative_to(ROOT)): sha256(p) for p in sorted(sources)}
            or input_hashes != {str(p.relative_to(ROOT)): sha256(p) for p in inputs}
            or manifest["executableSHA256"] != sha256(executable)):
        raise RuntimeError("Source, input or executable changed during collection; discard comparisons")
    manifest["status"] = "completed"
finally:
    if manifest["status"] != "completed":
        manifest["status"] = "failed"
    manifest["finishedAtUTC"] = datetime.now(timezone.utc).isoformat()
    manifest["diskFreeBytesAfterRun"] = shutil.disk_usage(ROOT).free
    manifest["outputs"] = {str(p.relative_to(output)): {"bytes": p.stat().st_size, "sha256": sha256(p)}
                           for p in output.rglob("*") if p.is_file() and p.name != "manifest.json"}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print((output / "probe.log").read_text())
print(output)
