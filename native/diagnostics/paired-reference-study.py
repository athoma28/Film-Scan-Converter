#!/usr/bin/env python3
"""Offline study of existing FSC controls against user-provided ACR triplets.

Uses production Swift renders, feature registration, spatial holdout, and
leave-one-frame-out curves. Inputs and outputs remain outside tracked fixtures.
Requires numpy, OpenCV and Pillow; see accompanying study note for interpretation.
"""
import argparse
import copy
import hashlib
import html
import json
import math
import os
from pathlib import Path
import subprocess
import shutil
import xml.etree.ElementTree as ET

import cv2
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get('FSC_STUDY_RENDERER',
                            ROOT / 'native/FilmScanEngine/.build/release/FilmScanLookbook'))
CRS = '{http://ns.adobe.com/camera-raw-settings/1.0/}'


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def invoke(out, name, jobs):
    manifest = out / (name + '.json')
    save(manifest, jobs)
    subprocess.run([str(BINARY), '--paired-study=' + str(manifest)], check=True)


def correction_document(directory, name):
    # Captured by Swift LookRecipe, not a hand-translated schema-1 document.
    document = json.loads((directory / (name + '.recipe.json')).read_text())
    if document.get('schemaVersion') != 2 or 'recipe' not in document:
        raise ValueError(f'Native recipe capture missing for {directory}/{name}')
    return document


def preference_parameters(parameters):
    # Explicit decode defaults added since the September 18 ledger. No rendering
    # setting or recorded hash is replaced to make a changed look pass.
    value = copy.deepcopy(parameters)
    value.setdefault('filmBaseChosenByUser', False)
    for key in ['whites', 'blacks', 'shadowFloor', 'midtoneLevel', 'highlightCeiling']:
        value['photoAdjustments'].setdefault(key, 0)
    return value


def check_preferences(out):
    checked = []
    for frame in json.loads((ROOT / 'docs/development/color-preference-checkpoints.json').read_text())['frames']:
        directory = out / 'preferences' / frame['stock'] / frame['frame']
        if not directory.exists():
            continue
        for candidate in frame['candidates']:
            image = directory / (candidate['variant'] + '.png')
            parameters = json.loads(image.with_suffix('.json').read_text())
            actual = hashlib.sha256(image.read_bytes()).hexdigest()
            if actual != candidate['imageSHA256'] or preference_parameters(parameters) != preference_parameters(candidate['parameters']):
                raise ValueError(f'Fresh preference differs: {image}; inspect without replacing the ledger.')
            checked.append(dict(frame=frame['stock']+'/'+frame['frame'], variant=candidate['variant'], imageSHA256=actual))
    return checked


def preferences(out):
    jobs = []
    ledger = json.loads((ROOT / 'docs/development/color-preference-checkpoints.json').read_text())
    for frame in ledger['frames']:
        source = out / frame['stock'] / frame['frame']
        if not source.exists():
            continue
        directory = out / 'preferences' / frame['stock'] / frame['frame']
        directory.mkdir(parents=True, exist_ok=True)
        for name in ['scan.bgr16', 'metadata.json']:
            shutil.copyfile(source / name, directory / name)
        metadata_path = ROOT / 'dist/camera-raw-study' / frame['stock'] / frame['frame'] / 'metadata.json'
        historical = json.loads(metadata_path.read_text())['medians']
        save(directory / 'historical-analysis.json', dict(source=str(metadata_path),
             sourceSHA256=hashlib.sha256(metadata_path.read_bytes()).hexdigest(), medians=historical))
        for candidate in frame['candidates']:
            jobs.append(dict(directory=str(directory), name=candidate['variant'],
                             parameters=candidate['parameters'], measuredMedians=historical, captureRecipe=False))
    invoke(out, 'preference-jobs', jobs)
    checked = check_preferences(out)
    save(out / 'preference-checks.json', checked)
    for frame in ledger['frames']:
        source = out / 'preferences' / frame['stock'] / frame['frame']
        if source.exists():
            for candidate in frame['candidates']:
                for extension in ['json', 'png', 'bgr16']:
                    name = candidate['variant'] + '.' + extension
                    shutil.copyfile(source / name, out / frame['stock'] / frame['frame'] / ('preferred-' + name))


def discover(out):
    """Read the triplet inventory without decoding or writing artifacts."""
    frames, incomplete = [], []
    for xmp in sorted((ROOT / 'sample-raw').rglob('*.xmp')):
        siblings = list(xmp.parent.iterdir())
        raw = next((p for p in siblings if p.stem.lower() == xmp.stem.lower()
                    and p.suffix.lower() == '.raf'), None)
        candidates = [p for p in siblings if p.suffix.lower() in ['.jpg', '.jpeg']
                      and (p.stem.lower() == xmp.stem.lower() or
                           p.stem.lower().startswith(xmp.stem.lower() + '-') or
                           p.stem.lower().startswith(xmp.stem.lower() + '_'))
                      and 'cnegprofile' not in p.name.lower()]
        candidates.sort(key=lambda p: (p.stem.lower() != xmp.stem.lower(), p.name))
        if not raw or not candidates:
            incomplete.append(str(xmp.relative_to(ROOT / 'sample-raw')))
            continue
        doc = ET.parse(xmp)
        attrs = {k.split('}')[-1]: v for e in doc.iter() for k, v in e.attrib.items()}
        curves = {k: [e.text for e in doc.find('.//' + CRS + k).iter() if e.tag.endswith('li')]
                  for k in ['ToneCurvePV2012', 'ToneCurvePV2012Red', 'ToneCurvePV2012Green',
                            'ToneCurvePV2012Blue'] if doc.find('.//' + CRS + k) is not None}
        stock = str(xmp.parent.relative_to(ROOT / 'sample-raw'))
        directory = out / stock / xmp.stem
        mono = attrs.get('ConvertToGrayscale') == 'True'
        frame = dict(stock=stock, stem=xmp.stem, raw=str(raw), target=str(candidates[0]),
                     xmp=str(xmp), directory=str(directory), monochrome=mono,
                     attributes=attrs, curves=curves)
        frames.append(frame)
    return frames, incomplete


def inventory(out):
    frames, incomplete = discover(out)
    jobs = []
    for frame in frames:
        directory = Path(frame['directory'])
        if not (directory / 'metadata.json').exists() or not (directory / 'reference.png').exists():
            jobs.append({k: frame[k] for k in ['stock', 'raw', 'target', 'directory', 'monochrome']})
    save(out / 'inventory.json', dict(frames=frames, incomplete=incomplete))
    print(f'{len(frames)} complete triplets; {len(incomplete)} incomplete', flush=True)
    invoke(out, 'decode-jobs', jobs)


def read16(directory, name):
    meta = json.loads((directory / 'metadata.json').read_text())
    a = np.fromfile(directory / (name + '.bgr16'), '<u2')
    channels = a.size // (meta['width'] * meta['height'])
    a = a.reshape(meta['height'], meta['width'], channels).astype(np.float32) / 65535
    return np.repeat(a, 3, 2) if channels == 1 else a


def register(frame):
    directory = Path(frame['directory'])
    ref = cv2.imread(str(directory / 'reference.png'))
    variants = json.loads((directory / 'metadata.json').read_text())['variants']
    sift = cv2.SIFT_create(nfeatures=6000)
    kp2, des2 = sift.detectAndCompute(cv2.cvtColor(ref, cv2.COLOR_BGR2GRAY), None)
    best = None
    for name in [n for n in ['natural', 'cleanInvert', 'bwPrint', 'punchyPrint'] if n in variants]:
        src = cv2.imread(str(directory / (name + '.png')))
        kp1, des1 = sift.detectAndCompute(cv2.cvtColor(src, cv2.COLOR_BGR2GRAY), None)
        if des1 is None or des2 is None: continue
        matches = cv2.BFMatcher().knnMatch(des1, des2, k=2)
        good = [m for pair in matches if len(pair) == 2 for m, n in [pair]
                if m.distance < .72 * n.distance]
        if len(good) < 12: continue
        a = np.float32([kp1[m.queryIdx].pt for m in good]); b = np.float32([kp2[m.trainIdx].pt for m in good])
        H, inliers = cv2.findHomography(a, b, cv2.RANSAC, 2.5)
        if H is None: continue
        count = int(inliers.sum())
        residual = np.linalg.norm(cv2.perspectiveTransform(a[:,None,:], H)[:,0,:]-b, axis=1)[inliers[:,0]>0]
        if best is None or count > best[0]: best=(count,H,float(np.median(residual)),src.shape[:2])
    if best is None or best[0] < 20: raise ValueError('Insufficient feature matches')
    count, H, residual, (h,w) = best
    target = cv2.warpPerspective(ref.astype(np.float32)/255, np.linalg.inv(H), (w,h))
    valid = cv2.warpPerspective(np.ones(ref.shape[:2],np.uint8), np.linalg.inv(H), (w,h)) > 0
    # Conservative image-content inset excludes sprockets/rebate in these scans.
    yy,xx=np.mgrid[:h,:w]
    mask=valid & (xx>w*.17) & (xx<w*.83) & (yy>h*.17) & (yy<h*.83)
    # Reject poorly overlapping or implausibly registered pairs rather than score them.
    if mask.sum() < h*w*.35 or residual > 1.5: raise ValueError('Registration coverage/residual failed')
    target = np.clip(target,0,1)
    np.save(directory / 'target.npy', target)
    cv2.imwrite(str(directory/'aligned-reference.png'), np.round(target*255).astype(np.uint8))
    cv2.imwrite(str(directory/'mask.png'), mask.astype(np.uint8)*255)
    save(directory/'alignment.json',dict(inliers=count,medianResidualPixels=residual,
         sourceToTarget=H.tolist(),coverage=float(mask.mean()),width=w,height=h))
    return target,mask


def samples(frame):
    d=Path(frame['directory'])
    target=np.load(d/'target.npy'); mask=cv2.imread(str(d/'mask.png'),0)>0
    yy,xx=np.indices(mask.shape)
    # Withhold spatial tiles, not random neighboring pixels, from per-frame fits.
    train=mask & ((xx//32+2*(yy//32))%4 != 0)
    test=mask & ~train
    return target,train,test,mask


def pava(y, weights):
    blocks=[]
    for i,(v,w) in enumerate(zip(y,weights)):
        blocks.append([i,i,float(v),float(w)])
        while len(blocks)>1 and blocks[-2][2]>blocks[-1][2]:
            b=blocks.pop();a=blocks.pop();s=a[3]+b[3]
            blocks.append([a[0],b[1],(a[2]*a[3]+b[2]*b[3])/s,s])
    out=np.empty(len(y))
    for a,b,v,w in blocks: out[a:b+1]=v
    return out


def fit_curves(pairs, mono=False):
    # Equal contribution per training frame avoids letting one large crop dominate.
    xs=[];ys=[]
    for a,b in pairs:
        step=max(1,len(a)//6000);xs.append(a[::step][:6000]);ys.append(b[::step][:6000])
    x=np.concatenate(xs);y=np.concatenate(ys)
    curves=[]
    for c in range(1 if mono else 3):
        xc=x.mean(1) if mono else x[:,c];yc=y.mean(1) if mono else y[:,c]
        edges=np.quantile(xc,np.linspace(0,1,15))
        points=[];weights=[]
        for lo,hi in zip(edges[:-1],edges[1:]):
            m=(xc>=lo)&(xc<=hi)
            if m.sum()<15: continue
            px=float(np.median(xc[m]));py=float(np.median(yc[m]))
            if points and px-points[-1][0]<.003: continue
            points.append([px,py]);weights.append(int(m.sum()))
        if len(points)<2: points=[[0,0],[1,1]];weights=[1,1]
        values=pava([p[1] for p in points],weights)
        points=[[p[0],float(v)] for p,v in zip(points,values)]
        # Extend conservatively, with finite endpoint slopes; do not flatten all tails.
        if points[0][0] > 0:
            slope=(points[1][1]-points[0][1])/max(points[1][0]-points[0][0],1e-5)
            points.insert(0,[0,max(0,points[0][1]-slope*points[0][0])])
        if points[-1][0] < 1:
            slope=(points[-1][1]-points[-2][1])/max(points[-1][0]-points[-2][0],1e-5)
            points.append([1,min(1,points[-1][1]+slope*(1-points[-1][0]))])
        curves.append([dict(input=px,output=py) for px,py in points])
    return curves


def with_curves(params,curves,mono):
    p=copy.deepcopy(params)
    if mono:
        p['curveEnabled']=True;p['curveControlPoints']=curves[0]
    else:
        for channel,curve in zip(['blue','green','red'],curves):
            p[channel+'CurveEnabled']=True;p[channel+'CurveControlPoints']=curve
    return p


def error(a,b,mask):
    # Pixel registration still differs at texture/edges; blur a little before scoring.
    a=cv2.GaussianBlur(a,(0,0),1.2);b=cv2.GaussianBlur(b,(0,0),1.2)
    delta=a[mask]-b[mask]
    weights=np.array([.0722,.7152,.2126])
    lum=(delta*weights).sum(axis=1)
    chroma=delta-lum[:,None]
    return dict(mae=float(np.abs(delta).mean()),lumaMAE=float(np.abs(lum).mean()),
                chromaMAE=float(np.abs(chroma).mean()))


def fit(out):
    inv=json.loads((out/'inventory.json').read_text()); frames=[];jobs=[];skipped=[]
    for f in inv['frames']:
        try:
            d=Path(f['directory'])
            if not (d/'alignment.json').exists(): register(f)
            target,train,test,mask=samples(f)
            meta=json.loads((d/'metadata.json').read_text())
            f['baselineScores']={}
            f['baselineTrainingScores']={}
            for name in meta['variants']:
                source=read16(d,name)
                f['baselineScores'][name]=error(source,target,test)
                f['baselineTrainingScores'][name]=error(source,target,train)
                curves=fit_curves([(source[train],target[train])],f['monochrome'])
                p=with_curves(json.loads((d/(name+'.json')).read_text()),curves,f['monochrome'])
                jobs.append(dict(directory=str(d),name=name+'-curves',parameters=p))
            frames.append(f)
            print('aligned',f['stock'],f['stem'],flush=True)
        except (ValueError,cv2.error) as e:
            skipped.append(dict(stem=f['stem'],reason=str(e)))
    save(out/'aligned-inventory.json',dict(frames=frames,skipped=skipped,incomplete=inv['incomplete']))
    invoke(out,'curve-jobs',jobs)


def report(out):
    inv=json.loads((out/'aligned-inventory.json').read_text()); rows=[]
    for f in inv['frames']:
        d=Path(f['directory']); target,train,test,mask=samples(f)
        f['curveScores']={n:error(read16(d,n+'-curves'),target,test) for n in f['baselineScores']}
        f['curveTrainingScores']={n:error(read16(d,n+'-curves'),target,train) for n in f['baselineScores']}
        f['bestBaseline']=min(f['baselineTrainingScores'],key=lambda n:f['baselineTrainingScores'][n]['mae'])
        f['bestCurves']=min(f['curveTrainingScores'],key=lambda n:f['curveTrainingScores'][n]['mae'])
        f['extraScores']={}
        for name in ['automatic','basic-best','basic-curves','natural-transfer','cleanInvert-transfer','bwPrint-transfer']:
            if (d/(name+'.bgr16')).exists():
                f['extraScores'][name]=error(read16(d,name),target,test)
        candidates=[n+'-curves' for n in f['curveScores']]
        candidates += [n for n in ['basic-best','basic-curves'] if n in f['extraScores']]
        f['finalRecipe']=min(candidates,key=lambda n:error(read16(d,n),target,train)['mae'])
        f['finalScore']=error(read16(d,f['finalRecipe']),target,test)
        for name in ['basic-best',f['finalRecipe']]:
            if (d/(name+'.json')).exists():
                save(d/(name+'.corrections.json'), correction_document(d, name))
        rows.append(f)
    save(out/'results.json',dict(frames=rows,incomplete=inv['incomplete'],skipped=inv['skipped']))
    write_gallery(out,rows)
    for stock in sorted(set(f['stock'] for f in rows)):
        fs=[f for f in rows if f['stock']==stock]
        print(stock,len(fs), 'natural',round(np.mean([f['baselineScores']['natural']['mae'] for f in fs]),4),
              'best baseline',round(np.mean([f['baselineScores'][f['bestBaseline']]['mae'] for f in fs]),4),
              'curves',round(np.mean([f['finalScore']['mae'] for f in fs]),4))


def write_gallery(out,rows):
    text='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>FSC × Camera Raw — reference study</title>
<style>body{background:#141619;color:#e4e4e4;font:15px system-ui;margin:28px}h1{font-size:25px}p{max-width:105ch;color:#bcbfc4}table{border-collapse:collapse}th{position:sticky;top:0;background:#141619;z-index:2}td,th{padding:8px;text-align:left;vertical-align:top}img{width:320px;display:block}small{display:block;max-width:320px;color:#adb4be}a{color:#aad0ff}button,select{padding:7px;background:#29313d;color:white;border:1px solid #596577;border-radius:5px;margin:7px 0;cursor:pointer}details{max-width:320px;font-size:12px}pre{white-space:pre-wrap;word-break:break-word}textarea{width:310px;height:100px}.score{font-variant-numeric:tabular-nums}.intro{border-left:3px solid #94b6ce;padding-left:15px}.hide{display:none}</style>
<h1>FSC × Camera Raw</h1><p class="intro">PAIRED_COUNTS · existing FSC controls. The final column uses fitted settings rendered through the production engine. These are frame-specific recipes. They are not new stock profiles or an exact Camera Raw implementation.</p>
<p>To try a result: open the matching RAF in FSC, click <b>Copy FSC corrections</b> below, then use <b>Paste Corrections</b> in FSC. First select the Film Base shown with the recipe. Copy preserves your framing and calibration; a different base or calibration changes the result. You can save the result as a named preset. Recipes use the current public controls. Full parameter JSON is retained separately for reproducibility.</p>
<p>Scores are normalized RGB mean absolute error on withheld central image tiles, after geometric registration and slight blur. Lower is closer to your edited reference; this is not a perceptual score or colorimetric accuracy claim. Borders are excluded. Recipe selection uses only the fitting tiles. Only separate leave-one-frame-out tests measure transfer to another photo.</p>
<label>Stock <select id="stock"><option value="">All stocks</option>'''
    text = text.replace('PAIRED_COUNTS', f'{len(rows)} paired scans · {len({f["stock"] for f in rows})} stocks')
    if (out/'proimage-review.html').exists():
        text=text.replace('<label>Stock', '<p><a href="proimage-review.html">Pro Image color follow-up and FSC favorites</a></p><label>Stock')
    if (out/'skin-review.html').exists():
        text=text.replace('<label>Stock', '<p><a href="skin-review.html">Segmented skin RGB comparison and refined corrections</a></p><label>Stock')
    for stock in sorted({f['stock'] for f in rows}):
        text+=f'<option>{html.escape(stock)}</option>'
    text+='</select></label><table><tr><th>Camera Raw reference</th><th>FSC automatic</th><th>Basic sliders only</th><th>Best fitted FSC recipe</th></tr>'
    for i,f in enumerate(rows):
        d=Path(f['directory']);rel=d.relative_to(out)
        auto='automatic' if 'automatic' in f['extraScores'] else 'natural'
        basic='basic-best' if 'basic-best' in f['extraScores'] else f['bestBaseline']
        columns=[('aligned-reference','Camera Raw'),(auto,'Automatic'),(basic,'Sliders'),(f['finalRecipe'],f['finalRecipe'])]
        text+=f'<tr data-stock="{html.escape(f["stock"])}">'
        for j,(name,label) in enumerate(columns):
            url=html.escape(str(rel/(name+'.png')))
            text+=f'<td><b>{html.escape(f["stock"]+" / "+f["stem"])}</b><a href="{url}"><img loading="lazy" src="{url}" alt="{html.escape(label)}"></a><small>{html.escape(label)}</small>'
            if name!='aligned-reference':
                target,train,test,mask=samples(f)
                score=error(read16(d,name),target,test)
                text+=f'<small class="score">RGB MAE {score["mae"]:.3f} · chroma MAE {score["chromaMAE"]:.3f}</small>'
                p=json.loads((d/(name+'.json')).read_text())
                text+=f'<small>Film Base: {html.escape(correction_document(d, name)["requiredFilmBase"])}</small>'
                if j>=2:
                    settings=correction_document(d, name)
                    save(d/(name+'.corrections.json'),settings)
                    token=f'preset-{i}-{j}'
                    text+=f'<button onclick="copyPreset(this,\'{token}\')">Copy FSC corrections</button><textarea hidden id="{token}">{html.escape(json.dumps(settings))}</textarea>'
                    text+=f' <a href="{html.escape(str(rel/(name+".corrections.json")))}">JSON</a>'
                    text+='<details><summary>Settings and curve points</summary><pre>'
                    text+=html.escape(json.dumps(p['photoAdjustments'],indent=2))
                    for channel in ['', 'red','green','blue']:
                        key=channel+'Curve' if channel else 'curve'
                        if p.get(key+'Enabled'):
                            coords=[(round(v['input']*255,1),round(v['output']*255,1)) for v in p[key+'ControlPoints']]
                            text+='\n'+(channel or 'master')+' curve (0–255):\n'+str(coords)
                    text+='</pre></details>'
                    if j==3 and (d/'FSC-matched-full.jpg').exists():
                        text+=f'<p><a href="{html.escape(str(rel/"FSC-matched-full.jpg"))}">Full-resolution FSC JPEG</a></p>'
            text+='</td>'
        text+='</tr>'
    text+='''</table><script>
    document.querySelector('#stock').addEventListener('change',e=>document.querySelectorAll('tr[data-stock]').forEach(row=>row.classList.toggle('hide',!!e.target.value&&row.dataset.stock!==e.target.value)));
    async function copyPreset(button,id){const el=document.getElementById(id);try{await navigator.clipboard.writeText(el.value);button.textContent='Copied — Paste Corrections in FSC';}catch(e){el.hidden=false;el.select();button.textContent='Select and copy this JSON';}}
    </script></html>'''
    (out/'index.html').write_text(text)
    preferred = ['gold200','proimage','luckyc200','fuji400-fresh','harmanphoenixii','cinestill800t']
    stocks = sorted({f['stock'] for f in rows}, key=lambda s: (preferred.index(s) if s in preferred else len(preferred), s))
    selected = [next(f for f in rows if f['stock'] == stock) for stock in stocks]
    if not selected:
        raise ValueError('No aligned frames to report; inspect aligned-inventory.json')
    sheet=Image.new('RGB',(1200,len(selected)*222),'#141619');draw=ImageDraw.Draw(sheet)
    for r,f in enumerate(selected):
        d=Path(f['directory'])
        names=['aligned-reference','automatic','basic-best',f['finalRecipe']]
        for c,n in enumerate(names):
            if not (d/(n+'.png')).exists(): n='natural'
            im=Image.open(d/(n+'.png'));im.thumbnail((294,184));sheet.paste(im,(c*300,r*222+21))
            draw.text((c*300+2,r*222+3),f['stock']+' / '+['Camera Raw','FSC automatic','Basic sliders','FSC fitted'][c],fill='white')
    sheet.save(out/'comparison.jpg',quality=93)


def basic(out):
    frames=json.loads((out/'results.json').read_text())['frames'];jobs=[]
    for f in frames:
        d=Path(f['directory']);target,train,test,mask=samples(f)
        np.round(target*65535).astype('<u2').tofile(d/'target.bgr16')
        # Erode the training mask so downsampling never mixes a held-out tile into a fit.
        cv2.erode(train.astype(np.uint8),np.ones((11,11),np.uint8)).tofile(d/'train-mask.u8')
        for name,base in [('basic-fit',f['bestBaseline']),('basic-alt',f['bestCurves'])]:
            if (d/(name+'.json')).exists(): continue
            p=json.loads((d/(base+'.json')).read_text())
            jobs.append(dict(directory=str(d),name=name,parameters=p,optimize=True))
    invoke(out,'basic-jobs',jobs)


def transfer(out):
    frames=json.loads((out/'results.json').read_text())['frames'];jobs=[]
    for f in frames:
        others=[g for g in frames if g['stock']==f['stock'] and g['stem']!=f['stem']]
        if len(others)<2: continue
        d=Path(f['directory'])
        for base in ['natural', 'bwPrint' if f['monochrome'] else 'cleanInvert']:
            pairs=[]
            for g in others:
                target,train,test,mask=samples(g)
                pairs.append((read16(Path(g['directory']),base)[mask],target[mask]))
            curves=fit_curves(pairs,f['monochrome'])
            p=with_curves(json.loads((d/(base+'.json')).read_text()),curves,f['monochrome'])
            jobs.append(dict(directory=str(d),name=base+'-transfer',parameters=p))
    invoke(out,'transfer-jobs',jobs)


def automatic(out):
    frames=json.loads((out/'results.json').read_text())['frames']
    invoke(out,'automatic-jobs',[dict(directory=f['directory'],name='automatic',
           parameters={},autoClassify=True) for f in frames])


def refine(out):
    frames=json.loads((out/'results.json').read_text())['frames'];jobs=[]
    for f in frames:
        d=Path(f['directory']);target,train,test,mask=samples(f)
        best=min(['basic-fit','basic-alt'],key=lambda name:error(read16(d,name),target,train)['mae'])
        for ext in ['json','png','bgr16','recipe.json']:
            shutil.copyfile(d/(best+'.'+ext),d/('basic-best.'+ext))
        source=read16(d,'basic-best')
        curves=fit_curves([(source[train],target[train])],f['monochrome'])
        p=with_curves(json.loads((d/'basic-best.json').read_text()),curves,f['monochrome'])
        jobs.append(dict(directory=str(d),name='basic-curves',parameters=p))
    invoke(out,'refine-jobs',jobs)


def full(out):
    frames=json.loads((out/'results.json').read_text())['frames'];jobs=[];checks=[]
    for f in frames:
        if f['stem'] not in ['DSCF5740','DSCF5800','DSCF5664','DSCF5702']: continue
        d=Path(f['directory'])
        p=json.loads((d/(f['finalRecipe']+'.json')).read_text())
        jobs.append(dict(raw=f['raw'],parameters=p,name='FSC-matched-full',directory=str(d)))
    invoke(out,'full-jobs',jobs)
    for f in frames:
        d=Path(f['directory']);info=d/'FSC-matched-full-export.json'
        if not info.exists():continue
        a=read16(d,'FSC-matched-full-check');b=read16(d,f['finalRecipe'])
        target,train,test,mask=samples(f)
        checks.append(dict(stem=f['stem'],stock=f['stock'],**json.loads(info.read_text()),
                      proxyToReference=f['finalScore'],fullToReference=error(a,target,test),
                      proxyToFull=error(a,b,mask)))
    save(out/'full-resolution-checks.json',checks)
    write_gallery(out,frames)


def crop(out):
    frames=json.loads((out/'results.json').read_text())['frames'];jobs=[];checks=[]
    rectangle=dict(x=.1,y=.1,width=.8,height=.8)
    for f in frames:
        if f['stem'] not in ['DSCF5740','DSCF5800','DSCF5664','DSCF5702']: continue
        d=Path(f['directory']);p=json.loads((d/(f['finalRecipe']+'.json')).read_text())
        p['manualCrop']=rectangle
        jobs.append(dict(directory=str(d),name='crop-sensitivity',parameters=p))
    invoke(out,'crop-jobs',jobs)
    for f in frames:
        d=Path(f['directory'])
        if not (d/'crop-sensitivity.bgr16').exists(): continue
        base=read16(d,f['finalRecipe']);h,w=base.shape[:2]
        x0,y0=math.floor(w*.1),math.floor(h*.1)
        x1,y1=math.ceil(w*.9),math.ceil(h*.9)
        expected=base[y0:y1,x0:x1]
        actual=np.fromfile(d/'crop-sensitivity.bgr16','<u2').reshape(expected.shape).astype(np.float32)/65535
        mask=samples(f)[3][y0:y1,x0:x1]
        checks.append(dict(stem=f['stem'],crop=rectangle,
                           changeOnSamePixels=error(actual,expected,mask)))
    save(out/'crop-sensitivity.json',checks)


def main():
    ap=argparse.ArgumentParser();ap.add_argument('stage',choices=['inventory','fit','report','basic','transfer','refine','automatic','preferences','full','crop']);ap.add_argument('--output',type=Path,default=ROOT/'dist/camera-raw-study')
    args=ap.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    globals()[args.stage](out)

if __name__=='__main__': main()
