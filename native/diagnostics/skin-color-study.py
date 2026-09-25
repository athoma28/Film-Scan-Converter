#!/usr/bin/env python3
"""Anatomy-masked RGB comparison and bounded public-control experiments.

Uses hand-annotated skin interiors, same-pixel registered references, spatial
training tiles, separate color controls, and leave-one-photo-out profile checks.
"""
import argparse
import copy
import hashlib
import html
import importlib.util
import itertools
import json
from pathlib import Path
import shutil
import uuid

import cv2
import numpy as np
from PIL import Image, ImageDraw

SPEC = importlib.util.spec_from_file_location('paired', Path(__file__).with_name('paired-reference-study.py'))
paired = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(paired)
ROOT = paired.ROOT
ANNOTATIONS = Path(__file__).with_name('skin-regions.json')
KEYS = ['temperatureShiftMired', 'tint', 'saturation', 'vibrance', 'castCleanup', 'colorSeparation']
STEP = .02
FEATURES = np.array([[0, -1, 1], [1, -1, 0], [.0722*.5, .7152*.5, .2126*.5]])
PROIMAGE_CONTROLS = {
    'DSCF5800': {'water': [140, 75, 260, 130], 'greenery': [690, 170, 770, 300], 'shorts': [98, 395, 170, 495]},
    'DSCF5809': {'shirt': [442, 359, 503, 403], 'tree': [630, 100, 695, 180], 'foliage': [745, 230, 790, 285]},
}


def load(path):
    return json.loads(path.read_text())


def inventory(out):
    annotations = load(ANNOTATIONS)['frames']
    frames = []
    for f in load(out / 'results.json')['frames']:
        key = f['stock']+'/'+f['stem']
        if key not in annotations:
            continue
        f['key'] = key
        f['regions'] = annotations[key]
        choices = load(out / 'proimage-choices.json') if f['stock'] == 'proimage' else {}
        f['skinBase'] = choices.get(f['stem'], f['finalRecipe'])
        f['preserveFavorite'] = key == 'fuji400-fresh/DSCF3115'
        frames.append(f)
    return frames


def masks(f):
    d = Path(f['directory'])
    target = np.load(d / 'target.npy')
    h, w = target.shape[:2]
    regions = {}
    for name, polygon in f['regions'].items():
        m = np.zeros((h, w), np.uint8)
        cv2.fillPoly(m, [np.array(polygon, np.int32)], 1)
        regions[name] = cv2.erode(m, np.ones((7, 7), np.uint8)) > 0
    skin = np.logical_or.reduce(list(regions.values()))
    reference = cv2.imread(str(d / 'reference.png'))
    matrix = np.array(load(d / 'alignment.json')['sourceToTarget'])
    valid = cv2.warpPerspective(np.ones(reference.shape[:2], np.uint8), np.linalg.inv(matrix), (w, h)) > 0
    yy, xx = np.indices((h, w))
    # The central mask conservatively bounds the remainder of the measured area;
    # explicitly annotated skin can extend beyond it without including rebate.
    content = valid & (((xx > w*.17) & (xx < w*.83) & (yy > h*.17) & (yy < h*.83)) | skin)
    train = (xx//32 + 2*(yy//32)) % 4 != 0
    near_skin = cv2.dilate(skin.astype(np.uint8), np.ones((13, 13), np.uint8)) > 0
    regions = {name: mask & valid for name, mask in regions.items()}
    if not all(mask.any() for mask in regions.values()):
        raise ValueError(f'Empty registered skin region: {f["key"]}')
    return target, skin & valid, content & ~near_skin, train, regions


def blur(a):
    return cv2.GaussianBlur(a, (0, 0), 1.2)


def rgb_stats(a, b, mask):
    if not mask.any():
        return None
    x, y = blur(a)[mask], blur(b)[mask]
    delta = x-y
    rg = (x[:, 2]-x[:, 1])-(y[:, 2]-y[:, 1])
    # A display-RGB luma difference is descriptive, not scene luminance.
    return dict(pixels=int(mask.sum()), meanRGB=(x.mean(0)[::-1]*255).tolist(),
                referenceMeanRGB=(y.mean(0)[::-1]*255).tolist(),
                meanRGBDifference=(delta.mean(0)[::-1]*255).tolist(),
                redMinusGreenBias=float(rg.mean()*255), redMinusGreenMAE=float(np.abs(rg).mean()*255),
                rgbMAE=float(np.abs(delta).mean()*255),
                lumaBias=float(np.sum(delta*np.array([.0722, .7152, .2126]), axis=1).mean()*255))


def segment(out):
    rows = []
    for f in inventory(out):
        d = Path(f['directory'])
        target, skin, background, train, regions = masks(f)
        cv2.imwrite(str(d / 'skin-mask.png'), skin.astype(np.uint8)*255)
        a = np.round(target*255).astype(np.uint8)
        a[skin] = np.round(a[skin]*.55+np.array([40, 230, 40])*.45).astype(np.uint8)
        cv2.imwrite(str(d / 'skin-overlay.png'), a)
        base = paired.read16(d, f['skinBase'])
        rows.append(dict(frame=f['key'], recipe=f['skinBase'], skin=rgb_stats(base, target, skin),
                         regions={n: rgb_stats(base, target, m) for n, m in regions.items()}))
    paired.save(out / 'skin-baseline-measurements.json', rows)


def public_delta(parameters, delta):
    p = copy.deepcopy(parameters)
    for key, value in zip(KEYS, delta):
        if key in ('castCleanup', 'colorSeparation'):
            field = 'densityCastRemovalStrength' if key == 'castCleanup' else 'densityUnmixStrength'
            p['filmNegativeParams'][field] = float(np.clip(p['filmNegativeParams'][field] + value, 0, 1))
        else:
            scale = 100 if key == 'temperatureShiftMired' else 1
            p['photoAdjustments'][key] = float(np.clip(p['photoAdjustments'][key] + value * scale, -scale, scale))
    return p


def jacobians(out):
    jobs = []
    for f in inventory(out):
        if f['preserveFavorite']:
            continue
        d = Path(f['directory'])
        base = load(d / (f['skinBase']+'.json'))
        for i, key in enumerate(KEYS):
            for sign, suffix in [(-1, 'minus'), (1, 'plus')]:
                delta = np.zeros(6); delta[i] = sign*STEP
                p = public_delta(base, delta)
                jobs.append(dict(directory=str(d), name=f'skin-jac-{i}-{suffix}', parameters=p))
    paired.invoke(out, 'skin-jacobian-jobs', jobs)


def equations(f):
    d = Path(f['directory'])
    target, skin, bg, train, _ = masks(f)
    base = blur(paired.read16(d, f['skinBase']))
    reference = blur(target)
    jac = np.stack([(blur(paired.read16(d, f'skin-jac-{i}-plus'))-
                     blur(paired.read16(d, f'skin-jac-{i}-minus')))/(2*STEP) for i in range(6)], axis=-1)
    aa, bb = [], []
    # Each frame and each category receive explicit weight independent of area.
    # Non-skin aims to retain the current image, not to solve all reference errors.
    for mask, wanted, weight in [(skin & train, reference-base, 1.0),
                                  (bg & train, np.zeros_like(base), .35)]:
        indices = np.flatnonzero(mask.ravel())
        indices = indices[::max(1, len(indices)//6000)]
        J = jac.reshape(-1, 3, 6)[indices]
        e = wanted.reshape(-1, 3)[indices]
        A = np.einsum('ab,nbc->nac', FEATURES, J).reshape(-1, 6)
        b = np.einsum('nb,ab->na', e, FEATURES).ravel()
        scale = np.sqrt(weight/len(indices))
        aa.append(A*scale); bb.append(b*scale)
    A, b = np.concatenate(aa), np.concatenate(bb)
    assert np.isfinite(A).all() and np.isfinite(b).all()
    return A, b


def solve(data):
    A = np.concatenate([a for a, _ in data])/np.sqrt(len(data))
    b = np.concatenate([b for _, b in data])/np.sqrt(len(data))
    # Shrink uncertain public-control changes; bound each incremental coefficient.
    A = np.concatenate([A, np.eye(6)*np.sqrt(.00015)])
    b = np.concatenate([b, np.zeros(6)])
    # Six variables: enumerate active lower/free/upper faces and solve each
    # strictly convex quadratic exactly. No optional optimizer dependency.
    h, g = np.einsum('ni,nj->ij', A, A), np.einsum('ni,n->i', A, b)
    best, best_loss = np.zeros(6), np.inf
    for status in itertools.product([-1, 0, 1], repeat=6):
        status = np.array(status)
        free, fixed = status == 0, status != 0
        x = status.astype(float)*.20
        if free.any():
            x[free] = np.linalg.solve(h[np.ix_(free, free)], g[free]-h[np.ix_(free, fixed)] @ x[fixed])
        if np.any(np.abs(x) > .2000000001):
            continue
        loss = x @ h @ x-2*g @ x
        if loss < best_loss:
            best, best_loss = x, loss
    return best


def red_adjusted(f, amounts):
    p = load(Path(f['directory']) / (f['skinBase']+'.json'))
    assert p['redCurveEnabled']
    points = p['redCurveControlPoints']
    for point in points:
        y = point['output']
        # Smooth output-domain lift; output values exactly 0 or 1 stay unchanged.
        bases = [max(0, 1-abs(y-center)/.35)**2 * 4*y*(1-y) for center in [.25, .5, .75]]
        point['output'] = float(np.clip(y+np.dot(amounts, bases), 0, 1))
    # Do not introduce a descending segment into a previously monotone curve.
    ys = np.array([v['output'] for v in points])
    if np.any(np.diff(ys) < 0):
        ys = paired.pava(ys, np.ones(len(ys)))
        for point, value in zip(points, ys):
            point['output'] = float(value)
    return p


def red_jacobians(out):
    jobs = []
    for f in inventory(out):
        if f['preserveFavorite']:
            continue
        for i in range(3):
            for sign, suffix in [(-1, 'minus'), (1, 'plus')]:
                amounts = np.zeros(3); amounts[i] = sign*.01
                jobs.append(dict(directory=f['directory'], name=f'skin-red-jac-{i}-{suffix}',
                                 parameters=red_adjusted(f, amounts)))
    paired.invoke(out, 'skin-red-jacobian-jobs', jobs)


def red_equations(f):
    d = Path(f['directory'])
    target, skin, bg, train, _ = masks(f)
    base = blur(paired.read16(d, f['skinBase']))
    jac = np.stack([(blur(paired.read16(d, f'skin-red-jac-{i}-plus'))-
                    blur(paired.read16(d, f'skin-red-jac-{i}-minus')))/.02 for i in range(3)], axis=-1)
    aa, bb = [], []
    for mask, desired, weight in [(skin & train, blur(target)-base, 1),
                                   (bg & train, np.zeros_like(base), .15)]:
        desired_rg = desired[:, :, 2]-desired[:, :, 1]
        J = jac[:, :, 2, :]-jac[:, :, 1, :]
        n = int(mask.sum())
        aa.append(J[mask]*np.sqrt(weight/n)); bb.append(desired_rg[mask]*np.sqrt(weight/n))
    A, b = np.concatenate(aa), np.concatenate(bb)
    assert np.isfinite(A).all() and np.isfinite(b).all()
    return A, b


def solve_red(data):
    A = np.concatenate([a for a, _ in data])/np.sqrt(len(data))
    b = np.concatenate([b for _, b in data])/np.sqrt(len(data))
    H = np.einsum('ni,nj->ij', A, A)+np.eye(3)*.00015
    g = np.einsum('ni,n->i', A, b)
    best, loss = np.zeros(3), np.inf
    for state in itertools.product([-1, 0, 1], repeat=3):
        state = np.array(state); free = state == 0; fixed = ~free
        x = state.astype(float)*.08
        if free.any():
            x[free] = np.linalg.solve(H[np.ix_(free, free)], g[free]-H[np.ix_(free, fixed)] @ x[fixed])
        value = x @ H @ x-2*g @ x
        if np.all(np.abs(x) <= .0800000001) and value < loss:
            best, loss = x, value
    return best


def red_fit(out):
    jobs, adjustments = [], []
    for f in inventory(out):
        if f['preserveFavorite']:
            continue
        best = solve_red([red_equations(f)])
        adjustments.append(dict(frame=f['key'], redCurveBasisAmounts=best.tolist()))
        jobs.append(dict(directory=f['directory'], name='skin-red', parameters=red_adjusted(f, best)))
    paired.save(out / 'skin-red-curve-adjustments.json', adjustments)
    paired.invoke(out, 'skin-red-fit-jobs', jobs)


def red_shared(out):
    fs = [f for f in inventory(out) if not f['preserveFavorite']]
    eq = {f['key']: red_equations(f) for f in fs}
    jobs, profiles = [], []
    for stock in sorted({f['stock'] for f in fs}):
        group = [f for f in fs if f['stock'] == stock]
        amounts = solve_red([eq[f['key']] for f in group])
        profiles.append(dict(stock=stock, trainingFrames=[f['key'] for f in group],
                             redCurveBasisAmounts=amounts.tolist()))
        for f in group:
            jobs.append(dict(directory=f['directory'], name='skin-red-stock', parameters=red_adjusted(f, amounts)))
            others = [g for g in group if g['key'] != f['key']]
            if others:
                heldout = solve_red([eq[g['key']] for g in others])
                jobs.append(dict(directory=f['directory'], name='skin-red-heldout', parameters=red_adjusted(f, heldout)))
    paired.save(out / 'skin-red-profile-candidates.json', profiles)
    paired.invoke(out, 'skin-red-shared-jobs', jobs)


def joint_proimage(out, rgb_weight=.5, prefix='skin-joint', equal_regions=False):
    """Joint public-color/curve fit with explicit non-skin color-control patches."""
    jobs, fits = [], []
    transform = np.concatenate([np.eye(3)*rgb_weight, FEATURES[:2]])
    for f in inventory(out):
        if f['stock'] != 'proimage':
            continue
        d = Path(f['directory']); target, skin, outside, train, regions = masks(f)
        base = blur(paired.read16(d, f['skinBase'])); ref = blur(target)
        derivatives = [(blur(paired.read16(d, f'skin-jac-{i}-plus'))-
                        blur(paired.read16(d, f'skin-jac-{i}-minus')))/(2*STEP) for i in range(6)]
        derivatives += [(blur(paired.read16(d, f'skin-red-jac-{i}-plus'))-
                         blur(paired.read16(d, f'skin-red-jac-{i}-minus')))/.02 for i in range(3)]
        jac = np.stack(derivatives, axis=-1)
        categories = [(skin & train, ref-base, 1), (outside & train, np.zeros_like(base), .15)]
        if equal_regions:
            categories = [(region & train, ref-base, 1/len(regions)) for region in regions.values()]
            categories.append((outside & train, np.zeros_like(base), .15))
        for x0, y0, x1, y1 in PROIMAGE_CONTROLS[f['stem']].values():
            region = np.zeros(skin.shape, bool); region[y0:y1, x0:x1] = True
            categories.append((region & train, ref-base, .25))
        aa, bb = [], []
        for mask, wanted, weight in categories:
            J = np.einsum('ab,nbc->nac', transform, jac[mask]).reshape(-1, 9)
            e = np.einsum('nb,ab->na', wanted[mask], transform).ravel()
            scale = np.sqrt(weight/int(mask.sum()))
            aa.append(J*scale); bb.append(e*scale)
        A, b = np.concatenate(aa), np.concatenate(bb)
        H = np.einsum('ni,nj->ij', A, A)+np.diag([.0005]*6+[.00015]*3)
        g = np.einsum('ni,n->i', A, b)
        bounds = np.array([.15]*6+[.08]*3)
        x = np.zeros(9)
        for iteration in range(10000):
            old = x.copy()
            for i in range(9):
                x[i] = np.clip((g[i]-np.dot(H[i], x)+H[i, i]*x[i])/H[i, i], -bounds[i], bounds[i])
            if np.max(np.abs(x-old)) < 1e-10:
                break
        assert iteration < 9999, 'Bounded quadratic did not converge'
        for strength in [1, .75, .5]:
            p = red_adjusted(f, x[6:]*strength)
            p = public_delta(p, x[:6]*strength)
            jobs.append(dict(directory=f['directory'], name=prefix+'-'+str(int(strength*100)), parameters=p))
        fits.append(dict(frame=f['key'], publicControlDelta=dict(zip(KEYS, x[:6].tolist())), redBasis=x[6:].tolist(),
                         iterations=iteration+1, nonSkinControlRects=PROIMAGE_CONTROLS[f['stem']]))
    paired.save(out / (prefix+'-proimage-fits.json'), fits)
    paired.invoke(out, prefix+'-proimage-jobs', jobs)


def joint_proimage_rgb(out):
    joint_proimage(out, rgb_weight=1, prefix='skin-joint-rgb')


def joint_proimage_regions(out):
    joint_proimage(out, rgb_weight=1, prefix='skin-joint-regions', equal_regions=True)


def adjusted(f, delta):
    p = load(Path(f['directory']) / (f['skinBase']+'.json'))
    return public_delta(p, delta)


def fit(out):
    fs = [f for f in inventory(out) if not f['preserveFavorite']]
    eq = {f['key']: equations(f) for f in fs}
    jobs, profiles = [], []
    for f in fs:
        delta = solve([eq[f['key']]])
        jobs.append(dict(directory=f['directory'], name='skin-frame', parameters=adjusted(f, delta)))
    # Shared stock increments are tested as candidates, not automatically accepted.
    for stock in sorted({f['stock'] for f in fs}):
        group = [f for f in fs if f['stock'] == stock]
        delta = solve([eq[f['key']] for f in group])
        profiles.append(dict(stock=stock, frames=[f['key'] for f in group],
                             publicControlDelta=dict(zip(KEYS, delta.tolist()))))
        for f in group:
            jobs.append(dict(directory=f['directory'], name='skin-stock', parameters=adjusted(f, delta)))
            others = [g for g in group if g['key'] != f['key']]
            if others:
                heldout_delta = solve([eq[g['key']] for g in others])
                jobs.append(dict(directory=f['directory'], name='skin-stock-heldout',
                                 parameters=adjusted(f, heldout_delta)))
    paired.save(out / 'skin-profile-candidates.json', profiles)
    paired.invoke(out, 'skin-fit-jobs', jobs)


def report(out):
    rows = []
    for f in inventory(out):
        d = Path(f['directory'])
        target, skin, bg, train, regions = masks(f)
        base = paired.read16(d, f['skinBase'])
        names = [f['skinBase']]
        if f['preserveFavorite']:
            names += ['preferred-automatic']
        else:
            names += [n for n in ['skin-frame', 'skin-stock', 'skin-stock-heldout', 'skin-red',
                                  'skin-red-stock', 'skin-red-heldout', 'skin-joint-100',
                                  'skin-joint-75', 'skin-joint-50', 'skin-joint-rgb-100',
                                  'skin-joint-rgb-75', 'skin-joint-rgb-50', 'skin-joint-regions-100',
                                  'skin-joint-regions-75', 'skin-joint-regions-50'] if (d/(n+'.bgr16')).exists()]
        row = dict(frame=f['key'], stock=f['stock'], base=f['skinBase'], preserveFavorite=f['preserveFavorite'], variants={})
        for name in names:
            a = paired.read16(d, name)
            row['variants'][name] = dict(skin=rgb_stats(a, target, skin),
                skinTest=rgb_stats(a, target, skin & ~train),
                skinTrain=rgb_stats(a, target, skin & train),
                backgroundChange=rgb_stats(a, base, bg),
                backgroundChangeTrain=rgb_stats(a, base, bg & train),
                backgroundChangeTest=rgb_stats(a, base, bg & ~train),
                backgroundReference=rgb_stats(a, target, bg),
                regions={n: rgb_stats(a, target, m) for n, m in regions.items()},
                regionsTrain={n: rgb_stats(a, target, m & train) for n, m in regions.items()},
                regionsTest={n: rgb_stats(a, target, m & ~train) for n, m in regions.items()})
            if f['stock'] == 'proimage':
                controls = {}
                for region, (x0, y0, x1, y1) in PROIMAGE_CONTROLS[f['stem']].items():
                    m = np.zeros(skin.shape, bool); m[y0:y1, x0:x1] = True
                    controls[region] = dict(all=rgb_stats(a, target, m),
                        train=rgb_stats(a, target, m & train), test=rgb_stats(a, target, m & ~train))
                row['variants'][name]['controlPatches'] = controls
            if name.startswith('skin-'):
                paired.save(d / (name+'.corrections.json'), paired.correction_document(d, name))
        rows.append(row)
        print(f['key'], {n: (round(v['skin']['redMinusGreenBias'], 2), round(v['skin']['rgbMAE'], 2),
                                   round(v['backgroundChange']['rgbMAE'], 2)) for n, v in row['variants'].items()})
    checkpoints = load(ROOT / 'docs/development/color-preference-checkpoints.json')
    assert len(paired.check_preferences(out)) == 5
    paired.save(out / 'skin-color-results.json', dict(units='8-bit display RGB levels',
        backgroundChangeDefinition='Central image area outside annotated skin and its margin; may include unannotated skin. controlPatches are explicit non-skin regions.',
        frames=rows))


def select_recipe(row):
    base = row['variants'][row['base']]['skinTrain']
    candidates = [row['base']]
    if row['preserveFavorite']:
        choice = 'preferred-automatic'
    else:
        options = ['skin-red', 'skin-frame', 'skin-stock', 'skin-red-stock']
        if row['stock'] == 'proimage':
            options += ['skin-joint-100', 'skin-joint-75', 'skin-joint-50',
                        'skin-joint-rgb-100', 'skin-joint-rgb-75', 'skin-joint-rgb-50']
        for name in options:
            v = row['variants'][name]
            controls_ok = True
            if row['stock'] == 'proimage':
                controls_ok = all(patch['train']['rgbMAE'] <= row['variants'][row['base']]['controlPatches'][key]['train']['rgbMAE']+.5
                                  for key, patch in v['controlPatches'].items())
            if (v['skinTrain']['rgbMAE'] < base['rgbMAE']
                and v['skinTrain']['redMinusGreenMAE'] < base['redMinusGreenMAE']
                and v['backgroundChangeTrain']['rgbMAE'] <= 4.1 and controls_ok):
                candidates.append(name)
        def score(name):
            v = row['variants'][name]
            control_score = .75*np.mean([p['train']['rgbMAE'] for p in v.get('controlPatches', {}).values()]) if v.get('controlPatches') else 0
            return (v['skinTrain']['rgbMAE']+.5*v['skinTrain']['redMinusGreenMAE']
                    +.25*v['backgroundChangeTrain']['rgbMAE']+control_score)
        choice = min(candidates, key=score)
    return choice


def publish(out, revisions_output=None):
    rows = load(out / 'skin-color-results.json')['frames']
    presets, revisions = [], []
    for row in rows:
        d = out / row['frame']
        choice = select_recipe(row)
        row['selected'] = choice
        if row['preserveFavorite'] or choice == row['base']:
            continue
        p = load(d / (choice+'.json'))
        original = load(d / (row['base']+'.json'))
        settings = paired.correction_document(d, choice)
        paired.save(d / 'skin-refined.corrections.json', settings)
        paired.save(d / 'skin-refined.json', p)
        for suffix in ['png', 'bgr16', 'recipe.json']:
            shutil.copyfile(d / (choice+'.'+suffix), d / ('skin-refined.'+suffix))
        name = row['frame'].replace('/', ' / ')+' — skin balance study'
        presets.append(dict(id=str(uuid.uuid5(uuid.NAMESPACE_URL, 'fsc:skin-study:'+row['frame'])),
                            name=name, settings=settings))
        revisions.append(dict(frame=row['frame'], baseRecipe=row['base'], selectedRecipe=choice,
            baseParametersSHA256=hashlib.sha256((d/(row['base']+'.json')).read_bytes()).hexdigest(),
            changedParameters={k: v for k, v in p.items() if original.get(k) != v},
            skinBefore=row['variants'][row['base']]['skin'], skinAfter=row['variants'][choice]['skin']))
    paired.save(out / 'skin-review-results.json', dict(frames=rows))
    paired.save(out / 'skin-presets.json', dict(schemaVersion=2, presets=presets))
    paired.save(revisions_output or out / 'skin-profile-revisions.json', dict(schemaVersion=1,
        scope='Reference-conditioned correction presets for this scan setup; not universal emulsion calibrations. Select the recorded film base; recipes replace all public look controls and retain destination calibration.',
        revisions=revisions))
    guards = []
    full_checks = {v['frame']: v for v in load(out/'skin-full-checks.json')} if (out/'skin-full-checks.json').exists() else {}
    for row in rows:
        if row['stock'] != 'proimage':
            continue
        d = out/row['frame']; target, skin, _, _, _ = masks(next(f for f in inventory(out) if f['key'] == row['frame']))
        before = paired.read16(d, row['base']); after = paired.read16(d, row['selected'])
        guard = dict(frame=row['frame'], base=row['base'], selected=row['selected'],
            greenBlueUnchanged=bool(np.array_equal(before[:, :, :2], after[:, :, :2])),
            nonSkinControls=row['variants'][row['selected']].get('controlPatches'))
        check = full_checks.get(row['frame'])
        if check and check.get('parametersSHA256') == hashlib.sha256((d/(row['selected']+'.json')).read_bytes()).hexdigest():
            guard['fullBefore'] = rgb_stats(paired.read16(d, 'FSC-color-refined-full-check'), target, skin)
            guard['fullAfter'] = rgb_stats(paired.read16(d, 'FSC-skin-refined-full-check'), target, skin)
        guards.append(guard)
    paired.save(out/'skin-proimage-guard-checks.json', guards)
    gallery(out, rows)
    print('Published', len(presets), 'revised correction presets')
    for row in rows:
        print(row['frame'], row['selected'])


def gallery(out, rows):
    full_checks = {v['frame']: v for v in load(out/'skin-full-checks.json')} if (out/'skin-full-checks.json').exists() else {}
    text = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Skin RGB — Camera Raw and FSC</title><style>
body{background:#17191c;color:#e9ecf0;font:15px system-ui;line-height:1.5;margin:28px}h1{font-size:28px}h2{margin-top:36px}p{max-width:100ch;color:#bfc6ce}a{color:#b4d4ff}.grid{display:grid;grid-template-columns:repeat(4,minmax(220px,1fr));gap:12px;overflow:auto}.card img{width:100%;display:block}.card b{display:block;margin:7px 0}button,select{padding:8px;background:#303941;color:white;border:1px solid #647282;border-radius:5px;cursor:pointer}textarea{width:95%;height:90px}table{border-collapse:collapse;margin:14px 0;font-variant-numeric:tabular-nums}td,th{padding:7px 12px;text-align:left;border-bottom:1px solid #3a4148}summary{cursor:pointer;color:#b4d4ff}.large{max-width:1200px}.large img{width:100%;display:block;margin-top:12px}.note{border-left:3px solid #89b49c;padding-left:16px}.hide{display:none}small{color:#bfc6ce}</style>
<h1>Skin RGB: the remaining red/green balance</h1>
<p class="note">15 photographs · 7 color stocks · manually segmented skin interiors. Masks follow anatomy, not a skin-hue threshold, so gray and greenish skin stays in the measurements. Each mask is inset by 3 pixels to reduce edge contamination.</p>
<p>The Pro Image refinements combine a red-curve adjustment with public color controls, using separate targets for skin, water, fabric and foliage. All pictures shown as FSC are rendered by FSC’s existing engine. The masks guide fitting and measurement; they are not local masks applied during rendering. Other objects of similar color can change too.</p>
<p>RGB values below use the same aligned pixels, modest blur, and a 0–255 scale. A negative R−G bias means FSC is less red relative to green than the reference. Mean bias can cancel opposing errors; absolute errors and individual skin regions are also listed.</p>
<p>Select the Film Base recorded in the recipe, then copy the corrections for the matching RAF, then use <b>Paste Corrections</b> and optionally save a named preset. These revisions are reference-conditioned recipes, not validated universal film profiles. <a href="skin-presets.json">Download named-preset document</a> · <a href="skin-color-results.json">All measurements</a> · <a href="proimage-review.html">Previous Pro Image study</a></p>
<p>Tests of shared corrections show mixed transfer between photographs. The revised recipes below retain individual tuning. Your Fuji DSCF3115 Automatic and Phoenix DSCF3079 / DSCF3086 favorites remain unchanged.</p>
<label>Film <select id="stock"><option value="">All films</option>'''
    for stock in sorted({r['stock'] for r in rows}):
        text += f'<option>{html.escape(stock)}</option>'
    text += '</select></label>'
    ordered = sorted(rows, key=lambda r: (r['stock'] != 'proimage', r['frame']))
    for index, row in enumerate(ordered):
        rel = Path(row['frame']); d = out / rel
        selected = row['selected']
        before_name = 'preferred-automatic' if row['preserveFavorite'] else row['base']
        before, after = row['variants'][before_name], row['variants'][selected]
        text += f'<section data-stock="{html.escape(row["stock"])}"><h2>{html.escape(row["frame"])}</h2>'
        if row['preserveFavorite']:
            text += '<p>User favorite preserved. Its difference from Camera Raw is not treated as a defect.</p>'
        elif selected == row['base']:
            text += '<p>Kept unchanged: the skin measurements do not support applying a shared red boost here.</p>'
        else:
            text += f'<p>Revision: {html.escape(selected)}. Fitted with training tiles; the remaining tiles are reported separately.</p>'
        columns = [('aligned-reference', 'Camera Raw'), (before_name, 'Previous FSC'),
                   (selected, 'Refined FSC' if selected != before_name else 'FSC retained'), ('skin-overlay', 'Measured skin regions')]
        text += '<div class="grid">'
        for name, label in columns:
            text += f'<div class="card"><b>{label}</b><a href="{rel}/{name}.png"><img loading="lazy" src="{rel}/{name}.png" alt="{label} for {html.escape(row["frame"])}"></a></div>'
        text += '</div>'
        if not row['preserveFavorite'] and selected != row['base']:
            settings = load(d / 'skin-refined.corrections.json')
            text += f'<p><button onclick="copyRecipe(this,\'recipe-{index}\')">Copy refined FSC corrections</button> <a href="{rel}/skin-refined.corrections.json">JSON</a></p><textarea hidden id="recipe-{index}">{html.escape(json.dumps(settings))}</textarea>'
            if ((d / 'FSC-skin-refined-full.jpg').exists()
                and full_checks.get(row['frame'], {}).get('parametersSHA256') == hashlib.sha256((d/'skin-refined.json').read_bytes()).hexdigest()):
                text += f'<p><a href="{rel}/FSC-skin-refined-full.jpg">Full-resolution FSC JPEG</a></p>'
        def triple(v):
            return ' / '.join(f'{x:.1f}' for x in v)
        text += '<table><tr><th>Skin measurement</th><th>Camera Raw</th><th>Previous FSC</th><th>Refined / retained</th></tr>'
        text += f'<tr><td>Mean R / G / B</td><td>{triple(before["skin"]["referenceMeanRGB"])}</td><td>{triple(before["skin"]["meanRGB"])}</td><td>{triple(after["skin"]["meanRGB"])}</td></tr>'
        for field, label in [('redMinusGreenBias', 'R−G mean bias'), ('redMinusGreenMAE', 'R−G absolute error'), ('rgbMAE', 'RGB absolute error')]:
            text += f'<tr><td>{label}</td><td>0</td><td>{before["skin"][field]:+.2f}</td><td>{after["skin"][field]:+.2f}</td></tr>'
        text += '</table>'
        if not row['preserveFavorite']:
            text += f'<p><small>Withheld skin tiles: RGB error {before["skinTest"]["rgbMAE"]:.2f} → {after["skinTest"]["rgbMAE"]:.2f}; R−G absolute error {before["skinTest"]["redMinusGreenMAE"]:.2f} → {after["skinTest"]["redMinusGreenMAE"]:.2f}. RGB change outside the sampled skin: {after["backgroundChange"]["rgbMAE"]:.2f} levels on average.</small></p>'
        if row['stock'] == 'proimage':
            text += '<table><tr><th>Non-skin control patch</th><th>Previous RGB error</th><th>Refined RGB error</th></tr>'
            for patch, value in before['controlPatches'].items():
                text += f'<tr><td>{html.escape(patch)}</td><td>{value["all"]["rgbMAE"]:.2f}</td><td>{after["controlPatches"][patch]["all"]["rgbMAE"]:.2f}</td></tr>'
            text += '</table>'
        text += '<details><summary>Individual skin regions</summary><table><tr><th>Region</th><th>Previous R−G bias</th><th>Refined R−G bias</th><th>Previous RGB error</th><th>Refined RGB error</th></tr>'
        for region, b in before['regions'].items():
            a = after['regions'][region]
            text += f'<tr><td>{html.escape(region)}</td><td>{b["redMinusGreenBias"]:+.2f}</td><td>{a["redMinusGreenBias"]:+.2f}</td><td>{b["rgbMAE"]:.2f}</td><td>{a["rgbMAE"]:.2f}</td></tr>'
        text += '</table></details><details class="large"><summary>Large comparison</summary><p><select onchange="document.getElementById(\'large-'+str(index)+'\').src=this.value">'
        for name, label in columns:
            text += f'<option value="{rel}/{name}.png">{label}</option>'
        text += f'</select></p><img loading="lazy" id="large-{index}" src="{rel}/aligned-reference.png" alt="Selected comparison for {html.escape(row["frame"])}"></details></section>'
    text += '''<script>document.getElementById('stock').addEventListener('change',e=>document.querySelectorAll('section[data-stock]').forEach(s=>s.classList.toggle('hide',!!e.target.value&&s.dataset.stock!==e.target.value)));
async function copyRecipe(button,id){const e=document.getElementById(id);try{await navigator.clipboard.writeText(e.value);button.textContent='Copied — Paste Corrections in FSC';}catch(error){e.hidden=false;e.select();button.textContent='Select and copy this JSON';}}</script></html>'''
    (out / 'skin-review.html').write_text(text)
    chosen = [r for r in ordered if r['stock'] == 'proimage']
    sheet = Image.new('RGB', (1600, 584), '#17191c'); draw = ImageDraw.Draw(sheet)
    for i, row in enumerate(chosen):
        for j, (name, label) in enumerate([('aligned-reference', 'Camera Raw'), (row['base'], 'Previous FSC'), (row['selected'], 'Skin-refined FSC'), ('skin-overlay', 'Measured skin')]):
            im = Image.open(out/row['frame']/(name+'.png')).convert('RGB'); im.thumbnail((396, 265))
            sheet.paste(im, (j*400, i*292+25)); draw.text((j*400+4, i*292+5), row['frame'].split('/')[-1]+' / '+label, fill='white')
    sheet.save(out / 'skin-proimage-comparison.jpg', quality=95)


def full(out):
    selected = {'DSCF5800', 'DSCF5809', 'DSCF5740', 'DSCF3088', 'DSCF2555'}
    jobs = []
    reviews = {row['frame']: row for row in load(out / 'skin-review-results.json')['frames']}
    for f in inventory(out):
        if f['stem'] in selected:
            choice = reviews[f['key']]['selected']
            jobs.append(dict(raw=f['raw'], directory=f['directory'], name='FSC-skin-refined-full',
                             parameters=load(Path(f['directory'])/(choice+'.json'))))
    paired.invoke(out, 'skin-full-jobs', jobs)
    checks = []
    for f in inventory(out):
        if f['stem'] not in selected:
            continue
        d = Path(f['directory']); target, skin, bg, _, _ = masks(f)
        choice = reviews[f['key']]['selected']
        proxy = paired.read16(d, choice); actual = paired.read16(d, 'FSC-skin-refined-full-check')
        checks.append(dict(frame=f['key'], selected=choice, parametersSHA256=hashlib.sha256((d/(choice+'.json')).read_bytes()).hexdigest(),
                           **load(d/'FSC-skin-refined-full-export.json'),
                           skinToReference=rgb_stats(actual, target, skin),
                           proxyToFull=rgb_stats(actual, proxy, skin | bg)))
    paired.save(out / 'skin-full-checks.json', checks)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=['segment', 'jacobians', 'fit', 'red_jacobians', 'red_fit', 'red_shared', 'joint_proimage', 'joint_proimage_rgb', 'joint_proimage_regions', 'report', 'publish', 'full'])
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/camera-raw-study')
    parser.add_argument('--revisions-output', type=Path,
                        help='With publish, explicitly record parameter patches elsewhere (default: OUTPUT/skin-profile-revisions.json).')
    args = parser.parse_args()
    if args.revisions_output and args.stage != 'publish':
        parser.error('--revisions-output only applies to publish')
    if args.stage == 'publish':
        publish(args.output.resolve(), args.revisions_output)
    else:
        globals()[args.stage](args.output.resolve())
