#!/usr/bin/env python3
"""Score fixed-recipe production X-T5 matrix A/B renders; never fit or select.

Input: inventory.json plus baseline|matrix/{preview,full}/<stock>/<stem>,
and {preferences,full-preferences}/<stock>/<stem> for the frozen ledger.
The native probe owns decoding, rendering, parser/parity checks and provenance.
This scorer only writes analysis/ artifacts and fails closed on incomplete data.
"""
import argparse
import copy
import hashlib
import html
import importlib.util
import json
from pathlib import Path
import shutil
import sys
from urllib.parse import quote

import cv2
import numpy as np
from PIL import Image, ImageDraw


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


paired = module('xt5_paired', 'paired-reference-study.py')
skin = module('xt5_skin', 'skin-color-study.py')
ROOT = paired.ROOT
VARIANTS = ('natural', 'clean', 'automatic')
ARMS = ('baseline', 'matrix')
TIERS = ('preview', 'full')
# These annotations were authored on 900 x 602 sensor-coordinate references.
# A different shape requires reannotation, never automatic rescaling.
ANNOTATION_SHAPE = (602, 900)


def load(path):
    return json.loads(path.read_text())


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def normalized_parameters(parameters):
    value = copy.deepcopy(parameters)
    # Medians are transient production analysis, intentionally absent from JSON.
    value.get('filmNegativeParams', {}).pop('measuredMedians', None)
    return value


def parameters(directory, name):
    return normalized_parameters(load(directory / f'{name}.json'))


def read_image(directory, name, metadata):
    width, height = int(metadata['width']), int(metadata['height'])
    require(width > 0 and height > 0, f'Invalid dimensions: {directory}')
    path = directory / f'{name}.bgr16'
    require(path.is_file(), f'Missing render: {path}')
    values = np.fromfile(path, dtype='<u2')
    pixels = width * height
    require(values.size in (pixels, pixels * 3), f'Invalid BGR16 size: {path}')
    channels = values.size // pixels
    image = values.reshape(height, width, channels).astype(np.float32) / 65535
    if channels == 1:
        image = np.repeat(image, 3, axis=2)
    png = directory / f'{name}.png'
    require(png.is_file(), f'Missing review PNG: {png}')
    expected_png = metadata['renders'][name].get('pngSHA256')
    require(expected_png and sha256(png) == expected_png, f'PNG hash differs/missing: {png}')
    with Image.open(png) as rendered:
        require(rendered.size == (width, height), f'PNG/BGR16 geometry differs: {png}')
    return image


def valid_metadata(directory, key, arm, tier, variants):
    metadata = load(directory / 'metadata.json')
    require(metadata.get('schemaVersion') == 1, f'Unsupported native metadata: {directory}')
    for field, expected in (('key', key), ('arm', arm), ('tier', tier)):
        if field in metadata:
            require(metadata[field] == expected, f'{field} mismatch in {directory}')
    require(set(variants).issubset(metadata['variants']), f'Missing variants in {directory}')
    require(metadata.get('decodedClipping') is not None, f'Missing decode clipping: {directory}')
    for name in variants:
        stats = metadata['renders'][name]
        require(stats.get('parametersSHA256') == sha256(directory / f'{name}.json'),
                f'Parameter hash differs/missing: {directory}/{name}')
        require(stats.get('clipping') is not None, f'Missing native clipping: {directory}/{name}')
        require(stats.get('proxyClipping') is not None, f'Missing proxy clipping: {directory}/{name}')
    return metadata


def check_geometry(a, b, label):
    for field in ('width', 'height', 'channels', 'rawWidth', 'rawHeight', 'rawChannels'):
        require(field in a and field in b, f'Missing {field}: {label}')
        require(a[field] == b[field], f'Geometry differs for {label}: {field} {a[field]} vs {b[field]}')
    require(a.get('rawSHA256') and a['rawSHA256'] == b.get('rawSHA256'),
            f'RAW source hash differs/missing: {label}')


def register(directory, destination, frame):
    """Use the established registration implementation in isolated scratch."""
    destination.mkdir(parents=True, exist_ok=True)
    for name in ('reference', 'natural', 'clean'):
        source = directory / f'{name}.png'
        require(source.is_file(), f'Missing registration input: {source}')
        target = destination / ('cleanInvert.png' if name == 'clean' else f'{name}.png')
        shutil.copyfile(source, target)
    metadata = load(directory / 'metadata.json')
    metadata['variants'] = ['natural', 'cleanInvert']
    save(destination / 'metadata.json', metadata)
    paired.register(dict(frame, directory=str(destination)))
    return load(destination / 'alignment.json')


def geometry_displacement(baseline, candidate):
    """Compare independently fitted mappings in source pixels over the frame."""
    width, height = baseline['width'], baseline['height']
    xx, yy = np.meshgrid(np.linspace(.17 * width, .83 * width, 9),
                         np.linspace(.17 * height, .83 * height, 9))
    points = np.stack((xx.ravel(), yy.ravel()), axis=1).astype(np.float64)[:, None, :]
    base_h = np.array(baseline['sourceToTarget'], np.float64)
    candidate_h = np.array(candidate['sourceToTarget'], np.float64)
    moved = cv2.perspectiveTransform(points, np.linalg.inv(candidate_h) @ base_h)
    distances = np.linalg.norm(moved - points, axis=2).ravel()
    require(np.isfinite(distances).all(), 'Nonfinite homography displacement')
    return dict(gridPoints=len(distances), coordinateSpace='baseline source pixels',
                medianPixels=float(np.median(distances)), maximumPixels=float(distances.max()),
                p95Pixels=float(np.percentile(distances, 95)),
                reviewRequired=bool(np.median(distances) > 1.5 or distances.max() > 3))


def score_blurred(image, target, mask):
    """Same sigma/units as skin.rgb_stats; caller blurs once per image."""
    require(mask.any(), 'Empty scoring region')
    x, y = image[mask], target[mask]
    delta = x - y
    rg = delta[:, 2] - delta[:, 1]
    luma = np.sum(delta * np.array([.0722, .7152, .2126]), axis=1)
    return dict(pixels=int(mask.sum()), meanRGB=(x.mean(0)[::-1] * 255).tolist(),
                referenceMeanRGB=(y.mean(0)[::-1] * 255).tolist(),
                meanRGBDifference=(delta.mean(0)[::-1] * 255).tolist(),
                rgbMAE=float(np.abs(delta).mean() * 255),
                redMinusGreenBias=float(rg.mean() * 255),
                redMinusGreenMAE=float(np.abs(rg).mean() * 255),
                lumaMAE=float(np.abs(luma).mean() * 255),
                lumaBias=float(luma.mean() * 255))


def comparison(baseline, candidate, target, mask):
    left = score_blurred(baseline, target, mask)
    right = score_blurred(candidate, target, mask)
    change = right['rgbMAE'] - left['rgbMAE']
    fraction = change / left['rgbMAE'] if left['rgbMAE'] > 1e-12 else None
    return dict(baseline=left, matrix=right, rgbMAEChange=change,
                relativeRGBMAEChange=fraction,
                matrixVsBaseline=score_blurred(candidate, baseline, mask),
                regression=bool(change > 1 or (fraction is not None and fraction > .10)))


def scored_masks(scratch, frame, annotations):
    f = dict(frame, directory=str(scratch), key=frame['stock'] + '/' + frame['stem'])
    target, train, test, content = paired.samples(f)
    reference = cv2.imread(str(scratch / 'reference.png'))
    h = np.array(load(scratch / 'alignment.json')['sourceToTarget'])
    valid = cv2.warpPerspective(np.ones(reference.shape[:2], np.uint8), np.linalg.inv(h),
                               (target.shape[1], target.shape[0])) > 0
    yy, xx = np.indices(target.shape[:2])
    tiles = (xx // 32 + 2 * (yy // 32)) % 4 != 0
    groups = {'whole': content}
    if f['key'] in annotations:
        require(target.shape[:2] == ANNOTATION_SHAPE,
                f'Annotation shape differs for {f["key"]}: {target.shape[:2]}')
        f['regions'] = annotations[f['key']]
        for name, polygon in f['regions'].items():
            xy = np.asarray(polygon)
            require(np.all(xy >= 0) and np.all(xy[:, 0] < target.shape[1])
                    and np.all(xy[:, 1] < target.shape[0]), f'Annotation out of bounds: {name}')
        _, aggregate, background, _, regions = skin.masks(f)
        groups.update({'skin': aggregate, 'outsideAnnotatedSkin': background})
        groups.update({'skin/' + name: value for name, value in regions.items()})
    if frame['stock'] == 'proimage':
        require(frame['stem'] in skin.PROIMAGE_CONTROLS,
                f'Pro Image controls not annotated: {f["key"]}')
        require(target.shape[:2] == ANNOTATION_SHAPE, 'Pro Image control shape changed')
        for name, (x0, y0, x1, y1) in skin.PROIMAGE_CONTROLS[frame['stem']].items():
            mask = np.zeros(target.shape[:2], bool)
            mask[y0:y1, x0:x1] = True
            groups['control/' + name] = mask & valid
    for name, mask in groups.items():
        require(mask.any(), f'Empty region {name}: {f["key"]}')
    return target, groups, tiles


def score_groups(baseline, candidate, target, groups, tiles):
    images = [skin.blur(a) for a in (baseline, candidate, target)]
    rows = {}
    for name, mask in groups.items():
        rows[name] = {}
        for split, selected in (('all', mask), ('train', mask & tiles), ('test', mask & ~tiles)):
            # Tiny anatomical masks can contain no pixels in one tile split.
            rows[name][split] = comparison(*images, selected) if selected.any() else None
    return rows


def clipping(image, mask):
    values = image[mask]
    return dict(pixels=int(mask.sum()),
                channelZeroFractionRGB=(values == 0).mean(0)[::-1].tolist(),
                channelMaxFractionRGB=(values == 1).mean(0)[::-1].tolist(),
                anyZeroFraction=float((values == 0).any(1).mean()),
                anyMaxFraction=float((values == 1).any(1).mean()))


def write_png(path, array):
    path.parent.mkdir(parents=True, exist_ok=True)
    require(cv2.imwrite(str(path), np.round(np.clip(array, 0, 1) * 255).astype(np.uint8)),
            f'Could not write {path}')


def panel(images, labels, path, width=360):
    tiles = []
    for image, label in zip(images, labels):
        rgb = np.round(np.clip(image[:, :, ::-1], 0, 1) * 255).astype(np.uint8)
        tile = Image.fromarray(rgb)
        height = max(1, round(tile.height * width / tile.width))
        tile = tile.resize((width, height), Image.Resampling.LANCZOS)
        canvas = Image.new('RGB', (width, height + 26), '#eeeeee')
        canvas.paste(tile, (0, 26))
        ImageDraw.Draw(canvas).text((6, 6), label, fill='#111111')
        tiles.append(canvas)
    result = Image.new('RGB', (sum(t.width for t in tiles), max(t.height for t in tiles)), 'white')
    offset = 0
    for tile in tiles:
        result.paste(tile, (offset, 0))
        offset += tile.width
    path.parent.mkdir(parents=True, exist_ok=True)
    result.save(path, quality=92)


def visual_artifacts(destination, target, baseline, candidate, groups):
    write_png(destination / 'difference-x4.png', np.abs(candidate - baseline) * 4)
    panel([target, baseline, candidate, np.abs(candidate - baseline) * 4],
          ['Aligned edited reference', 'Baseline: Clean Invert', 'Matrix: same recipe', '|difference| x4'],
          destination / 'clean-comparison.jpg')
    names = [name for name in groups if name.startswith(('skin/', 'control/'))]
    if names:
        overlay_images = []
        for image in (target, baseline, candidate):
            overlay = image.copy()
            for name in names:
                mask = groups[name]
                tint = np.array([.15, .95, .15] if name.startswith('skin/') else [.95, .55, .10])
                overlay[mask] = overlay[mask] * .55 + tint * .45
                yy, xx = np.where(mask)
                cv2.putText(overlay, name.split('/', 1)[1], (int(xx.min()), max(12, int(yy.min()) - 3)),
                            cv2.FONT_HERSHEY_SIMPLEX, .35, (1, 1, 1), 1, cv2.LINE_AA)
            overlay_images.append(overlay)
        panel(overlay_images, ['Reference masks', 'Baseline masks', 'Matrix masks'],
              destination / 'region-overlays.jpg', width=600)
    crops = []
    for index, name in enumerate(names):
        yy, xx = np.where(groups[name])
        y0, y1 = max(0, yy.min() - 12), min(target.shape[0], yy.max() + 13)
        x0, x1 = max(0, xx.min() - 12), min(target.shape[1], xx.max() + 13)
        crop_path = destination / f'region-{index:02d}.jpg'
        panel([a[y0:y1, x0:x1] for a in (target, baseline, candidate)],
              [name + ': reference', 'Baseline', 'Matrix'], crop_path, width=300)
        crops.append(dict(name=name, image=str(crop_path), bounds=[int(x0), int(y0), int(x1), int(y1)]))
    return crops


def renderer_checks(metadata, name, failures, label, legacy=False):
    checks = metadata['renders'][name]
    parser = checks.get('appParser', {})
    if not legacy and (parser.get('exactParameters') is not True or parser.get('exactPixels') is not True):
        failures.append(dict(frame=label, stage='app-parser', message=f'{name}: {parser}'))
    metal = checks.get('metalParity', {})
    if metal.get('status') != 'passed':
        failures.append(dict(frame=label, stage='metal-parity', message=f'{name}: {metal}'))
    return dict(appParser=parser, metalParity=metal,
                decodedClipping=metadata['decodedClipping'], nativeRenderClipping=checks['clipping'],
                proxyRenderClipping=checks['proxyClipping'])


def frame_score(output, analysis, frame, annotations, failures):
    key = frame['stock'] + '/' + frame['stem']
    result = dict(frame=key, monochrome=bool(frame.get('monochrome', False)),
                  stock=frame['stock'], tiers={}, failures=[])
    directories = {(arm, tier): output / arm / tier / key for arm in ARMS for tier in TIERS}
    metadata = {(arm, tier): valid_metadata(directory, key, arm, tier, VARIANTS)
                for (arm, tier), directory in directories.items()}
    for tier in TIERS:
        check_geometry(metadata['baseline', tier], metadata['matrix', tier], key + '/' + tier)
    require(sha256(directories['baseline', 'preview'] / 'reference.png')
            == sha256(directories['matrix', 'preview'] / 'reference.png'),
            f'Reference pixels differ between arms: {key}')
    result['sourceMetadata'] = {
        tier: {arm: {field: metadata[arm, tier].get(field) for field in
                     ('rawWidth', 'rawHeight', 'rawChannels', 'rawSHA256', 'sourceImageSHA256',
                      'decodedClipping', 'scanClipping', 'decode')} for arm in ARMS} for tier in TIERS}
    scratch = analysis / 'registration' / 'baseline' / key
    baseline_alignment = register(directories['baseline', 'preview'], scratch, frame)
    result['registration'] = {'baseline': baseline_alignment, 'sharedBaselineTransformForScoring': True}
    try:
        candidate_alignment = register(directories['matrix', 'preview'],
                                       analysis / 'registration' / 'matrix' / key, frame)
        displacement = geometry_displacement(baseline_alignment, candidate_alignment)
        result['registration'].update(matrix=candidate_alignment, displacement=displacement)
        if displacement['reviewRequired']:
            result['failures'].append(dict(stage='candidate-registration-geometry', message=str(displacement)))
    except (ValueError, KeyError, OSError, cv2.error) as error:
        # Keep scores on the same source grid; a bad candidate cannot disappear.
        result['registration']['matrix'] = {'status': 'failed', 'error': str(error)}
        result['failures'].append(dict(stage='candidate-registration', message=str(error)))
    target, groups, tiles = scored_masks(scratch, frame, annotations)
    preview_images = {}
    full_images = {}
    for tier in TIERS:
        result['tiers'][tier] = {}
        for name in VARIANTS:
            a_dir, b_dir = directories['baseline', tier], directories['matrix', tier]
            recipe = parameters(a_dir, name)
            require(recipe == parameters(b_dir, name), f'Fixed recipe mismatch: {key}/{tier}/{name}')
            require(recipe == parameters(directories['baseline', 'preview'], name),
                    f'Preview/full recipe mismatch: {key}/{tier}/{name}')
            images = [read_image(directories[arm, tier], name, metadata[arm, tier]) for arm in ARMS]
            require(all(image.shape == target.shape for image in images),
                    f'Preview/full scoring-grid mismatch: {key}/{tier}/{name}')
            record = dict(parametersEqual=True, parametersSHA256=sha256(a_dir / f'{name}.json'),
                          groups=score_groups(*images, target, groups, tiles),
                          clipping={arm: clipping(image, groups['whole']) for arm, image in zip(ARMS, images)},
                          nativeChecks={arm: renderer_checks(metadata[arm, tier], name, failures,
                                                              key + '/' + arm + '/' + tier) for arm in ARMS})
            result['tiers'][tier][name] = record
            (preview_images if tier == 'preview' else full_images)[name] = images
        if tier == 'full':
            for arm in ARMS:
                jpeg = metadata[arm, tier]['renders']['clean'].get('jpeg')
                require(jpeg and jpeg['width'] == jpeg['readbackWidth']
                        and jpeg['height'] == jpeg['readbackHeight'], f'Missing/invalid full JPEG: {key}/{arm}')
                jpeg_path = directories[arm, tier] / 'clean.jpg'
                require(jpeg_path.is_file(), f'Missing full-resolution JPEG: {jpeg_path}')
                with Image.open(jpeg_path) as image:
                    require(image.size == (jpeg['width'], jpeg['height']), f'JPEG geometry differs: {jpeg_path}')
                require(jpeg.get('sha256') == sha256(jpeg_path), f'JPEG hash differs: {jpeg_path}')
            result['fullExports'] = {arm: metadata[arm, tier]['renders']['clean']['jpeg'] for arm in ARMS}
    result['previewVsFull'] = {}
    for name in VARIANTS:
        proxies, full = preview_images[name], full_images[name]
        mask = groups['whole']
        proxy_delta = skin.blur(proxies[1]) - skin.blur(proxies[0])
        full_delta = skin.blur(full[1]) - skin.blur(full[0])
        result['previewVsFull'][name] = dict(
            arms={arm: score_blurred(skin.blur(f), skin.blur(p), mask)
                  for arm, p, f in zip(ARMS, proxies, full)},
            matrixDeltaDifferenceMAE=float(np.abs(full_delta[mask] - proxy_delta[mask]).mean() * 255),
            matrixDeltaPreviewMAE=float(np.abs(proxy_delta[mask]).mean() * 255),
            matrixDeltaFullMAE=float(np.abs(full_delta[mask]).mean() * 255),
            sameReferenceErrorDirection=bool(
                result['tiers']['preview'][name]['groups']['whole']['all']['rgbMAEChange']
                * result['tiers']['full'][name]['groups']['whole']['all']['rgbMAEChange'] >= 0))
    review = analysis / 'frames' / key
    result['regionCrops'] = visual_artifacts(review, target, *preview_images['clean'], groups)
    for tier, images in (('preview', preview_images), ('full', full_images)):
        for name in VARIANTS:
            write_png(review / f'{tier}-{name}-difference-x4.png', np.abs(images[name][1] - images[name][0]) * 4)
    result['reviewDirectory'] = str(review)
    for failure in result['failures']:
        failures.append(dict(frame=key, **failure))
    save(review / 'scores.json', result)
    return result


def preference_scores(output, analysis, failures):
    ledger = load(ROOT / 'docs/development/color-preference-checkpoints.json')
    results = []
    for frame in ledger['frames']:
        key = frame['stock'] + '/' + frame['frame']
        names = [entry['variant'] for entry in frame['candidates']]
        for candidate in frame['candidates']:
            name = candidate['variant']
            record = dict(frame=key, variant=name, expectedBaselinePNGHash=candidate['imageSHA256'], tiers={})
            rendered = {}
            try:
                for tier, folder in (('preview', 'preferences'), ('full', 'full-preferences')):
                    dirs = {arm: output / arm / folder / key for arm in ARMS}
                    meta = {arm: valid_metadata(dirs[arm], key, arm, tier, names) for arm in ARMS}
                    check_geometry(meta['baseline'], meta['matrix'], 'preferences/' + key + '/' + tier)
                    require(parameters(dirs['baseline'], name) == parameters(dirs['matrix'], name),
                            f'Preference parameters differ between arms: {key}/{name}/{tier}')
                    require(parameters(dirs['baseline'], name)
                            == parameters(output / 'baseline' / 'preferences' / key, name),
                            f'Preference preview/full settings differ: {key}/{name}')
                    images = [read_image(dirs[arm], name, meta[arm]) for arm in ARMS]
                    require(images[0].shape == images[1].shape, 'Preference render shape mismatch')
                    rendered[tier] = images
                    mask = np.ones(images[0].shape[:2], bool)
                    delta = score_blurred(skin.blur(images[1]), skin.blur(images[0]), mask)
                    hashes = {arm: sha256(dirs[arm] / f'{name}.png') for arm in ARMS}
                    # The threshold is a review flag, never an aesthetic acceptance criterion.
                    material = delta['rgbMAE'] > 1 or max(abs(v) for v in delta['meanRGBDifference']) > 1
                    native = {arm: renderer_checks(meta[arm], name, failures,
                                                   'preferences/' + key + '/' + arm + '/' + tier, legacy=True)
                              for arm in ARMS}
                    record['tiers'][tier] = dict(pngSHA256=hashes, matrixVsBaseline=delta,
                                                  exactPixelEquality=bool(np.array_equal(*images)),
                                                  materialAppearanceReview=material, nativeChecks=native)
                    destination = analysis / 'preferences' / key
                    panel([*images, np.abs(images[1] - images[0]) * 4],
                          ['Frozen baseline: ' + name, 'Upstream matrix: same settings', '|difference| x4'],
                          destination / f'{tier}-{name}.jpg')
                    if tier == 'preview':
                        matched = hashes['baseline'] == candidate['imageSHA256']
                        record['baselineCheckpointMatch'] = matched
                        if not matched:
                            failures.append(dict(frame=key, stage='preference-checkpoint',
                                                 message=f'{name}: baseline PNG differs from ledger; inspect source/environment'))
                mask = np.ones(rendered['preview'][0].shape[:2], bool)
                require(all(a.shape == rendered['preview'][0].shape for a in rendered['full']),
                        'Preference preview/full geometry differs')
                record['previewVsFull'] = {
                    arm: score_blurred(skin.blur(f), skin.blur(p), mask)
                    for arm, p, f in zip(ARMS, rendered['preview'], rendered['full'])}
            except (ValueError, KeyError, OSError, cv2.error) as error:
                record['error'] = str(error)
                failures.append(dict(frame=key, stage='preference-data', message=f'{name}: {error}'))
            results.append(record)
    return results


def aggregates(frames):
    cohorts = {'allColor': [f for f in frames if not f['monochrome']],
               'monochrome': [f for f in frames if f['monochrome']]}
    for stock in sorted({f['stock'] for f in frames}):
        cohorts['stock/' + stock] = [f for f in frames if f['stock'] == stock]
    result = {}
    for cohort, selected in cohorts.items():
        if not selected:
            continue
        result[cohort] = {'frames': len(selected), 'tiers': {}}
        for tier in TIERS:
            result[cohort]['tiers'][tier] = {}
            for name in VARIANTS:
                splits = {}
                for split in ('all', 'train', 'test'):
                    rows = [f['tiers'][tier][name]['groups']['whole'][split] for f in selected]
                    splits[split] = dict(
                        baselineRGBMAE=float(np.mean([r['baseline']['rgbMAE'] for r in rows])),
                        matrixRGBMAE=float(np.mean([r['matrix']['rgbMAE'] for r in rows])),
                        meanRGBMAEChange=float(np.mean([r['rgbMAEChange'] for r in rows])),
                        improvedFrames=sum(r['rgbMAEChange'] < 0 for r in rows),
                        worsenedFrames=sum(r['rgbMAEChange'] > 0 for r in rows),
                        regressionFlagFrames=sum(r['regression'] for r in rows))
                result[cohort]['tiers'][tier][name] = splits
    return result


def regression_rows(frames):
    rows = []
    for frame in frames:
        for tier in TIERS:
            for name, variant in frame['tiers'][tier].items():
                for region, splits in variant['groups'].items():
                    for split, values in splits.items():
                        if values and values['regression']:
                            rows.append(dict(frame=frame['frame'], tier=tier, variant=name,
                                             region=region, split=split,
                                             baselineRGBMAE=values['baseline']['rgbMAE'],
                                             matrixRGBMAE=values['matrix']['rgbMAE'],
                                             rgbMAEChange=values['rgbMAEChange']))
    return rows


def make_contact_sheets(analysis, frames):
    result = []
    for cohort, mono in (('color', False), ('monochrome', True)):
        selected = [f for f in frames if f['monochrome'] == mono]
        for start in range(0, len(selected), 8):
            rows = []
            for frame in selected[start:start + 8]:
                path = Path(frame['reviewDirectory']) / 'clean-comparison.jpg'
                with Image.open(path) as image:
                    image = image.copy()
                row = Image.new('RGB', (image.width, image.height + 24), 'white')
                row.paste(image, (0, 24))
                ImageDraw.Draw(row).text((6, 5), frame['frame'], fill='black')
                rows.append(row)
            sheet = Image.new('RGB', (max(row.width for row in rows), sum(row.height for row in rows)), 'white')
            y = 0
            for row in rows:
                sheet.paste(row, (0, y))
                y += row.height
            path = analysis / f'contact-{cohort}-{start // 8 + 1}.jpg'
            sheet.save(path, quality=90)
            result.append(str(path))
    return result


def gallery(output, analysis, report):
    def url(path):
        return quote(str(Path(path).relative_to(analysis)))

    def render_url(arm, tier, key, name):
        return '../' + quote(f'{arm}/{tier}/{key}/{name}.png')

    def image(path, alt):
        return f'<a href="{path}"><img loading="lazy" src="{path}" alt="{html.escape(alt)}"></a>'

    parts = ['<!doctype html><meta charset="utf-8"><title>X-T5 upstream matrix A/B</title>',
             '<style>body{font:15px system-ui;margin:28px;background:#f5f4f1;color:#222} '
             'h1,h2{font-weight:650}table{border-collapse:collapse;width:100%;background:white;margin:12px 0}'
             'td,th{padding:7px;border:1px solid #ddd;text-align:right}td:first-child,th:first-child{text-align:left}'
             '.grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:8px}.grid img{width:100%}'
             'img.wide{max-width:100%;height:auto}.bad{color:#a12624}.good{color:#176636}'
             'section{background:#fff;padding:18px;margin:24px 0}summary{cursor:pointer;padding:8px}'
             'a{color:#245987}pre{white-space:pre-wrap} .small{font-size:13px}</style>',
             '<h1>X-T5 upstream camera matrix: fixed-recipe A/B</h1>',
             f'<p>Status: <b>{html.escape(report["status"])}</b>. Scored {len(report["frames"])} of '
             f'{report["expectedFrames"]} complete pairs. No fitting or recipe selection.</p>',
             '<p>All errors are mean absolute display RGB differences in 0–255 levels after Gaussian blur σ=1.2; '
             'these are edited-reference appearance differences, not Delta E or calibrated color accuracy. '
             'Primary comparison: Clean Invert, equally weighted photographs. Train/test tiles are reported separately '
             'for consistency; neither selects a candidate. The matrix arm uses the baseline registration and masks.</p>',
             '<p>Full results include all three fixed recipes, individual skin regions, Pro Image control patches, '
             'raw/render clipping, parser/Metal checks, full-size export metadata and preview/full agreement. '
             'A lower reference error cannot override the five preferred looks. Material preference change uses a '
             '&gt;1-level flag for review, not automatic acceptance.</p>',
             '<p><a href="scores.json">Complete machine-readable report</a> · '
             '<a href="regressions.json">Every regression flag</a></p>']
    if report['failures']:
        parts.append('<details open><summary class="bad">Failures and review gates</summary><ul>')
        parts.extend('<li>' + html.escape(f'{f["frame"]}: {f["stage"]}: {f["message"]}') + '</li>'
                     for f in report['failures'])
        parts.append('</ul></details>')
    parts.append('<h2>Clean Invert macro averages</h2><table><tr><th>Cohort</th><th>Frames</th>'
                 '<th>Preview baseline</th><th>Preview matrix</th><th>Δ</th><th>Full baseline</th><th>Full matrix</th><th>Δ</th></tr>')
    for name, cohort in report['aggregates'].items():
        values = [cohort['tiers'][tier]['clean']['all'] for tier in TIERS]
        cells = ''.join(f'<td>{v[key]:.2f}</td>' for v in values
                        for key in ('baselineRGBMAE', 'matrixRGBMAE', 'meanRGBMAEChange'))
        parts.append(f'<tr><td>{html.escape(name)}</td><td>{cohort["frames"]}</td>{cells}</tr>')
    parts.append('</table><h2>Contact sheets</h2><p>' + ' · '.join(
        f'<a href="{url(path)}">{html.escape(Path(path).stem)}</a>' for path in report['contactSheets']) + '</p>')
    parts.append('<h2>Frozen preferences</h2>')
    for pref in report['preferences']:
        parts.append(f'<section><h3>{html.escape(pref["frame"])} / {html.escape(pref["variant"])}</h3>')
        parts.append(f'<p>Baseline PNG matches frozen ledger: <b>{pref.get("baselineCheckpointMatch", False)}</b>.</p>')
        for tier, values in pref['tiers'].items():
            delta = values['matrixVsBaseline']['rgbMAE']
            path = analysis / 'preferences' / pref['frame'] / f'{tier}-{pref["variant"]}.jpg'
            parts.append(f'<p>{tier}: matrix changes frozen appearance by {delta:.2f} RGB levels; '
                         f'material review flag: {values["materialAppearanceReview"]}.</p>')
            parts.append(f'<img class="wide" loading="lazy" src="{url(path)}">')
        parts.append('</section>')
    parts.append('<h2>Individual frames</h2>')
    for frame in report['frames']:
        key = frame['frame']
        review = Path(frame['reviewDirectory'])
        target = analysis / 'registration' / 'baseline' / key / 'aligned-reference.png'
        parts.append(f'<section id="{html.escape(key)}"><h3>{html.escape(key)}</h3>')
        registration = frame['registration']
        parts.append('<p class="small">Registration: baseline '
                     f'{registration["baseline"]["inliers"]} inliers, residual '
                     f'{registration["baseline"]["medianResidualPixels"]:.3f}px. Candidate displacement: '
                     + html.escape(json.dumps(registration.get('displacement', registration['matrix']))) + '</p>')
        parts.append('<table><tr><th>Tier / recipe</th><th>Baseline all</th><th>Matrix all</th><th>Δ all</th>'
                     '<th>Δ train</th><th>Δ test</th><th>Changed RGB</th><th>Flag</th></tr>')
        for tier in TIERS:
            for name in VARIANTS:
                scores = frame['tiers'][tier][name]['groups']['whole']
                all_ = scores['all']
                cells = [all_['baseline']['rgbMAE'], all_['matrix']['rgbMAE'], all_['rgbMAEChange'],
                         scores['train']['rgbMAEChange'], scores['test']['rgbMAEChange'],
                         all_['matrixVsBaseline']['rgbMAE']]
                parts.append(f'<tr><td>{tier} / {name}</td>' + ''.join(f'<td>{x:.2f}</td>' for x in cells)
                             + f'<td>{all_["regression"]}</td></tr>')
        parts.append('</table>')
        for name in VARIANTS:
            if name != 'clean':
                parts.append(f'<details><summary>{name} comparison</summary>')
            parts.append('<div class="grid">' + image(url(target), 'Aligned reference')
                         + image(render_url('baseline', 'preview', key, name), 'Baseline ' + name)
                         + image(render_url('matrix', 'preview', key, name), 'Matrix ' + name)
                         + image(url(review / f'preview-{name}-difference-x4.png'), 'Absolute difference x4') + '</div>')
            if name != 'clean':
                parts.append('</details>')
        if frame['regionCrops']:
            parts.append('<details><summary>Fresh masks and anatomical/control crops</summary>')
            parts.append(f'<img class="wide" loading="lazy" src="{url(review / "region-overlays.jpg")}">')
            for crop in frame['regionCrops']:
                scores = frame['tiers']['preview']['clean']['groups'][crop['name']]['all']
                parts.append(f'<p>{html.escape(crop["name"])}: '
                             f'{scores["baseline"]["rgbMAE"]:.2f} → {scores["matrix"]["rgbMAE"]:.2f} '
                             f'(Δ {scores["rgbMAEChange"]:+.2f}); regression flag {scores["regression"]}.</p>')
                parts.append(f'<img class="wide" loading="lazy" src="{url(crop["image"])}">')
            parts.append('</details>')
        parts.append('<details><summary>Clipping, native checks and full-size agreement</summary><pre>'
                     + html.escape(json.dumps(dict(
                         previewVsFull=frame['previewVsFull'],
                         clean={tier: {k: v for k, v in frame['tiers'][tier]['clean'].items()
                                       if k in ('clipping', 'nativeChecks')} for tier in TIERS},
                         fullExports=frame['fullExports']), indent=2)) + '</pre></details>')
        parts.append(f'<p><a href="{url(review / "scores.json")}">Frame JSON</a> · '
                     f'<a href="../baseline/full/{quote(key)}/clean.jpg">Baseline full JPEG</a> · '
                     f'<a href="../matrix/full/{quote(key)}/clean.jpg">Matrix full JPEG</a></p></section>')
    parts.append('<h2>Exclusions</h2><pre>' + html.escape(json.dumps(report['exclusions'], indent=2)) + '</pre>')
    (analysis / 'index.html').write_text('\n'.join(parts) + '\n')


def run(output):
    analysis = output / 'analysis'
    analysis.mkdir(parents=True, exist_ok=True)
    inventory = load(output / 'inventory.json')
    frames = inventory['frames'] if isinstance(inventory, dict) else inventory
    incomplete = inventory.get('incomplete', []) if isinstance(inventory, dict) else []
    require(isinstance(frames, list) and frames, 'Inventory has no frames')
    keys = [f['stock'] + '/' + f['stem'] for f in frames]
    require(len(set(keys)) == len(keys), 'Duplicate frame keys')
    require(all(not Path(k).is_absolute() and '..' not in Path(k).parts for k in keys), 'Unsafe frame key')
    annotations = load(Path(__file__).with_name('skin-regions.json'))['frames']
    failures, scored, exclusions = [], [], []
    for frame in frames:
        key = frame['stock'] + '/' + frame['stem']
        print(f'Scoring {key}', flush=True)
        try:
            scored.append(frame_score(output, analysis, frame, annotations, failures))
        except (ValueError, KeyError, OSError, cv2.error) as error:
            failure = dict(frame=key, stage='frame-data-or-baseline-registration', message=str(error))
            failures.append(failure)
            exclusions.append(failure)
    preferences = preference_scores(output, analysis, failures)
    expected_preferences = sum(len(f['candidates']) for f in load(
        ROOT / 'docs/development/color-preference-checkpoints.json')['frames'])
    material_preferences = [dict(frame=p['frame'], variant=p['variant'], tier=tier)
                            for p in preferences for tier, data in p['tiers'].items()
                            if data['materialAppearanceReview']]
    report = dict(schemaVersion=1, status='failed' if failures else 'complete',
                  purpose='Fixed-recipe upstream X-T5 matrix comparison; no fitting or default change',
                  units='0–255 display RGB levels; sigma=1.2px; not Delta E',
                  primaryVariant='clean', aggregateWeighting='equal weight per photograph; color/B&W separate',
                  spatialSplit='(x // 32 + 2 * (y // 32)) % 4 != 0 selects training tiles; no fit or selection',
                  backgroundDefinition='central valid content outside annotated skin and 6px margin; can include unannotated skin',
                  annotationShape={'width': ANNOTATION_SHAPE[1], 'height': ANNOTATION_SHAPE[0]},
                  annotationReview='Fresh overlays require visual inspection; shape equality alone is not validation',
                  promotionEligible=False,
                  promotionLimit='Diagnostic evidence only. No new calibration/default validated; preferences override reference scores.',
                  expectedFrames=len(frames), expectedPreferences=expected_preferences,
                  incompleteInputPairs=incomplete, exclusions=exclusions, failures=failures,
                  frames=scored, preferences=preferences, materialPreferenceChanges=material_preferences,
                  aggregates=aggregates(scored), regressions=regression_rows(scored))
    report['contactSheets'] = make_contact_sheets(analysis, scored)
    save(analysis / 'scores.json', report)
    save(analysis / 'regressions.json', report['regressions'])
    gallery(output, analysis, report)
    print(f'{report["status"]}: {len(scored)}/{len(frames)} frames, '
          f'{len(preferences)}/{expected_preferences} preferences; {len(failures)} failures; '
          f'{len(material_preferences)} material preference changes', flush=True)
    print(analysis / 'index.html', flush=True)
    return 1 if failures else 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        sys.exit(run(args.output.resolve()))
    except (ValueError, KeyError, OSError, cv2.error) as error:
        parser.exit(1, f'Scoring failed: {error}\n')
