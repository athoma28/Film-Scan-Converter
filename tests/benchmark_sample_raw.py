"""Benchmark representative RAF scans after decoding them to 16-bit BGR NumPy arrays.

Decode the RAFs with the application's RawPy settings, then run this script with:

    python3 tests/benchmark_sample_raw.py --decoded-dir /tmp/film_scan_corpus

The decoded directory must contain one ``<RAF stem>.npy`` file per manifest entry.
"""

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tests.support import import_raw_processing, make_processor


RawProcessing = import_raw_processing()

CORPUS = {
    'DSCF0669': {'film_type': 0, 'rotation': 3, 'scene': 'black-and-white night exterior'},
    'DSCF0718': {'film_type': 1, 'rotation': 1, 'scene': 'color negative outdoor daylight'},
    'DSCF0729': {'film_type': 1, 'rotation': 1, 'scene': 'color negative mixed indoor lighting'},
    'DSCF2417': {'film_type': 0, 'rotation': 0, 'scene': 'black-and-white daylight portrait'},
    'DSCF2422': {'film_type': 1, 'rotation': 3, 'scene': 'color negative indoor portrait'},
}

BW_PRESETS = {
    'neutral': {},
    'tonal_recovery': {
        'white_point': -12,
        'gamma': 12,
        'shadows': 25,
        'highlights': -35,
    },
    'contrast': {
        'black_point': -12,
        'white_point': 5,
        'gamma': 2,
        'shadows': -12,
        'highlights': 8,
    },
}

COLOR_PRESETS = {
    'DSCF0718': {
        'base_rgb': (163, 111, 67),
        'black_point': 15,
        'white_point': 10,
        'gamma': -5,
        'shadows': 0,
        'highlights': -20,
        'temp': 10,
        'tint': 0,
    },
    'DSCF0729': {
        'base_rgb': (169, 117, 74),
        'black_point': 5,
        'white_point': 10,
        'gamma': 20,
        'shadows': 30,
        'highlights': -20,
        'temp': 0,
        'tint': -5,
    },
    'DSCF2422': {
        'base_rgb': (197, 150, 111),
        'black_point': 10,
        'white_point': -10,
        'gamma': 20,
        'shadows': 30,
        'highlights': 10,
        'temp': 10,
        'tint': -10,
    },
}


def presets_for(stem, film_type):
    if film_type == 0:
        presets = dict(BW_PRESETS)
        presets['tonal_recovery_dust'] = {**BW_PRESETS['tonal_recovery'], 'remove_dust': True}
        return presets

    tuned = {'base_detect': 1, **COLOR_PRESETS[stem]}
    return {
        'neutral_auto': {},
        'manual_base': {'base_detect': 1, 'base_rgb': tuned['base_rgb']},
        'tuned': tuned,
        'tuned_cooler': {**tuned, 'temp': tuned['temp'] - 10},
        'tuned_dust': {**tuned, 'remove_dust': True},
    }


def clear_caches(processor):
    for attribute in RawProcessing.memory_attributes:
        if attribute not in ('RAW_IMG', 'proxy_RAW_IMG'):
            processor.__dict__.pop(attribute, None)


def measure(function, repetitions):
    samples = []
    for _ in range(repetitions):
        start = time.perf_counter()
        function()
        samples.append(time.perf_counter() - start)
    return {
        'best_seconds': min(samples),
        'median_seconds': statistics.median(samples),
        'samples_seconds': samples,
    }


def image_metrics(image):
    height, width = image.shape[:2]
    center = image[height // 10:-height // 10, width // 10:-width // 10]
    image8 = cv2.convertScaleAbs(center, alpha=255.0 / 65535.0)
    if image8.ndim == 2:
        gray = image8
        channel_medians = [float(np.median(image8))]
    else:
        gray = cv2.cvtColor(image8, cv2.COLOR_BGR2GRAY)
        channel_medians = [
            float(value) for value in np.median(image8.reshape(-1, 3), axis=0)[::-1]
        ]

    histogram = cv2.calcHist([gray], [0], None, [256], [0, 256]).ravel()
    probabilities = histogram[histogram > 0] / histogram.sum()
    percentiles = np.percentile(gray, [1, 5, 50, 95, 99])

    return {
        'gray_percentiles': [float(value) for value in percentiles],
        'black_clip_percent': float(np.mean(gray <= 1) * 100),
        'white_clip_percent': float(np.mean(gray >= 254) * 100),
        'gray_stddev': float(gray.std()),
        'entropy_bits': float(-np.sum(probabilities * np.log2(probabilities))),
        'laplacian_variance': float(cv2.Laplacian(gray, cv2.CV_64F).var()),
        'rgb_medians': channel_medians,
    }


def render_preview(image, path):
    if image.ndim == 2:
        image = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
    image8 = cv2.convertScaleAbs(image, alpha=255.0 / 65535.0)
    scale = min(1200 / image8.shape[1], 1200 / image8.shape[0], 1)
    preview = cv2.resize(
        image8,
        (int(image8.shape[1] * scale), int(image8.shape[0] * scale)),
        interpolation=cv2.INTER_AREA,
    )
    cv2.imwrite(str(path), preview, [cv2.IMWRITE_JPEG_QUALITY, 94])


def benchmark_edit(raw_image, metadata, settings, repetitions):
    processor = make_processor(RawProcessing, raw_image, **metadata, **settings)
    processor.class_parameters = processor.class_parameters.copy()
    processor.class_parameters['max_proxy_size'] = 100000

    def cold_process():
        clear_caches(processor)
        processor.proxy = False
        processor.process()

    cold = measure(cold_process, repetitions)
    warm = measure(lambda: processor.process(skip_crop=True), repetitions)
    render = measure(lambda: processor.get_IMG(as_array=True), repetitions)
    output = processor.get_IMG(as_array=True)

    return {
        'cold_process': cold,
        'warm_process': warm,
        'render': render,
        'quality': image_metrics(output),
        'output_shape': list(output.shape),
        'output_bytes': output.nbytes,
    }, output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--decoded-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, default=Path('/tmp/film_scan_benchmark'))
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    preview_dir = args.output_dir / 'previews'
    preview_dir.mkdir(exist_ok=True)
    report = {'corpus': CORPUS, 'results': {}}

    for stem, metadata in CORPUS.items():
        raw_image = np.load(args.decoded_dir / f'{stem}.npy')
        report['results'][stem] = {
            'scene': metadata['scene'],
            'decoded_shape': list(raw_image.shape),
            'decoded_bytes': raw_image.nbytes,
            'edits': {},
        }
        for name, settings in presets_for(stem, metadata['film_type']).items():
            result, output = benchmark_edit(raw_image, metadata, settings, args.repetitions)
            result['settings'] = settings
            report['results'][stem]['edits'][name] = result
            render_preview(output, preview_dir / f'{stem}_{name}.jpg')
            print(
                f'{stem} {name}: '
                f'cold={result["cold_process"]["best_seconds"]:.4f}s '
                f'warm={result["warm_process"]["best_seconds"]:.4f}s'
            )

    report_path = args.output_dir / 'results.json'
    report_path.write_text(json.dumps(report, indent=2))
    print(f'Wrote {report_path}')


if __name__ == '__main__':
    main()
