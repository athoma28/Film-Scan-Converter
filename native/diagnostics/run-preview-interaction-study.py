#!/usr/bin/env python3
"""Build, replay and summarize the production native-window interaction diagnostic.

Use normal macOS graphics access and existing Screen Recording permission. Only
the benchmark window is sampled; no screen images/audio are saved. Outputs must
be fresh and under ignored dist/. No user settings or export destinations change.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "native/FilmScanEngine"


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def distribution(values):
    values = sorted(values)
    if not values:
        return {"count": 0, "median": None, "p95": None, "maximum": None}

    def quantile(q):
        position = q * (len(values) - 1)
        lo = math.floor(position)
        hi = math.ceil(position)
        return values[lo] + (values[hi] - values[lo]) * (position - lo)

    return {"count": len(values), "median": quantile(.5), "p95": quantile(.95),
            "maximum": values[-1]}


def summarize(report):
    frames = report["compositorCapture"]["frames"]
    cases = []
    for case in report["cases"]:
        start, end = case["gestureStartMilliseconds"], case["releaseMilliseconds"]
        events = case["events"]
        stages = {}
        for event in events:
            if event.get("revision") is not None:
                stages.setdefault(event["revision"], {}).setdefault(event["stage"], event)
        published = {e["revision"]: e for e in events if e["stage"] == "modelPublished"}
        observations = {}
        for frame in frames:
            revision = frame.get("revision")
            if revision in published:
                observations.setdefault(revision, frame)
        during = {r: f for r, f in observations.items() if start <= f["callbackMilliseconds"] < end}
        observed = sorted(during.values(), key=lambda f: f["presentationTimeSeconds"])
        pts = [f["presentationTimeSeconds"] for f in observed]
        gaps = [(b - a) * 1000 for a, b in zip(pts, pts[1:])]
        duration = (end - start) / 1000
        rate = len(during) / duration
        render = []
        preparation = []
        queue = []
        publish = []
        model_latency = []
        delivery = []
        callback_latency = []
        worker_compute = []
        worker_dispatch = []
        main_actor_resume = []
        for revision, stage in stages.items():
            if not {"requestSubmitted", "renderBegan", "renderReturned", "modelPublished"} <= stage.keys():
                continue
            submitted = stage["requestSubmitted"]
            if not start <= submitted["milliseconds"] < end:
                continue
            queue.append(stage["renderBegan"]["milliseconds"] - submitted["milliseconds"])
            render.append(stage["renderReturned"]["milliseconds"] - stage["renderBegan"]["milliseconds"])
            if "workerBegan" in stage and "workerFinished" in stage:
                worker_dispatch.append(stage["workerBegan"]["milliseconds"] - stage["renderBegan"]["milliseconds"])
                worker_compute.append(stage["workerFinished"]["milliseconds"] - stage["workerBegan"]["milliseconds"])
                main_actor_resume.append(stage["renderReturned"]["milliseconds"] - stage["workerFinished"]["milliseconds"])
            publish.append(stage["modelPublished"]["milliseconds"] - stage["renderReturned"]["milliseconds"])
            if submitted.get("interactionMilliseconds") is not None:
                preparation.append(submitted["milliseconds"] - submitted["interactionMilliseconds"])
                model_latency.append(stage["modelPublished"]["milliseconds"] - submitted["interactionMilliseconds"])
            if revision in observations:
                frame = observations[revision]
                delivery.append(frame["callbackMilliseconds"] - stage["modelPublished"]["milliseconds"])
                if submitted.get("interactionMilliseconds") is not None:
                    callback_latency.append(frame["callbackMilliseconds"] - submitted["interactionMilliseconds"])
        final = observations.get(case["finalRevision"])
        final_model = published.get(case["finalRevision"])
        publication_times = sorted(e["milliseconds"] for e in published.values()
                                   if start <= e["milliseconds"] < end)
        viewport_update = []
        viewport_begins = {}
        for event in events:
            revision = event.get("revision")
            if event["stage"] == "viewportUpdateBegan":
                viewport_begins[revision] = event["milliseconds"]
            elif event["stage"] == "viewportUpdateEnded" and revision in viewport_begins:
                began = viewport_begins.pop(revision)
                if start <= began < end:
                    viewport_update.append(event["milliseconds"] - began)
        cases.append({
            "name": case["name"], "repetition": case["repetition"],
            "gestureDurationSeconds": duration,
            "submittedInputCount": len(case["inputs"]),
            "modelPublishedDuringGesture": sum(start <= e["milliseconds"] < end for e in published.values()),
            "distinctCompositorRevisionsDuringGesture": len(during),
            "compositorObservedRevisionsPerSecond": rate,
            "meets40RevisionPerSecondTarget": rate >= 40,
            "compositorPTSInterRevisionGapMilliseconds": distribution(gaps),
            "setterToCompositorCallbackMilliseconds": distribution(callback_latency),
            "preparationMilliseconds": distribution(preparation),
            "setterToModelPublicationMilliseconds": distribution(model_latency),
            "modelPublicationGapMilliseconds": distribution([
                b - a for a, b in zip(publication_times, publication_times[1:])]),
            "queueMilliseconds": distribution(queue),
            "renderMilliseconds": distribution(render),
            "workerComputeMilliseconds": distribution(worker_compute),
            "workerDispatchMilliseconds": distribution(worker_dispatch),
            "workerFinishToMainActorResumeMilliseconds": distribution(main_actor_resume),
            "nativeViewportUpdateMilliseconds": distribution(viewport_update),
            "renderReturnToModelPublicationMilliseconds": distribution(publish),
            "modelPublicationToCaptureCallbackMilliseconds": distribution(delivery),
            "inputLatenessMilliseconds": distribution([
                e["setterStartMilliseconds"] - e["scheduledMilliseconds"] for e in case["inputs"]]),
            "setterMilliseconds": distribution([
                e["setterEndMilliseconds"] - e["setterStartMilliseconds"] for e in case["inputs"]]),
            "releaseToFinalCompositorCallbackMilliseconds":
                None if final is None else final["callbackMilliseconds"] - end,
            "releaseToFinalModelPublicationMilliseconds":
                None if final_model is None else final_model["milliseconds"] - end,
            "publishedRevisionsNotObservedByCapture": sorted(set(published) - set(observations)),
            "observedRevisionCountIncludingRefinement": len(observations),
            "nativeDrawEndCount": sum(e["stage"] == "hostingDrawEnded" for e in events),
        })
    return {
        "note": "Composited revision-marker observations from the diagnostic window, not mouse events or physical screen scan-out. Rates count distinct revisions received during the measured gesture, so include capture-delivery boundary effects. Setter-to-callback latency includes ScreenCaptureKit delivery. Inter-revision gaps use capture sample PTS differences, never mixed clocks. 40 updates/s is a desired target, not a test assertion. renderMilliseconds spans dispatch through MainActor resumption; workerComputeMilliseconds times only the detached worker, and workerFinishToMainActorResumeMilliseconds separates UI contention when worker timestamps exist. Empty worker distributions in older reports mean unavailable, not zero. Short replays do not estimate population tails. Capture and diagnostics add overhead; compare matched instrumented runs. The marker shares the preview's SwiftUI revision update but is not a checksum of the image pixels.",
        "markerDecodedCompleteFrames": sum(f.get("revision") is not None for f in frames),
        "markerMissingCompleteFrames": sum(f.get("revision") is None for f in frames),
        "capturedCompleteFrames": len(frames),
        "allCasesHaveCompositorEvidence": all(c["distinctCompositorRevisionsDuringGesture"] > 0 for c in cases),
        "allCasesMeet40Target": all(c["meets40RevisionPerSecondTarget"] for c in cases),
        "cases": cases,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, choices=range(1, 6), default=3)
    parser.add_argument("--events", type=int, choices=range(60, 241), default=120)
    options = parser.parse_args()
    output = options.output.resolve()
    if not output.is_relative_to(ROOT / "dist") or output == ROOT / "dist":
        parser.error("Choose a new directory under ignored dist/")
    if output.exists() and any(output.iterdir()):
        parser.error("Output is not empty; preserve earlier evidence and choose a fresh directory")
    output.mkdir(parents=True, exist_ok=True)
    def hashes():
        sources = sorted(p for folder in (PACKAGE / "Sources", PACKAGE / "Tests")
                         for p in folder.rglob("*") if p.is_file())
        sources += [PACKAGE / "Package.swift", Path(__file__).resolve()]
        return {str(p.relative_to(ROOT)): sha256(p) for p in sources}

    before = hashes()
    raw_input = ROOT / "sample-raw/fuji400-fresh/DSCF2833.RAF"
    input_hash = sha256(raw_input)
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH="/tmp/film-scan-clang-cache",
                       SWIFTPM_MODULECACHE_OVERRIDE="/tmp/film-scan-swiftpm-cache")
    environment.pop("RUN_PREVIEW_INTERACTION_BENCHMARK", None)
    base = ["swift", "test", "--disable-sandbox", "-c", "release", "--package-path", str(PACKAGE),
            "--no-parallel", "--filter", "PreviewInteractionPerformanceTests"]
    manifest = {"startedAtUTC": datetime.now(timezone.utc).isoformat(),
                "status": "building", "sources": before, "platform": platform.platform(),
                "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "buildCommand": base, "repetitions": options.repetitions, "events": options.events,
                "inputSHA256": input_hash,
                "swift": subprocess.check_output(["swift", "--version"], text=True).strip(),
                "libraw": subprocess.check_output(["pkg-config", "--modversion", "libraw_r"], text=True).strip()}
    write(output / "manifest.json", manifest)
    try:
        with (output / "build.log").open("w") as log:
            subprocess.run(base, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
        if hashes() != before:
            raise RuntimeError("Source changed during build; choose a fresh output")
        binaries = [PACKAGE / ".build/release/FilmScanConverterMac",
                    PACKAGE / ".build/release/FilmScanEnginePackageTests.xctest/Contents/MacOS/FilmScanEnginePackageTests"]
        binary_hashes = {str(p.relative_to(ROOT)): sha256(p) for p in binaries}
        manifest["binaries"] = binary_hashes
        environment.update(RUN_PREVIEW_INTERACTION_BENCHMARK="1",
                           FSC_PREVIEW_INTERACTION_OUTPUT=str(output / "raw.json"),
                           FSC_INTERACTION_REPETITIONS=str(options.repetitions),
                           FSC_INTERACTION_EVENTS=str(options.events))
        command = base + ["--skip-build"]
        manifest.update(status="running", replayCommand=command)
        write(output / "manifest.json", manifest)
        with (output / "replay.log").open("w") as log:
            subprocess.run(command, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
        if (hashes() != before or sha256(raw_input) != input_hash
                or binary_hashes != {str(p.relative_to(ROOT)): sha256(p) for p in binaries}):
            raise RuntimeError("Source, input or binary changed during replay; discard comparisons")
        report = json.loads((output / "raw.json").read_text())
        if report["inputSHA256"] != input_hash:
            raise RuntimeError("The replay input digest does not match the runner")
        summary = summarize(report)
        write(output / "summary.json", summary)
        if not summary["allCasesHaveCompositorEvidence"]:
            raise RuntimeError("Missing compositor marker evidence in one or more cases; inspect raw.json")
        if report["discardedTraceEvents"] or report["compositorCapture"]["discardedFrames"]:
            raise RuntimeError("Diagnostic capacity exceeded; report is incomplete")
        manifest["status"] = "completed"
    except Exception as error:
        manifest.update(status="failed", error=str(error))
        raise
    finally:
        manifest["finishedAtUTC"] = datetime.now(timezone.utc).isoformat()
        manifest["outputs"] = {p.name: sha256(p) for p in output.iterdir()
                               if p.is_file() and p.name != "manifest.json"}
        write(output / "manifest.json", manifest)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
