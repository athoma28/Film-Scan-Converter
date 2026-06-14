"""Generate compact RawPy reference hashes for the representative RAF corpus."""

import argparse
import hashlib
import json
from pathlib import Path

import rawpy


def decode(path, full_resolution):
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
            half_size=not full_resolution,
        )
        color_description = raw.color_desc.decode('ascii').rstrip('\x00')
    return image[:, :, ::-1], color_description


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--raw-dir', type=Path, default=Path('sample-raw'))
    parser.add_argument('--full-resolution-file', default='DSCF0718.RAF')
    parser.add_argument(
        '--output',
        type=Path,
        default=Path(
            'native/FilmScanEngine/Tests/FilmScanEngineTests/Fixtures/'
            'raw_decode_reference.json'
        ),
    )
    args = parser.parse_args()

    entries = []
    for path in sorted(args.raw_dir.glob('*.RAF')):
        image, color_description = decode(path, full_resolution=False)
        entries.append(
            {
                'file': path.name,
                'shape': list(image.shape),
                'sha256': hashlib.sha256(image.tobytes(order='C')).hexdigest(),
                'colorDescription': color_description,
            }
        )
        print(f'{path.name}: {image.shape} {entries[-1]["sha256"]}')

    if not entries:
        raise SystemExit(f'No RAF files found in {args.raw_dir}')

    full_path = args.raw_dir / args.full_resolution_file
    if not full_path.exists():
        raise SystemExit(f'Full-resolution reference file not found: {full_path}')
    full_image, full_color_description = decode(full_path, full_resolution=True)
    full_resolution = {
        'file': full_path.name,
        'shape': list(full_image.shape),
        'sha256': hashlib.sha256(full_image.tobytes(order='C')).hexdigest(),
        'colorDescription': full_color_description,
    }
    print(f'{full_path.name} full: {full_image.shape} {full_resolution["sha256"]}')

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(
            {
                'schemaVersion': 1,
                'decoder': f'rawpy {rawpy.__version__} / LibRaw {rawpy.libraw_version}',
                'settings': {
                    'output_bps': 16,
                    'use_camera_wb': True,
                    'user_wb': [1, 1, 1, 1],
                    'demosaic_algorithm': 2,
                    'fbdd_noise_reduction': 0,
                    'output_color': 7,
                    'gamma': [2.222, 4.5],
                    'auto_bright_thr': 0,
                    'median_filter_passes': 0,
                    'noise_thr': 0,
                    'exp_preserve_highlights': 1,
                    'exp_shift': 8,
                    'half_size': True,
                },
                'entries': entries,
                'fullResolution': full_resolution,
            },
            indent=2,
        )
        + '\n'
    )


if __name__ == '__main__':
    main()
