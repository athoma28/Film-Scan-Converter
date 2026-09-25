#!/usr/bin/env python3
"""Build a local, unpaired RAW reference review after FilmScanLookbook --lucky-study.

Requires the repository's rawpy, numpy, and Pillow environment. No registration,
pixel-error score, or assertion of measured scene color is made.
"""
import argparse
import colorsys
import html
import json
from pathlib import Path

import numpy as np
import rawpy
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("render_directory", type=Path)
parser.add_argument("--output", type=Path, default=ROOT / "dist/lucky200-reference-study")
args = parser.parse_args()
out = args.output
out.mkdir(parents=True, exist_ok=True)
references = ROOT / "sample-raw/luckyc200/tahoe test digital photos"
metadata = {}
for path in sorted(references.glob("*.RAF")):
    with rawpy.imread(str(path)) as raw:
        metadata[path.stem] = {"camera_white_balance": raw.camera_whitebalance}
        rgb = raw.postprocess(
            use_camera_wb=True, output_color=rawpy.ColorSpace.sRGB,
            gamma=(2.4, 12.92), output_bps=8, half_size=True,
        )
    im = Image.fromarray(rgb)
    im.thumbnail((1200, 1200))
    im.save(out / f"{path.stem}-reference.jpg", quality=96)

# Rebate cropping and orientation are presentation-only, identical for both recipes.
rows = [
    ("DSCF3790", (55, 75, 1090, 765), 0, "DSCF3500", "Shaded road and mixed foliage"),
    ("DSCF3799", (20, 65, 1050, 765), 270, "DSCF3560", "Pine, lake, and backlight"),
    ("DSCF3802", (15, 80, 1048, 770), 0, "DSCF3550", "Sunlit path, sage, and granite"),
    ("DSCF3811", (10, 80, 1045, 772), 90, "DSCF3515", "Shoreline foliage and granite; skin check"),
    ("DSCF3816 copy 2", (40, 70, 1073, 750), 0, "DSCF3444", "Shoreline shrubs and distant mountains"),
]
body = []
for stem, crop, rotation, ref, label in rows:
    files = []
    for recipe in ("cleanInvert", "foliage"):
        im = Image.open(args.render_directory / f"{stem}-{recipe}.jpg")
        im = im.crop(crop).rotate(rotation, expand=True)
        name = f"{stem}-{recipe}.jpg"
        im.save(out / name, quality=96)
        files.append(name)
    files.append(f"{ref}-reference.jpg")
    images = ''.join(f'<td><a href="{html.escape(f)}"><img src="{html.escape(f)}"></a></td>' for f in files)
    body.append(f'<tr><th>{html.escape(stem)}<br><small>{label}</small></th>{images}</tr>')

# Descriptive patch statistics only: these are unpaired materials in different scenes.
patches = [
    ("DSCF3790", 0, "foliage", (340, 120, 520, 320)),
    ("DSCF3802", 0, "sage", (810, 420, 930, 500)),
    ("DSCF3802", 0, "sun pavement", (475, 620, 600, 710)),
    ("DSCF3811", 90, "shrubs", (592, 757, 720, 891)),
    ("DSCF3811", 90, "skin", (376, 743, 443, 807)),
    ("DSCF3811", 90, "sun granite", (228, 708, 347, 750)),
    ("DSCF3816 copy 2", 0, "foreground shrubs", (560, 640, 700, 720)),
]
report = {"scope": "Unpaired qualitative tuning; all five scans were inspected during iteration. No independent held-out accuracy claim.",
          "reference_decode": "LibRaw/rawpy, camera WB, sRGB, sRGB transfer, auto brightness, half-size; no film simulation or per-channel edit",
          "rawpy_version": rawpy.__version__, "references": metadata, "patches": []}
for stem, rotation, label, box in patches:
    entry = {"scan": stem, "material": label, "rotation_ccw": rotation, "box_pixels_before_rebate_crop": box}
    for recipe in ("cleanInvert", "foliage"):
        im = Image.open(args.render_directory / f"{stem}-{recipe}.jpg").rotate(rotation, expand=True)
        rgb = np.asarray(im.crop(box), dtype=float).reshape(-1, 3) / 255
        hsv = np.array([colorsys.rgb_to_hsv(*p) for p in rgb])
        useful = (hsv[:, 1] > .15) & (hsv[:, 2] > .12)
        entry[recipe] = {"median_rgb": np.median(rgb, axis=0).round(4).tolist(),
                         "median_saturation": round(float(np.median(hsv[:, 1])), 4),
                         "median_chromatic_hue_degrees": round(float(np.median(hsv[useful, 0]) * 360), 2) if useful.any() else None}
    report["patches"].append(entry)
report["reference_materials"] = []
for stem, label, box in [
    ("DSCF3500", "broadleaf shrub", (60, 350, 145, 385)),
    ("DSCF3550", "pine", (686, 300, 789, 430)),
    ("DSCF3550", "sage", (1040, 475, 1180, 555)),
]:
    rgb = np.asarray(Image.open(out / f"{stem}-reference.jpg").crop(box), dtype=float).reshape(-1, 3) / 255
    hsv = np.array([colorsys.rgb_to_hsv(*p) for p in rgb])
    useful = (hsv[:, 1] > .15) & (hsv[:, 2] > .12)
    report["reference_materials"].append({
        "reference": stem, "material": label, "box_pixels": box,
        "median_chromatic_hue_degrees": round(float(np.median(hsv[useful, 0]) * 360), 2),
        "median_saturation": round(float(np.median(hsv[:, 1])), 4),
    })
(out / "patch-report.json").write_text(json.dumps(report, indent=2) + '\n')
(out / "index.html").write_text('''<!doctype html><meta charset="utf-8"><title>Foliage · Tahoe reference study</title>
<style>body{background:#151715;color:#e9e9e0;font:15px/1.5 system-ui;margin:30px}h1{font-size:25px}p{max-width:90ch;color:#bbc0b7}table{border-collapse:collapse}td,th{padding:12px;vertical-align:top;text-align:left}img{max-width:360px;max-height:480px}small{font-weight:400}thead{position:sticky;top:0;background:#151715}a{color:inherit}</style>
<h1>Foliage — Tahoe daylight</h1><p>Clean Invert and the new Foliage preset use the same scan and exposure. Digital RAF references show nearby settings, not identical scenes. Camera white balance and a standard sRGB RAW rendering provide color guidance; brightness, viewpoint, haze, and lighting differ. All five scans were inspected during tuning. This is a tuned roll/scan preset, not a measured emulsion calibration.</p>
<table><thead><tr><th>Scene</th><th>Clean Invert</th><th>Foliage</th><th>Nearby digital RAW reference</th></tr></thead><tbody>''' + ''.join(body) + '</tbody></table><p><a href="patch-report.json">Descriptive patch measurements and decode settings</a></p>')

# Compact shareable proof sheet: two landscape cases that exposed the initial failure.
sheet = Image.new("RGB", (1440, 1040), "#171a17")
draw = ImageDraw.Draw(sheet)
for row, stem in enumerate(("DSCF3802", "DSCF3816 copy 2")):
    for col, recipe in enumerate(("cleanInvert", "foliage")):
        im = Image.open(out / f"{stem}-{recipe}.jpg")
        im.thumbnail((704, 468))
        x, y = col * 720 + 8, row * 520 + 36
        sheet.paste(im, (x, y))
        draw.text((x, y - 24), f"{stem}  |  {'Clean Invert' if col == 0 else 'Foliage'}", fill="#eeeeea")
sheet.save(out / "before-after.jpg", quality=95)
print(out / "index.html")
print(json.dumps(report["patches"], indent=2))
