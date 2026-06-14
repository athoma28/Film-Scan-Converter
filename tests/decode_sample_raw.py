"""Decode the representative RAF corpus using Film Scan Converter's RawPy settings."""

import argparse
import hashlib
import json
import statistics
import time
from pathlib import Path

import numpy as np
import rawpy


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--raw-dir', type=Path, default=Path('sample-raw'))
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--full-resolution', action='store_true')
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    results = []

    for path in sorted(args.raw_dir.glob('*.RAF')):
        samples = []
        for _ in range(args.repetitions):
            start = time.perf_counter()
            with rawpy.imread(str(path)) as raw:
                image = raw.postprocess(
                    output_bps=16,
                    use_camera_wb=True,
                    user_wb=[1, 1, 1, 1],
                    demosaic_algorithm=rawpy.DemosaicAlgorithm(2),
                    fbdd_noise_reduction=rawpy.FBDDNoiseReductionMode(0),
                    output_color=rawpy.ColorSpace(7),
                    gamma=(2.222, 4.5),
                    auto_bright_thr=0,
                    median_filter_passes=0,
                    noise_thr=0,
                    exp_preserve_highlights=1,
                    exp_shift=2 ** 3,
                    half_size=not args.full_resolution,
                )
            image = np.ascontiguousarray(image[:, :, ::-1])
            samples.append(time.perf_counter() - start)
        np.save(args.output_dir / f'{path.stem}.npy', image)
        result = {
            'file': path.name,
            'decoder': f'rawpy {rawpy.__version__} / LibRaw {rawpy.libraw_version}',
            'fullResolution': args.full_resolution,
            'shape': list(image.shape),
            'bytes': image.nbytes,
            'sha256': hashlib.sha256(image.tobytes(order='C')).hexdigest(),
            'minimum': int(image.min()),
            'maximum': int(image.max()),
            'channelMeansBGR': [float(value) for value in image.mean(axis=(0, 1))],
            'blackClipPercent': float(np.mean(image == 0) * 100),
            'whiteClipPercent': float(np.mean(image == 65535) * 100),
            'bestSeconds': min(samples),
            'medianSeconds': statistics.median(samples),
            'samplesSeconds': samples,
        }
        results.append(result)
        print(
            f'{path.name}: best={result["bestSeconds"]:.4f}s '
            f'median={result["medianSeconds"]:.4f}s {image.shape} {image.nbytes:,} bytes'
        )

    report = {
        'generatedAt': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'repetitions': args.repetitions,
        'fullResolution': args.full_resolution,
        'results': results,
    }
    (args.output_dir / 'decode_results.json').write_text(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
