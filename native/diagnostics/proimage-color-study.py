#!/usr/bin/env python3
"""Follow up the paired study using user preferences and Pro Image color separation.

Requires the paired study's registered scans and fitted curves. All renderings,
including public-control trials, use the production Swift engine. This is a
within-frame reachability experiment, not a new automatic or stock profile.
"""
import argparse
import hashlib
import html
import importlib.util
import json
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw

SPEC = importlib.util.spec_from_file_location('paired', Path(__file__).with_name('paired-reference-study.py'))
paired = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(paired)
ROOT = paired.ROOT
PATCHES = {
    'DSCF5800': {'knee': [150, 210, 240, 310], 'shoulder': [532, 402, 572, 460],
                 'water': [140, 75, 260, 130], 'greenery': [690, 170, 770, 300],
                 'shorts': [98, 395, 170, 495]},
    'DSCF5809': {'leg': [220, 350, 260, 420], 'shirt': [442, 359, 503, 403],
                 'tree': [630, 100, 695, 180], 'foliage': [745, 230, 790, 285]},
}


def load(path):
    return json.loads(path.read_text())


def choices(out):
    return load(out / 'proimage-choices.json')


def frames(out):
    return [f for f in load(out / 'results.json')['frames'] if f['stock'] == 'proimage']


def color_masks(directory):
    target = np.load(directory / 'target.npy')
    h, w = target.shape[:2]
    reference = cv2.imread(str(directory / 'reference.png'))
    matrix = np.array(load(directory / 'alignment.json')['sourceToTarget'])
    valid = cv2.warpPerspective(np.ones(reference.shape[:2], np.uint8),
                               np.linalg.inv(matrix), (w, h)) > 0
    yy, xx = np.indices((h, w))
    # Visually checked content region for these two frames. Include the water,
    # shorts and outer foliage missed by the original conservative central mask.
    content = valid & (xx > w*.05) & (xx < w*.90) & (yy > h*.10) & (yy < h*.93)
    train = content & ((xx//32 + 2*(yy//32)) % 4 != 0)
    return target, train, content & ~train, content


def fit(out):
    jobs = []
    for f in frames(out):
        d = Path(f['directory'])
        target, train, _, content = color_masks(d)
        np.round(target*65535).astype('<u2').tofile(d / 'target.bgr16')
        train.astype(np.uint8).tofile(d / 'color-train-mask.u8')
        cv2.imwrite(str(d / 'color-mask.png'), content.astype(np.uint8)*255)
        starts = [('cleanInvert-curves' if f['stem'] == 'DSCF5800' else 'basic-curves', 'color-separation')]
        if f['stem'] == 'DSCF5809':
            starts.append(('cleanInvert-curves', 'color-balanced'))
        for base, name in starts:
            jobs.append(dict(directory=str(d), name=name, parameters=load(d / (base+'.json')),
                             refineColor=True))
    paired.invoke(out, 'proimage-color-jobs', jobs)
    selected = {}
    for frame in frames(out):
        directory = Path(frame['directory'])
        candidates = [job['name'] for job in jobs if job['directory'] == str(directory)]
        selected[frame['stem']] = min(candidates, key=lambda name: load(directory / (name+'-fit.json'))['finalTrainingObjective'])
    paired.save(out / 'proimage-choices.json', selected)
    # Transfer only the public cast/separation controls: the receiving frame keeps its own
    # target-fitted curves. This is NOT a held-out-photo validation of the recipe.
    d = out / 'proimage/DSCF5809'
    p = load(d / 'cleanInvert-curves.json')
    donor = load(out / 'proimage/DSCF5800/color-separation.json')
    for key in ['densityCastRemovalStrength', 'densityUnmixStrength']:
        p['filmNegativeParams'][key] = donor['filmNegativeParams'][key]
    paired.invoke(out, 'proimage-color-transfer-jobs',
                  [dict(directory=str(d), name='color-from-5800', parameters=p)])


def appearance(image, mask):
    lab = cv2.cvtColor(cv2.GaussianBlur(image, (0, 0), 1.2), cv2.COLOR_BGR2LAB)
    chroma = np.linalg.norm(lab[:, :, 1:], axis=2)
    raw_luma = cv2.cvtColor(image, cv2.COLOR_BGR2LAB)[:, :, 0]
    structure = cv2.GaussianBlur(raw_luma, (0, 0), 2) - cv2.GaussianBlur(raw_luma, (0, 0), 12)
    fine = raw_luma - cv2.GaussianBlur(raw_luma, (0, 0), 1.2)
    return dict(lightnessQuantiles=np.percentile(lab[:, :, 0][mask], [1, 10, 25, 50, 75, 90, 99]).tolist(),
                chromaP90=float(np.percentile(chroma[mask], 90)),
                structureRMS=float(np.sqrt(np.mean(structure[mask]**2))),
                fineResidualRMS=float(np.sqrt(np.mean(fine[mask]**2))))


def report(out):
    rows = []
    for f in frames(out):
        d = Path(f['directory'])
        target, train, test, content = color_masks(d)
        central_test = paired.samples(f)[2]
        variants = ['aligned-reference', 'cleanInvert-curves', 'basic-curves', 'color-separation']
        if f['stem'] == 'DSCF5809':
            variants += ['color-balanced', 'color-from-5800']
        row = dict(frame=f['stem'], displayedTrial=choices(out)[f['stem']], variants={})
        for name in variants:
            a = target if name == 'aligned-reference' else paired.read16(d, name)
            lab = cv2.cvtColor(cv2.GaussianBlur(a, (0, 0), 1.2), cv2.COLOR_BGR2LAB)
            patches = {}
            for patch, (x0, y0, x1, y1) in PATCHES[f['stem']].items():
                region = lab[y0:y1, x0:x1]
                patches[patch] = dict(medianLab=np.median(region, axis=(0, 1)).tolist(),
                                     medianChroma=float(np.median(np.linalg.norm(region[:, :, 1:], axis=2))))
            row['variants'][name] = dict(centralTest=paired.error(a, target, central_test),
                expandedTrain=paired.error(a, target, train), expandedTest=paired.error(a, target, test),
                centralAppearance=appearance(a, paired.samples(f)[3]), patches=patches)
            if name != 'aligned-reference':
                paired.save(d / (name+'.corrections.json'),
                            paired.correction_document(d, name))
        rows.append(row)
    checkpoints = load(ROOT / 'docs/development/color-preference-checkpoints.json')
    assert len(paired.check_preferences(out)) == 5
    paired.save(out / 'proimage-color-results.json', dict(
        interpretation='Exploratory per-frame trials. Spatial tiles are not independent photos. Lab values are descriptive, not colorimetric accuracy.',
        patchCoordinates=PATCHES, preferenceCheckpointsUnchanged=True, frames=rows))
    gallery(out, checkpoints)
    paired.write_gallery(out, load(out / 'results.json')['frames'])
    for row in rows:
        print(row['frame'], {n: round(v['centralTest']['chromaMAE'], 5) for n, v in row['variants'].items()})


def gallery(out, checkpoints):
    text = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pro Image — color follow-up</title><style>
body{background:#151719;color:#eee;font:16px system-ui;margin:32px;line-height:1.5}h1{font-size:28px}h2{margin-top:42px}p{max-width:85ch;color:#bbc0c7}a{color:#b3d3ff}.grid{display:grid;grid-template-columns:repeat(3,minmax(280px,1fr));gap:16px;overflow:auto}.card img{display:block;width:100%;height:auto}.card p{font-size:14px}.card b{display:block;margin:10px 0}button,select{padding:8px;background:#303841;border:1px solid #657080;color:white;border-radius:5px;cursor:pointer}textarea{width:95%;height:100px}label{margin-right:16px}.compare{max-width:1200px}.compare img{width:100%;display:block;margin-top:12px}.note{border-left:3px solid #a0c3af;padding-left:18px}summary{cursor:pointer;color:#b3d3ff}</style>
<h1>Pro Image: restoring color separation</h1>
<p class="note">Your Fuji and Phoenix favorites are part of the target. The aim is to make FSC easier to steer while preserving the looks you already enjoy.</p>
<p>These are new trials using FSC’s existing controls. Compare the water, blue fabric, foliage and skin. The previous curve fits already had similar overall brightness and contrast; some colors were still weaker or shifted.</p>
<p>Choose a view below to compare at the same size, or use the three-column overview. The refined settings are specific to each frame. To try one, open its RAF in FSC, copy the corrections, then use <b>Paste Corrections</b>. Select Color C-41 first; framing and calibration are preserved. The app parser verifies each public recipe against its scored render.</p>
<p><a href="index.html">All 40 comparisons</a></p>'''
    if (out / 'skin-review.html').exists():
        text += '<p><a href="skin-review.html">New: segmented skin RGB analysis and red-curve refinements</a></p>'
    for stem, choice in choices(out).items():
        d = out / 'proimage' / stem
        text += f'<h2>Pro Image / {stem}</h2>'
        text += '<p>Refined with public color controls and small grading adjustments, retaining the previous channel curves.</p>'
        columns = [('aligned-reference', 'Camera Raw reference'), ('cleanInvert-curves', 'Clean Invert + curves'),
                   (choice, 'FSC color refinement')]
        text += '<div class="grid">'
        for name, label in columns:
            rel = Path('proimage') / stem
            url = str(rel / (name+'.png'))
            text += f'<div class="card"><b>{html.escape(label)}</b><a href="{url}"><img src="{url}" alt="{label} for {stem}"></a>'
            if name != 'aligned-reference':
                token = stem+'-'+name
                settings = load(d / (name+'.corrections.json'))
                text += f'<p><button onclick="copyRecipe(this,\'{token}\')">Copy FSC corrections</button> <a href="{rel}/{name}.corrections.json">JSON</a></p>'
                text += f'<textarea hidden id="{token}">{html.escape(json.dumps(settings))}</textarea>'
            if name == choice and (d / 'FSC-color-refined-full.jpg').exists():
                text += f'<p><a href="{rel}/FSC-color-refined-full.jpg">Full-resolution FSC JPEG</a></p>'
            text += '</div>'
        text += '</div><div class="compare">'
        text += f'<p><label>Large comparison <select onchange="document.getElementById(\'view-{stem}\').src=this.value">'
        for name, label in columns + [('basic-curves', 'Earlier best fitted recipe')]:
            text += f'<option value="proimage/{stem}/{name}.png">{html.escape(label)}</option>'
        text += f'</select></label></p><img id="view-{stem}" src="proimage/{stem}/aligned-reference.png" alt="Selected rendering of {stem}"></div>'
    text += '<h2>Looks to preserve</h2><p>Fuji DSCF3115 Automatic is an explicit favorite. For the two Phoenix frames, both Phoenix II choices are retained here because the feedback did not distinguish Natural from Darkroom. These historical settings were freshly rendered and checked against the preference ledger; they are separate from current Automatic.</p><div class="grid">'
    for f in checkpoints['frames']:
        text += f'<div class="card"><b>{f["stock"]} / {f["frame"]}</b>'
        for c in f['candidates']:
            rel = Path('preferences') / f['stock'] / f['frame'] / (c['variant']+'.png')
            label = 'Automatic · Phoenix Darkroom' if c['variant'] == 'automatic' else 'Phoenix II · Natural'
            text += f'<a href="{rel}"><img loading="lazy" src="{rel}" alt="{html.escape(label)}"></a><p>{label}</p>'
        text += '</div>'
    text += '''</div><p>The refinements improve some color relationships; they do not reproduce Adobe’s full rendering or make these adjustments easy yet. Color matching and aesthetic preference are separate checks.</p>
<script>async function copyRecipe(button,id){const el=document.getElementById(id);try{await navigator.clipboard.writeText(el.value);button.textContent='Copied — Paste Corrections in FSC';}catch(e){el.hidden=false;el.select();button.textContent='Select and copy this JSON';}}</script></html>'''
    (out / 'proimage-review.html').write_text(text)
    sheet = Image.new('RGB', (1500, 738), '#151719')
    draw = ImageDraw.Draw(sheet)
    for row, (stem, choice) in enumerate(choices(out).items()):
        for col, (name, label) in enumerate([('aligned-reference', 'Camera Raw'),
                                            ('cleanInvert-curves', 'Clean Invert + curves'),
                                            (choice, 'FSC color refinement')]):
            im = Image.open(out / 'proimage' / stem / (name+'.png')).convert('RGB')
            im.thumbnail((496, 334))
            sheet.paste(im, (500*col, 369*row+28))
            draw.text((500*col+4, 369*row+7), stem+' / '+label, fill='white')
    sheet.save(out / 'proimage-color-comparison.jpg', quality=95)


def full(out):
    jobs = [dict(raw=f['raw'], directory=f['directory'], name='FSC-color-refined-full',
                 parameters=load(Path(f['directory']) / (choices(out)[f['stem']]+'.json'))) for f in frames(out)]
    paired.invoke(out, 'proimage-full-jobs', jobs)
    checks = []
    for f in frames(out):
        d = Path(f['directory'])
        target, _, test, mask = paired.samples(f)
        a = paired.read16(d, 'FSC-color-refined-full-check')
        b = paired.read16(d, choices(out)[f['stem']])
        checks.append(dict(frame=f['stem'], **load(d / 'FSC-color-refined-full-export.json'),
                           fullToReference=paired.error(a, target, test), proxyToFull=paired.error(a, b, mask)))
    paired.save(out / 'proimage-full-checks.json', checks)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=['fit', 'report', 'full'])
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/camera-raw-study')
    args = parser.parse_args()
    globals()[args.stage](args.output.resolve())
