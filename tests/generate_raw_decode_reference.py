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
    parser.add_argument(
        '--file',
        action='append',
        dest='files',
        help=(
            'Relative RAF path to include; repeat for a compact representative '
            'corpus. Defaults to every RAF below --raw-dir.'
        ),
    )
    parser.add_argument(
        '--full-resolution-file',
        help='Relative path or unambiguous basename; defaults to the first selected RAF.',
    )
    parser.add_argument(
        '--output',
        type=Path,
        default=Path(
            'native/FilmScanEngine/Tests/FilmScanEngineTests/Fixtures/'
            'raw_decode_reference.json'
        ),
    )
    args = parser.parse_args()

    all_raws = sorted(
        candidate
        for candidate in args.raw_dir.rglob('*')
        if candidate.is_file() and candidate.suffix.lower() == '.raf'
    )

    def resolve_file(filename):
        relative = args.raw_dir / filename
        if relative.is_file():
            return relative
        matches = [path for path in all_raws if path.name == filename]
        if len(matches) != 1:
            description = 'not found' if not matches else 'ambiguous'
            raise SystemExit(f'RAF {filename} is {description} below {args.raw_dir}')
        return matches[0]

    selected_raws = (
        [resolve_file(filename) for filename in args.files]
        if args.files
        else all_raws
    )
    entries = []
    for path in selected_raws:
        image, color_description = decode(path, full_resolution=False)
        relative_path = path.relative_to(args.raw_dir).as_posix()
        entries.append(
            {
                'file': relative_path,
                'shape': list(image.shape),
                'sha256': hashlib.sha256(image.tobytes(order='C')).hexdigest(),
                'colorDescription': color_description,
            }
        )
        print(f'{relative_path}: {image.shape} {entries[-1]["sha256"]}')

    if not entries:
        raise SystemExit(f'No RAF files found in {args.raw_dir}')

    full_path = (
        resolve_file(args.full_resolution_file)
        if args.full_resolution_file
        else selected_raws[0]
    )
    full_image, full_color_description = decode(full_path, full_resolution=True)
    full_resolution = {
        'file': full_path.relative_to(args.raw_dir).as_posix(),
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
