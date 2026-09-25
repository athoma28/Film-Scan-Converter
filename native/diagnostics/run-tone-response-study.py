#!/usr/bin/env python3
"""Fresh production tone-response study with fixed regions and ordinary edit deltas.

Requires the existing color-study environment (numpy, OpenCV, Pillow), macOS,
Swift and LibRaw. Outputs stay in a new ignored dist/ directory. No scans, saved
settings, recipes, preferred looks, or engine behavior are changed.
"""

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import html
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import shlex
import subprocess
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw

from tone_response_metrics import (METHOD, features, fixed_masks, measure,
                                   read_render, reliable_chroma_mask)


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
PREFERENCES = ROOT / "docs/development/color-preference-checkpoints.json"


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def hashes(paths, relative_to=ROOT):
    return {str(path.relative_to(relative_to)) if path.is_relative_to(relative_to) else str(path):
            sha256(path) for path in sorted(paths)}


def capture(command):
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    return {"command": command, "returncode": result.returncode,
            "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}


def variants():
    result = [{"id": "baseline", "label": "Baseline", "deltas": {}}]
    for key, label, values in [
        ("exposureEV", "Exposure", [-.5, -.25, .25, .5]),
        ("brightness", "Brightness", [-.25, -.1, .1, .25]),
        ("contrast", "Contrast", [-.25, -.1, .1, .25]),
        ("highlights", "Highlights", [-.25, -.1, .1, .25]),
        ("shadows", "Shadows", [-.25, -.1, .1, .25]),
        ("whites", "Whites", [-.25, .25]),
        ("blacks", "Blacks", [-.25, .25]),
        ("shadowFloor", "Shadow Floor", [-.25, .25]),
        ("midtoneLevel", "Midtone Level", [-.25, .25]),
        ("highlightCeiling", "Highlight Ceiling", [-.25, .25]),
    ]:
        for value in values:
            token = ("m" if value < 0 else "p") + str(abs(value)).replace(".", "_")
            result.append({"id": key + "_" + token,
                           "label": f"{label} {value:+g}" + (" EV" if key == "exposureEV" else ""),
                           "deltas": {key: value}})
    result.extend([
        {"id": "lift_protect", "label": "Exposure +.5, highlights −.25",
         "deltas": {"exposureEV": .5, "highlights": -.25}},
        {"id": "open_shadows", "label": "Shadows +.25, contrast +.1",
         "deltas": {"shadows": .25, "contrast": .1}},
        {"id": "brighten_separate", "label": "Brightness +.1, contrast +.1",
         "deltas": {"brightness": .1, "contrast": .1}},
        {"id": "darken_open", "label": "Exposure −.5, shadows +.25",
         "deltas": {"exposureEV": -.5, "shadows": .25}},
        {"id": "compress_range", "label": "Highlights −.25, shadows +.25",
         "deltas": {"highlights": -.25, "shadows": .25}},
        {"id": "contrast_recover", "label": "Contrast +.25, highlights −.1, shadows +.1",
         "deltas": {"contrast": .25, "highlights": -.1, "shadows": .1}},
    ])
    return result


def default_profiles():
    return [
        {"name": "clean-invert-v2", "schemaVersion": 2, "photoOverrides": {},
         "variantIDs": None},
        {"name": "modest-color-v2", "schemaVersion": 2,
         "photoOverrides": {"temperatureShiftMired": 15, "tint": .08,
                            "saturation": .2, "vibrance": .15},
         "variantIDs": ["baseline", "exposureEV_p0_5", "shadows_p0_25", "contrast_p0_25",
                        "lift_protect", "open_shadows"]},
    ]


def validate_profiles(profiles, allowed_variants):
    names = set()
    keys = {"exposureEV", "brightness", "contrast", "highlights", "shadows", "whites",
            "blacks", "shadowFloor", "midtoneLevel", "highlightCeiling",
            "temperatureShiftMired", "tint", "saturation", "vibrance"}
    if not profiles:
        raise ValueError("At least one named profile is required")
    for profile in profiles:
        name = profile["name"]
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", name) or name in names:
            raise ValueError(f"Profile names must be unique safe lowercase IDs: {name}")
        names.add(name)
        if profile["schemaVersion"] not in [1, 2, 3, 4]:
            raise ValueError("Only supported tone schemas 1–4 can be measured")
        overrides = profile["photoOverrides"]
        if set(overrides) - keys or not all(type(x) in [int, float] and np.isfinite(x)
                                          for x in overrides.values()):
            raise ValueError("Invalid photoOverrides")
        ids = profile.get("variantIDs")
        if ids is not None and ("baseline" not in ids or len(set(ids)) != len(ids)
                                or set(ids) - allowed_variants):
            raise ValueError("variantIDs must include baseline and known, unique IDs")
        profile.setdefault("variantIDs", None)


def same_edit_pairs(profiles):
    pairs = []
    for candidate in profiles:
        if candidate["schemaVersion"] not in [3, 4]:
            continue
        matches = [p for p in profiles if p["schemaVersion"] == 2
                   and p["photoOverrides"] == candidate["photoOverrides"]]
        explicit = candidate.get("sameEditReferenceProfile")
        if explicit:
            matches = [p for p in matches if p["name"] == explicit]
        if len(matches) != 1:
            raise ValueError(f"Trial {candidate['name']} needs exactly one schema-2 reference with identical "
                             "photoOverrides (or an explicit sameEditReferenceProfile)")
        reference_ids, candidate_ids = matches[0].get("variantIDs"), candidate.get("variantIDs")
        if reference_ids is not None and (candidate_ids is None or set(candidate_ids) - set(reference_ids)):
            raise ValueError(f"Reference {matches[0]['name']} must render every requested trial variant")
        pairs.append({"referenceProfile": matches[0]["name"],
                      "candidateProfile": candidate["name"]})
    return pairs


def preference_inputs(archive):
    ledger = json.loads(PREFERENCES.read_text())
    if ledger.get("schemaVersion") != 1:
        raise ValueError("Unsupported preference ledger")
    inputs, count = [PREFERENCES], 0
    for frame in ledger["frames"]:
        identifier = frame["stock"] + "/" + frame["frame"]
        if not re.fullmatch(r"[A-Za-z0-9_-]+/[A-Za-z0-9_-]+", identifier):
            raise ValueError("Unsafe preference frame ID")
        directory = archive / identifier
        metadata_path, scan = directory / "metadata.json", directory / "scan.bgr16"
        metadata = json.loads(metadata_path.read_text())
        if (metadata["channels"] != 3 or "medians" not in metadata
                or scan.stat().st_size != metadata["width"] * metadata["height"] * 6):
            raise ValueError(f"Incomplete historical preference input: {identifier}")
        for candidate in frame["candidates"]:
            if (not re.fullmatch(r"[A-Za-z0-9_-]+", candidate["variant"])
                    or not re.fullmatch(r"[a-f0-9]{64}", candidate["imageSHA256"])):
                raise ValueError("Invalid frozen preference candidate")
            count += 1
        inputs.extend([metadata_path, scan])
    if count < 5:
        raise ValueError("All five frozen preference snapshots are required")
    return inputs, count


def prepare_spec(cohort, archive, profiles, compare_metal, correction_documents=False):
    if cohort.get("schemaVersion") != 1 or not cohort.get("frames"):
        raise ValueError("Unsupported or empty cohort")
    frames, inputs, ids = [], [], set()
    for frame in cohort["frames"]:
        identifier = frame["id"]
        if (not re.fullmatch(r"[A-Za-z0-9_-]+/[A-Za-z0-9_-]+", identifier)
                or identifier in ids):
            raise ValueError(f"Unsafe or duplicate frame ID: {identifier}")
        ids.add(identifier)
        if frame["filmBase"] not in ["colorC41", "colorCyanMask"]:
            raise ValueError("This study explicitly supports C-41 and cyan-mask color bases")
        directory = archive / identifier
        metadata_path, scan = directory / "metadata.json", directory / "scan.bgr16"
        metadata = json.loads(metadata_path.read_text())
        width, height, channels = (metadata[k] for k in ["width", "height", "channels"])
        if (any(type(x) is not int for x in [width, height, channels]) or channels != 3
                or width <= 0 or height <= 0 or scan.stat().st_size != width * height * channels * 2):
            raise ValueError(f"Wrong archived scan size: {identifier}")
        # Fail before building if an authored region is invalid; never silently
        # drop a photograph or clamp a region into a more flattering selection.
        blank = features(np.full((height, width, 3), .5))
        fixed_masks(frame, blank)
        frames.append({**frame, "directory": str(directory), "width": width, "height": height})
        inputs.extend([metadata_path, scan])
    study_variants = variants()
    validate_profiles(profiles, {v["id"] for v in study_variants})
    pairs = same_edit_pairs(profiles)
    frozen_inputs, frozen_count = preference_inputs(archive)
    inputs.extend(frozen_inputs)
    return {"schemaVersion": 1, "frames": frames, "variants": study_variants,
            "profiles": profiles, "sameEditPairs": pairs, "compareMetal": compare_metal,
            "preferenceCheckpoints": str(PREFERENCES), "archiveDirectory": str(archive),
            "preferenceSnapshotCount": frozen_count,
            "writeCorrectionDocuments": correction_documents}, list(set(inputs))


def compile_probe(output, env, commands):
    build = ROOT / "native/FilmScanEngine/.build/release"
    build_command = ["swift", "build", "--disable-sandbox", "-c", "release", "--package-path",
                     str(ROOT / "native/FilmScanEngine"), "--product", "FilmScanPreviewComparator"]
    commands["buildCommand"] = build_command
    with (output / "build.log").open("w") as log:
        subprocess.run(build_command, cwd=ROOT, env=env, stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    link_file = build / "FilmScanPreviewComparator.product/Objects.LinkFileList"
    objects = [path for path in shlex.split(link_file.read_text()) if any(
        part in path for part in ["/FilmScanEngine.build/", "/CLibRawShim.build/",
                                  "/FilmScanPreviewRenderer.build/"])]
    if not objects:
        raise RuntimeError("No production objects found in release linker input")
    libraries = shlex.split(subprocess.check_output(
        ["pkg-config", "--libs-only-L", "libraw_r"], text=True))
    executable = output / "ToneResponseStudy"
    command = ["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(build / "ModuleCache"),
               "-I", str(build / "Modules"), "-Xcc",
               "-fmodule-map-file=" + str(build / "CLibRawShim.build/module.modulemap"),
               "-I", str(ROOT / "native/FilmScanEngine/Sources/CLibRawShim/include"),
               str(HERE / "ToneResponseStudy.swift"), *objects, *libraries,
               "-lraw_r", "-lc++", "-o", str(executable)]
    commands["compileCommand"] = command
    with (output / "build.log").open("a") as log:
        subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    return executable, [Path(path) for path in objects]


def overlay(output, frame, rgb):
    image = Image.fromarray(np.rint(rgb * 255).astype(np.uint8))
    draw = ImageDraw.Draw(image)
    colors = ["#ffe066", "#69dbff", "#ff92cc", "#a9e34b", "#ffa94d", "#b197fc"]
    for i, region in enumerate(frame["regions"]):
        x0, y0, x1, y1 = region["rect"]
        color = colors[i % len(colors)]
        draw.rectangle((x0, y0, x1 - 1, y1 - 1), outline=color, width=2)
        draw.text((x0 + 3, y0 + 3), region["id"], fill=color, stroke_width=1,
                  stroke_fill="#101010")
    relative = frame["id"] + "/regions.png"
    image.save(output / relative)
    return relative


def analyze(output, spec):
    native = json.loads((output / "renders.json").read_text())
    render_index = {(r["frame"], r["profile"], r["variant"]): r for r in native["renders"]}
    expected = {(f["id"], p["name"], v["id"]) for f in spec["frames"] for p in spec["profiles"]
                for v in spec["variants"] if p["variantIDs"] is None or v["id"] in p["variantIDs"]}
    if set(render_index) != expected or len(native["renders"]) != len(expected):
        raise RuntimeError("Missing, duplicated or unexpected production renders")
    report = {"schemaVersion": 1, "method": METHOD, "frames": [], "measurements": [],
              "profiles": spec["profiles"], "variants": spec["variants"],
              "nativeRenderCount": len(expected), "frameExclusions": [],
              "sameEditPairs": spec["sameEditPairs"], "sameEditMeasurements": [],
              "sameEditMethod": "Candidate-minus-reference output at identical serialized parameters except tone schema. Geometric/tonal masks remain frozen to the first profile baseline. Color eligibility is frozen to the exact reference edit for each pair/variant. The response difference subtracts each profile's own baseline offset: (candidate edit−candidate baseline)−(reference edit−reference baseline). Clean Invert has nonzero Highlights/Shadows, so baseline render differences are explicitly included, not hidden as a new control response."}
    reference_profile = spec["profiles"][0]["name"]
    for frame in spec["frames"]:
        identifier = frame["id"]
        canonical = features(read_render(output / render_index[identifier, reference_profile, "baseline"]["render"]))
        masks, thresholds, safe = fixed_masks(frame, canonical)
        frame_row = {**frame, "maskReferenceProfile": reference_profile,
                     "encodedLumaQuintileBoundaries": thresholds,
                     "fixedMaskPixelCounts": {name: int(mask.sum()) for name, mask in masks.items()},
                     "regionOverlay": overlay(output, frame, canonical.rgb)}
        report["frames"].append(frame_row)
        # Save memberships themselves, not just thresholds, for reproducible
        # inspection and later candidate studies without drifting selections.
        np.savez_compressed(output / identifier / "fixed-masks.npz", **masks)
        for profile in spec["profiles"]:
            base_row = render_index[identifier, profile["name"], "baseline"]
            baseline = features(read_render(output / base_row["render"]))
            color_mask = reliable_chroma_mask(baseline)
            np.save(output / identifier / profile["name"] / "reliable-chroma-mask.npy", color_mask)
            for variant in spec["variants"]:
                key = identifier, profile["name"], variant["id"]
                if key not in render_index:
                    continue
                row = render_index[key]
                edited = baseline if variant["id"] == "baseline" else features(read_render(output / row["render"]))
                if edited.rgb.shape != baseline.rgb.shape:
                    raise RuntimeError(f"Output geometry changed: {key}")
                for name, mask in masks.items():
                    value = {"frame": identifier, "profile": profile["name"],
                             "variant": variant["id"], "selection": name,
                             **measure(baseline, edited, mask, color_mask, safe,
                                       erode_selection_for_detail=not name.startswith("baseline_luma_"))}
                    report["measurements"].append(value)
        response_index = {(r["profile"], r["variant"], r["selection"]): r
                          for r in report["measurements"] if r["frame"] == identifier}
        for pair in spec["sameEditPairs"]:
            reference_name, candidate_name = pair["referenceProfile"], pair["candidateProfile"]
            for variant in spec["variants"]:
                reference_key, candidate_key = ((identifier, name, variant["id"])
                                                for name in [reference_name, candidate_name])
                if reference_key not in render_index or candidate_key not in render_index:
                    continue
                reference_row, candidate_row = render_index[reference_key], render_index[candidate_key]
                reference_parameters = json.loads((output / reference_row["parameters"]).read_text())
                candidate_parameters = json.loads((output / candidate_row["parameters"]).read_text())
                for parameters in [reference_parameters, candidate_parameters]:
                    parameters["photoAdjustments"].pop("schemaVersion")
                if reference_parameters != candidate_parameters:
                    raise RuntimeError(f"Same-edit pair has differing parameters beyond schema: {candidate_key}")
                reference = features(read_render(output / reference_row["render"]))
                candidate = features(read_render(output / candidate_row["render"]))
                eligible = reliable_chroma_mask(reference)
                for name, mask in masks.items():
                    ref_response = response_index[reference_name, variant["id"], name]
                    trial_response = response_index[candidate_name, variant["id"], name]
                    value = {"frame": identifier, "profile": candidate_name,
                             "referenceProfile": reference_name, "variant": variant["id"],
                             "selection": name,
                             **measure(reference, candidate, mask, eligible, safe,
                                       erode_selection_for_detail=not name.startswith("baseline_luma_"))}
                    if value["status"] == "measured":
                        response_delta = (trial_response["encodedLumaDelta255"]["mean"]
                                          - ref_response["encodedLumaDelta255"]["mean"])
                        value["responseDifference"] = {
                            "encodedLumaMean255": response_delta,
                            "linearYMean": trial_response["linearYDelta"]["mean"] - ref_response["linearYDelta"]["mean"],
                            "baselineEncodedLumaMeanDifference255": value["encodedLumaDelta255"]["mean"] - response_delta,
                        }
                    report["sameEditMeasurements"].append(value)
        print(f"Measured {identifier}", flush=True)
    write_json(output / "measurements.json", report)
    write_json(output / "same-edit-comparisons.json", {
        "schemaVersion": 1, "method": report["sameEditMethod"],
        "pairs": report["sameEditPairs"], "measurements": report["sameEditMeasurements"]})
    with (output / "same-edit-comparisons.csv").open("w", newline="") as stream:
        columns = ["frame", "referenceProfile", "profile", "variant", "selection", "pixels",
                   "sameEditMeanLumaDifference255", "responseMeanLumaDifference255",
                   "baselineMeanLumaDifference255", "medianRelativeChromaCLPercent",
                   "p95AbsoluteHueDegrees"]
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        for row in report["sameEditMeasurements"]:
            if row["status"] != "measured":
                continue
            color = row["color"]
            writer.writerow({**{k: row[k] for k in columns[:5]}, "pixels": row["pixelCount"],
                "sameEditMeanLumaDifference255": row["encodedLumaDelta255"]["mean"],
                "responseMeanLumaDifference255": row["responseDifference"]["encodedLumaMean255"],
                "baselineMeanLumaDifference255": row["responseDifference"]["baselineEncodedLumaMeanDifference255"],
                "medianRelativeChromaCLPercent": color["relativeChromaCLChangePercent"]["median"]
                    if color["relativeChromaCLChangePercent"] else None,
                "p95AbsoluteHueDegrees": color["absoluteHueDeltaDegrees"]["p95"]
                    if color["absoluteHueDeltaDegrees"] else None})
    with (output / "measurements.csv").open("w", newline="") as stream:
        columns = ["frame", "profile", "variant", "selection", "pixels", "meanLumaDelta255",
                   "medianYChangeEV", "medianRelativeChromaCLPercent", "p95AbsoluteHueDegrees",
                   "meanMatchedYRayDistanceOKLab100", "huePixels", "fineLocalContrastRatio",
                   "coarseLocalContrastRatio"]
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        for row in report["measurements"]:
            if row["status"] != "measured":
                continue
            color = row["color"]
            get = lambda field, key: field[key] if field else None
            writer.writerow({**{k: row[k] for k in columns[:4]}, "pixels": row["pixelCount"],
                "meanLumaDelta255": row["encodedLumaDelta255"]["mean"],
                "medianYChangeEV": row["medianLinearYChangeEV"],
                "medianRelativeChromaCLPercent": get(color["relativeChromaCLChangePercent"], "median"),
                "p95AbsoluteHueDegrees": get(color["absoluteHueDeltaDegrees"], "p95"),
                "meanMatchedYRayDistanceOKLab100": get(color["matchedYColorRayDistanceOKLab100"], "mean"),
                "huePixels": color["huePixelCount"],
                "fineLocalContrastRatio": row["detailBandpass"]["fine"]["ratio"],
                "coarseLocalContrastRatio": row["detailBandpass"]["coarse"]["ratio"]})
    return report, native


def contact_sheet(output, spec, native):
    requested = ["baseline", "shadows_p0_25", "highlights_m0_25", "lift_protect",
                 "open_shadows", "compress_range", "contrast_recover"]
    profile = spec["profiles"][0]["name"]
    index = {(r["frame"], r["profile"], r["variant"]): r for r in native["renders"]}
    selected = [v for v in requested if all((f["id"], profile, v) in index for f in spec["frames"])]
    labels = {v["id"]: v["label"] for v in spec["variants"]}
    width, height = 255, 210
    sheet = Image.new("RGB", (len(selected) * width, len(spec["frames"]) * height), "#17191d")
    draw = ImageDraw.Draw(sheet)
    for y, frame in enumerate(spec["frames"]):
        for x, variant in enumerate(selected):
            row = index.get((frame["id"], profile, variant))
            if row:
                image = Image.fromarray(np.rint(read_render(output / row["render"]) * 255).astype(np.uint8))
                image.thumbnail((width - 10, height - 42), Image.Resampling.LANCZOS)
                sheet.paste(image, (x * width + 5, y * height + 22))
            draw.text((x * width + 5, y * height + 3), frame["id"], fill="#eeeeee")
            draw.text((x * width + 5, y * height + height - 18), labels[variant], fill="#dddddd")
    sheet.save(output / "contact-sheet.jpg", quality=93)


def make_gallery(output, report, native):
    signal = json.loads((output / "signal-response.json").read_text())
    preferences = json.loads((output / "preference-checks.json").read_text())
    data = {"report": report, "native": native, "signal": signal, "preferences": preferences}
    payload = json.dumps(data, allow_nan=False, separators=(",", ":")).replace("<", "\\u003c")
    method = "".join(f"<dt>{html.escape(key)}</dt><dd>{html.escape(value)}</dd>"
                     for key, value in METHOD.items())
    document = """<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FSC photographic control response</title>
<style>
body{font:15px system-ui;background:#16191d;color:#eef1f5;margin:24px}h1{font-size:28px}p{max-width:105ch;line-height:1.5;color:#c8d0db}a{color:#8fcaff}select,button{background:#252c35;color:#eef1f5;padding:7px;border:1px solid #667080;border-radius:5px}label{display:inline-block;margin:4px 12px 10px 0}figure{margin:0}figcaption{padding:8px 0}.pair{display:grid;grid-template-columns:1fr 1fr;gap:14px}img{display:block;width:100%}.pair img{background:#080a0c}table{width:100%;border-collapse:collapse;font-size:12px}td,th{padding:7px;text-align:right;border-bottom:1px solid #343a43}td:first-child,th:first-child{text-align:left}thead{background:#252b34}.scroll{overflow:auto}.hint{font-size:13px;color:#aebacc}summary{cursor:pointer;padding:12px 0}dt{margin-top:10px;font-weight:650}dd{margin-left:0;color:#c1cbd8;line-height:1.45}.overlay{max-width:1100px}.card{background:#222933;padding:12px;border-radius:8px;margin:14px 0}code{font-size:12px}#params{white-space:pre-wrap}.contact{max-width:1800px}@media(max-width:800px){.pair{grid-template-columns:1fr}body{margin:12px}}
</style>
<h1>Photographic control response</h1>
<p>Fresh production Swift renders at ordinary slider increments. Choose a photograph and a control move, then inspect the whole image and individual material samples. The measurements describe display-output behavior; they do not score how a photograph should look.</p>
<p><a href="measurements.csv">Measurements CSV</a> · <a href="measurements.json">Complete metrics and definitions</a> · <a href="study.json">Exact study specification</a> · <a href="renders.json">Render and Metal results</a> · <a href="signal-response.json">Floating over-white signal probe</a> · <a href="manifest.json">Provenance</a></p>
<label>Photograph <select id="frame"></select></label><label>Context <select id="profile"></select></label><label>Control move <select id="variant"></select></label>
<p id="description"></p><div class="pair"><figure><a id="baseLink"><img id="base" alt="Production baseline render"></a><figcaption>Context baseline</figcaption></figure><figure><a id="editLink"><img id="edit" alt="Production edited render"></a><figcaption id="editLabel"></figcaption></figure></div>
<div class="card"><div id="params"></div><p class="hint" id="parity"></p></div>
<p class="hint">Changes are relative to this context’s baseline. C/L is relative chroma; hue excludes unreliable near-neutrals. Fine/coarse ratios describe bandpass luma contrast including grain and edges, not recovered texture. “—” means insufficient eligible samples or baseline signal; consult JSON for every exclusion count.</p>
<div class="scroll"><table><thead><tr><th>Fixed sample</th><th>Pixels</th><th>Mean Δ luma /255</th><th>Median Δ linear Y EV</th><th>Median Δ C/L %</th><th>p95 |Δ hue| °</th><th>Hue pixels</th><th>Mean matched-Y ray distance ×100</th><th>Fine contrast ratio</th><th>Coarse contrast ratio</th></tr></thead><tbody id="metrics"></tbody></table></div>
<details id="sameedit" open><summary>Same edit: current tone controls versus the explicit trial</summary>
<p>These pairs use identical complete serialized parameters except the tone schema. Clean Invert already contains Highlights −.08 and Shadows +.04, so even its baseline can look different under the trial. The table separates the actual same-edit difference from the control-response difference after subtracting that baseline offset. No trial is selected as a new default.</p>
<p><a href="same-edit-comparisons.json">Complete same-edit measurements</a> · <a href="same-edit-comparisons.csv">Same-edit CSV</a></p>
<label>Pair <select id="samePair"></select></label><label>Identical control move <select id="sameVariant"></select></label>
<div class="pair"><figure><a id="sameReferenceLink"><img id="sameReference" alt="Current tone schema at the same edit"></a><figcaption id="sameReferenceLabel"></figcaption></figure><figure><a id="sameCandidateLink"><img id="sameCandidate" alt="Explicit trial tone schema at the same edit"></a><figcaption id="sameCandidateLabel"></figcaption></figure></div>
<p id="sameDocuments"></p><div class="scroll"><table><thead><tr><th>Fixed sample</th><th>Pixels</th><th>Actual mean Δ luma /255</th><th>Baseline mean offset /255</th><th>Response difference /255</th><th>Median Δ C/L %</th><th>p95 |Δ hue| °</th><th>Hue pixels</th></tr></thead><tbody id="sameMetrics"></tbody></table></div></details>
<details><summary id="preferencesTitle">Fresh frozen-preference checks</summary><p>The original ledger parameters are decoded by production Swift, supplied their historical archived medians, and rendered again. PNG hashes must match every checkpoint or the run fails. Neither old outputs nor the preference ledger are rewritten.</p><p><a href="preference-checks.json">Fresh preference checks and exact hashes</a></p><ul id="preferencesList"></ul></details>
<details open><summary>Exact measured rectangles and frozen baseline tonal cohorts</summary><p id="maskInfo" class="hint"></p><img id="overlay" class="overlay" alt="Exact fixed material sample rectangles"></details>
<details><summary>Methods, exclusions and scope</summary><dl>METHOD</dl><p>All configured photographs are required. Missing inputs, invalid regions, incomplete renders and requested Metal failures stop the run. Named contexts using a different schema are explicit authored comparisons, not claims that identical numbers have equivalent intent. No engine default or saved edit is changed.</p></details>
<details><summary>Production floating signal direction</summary><p id="signalInfo"></p><div class="scroll"><table><thead><tr><th>Linear input Y</th><th>EV before</th><th>EV after</th><th>Output before</th><th>Output after</th><th>Δ output</th></tr></thead><tbody id="signalRows"></tbody></table></div></details>
<details><summary>Six-frame contact sheet</summary><a href="contact-sheet.jpg"><img class="contact" src="contact-sheet.jpg" alt="Contact sheet of ordinary edits on the full cohort"></a></details>
<script>
const data=PAYLOAD;const report=data.report, native=data.native;
const el=id=>document.getElementById(id), fmt=(v,n=3)=>v==null?'—':Number(v).toFixed(n);
function options(id,rows){el(id).replaceChildren(...rows.map(([value,text])=>{const o=document.createElement('option');o.value=value;o.textContent=text;return o;}));}
options('frame',report.frames.map(f=>[f.id,f.id]));options('profile',report.profiles.map(p=>[p.name,p.name]));
function chooseVariants(){const old=el('variant').value,p=report.profiles.find(p=>p.name===el('profile').value);options('variant',report.variants.filter(v=>!p.variantIDs||p.variantIDs.includes(v.id)).map(v=>[v.id,v.label]));const values=[...el('variant').options].map(o=>o.value);el('variant').value=values.includes(old)?old:values.includes('exposureEV_p0_5')?'exposureEV_p0_5':values[0];update();}
function update(){const frame=report.frames.find(f=>f.id===el('frame').value),profile=el('profile').value,variant=el('variant').value;
const row=(v)=>native.renders.find(r=>r.frame===frame.id&&r.profile===profile&&r.variant===v),b=row('baseline'),e=row(variant);
el('description').textContent=frame.description;el('base').src=b.render;el('baseLink').href=b.render;el('edit').src=e.render;el('editLink').href=e.render;el('editLabel').textContent=report.variants.find(v=>v.id===variant).label;
el('params').replaceChildren();const a=document.createElement('a');a.href=e.parameters;a.textContent='Exact edited parameters';const bb=document.createElement('a');bb.href=b.parameters;bb.textContent='Baseline parameters';el('params').append(a,' · ',bb,' · Deltas: '+JSON.stringify(report.variants.find(v=>v.id===variant).deltas));if(e.correctionDocument){const d=document.createElement('a');d.href=e.correctionDocument;d.textContent='Schema-2 correction document';el('params').append(' · ',d);}
el('parity').textContent=e.metalComparison?'Same-input CPU/Metal display comparison: maximum '+e.metalComparison.maxRGBDifference255+'/255, mean '+fmt(e.metalComparison.meanRGBDifference255,5)+'/255.':'Metal comparison: '+e.metalStatus+'.';
const rows=report.measurements.filter(r=>r.frame===frame.id&&r.profile===profile&&r.variant===variant);el('metrics').replaceChildren(...rows.map(r=>{const tr=document.createElement('tr');const c=r.color;const vals=r.status==='measured'?[r.selection,r.pixelCount,fmt(r.encodedLumaDelta255.mean),fmt(r.medianLinearYChangeEV),fmt(c.relativeChromaCLChangePercent?.median),fmt(c.absoluteHueDeltaDegrees?.p95),c.huePixelCount,fmt(c.matchedYColorRayDistanceOKLab100?.mean),fmt(r.detailBandpass.fine.ratio),fmt(r.detailBandpass.coarse.ratio)]:[r.selection,0,'—','—','—','—',0,'—','—','—'];for(const v of vals){const td=document.createElement('td');td.textContent=v;tr.append(td);}return tr;}));
el('overlay').src=frame.regionOverlay;el('maskInfo').textContent='All tonal memberships frozen from '+frame.maskReferenceProfile+' baseline. Encoded luma quintile boundaries: '+frame.encodedLumaQuintileBoundaries.map(x=>fmt(x,4)).join(', ')+'. Region labels identify sampled interiors, not complete semantic masks. Exact membership files: '+frame.id+'/fixed-masks.npz';updateSameEdit();}
function updateSameEdit(resetOptions=true){const pairs=report.sameEditPairs;el('sameedit').hidden=!pairs.length;if(!pairs.length)return;const priorPair=el('samePair').value;options('samePair',pairs.map(p=>[p.candidateProfile,p.referenceProfile+' → '+p.candidateProfile]));if(pairs.some(p=>p.candidateProfile===priorPair))el('samePair').value=priorPair;const pair=pairs.find(p=>p.candidateProfile===el('samePair').value),frame=el('frame').value;
if(resetOptions){const old=el('sameVariant').value,available=report.variants.filter(v=>[pair.referenceProfile,pair.candidateProfile].every(p=>native.renders.some(r=>r.frame===frame&&r.profile===p&&r.variant===v.id)));options('sameVariant',available.map(v=>[v.id,v.label]));const ids=available.map(v=>v.id);el('sameVariant').value=ids.includes(old)?old:ids.includes('shadows_p0_25')?'shadows_p0_25':ids[0];}
const variant=el('sameVariant').value,row=p=>native.renders.find(r=>r.frame===frame&&r.profile===p&&r.variant===variant),reference=row(pair.referenceProfile),candidate=row(pair.candidateProfile);for(const [prefix,r,label] of [['sameReference',reference,pair.referenceProfile],['sameCandidate',candidate,pair.candidateProfile]]){el(prefix).src=r.render;el(prefix+'Link').href=r.render;el(prefix+'Label').textContent=label+' · '+report.variants.find(v=>v.id===variant).label;}
el('sameDocuments').replaceChildren();for(const [label,r] of [['Current',reference],['Trial',candidate]]){const a=document.createElement('a');a.href=r.parameters;a.textContent=label+' exact parameters';el('sameDocuments').append(a,' · ');if(r.correctionDocument){const d=document.createElement('a');d.href=r.correctionDocument;d.textContent=label+' correction document';el('sameDocuments').append(d,' · ');}}
el('sameMetrics').replaceChildren(...report.sameEditMeasurements.filter(r=>r.frame===frame&&r.profile===pair.candidateProfile&&r.variant===variant).map(r=>{const tr=document.createElement('tr'),c=r.color;const vals=r.status==='measured'?[r.selection,r.pixelCount,fmt(r.encodedLumaDelta255.mean),fmt(r.responseDifference.baselineEncodedLumaMeanDifference255),fmt(r.responseDifference.encodedLumaMean255),fmt(c.relativeChromaCLChangePercent?.median),fmt(c.absoluteHueDeltaDegrees?.p95),c.huePixelCount]:[r.selection,0,'—','—','—','—','—',0];for(const value of vals){const td=document.createElement('td');td.textContent=value;tr.append(td);}return tr;}));}
el('samePair').onchange=()=>updateSameEdit();el('sameVariant').onchange=()=>updateSameEdit(false);
el('frame').onchange=update;el('profile').onchange=chooseVariants;el('variant').onchange=update;chooseVariants();
el('preferencesTitle').textContent='Fresh frozen-preference checks: '+data.preferences.checks.filter(c=>c.match).length+'/'+data.preferences.checks.length+' exact PNG matches';el('preferencesList').replaceChildren(...data.preferences.checks.map(c=>{const li=document.createElement('li'),a=document.createElement('a');a.href=c.render;a.textContent=c.frame+' / '+c.variant+' — '+(c.match?'exact match':'MISMATCH');li.append(a);return li;}));
el('signalInfo').textContent=data.signal.scope+' The production floating probe found '+data.signal.positiveExposureDecreaseCases.length+' sampled positive-exposure steps that reduce output. These signal cases are reported independently of photographic scores.';
el('signalRows').replaceChildren(...data.signal.positiveExposureDecreaseCases.map(r=>{const tr=document.createElement('tr');for(const key of ['inputLinearY','fromEV','toEV','fromLinearY','toLinearY','deltaLinearY']){const td=document.createElement('td');td.textContent=fmt(r[key],7);tr.append(td);}return tr;}));
</script></html>"""
    (output / "index.html").write_text(document.replace("METHOD", method).replace("PAYLOAD", payload))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Fresh directory inside ignored dist/")
    parser.add_argument("--archive", type=Path, default=ROOT / "dist/camera-raw-study")
    parser.add_argument("--cohort", type=Path, default=HERE / "tone-response-cohort.json")
    parser.add_argument("--profiles", type=Path, help="Optional named schema/photoOverrides contexts JSON array")
    parser.add_argument("--metal", action="store_true", help="Require every same-input CPU/Metal comparison <=2/255")
    parser.add_argument("--correction-documents", action="store_true",
                        help="Write schema-2 LookRecipe correction snapshots for review; never install them")
    parser.add_argument("--preflight-only", action="store_true", help="Read inputs/configuration and report counts; no build or output")
    args = parser.parse_args()
    output, archive, cohort_path = args.output.resolve(), args.archive.resolve(), args.cohort.resolve()
    if not output.is_relative_to(ROOT / "dist") or output == ROOT / "dist":
        parser.error("Output must be a new child directory inside ignored dist/")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("Choose a fresh output directory; old evidence is never overwritten")
    profiles = json.loads(args.profiles.read_text()) if args.profiles else default_profiles()
    cohort = json.loads(cohort_path.read_text())
    spec, inputs = prepare_spec(cohort, archive, profiles, args.metal, args.correction_documents)
    if args.preflight_only:
        count = sum(len(p["variantIDs"] or spec["variants"]) for p in profiles) * len(spec["frames"])
        print(json.dumps({"frames": [f["id"] for f in spec["frames"]], "renderCount": count,
                          "profiles": profiles, "metalRequired": args.metal,
                          "preferenceSnapshotCount": spec["preferenceSnapshotCount"],
                          "sameEditPairs": spec["sameEditPairs"],
                          "output": str(output), "buildStarted": False}, indent=2))
        return
    output.mkdir(parents=True, exist_ok=True)
    def source_paths():
        sources = [p for p in (ROOT / "native/FilmScanEngine/Sources").rglob("*") if p.is_file()]
        sources += [ROOT / "native/FilmScanEngine/Package.swift", HERE / "ToneResponseStudy.swift",
                    Path(__file__).resolve(), HERE / "tone_response_metrics.py", cohort_path]
        if args.profiles:
            sources.append(args.profiles.resolve())
        return set(sources)
    source_hashes, input_hashes = hashes(source_paths()), hashes(inputs)
    write_json(output / "study.json", spec)
    manifest = {
        "schemaVersion": 1, "status": "building", "startedAtUTC": datetime.now(timezone.utc).isoformat(),
        "revision": capture(["git", "rev-parse", "HEAD"]),
        "workingTree": capture(["git", "status", "--short"]),
        "platform": platform.platform(), "python": sys.version,
        "pythonPackages": {name: importlib.metadata.version(name) for name in ["numpy", "opencv-python", "Pillow"]},
        "swift": capture(["swift", "--version"]), "libraw": capture(["pkg-config", "--modversion", "libraw_r"]),
        "sources": source_hashes, "inputs": input_hashes,
        "studySHA256": sha256(output / "study.json"),
        "scope": METHOD["limits"], "commands": {}, "requestedMetal": args.metal,
    }
    write_json(output / "manifest.json", manifest)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH="/tmp/film-scan-clang-cache",
               SWIFTPM_MODULECACHE_OVERRIDE="/tmp/film-scan-swiftpm-cache")
    try:
        executable, objects = compile_probe(output, env, manifest["commands"])
        manifest["linkedObjects"] = hashes(objects)
        manifest["executableSHA256"] = sha256(executable)
        if (hashes(source_paths()) != source_hashes or hashes(inputs) != input_hashes
                or sha256(output / "study.json") != manifest["studySHA256"]):
            raise RuntimeError("Source/input changed during build; choose a fresh output and rerun")
        command = [str(executable), str(output / "study.json"), str(output)]
        manifest["commands"]["probeCommand"] = command
        manifest["status"] = "rendering"
        write_json(output / "manifest.json", manifest)
        with (output / "probe.log").open("w") as log:
            subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        manifest["status"] = "analyzing"
        write_json(output / "manifest.json", manifest)
        report, native = analyze(output, spec)
        contact_sheet(output, spec, native)
        make_gallery(output, report, native)
        if (hashes(source_paths()) != source_hashes or hashes(inputs) != input_hashes
                or sha256(output / "study.json") != manifest["studySHA256"]
                or hashes(objects) != manifest["linkedObjects"]
                or sha256(executable) != manifest["executableSHA256"]):
            raise RuntimeError("Source/input/object/executable changed during collection; choose a fresh output")
        manifest["nativeRenderCount"] = len(native["renders"])
        manifest["measurementRowCount"] = len(report["measurements"])
        manifest["sameEditMeasurementRowCount"] = len(report["sameEditMeasurements"])
        manifest["preferenceSnapshotCount"] = spec["preferenceSnapshotCount"]
        manifest["status"] = "completed"
    except Exception as error:
        manifest["status"] = "failed"
        manifest["error"] = str(error)
        raise
    finally:
        manifest["finishedAtUTC"] = datetime.now(timezone.utc).isoformat()
        manifest["outputs"] = {str(p.relative_to(output)): {"bytes": p.stat().st_size, "sha256": sha256(p)}
                               for p in sorted(output.rglob("*")) if p.is_file() and p.name != "manifest.json"}
        write_json(output / "manifest.json", manifest)
    print(output / "index.html")


if __name__ == "__main__":
    main()
