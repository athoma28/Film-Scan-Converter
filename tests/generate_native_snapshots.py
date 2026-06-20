"""Generate frozen fixtures consumed by FilmScanEngine Swift tests.

Covers: rotate/flip, add_frame, standard image decode (PNG/BMP/JPEG/TIFF),
threshold generation, and floating-point correction stages.
"""

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tests.support import import_raw_processing, make_processor


RawProcessing = import_raw_processing()


def sha256(array):
    return hashlib.sha256(array.tobytes(order='C')).hexdigest()


def write_case(output_dir, name, stage, source, expected, parameters, elapsed_ms):
    case_dir = output_dir / name
    case_dir.mkdir(parents=True, exist_ok=True)
    np.save(case_dir / 'input.npy', source)
    np.save(case_dir / 'expected.npy', expected)
    metadata = {
        'schemaVersion': 1,
        'stage': stage,
        'inputShape': list(source.shape),
        'outputShape': list(expected.shape),
        'dtype': str(expected.dtype),
        'inputSHA256': sha256(source),
        'outputSHA256': sha256(expected),
        'parameters': parameters,
        'renderingMilliseconds': elapsed_ms,
        'generator': 'tests/generate_native_snapshots.py',
    }
    (case_dir / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')


def measured(function):
    start = time.perf_counter()
    result = function()
    return result, (time.perf_counter() - start) * 1000


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--output-dir',
        type=Path,
        default=Path('native/FilmScanEngine/Tests/FilmScanEngineTests/Fixtures'),
    )
    args = parser.parse_args()

    rng = np.random.default_rng(0)
    source = rng.integers(0, 65536, size=(8, 12, 3), dtype=np.uint16)

    rotate_processor = make_processor(RawProcessing, source, rotation=1, flip=True)
    rotated, elapsed = measured(lambda: rotate_processor.rotate(source))
    write_case(
        args.output_dir,
        'rotate_flip',
        'rotate',
        source,
        rotated,
        {'rotation': 1, 'flip': True},
        elapsed,
    )

    png8 = np.array(
        [
            [[0, 64, 255], [15, 127, 240], [30, 200, 10]],
            [[255, 1, 128], [90, 80, 70], [5, 4, 3]],
        ],
        dtype=np.uint8,
    )
    png_dir = args.output_dir / 'decode_png8'
    png_dir.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(png_dir / 'input.png'), png8)
    png_expected = cv2.imread(str(png_dir / 'input.png'), cv2.IMREAD_UNCHANGED).astype(np.uint16) * 256
    np.save(png_dir / 'expected.npy', png_expected)

    bmp_dir = args.output_dir / 'decode_bmp8'
    bmp_dir.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(bmp_dir / 'input.bmp'), png8)
    bmp_expected = cv2.imread(str(bmp_dir / 'input.bmp'), cv2.IMREAD_UNCHANGED).astype(np.uint16) * 256
    np.save(bmp_dir / 'expected.npy', bmp_expected)

    jpeg8 = np.fromfunction(
        lambda y, x, channel: (y * 29 + x * 17 + channel * 71) % 256,
        (8, 8, 3),
        dtype=int,
    ).astype(np.uint8)
    jpeg_dir = args.output_dir / 'decode_jpeg8'
    jpeg_dir.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(jpeg_dir / 'input.jpg'), jpeg8, [cv2.IMWRITE_JPEG_QUALITY, 100])
    jpeg_expected = cv2.imread(str(jpeg_dir / 'input.jpg'), cv2.IMREAD_UNCHANGED).astype(np.uint16) * 256
    np.save(jpeg_dir / 'expected.npy', jpeg_expected)

    grayscale8 = np.array(
        [[0, 63, 127], [128, 200, 255]],
        dtype=np.uint8,
    )
    grayscale_dir = args.output_dir / 'decode_grayscale_png8'
    grayscale_dir.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(grayscale_dir / 'input.png'), grayscale8)
    grayscale_expected = (
        cv2.imread(str(grayscale_dir / 'input.png'), cv2.IMREAD_UNCHANGED).astype(np.uint16) * 256
    )
    np.save(grayscale_dir / 'expected.npy', grayscale_expected)

    tiff16 = np.array(
        [
            [[0, 32768, 65535], [1, 257, 4096], [60000, 50000, 40000]],
            [[65535, 12345, 54321], [22222, 33333, 44444], [17, 31, 63]],
        ],
        dtype=np.uint16,
    )
    tiff_dir = args.output_dir / 'decode_tiff16'
    tiff_dir.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(tiff_dir / 'input.tiff'), tiff16)
    np.save(tiff_dir / 'expected.npy', cv2.imread(str(tiff_dir / 'input.tiff'), cv2.IMREAD_UNCHANGED))

    frame_processor = make_processor(RawProcessing, source)
    frame_processor.class_parameters['frame'] = 10
    frame_processor.class_parameters['fit_aspect_ratio'] = '3:2 (Landscape)'
    framed, elapsed = measured(lambda: frame_processor.add_frame(source))
    write_case(
        args.output_dir,
        'frame_aspect',
        'add_frame',
        source,
        framed,
        {'frame': 10, 'fit_aspect_ratio': '3:2 (Landscape)'},
        elapsed,
    )

    threshold_image = _build_threshold_image()
    threshold_processor = make_processor(RawProcessing, threshold_image)

    for dark, light in (
        (25, 100),
        (0, 100),
        (25, 75),
        (100, 100),
        (75, 25),
    ):
        threshold_processor.dark_threshold = dark
        threshold_processor.light_threshold = light
        params = {'dark_threshold': dark, 'light_threshold': light}
        result, elapsed = measured(
            lambda: threshold_processor.get_threshold(threshold_image)
        )
        write_case(
            args.output_dir,
            f'threshold_d{dark}_l{light}',
            'get_threshold',
            threshold_image,
            result.astype(np.uint16),
            params,
            elapsed,
        )

    dust_image = _build_dust_image()
    for name, parameters in (
        ('dust_mask_default', {
            'dust_threshold': 10,
            'max_dust_area': 15,
            'dust_iter': 5,
            'ignore_border': [0, 0],
        }),
        ('dust_mask_border_ignored', {
            'dust_threshold': 18,
            'max_dust_area': 28,
            'dust_iter': 2,
            'ignore_border': [12, 8],
        }),
        ('dust_mask_contour_area_gate', {
            'dust_threshold': 18,
            'max_dust_area': 20,
            'dust_iter': 2,
            'ignore_border': [12, 8],
        }),
    ):
        dust_processor = make_processor(RawProcessing, dust_image)
        dust_processor.class_parameters.update(parameters)
        result, elapsed = measured(lambda: dust_processor.find_dust(dust_image))
        write_case(
            args.output_dir,
            name,
            'find_dust',
            dust_image,
            result.astype(np.uint16),
            parameters,
            elapsed,
        )

    exposure_source = np.array(
        [
            [-1000.0, 0.0, 1.0, 8192.0],
            [16384.0, 32768.0, 49152.0, 65535.0],
            [65536.0, 70000.0, 12345.5, 54321.25],
        ],
        dtype=np.float64,
    )
    for name, gamma, shadows, highlights in (
        ('exposure_neutral', 0, 0, 0),
        ('exposure_gamma40', 40, 0, 0),
        ('exposure_shadows60', 0, 60, 0),
        ('exposure_highlightsm45', 0, 0, -45),
        ('exposure_combined', -35, 70, -55),
    ):
        exposure_processor = make_processor(
            RawProcessing,
            exposure_source,
            gamma=gamma,
            shadows=shadows,
            highlights=highlights,
        )
        result, elapsed = measured(lambda: exposure_processor.exposure(exposure_source))
        write_case(
            args.output_dir,
            name,
            'exposure',
            exposure_source,
            result.astype(np.float64),
            {'gamma': gamma, 'shadows': shadows, 'highlights': highlights},
            elapsed,
        )

    hist_source = rng.integers(0, 65536, size=(60, 80, 3), dtype=np.uint16)

    for name, film_type, black_point, white_point, base_detect, base_rgb in (
        ('histeq_bw_neutral', 0, 0, 0, 0, (255, 255, 255)),
        ('histeq_colour_neg', 1, -35, 45, 0, (255, 255, 255)),
        ('histeq_slide_base', 2, 20, -15, 1, (220, 180, 140)),
    ):
        proc = make_processor(
            RawProcessing, hist_source,
            film_type=film_type,
            black_point=black_point,
            white_point=white_point,
            base_detect=base_detect,
            base_rgb=base_rgb,
        )
        proc.rect = None
        proc.class_parameters['ignore_border'] = (0, 0)
        proc.class_parameters['ignore_neg_border'] = False

        input_uint16 = (
            cv2.cvtColor(hist_source, cv2.COLOR_BGR2GRAY)
            if film_type == 0
            else hist_source
        )
        result, elapsed = measured(lambda: proc.hist_EQ(input_uint16.copy()))
        write_case(
            args.output_dir,
            name,
            'histogram_equalisation',
            input_uint16,
            result,
            {
                'film_type': film_type,
                'black_point': black_point,
                'white_point': white_point,
                'base_detect': base_detect,
                'base_rgb': list(base_rgb),
            },
            elapsed,
        )


def _build_threshold_image():
    h, w = 80, 100
    img = np.zeros((h, w, 3), dtype=np.uint16)
    band = w // 5
    img[:, 0:band] = (4000, 4500, 5000)
    img[:, band : 2 * band] = (8000, 9000, 10000)
    img[:, 2 * band : 3 * band] = (25000, 28000, 31000)
    img[:, 3 * band : 4 * band] = (40000, 43000, 46000)
    img[:, 4 * band :] = (55000, 58000, 60000)
    img[15:30, :] = (60000, 55000, 50000)
    img[45:60, :] = (5000, 4000, 3000)
    return img


def _build_dust_image():
    height, width = 480, 640
    y, x = np.mgrid[:height, :width]
    base = 30000 + x * 18 + y * 9
    image = np.stack((base - 1800, base, base + 1400), axis=-1)
    image = np.clip(image, 0, 65535).astype(np.uint16)

    for center_x, center_y, radius, value in (
        (220, 135, 1, 650),
        (110, 90, 2, 900),
        (290, 205, 3, 1400),
        (470, 330, 4, 1200),
        (18, 24, 3, 700),
    ):
        disk = (x - center_x) ** 2 + (y - center_y) ** 2 <= radius ** 2
        image[disk] = value

    # A large dark object must be rejected by the maximum-particle-area gate.
    image[355:405, 85:145] = 1100
    return image


if __name__ == '__main__':
    main()
