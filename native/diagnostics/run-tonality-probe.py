"""Link a tiny probe against an existing release build; never rebuild it."""

from pathlib import Path
import argparse
import shlex
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
group = parser.add_mutually_exclusive_group()
group.add_argument("--pass-two", action="store_true", help="Run bounded follow-up experiments.")
group.add_argument("--paired-recipes", type=Path,
                    help="Validate paired-study clipboard recipes and probe current color controls.")
options = parser.parse_args()
sources = [Path(__file__).with_name("BWTonalityProbe.swift")]
if options.pass_two:
    sources = [
        Path(__file__).with_name("ResearchPassTwoProbe.swift"),
        root / "native/FilmScanEngine/Sources/FilmScanConverterMac/PerFileSettingsStore.swift",
    ]
if options.paired_recipes:
    sources = [
        Path(__file__).with_name("PairedControlProbe.swift"),
        root / "native/FilmScanEngine/Sources/FilmScanConverterMac/CorrectionSettings.swift",
    ]
build = root / "native/FilmScanEngine/.build/release"
link_file = next(
    (
        build / product / "Objects.LinkFileList"
        for product in [
            "FilmScanLookbook.product",
            "FilmScanConverterMac.product",
            "FilmScanRawBenchmark.product",
            "FilmScanEnginePackageTests.product",
        ]
        if (build / product / "Objects.LinkFileList").is_file()
    ),
    None,
)
if link_file is None:
    sys.exit("A current release build is required; see the diagnostics README.")

# The directory may contain stale objects for deleted Swift files. Use only the
# product's link list, excluding its executable/test entry points.
objects = [
    path
    for path in shlex.split(link_file.read_text())
    if "/FilmScanEngine.build/" in path or "/CLibRawShim.build/" in path
]
if not objects or any(not Path(path).is_file() for path in objects):
    sys.exit("The release build has missing objects; rebuild before running the probe.")

libraw_paths = shlex.split(
    subprocess.check_output(["pkg-config", "--libs-only-L", "libraw_r"], text=True)
)
with tempfile.TemporaryDirectory(prefix="fsc-tonality-") as temporary:
    executable = Path(temporary) / "probe"
    subprocess.run(
        [
            # Access the internal merge stage for this diagnostic only, without
            # rebuilding the app or exporting a new production API.
            "swiftc", "-O", "-Xfrontend", "-disable-access-control",
            "-module-cache-path", str(build / "ModuleCache"),
            "-I", str(build / "Modules"),
            "-Xcc", "-fmodule-map-file=" + str(build / "CLibRawShim.build/module.modulemap"),
            "-I", str(root / "native/FilmScanEngine/Sources/CLibRawShim/include"),
            *map(str, sources),
            *objects, *libraw_paths, "-lraw_r", "-lc++", "-o", str(executable),
        ],
        check=True,
    )
    subprocess.run([str(executable)] + ([str(options.paired_recipes)] if options.paired_recipes else []),
                   check=True)
