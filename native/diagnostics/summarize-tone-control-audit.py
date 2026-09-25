"""Plot production ramp samples and summarize inspected content regions; no new rendering."""

import argparse
import csv
import hashlib
import html
import json
import os
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", "/tmp/fsc-tone-audit-matplotlib")
import cv2
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
args = parser.parse_args()
output = args.output.resolve()

# Pixel rectangles chosen by inspecting the sensor-oriented 900px source renders.
# They exclude film edges, sprockets and the holder; no fitting or ACR registration.
regions = {
    "fuji400-fresh/DSCF2833": [160, 125, 720, 488],
    "proimage/DSCF5800": [50, 64, 804, 560],
    "harmanphoenixii/DSCF3079": [95, 90, 775, 526],
}
names = ["contrast_-1.0", "contrast_-0.5", "neutral", "contrast_0.5", "contrast_1.0",
         "brightness_-1.0", "brightness_-0.5", "neutral", "brightness_0.5", "brightness_1.0",
         "exposure_-2.0", "exposure_-1.0", "neutral", "exposure_1.0", "exposure_2.0"]
measurements = []
png_hashes = {}
for frame, (x0, y0, x1, y1) in regions.items():
    for path in sorted((output / frame).glob("*.png")):
        pixels = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
        assert pixels is not None and pixels.dtype == np.uint16 and pixels.shape[2] == 3
        content = pixels[y0:y1, x0:x1, :]
        floating = content.astype(np.float64)
        luma = (.0722 * floating[..., 0] + .7152 * floating[..., 1]
                + .2126 * floating[..., 2]) / 257
        assert np.isfinite(luma).all()
        measurements.append({
            "frame": frame, "variant": path.stem, "regionPixelsXYXY": [x0, y0, x1, y1],
            "blackChannelPercent": float(100 * np.mean(content == 0)),
            "nearWhiteChannelPercent": float(100 * np.mean(content >= 65534)),
            "encodedLuma255Quantiles": np.quantile(luma, [0, .01, .5, .99, 1]).tolist(),
        })
        png_hashes[str(path.relative_to(output))] = hashlib.sha256(path.read_bytes()).hexdigest()
(output / "content-metrics.json").write_text(json.dumps({
    "note": "Absolute same-pixel measurements, per-channel endpoint occupancy, not perceptual scores. Black = 0; near-white >= 65534 accommodates CPU truncation. Regions exclude inspected borders. The earlier photographs.json 10% inset includes holder on some frames and is not used for subject claims.",
    "regions": regions, "measurements": measurements, "renderedPNG_SHA256": png_hashes,
    "analysisScriptSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
}, indent=2) + "\n")

ramps = {}
with (output / "ramps.csv").open() as stream:
    for row in csv.DictReader(stream):
        ramps.setdefault(row["variant"], []).append([float(row["input255"]), float(row["output255"])])
fig, axes = plt.subplots(2, 2, figsize=(10, 8), layout="constrained")
fig.suptitle("FSC tone controls: measured production output", fontsize=17)
groups = [
    ("Brightness", ["brightness_-0.5", "neutral", "brightness_0.5"]),
    ("Contrast", ["contrast_-1.0", "neutral", "contrast_1.0"]),
    ("Exposure", ["exposure_-1.0", "neutral", "exposure_1.0"]),
    ("Highlights", ["neutral", "highlights_1.0"]),
]
for ax, (title, variants) in zip(axes.flat, groups):
    for name in variants:
        values = np.array(ramps[name])
        ax.plot(values[:, 0], values[:, 1], label=name.replace("_", " "),
                color="#9b9b9b" if name == "neutral" else None,
                linestyle="--" if name == "neutral" else "-", linewidth=2)
    ax.set(title=title, xlim=(0, 255), ylim=(0, 255), xlabel="Input gray (0–255)", ylabel="Output gray (0–255)")
    ax.set_xticks([0, 64, 128, 192, 255])
    ax.set_yticks([0, 64, 128, 192, 255])
    ax.grid(alpha=.2)
    ax.legend(fontsize=9, loc="upper left")
fig.savefig(output / "tone-curves.png", dpi=160)
fig.savefig(output / "tone-curves.svg")
plt.close(fig)

parts = ["""<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FSC tone-control audit · September 22</title>
<style>body{background:#17191c;color:#edeff2;font:15px system-ui;margin:24px}p{max-width:95ch;color:#bfc6cf}h2{margin-top:38px}a{color:#91c9ff}.row{display:grid;grid-template-columns:repeat(5,minmax(240px,1fr));gap:12px;min-width:1250px}.scroll{overflow:auto}figure{margin:0 0 18px}img{width:100%;display:block}figcaption{padding:8px 0;color:#d4dbe4;font-size:13px}small{display:block}.measured{position:relative}.roi{position:absolute;border:2px solid #ffdc69;box-sizing:border-box;pointer-events:none}.plot{max-width:1050px}</style>
<h1>Tone-control audit</h1><p>Fresh production CPU renders of three archived 900px scan inputs. Each frame uses its explicit current film base + Clean Invert. Values are semantic slider values. “Baseline” keeps Clean Invert's small highlight/shadow/color adjustments. No preset fitting, automatic classification, ACR scoring, or full-resolution export claim.</p>
<p>Charts isolate the tone operators on a 65,536-step grayscale ramp in the Slide path, with other controls neutral. Gray axes are display-encoded values. Photographs remain in sensor orientation. Yellow rectangles mark measured content; sprockets and holder are excluded.</p>
<p><a href="content-metrics.json">Content metrics</a> · <a href="ramps.json">Ramp metrics</a> · <a href="performance.json">Render timings</a> · <a href="manifest.json">Provenance</a></p>
<img class="plot" src="tone-curves.png" alt="Measured brightness, contrast, exposure, and highlights transfer curves">"""]
index = {(r["frame"], r["variant"]): r for r in measurements}
for frame, (x0, y0, x1, y1) in regions.items():
    baseline = cv2.imread(str(output / frame / "neutral.png"), cv2.IMREAD_UNCHANGED)
    height, width = baseline.shape[:2]
    parts.append(f"<h2>{html.escape(frame)}</h2><div class='scroll'>")
    for start in [0, 5, 10]:
        parts.append("<div class='row'>")
        for name in names[start:start+5]:
            r = index[frame, name]
            label = "Baseline" if name == "neutral" else name.replace("_", " ")
            url = html.escape(f"{frame}/{name}.png", quote=True)
            parts.append(f"<figure><a class='measured' style='display:block' href='{url}'><img src='{url}' alt='{label}'><span class='roi' style='left:{x0/width*100}%;top:{y0/height*100}%;width:{(x1-x0)/width*100}%;height:{(y1-y0)/height*100}%'></span></a><figcaption>{label}<small>Black channels: {r['blackChannelPercent']:.2f}% · near-white: {r['nearWhiteChannelPercent']:.2f}%</small></figcaption></figure>")
        parts.append("</div>")
    parts.append("</div>")
parts.append("</html>")
(output / "index.html").write_text("\n".join(parts))
for r in measurements:
    if r["variant"] in ["neutral", "brightness_-0.5", "contrast_0.5", "exposure_1.0", "contrast_-1.0"]:
        print(r["frame"], r["variant"], "black=", round(r["blackChannelPercent"], 2),
              "near-white=", round(r["nearWhiteChannelPercent"], 2),
              "p99=", round(r["encodedLuma255Quantiles"][3], 1))
print(output / "index.html")
