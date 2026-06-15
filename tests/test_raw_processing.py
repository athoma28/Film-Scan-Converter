import pickle
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from tests.support import import_raw_processing, make_processor


RawProcessing = import_raw_processing()


class RawProcessingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rng = np.random.default_rng(20260613)
        cls.image = rng.integers(0, 65536, (240, 360, 3), dtype=np.uint16)

    def test_default_process_skips_dust_detection(self):
        processor = make_processor(RawProcessing, self.image)
        processor.find_dust = lambda _: self.fail('dust detection should not run')

        processor.process()

        self.assertTrue(processor.processed)
        self.assertFalse(hasattr(processor, 'dust_mask'))

    def test_dust_mask_cache_and_invalidation(self):
        processor = make_processor(RawProcessing, self.image, remove_dust=True)
        calls = 0
        original = processor.find_dust

        def counted(image):
            nonlocal calls
            calls += 1
            return original(image)

        processor.find_dust = counted
        processor.process()
        first_mask = processor.dust_mask.copy()
        processor.process(skip_crop=True)
        self.assertEqual(calls, 1)
        np.testing.assert_array_equal(processor.dust_mask, first_mask)

        processor.class_parameters['dust_threshold'] += 1
        processor.process(skip_crop=True)
        self.assertEqual(calls, 2)

        processor._raw_revision += 1
        processor.process(skip_crop=True)
        self.assertEqual(calls, 3)

    def test_find_dust_matches_reference_implementation(self):
        processor = make_processor(RawProcessing, self.image)
        actual = processor.find_dust(self.image)
        expected = self.reference_find_dust(processor, self.image)

        np.testing.assert_array_equal(actual, expected)

    def test_histogram_matches_reference_implementation(self):
        processor = make_processor(RawProcessing, self.image)

        actual = processor.draw_histogram(self.image)
        expected = self.reference_draw_histogram(processor, self.image)

        np.testing.assert_array_equal(actual, expected)

    def test_histogram_statistics_cache_and_invalidation(self):
        processor = make_processor(RawProcessing, self.image, film_type=2)
        processor.rect = None
        crop_calls = 0
        original_crop = processor.crop

        def counted_crop(*args, **kwargs):
            nonlocal crop_calls
            crop_calls += 1
            return original_crop(*args, **kwargs)

        processor.crop = counted_crop
        first = processor.hist_EQ(self.image)
        second = processor.hist_EQ(self.image)

        self.assertEqual(crop_calls, 1)
        np.testing.assert_array_equal(first, second)

        processor.gamma += 10
        third = processor.hist_EQ(self.image)
        self.assertEqual(crop_calls, 1)
        np.testing.assert_array_equal(first, third)

        processor.black_point += 1
        processor.hist_EQ(self.image)
        self.assertEqual(crop_calls, 2)

        processor._raw_revision += 1
        processor.hist_EQ(self.image)
        self.assertEqual(crop_calls, 3)

    def test_histogram_equalization_matches_reference_implementation(self):
        settings = (
            {'film_type': 0, 'black_point': 0, 'white_point': 0},
            {'film_type': 1, 'black_point': -35, 'white_point': 45},
            {
                'film_type': 2,
                'black_point': 20,
                'white_point': -15,
                'base_detect': 1,
                'base_rgb': (220, 180, 140),
            },
        )
        for values in settings:
            with self.subTest(settings=values):
                processor = make_processor(RawProcessing, self.image, **values)
                processor.rect = None
                source = (
                    cv2.cvtColor(self.image, cv2.COLOR_BGR2GRAY)
                    if processor.film_type == 0
                    else self.image
                )

                actual = processor.hist_EQ(source.copy())
                expected = self.reference_histogram_equalization(processor, source.copy())
                cached = processor.hist_EQ(source.copy())

                np.testing.assert_array_equal(actual, expected)
                np.testing.assert_array_equal(cached, expected)

    def test_exposure_matches_reference_for_neutral_and_adjusted_settings(self):
        rng = np.random.default_rng(17)
        images = (
            rng.random((120, 180, 3)) * 90000 - 10000,
            rng.integers(0, 65536, (120, 180, 3), dtype=np.uint16),
            rng.random((120, 180)) * 90000 - 10000,
            rng.integers(0, 65536, (120, 180), dtype=np.uint16),
        )
        processor = make_processor(RawProcessing, self.image)

        for image in images:
            for gamma, shadows, highlights in ((0, 0, 0), (35, -40, 60), (-75, 100, -100)):
                with self.subTest(
                    dtype=image.dtype,
                    gamma=gamma,
                    shadows=shadows,
                    highlights=highlights,
                ):
                    processor.gamma = gamma
                    processor.shadows = shadows
                    processor.highlights = highlights

                    actual = processor.exposure(image)
                    expected = self.reference_exposure(processor, image)

                    np.testing.assert_array_equal(actual, expected)

    def test_neutral_white_balance_returns_same_pixels(self):
        rng = np.random.default_rng(23)
        image = rng.random((120, 180, 3)) * 65535
        processor = make_processor(RawProcessing, self.image)

        actual = processor.wb_adjust_coeff(image)
        expected = np.multiply(image, np.array([1.0, 1.0, 1.0]))

        np.testing.assert_array_equal(actual, expected)

    def test_adjusted_white_balance_matches_reference(self):
        rng = np.random.default_rng(29)
        image = rng.random((120, 180, 3)) * 65535
        processor = make_processor(RawProcessing, self.image, temp=65, tint=-40)
        multiplier = 200
        coefficients = np.array([
            1 - processor.temp / multiplier + processor.tint / multiplier / 2,
            1 - processor.tint / multiplier,
            1 + processor.temp / multiplier + processor.tint / multiplier / 2,
        ])

        actual = processor.wb_adjust_coeff(image.copy())
        expected = np.multiply(image, coefficients)

        np.testing.assert_array_equal(actual, expected)

    def test_contour_zebra_generation_matches_reference(self):
        processor = make_processor(RawProcessing, self.image)
        processor.IMG = self.image
        processor.thresh = processor.get_threshold(self.image)
        processor.rect = None
        processor.largest_contour = None

        actual = processor.get_IMG('Contours', as_array=True)

        thresh_img = np.uint8(cv2.cvtColor(processor.thresh, cv2.COLOR_GRAY2BGR) / 2)
        thresh_img[:, :, 2] = 0
        indices = np.indices(thresh_img.shape[:2])
        zebra_width = int(np.max(indices) / 100)
        zebra = np.repeat(
            (np.mod(indices[0] + indices[1], zebra_width * 2) > zebra_width)[:, :, np.newaxis],
            3,
            axis=2,
        )
        thresh_img = np.where(zebra, 0, thresh_img)
        expected = cv2.addWeighted(
            cv2.convertScaleAbs(self.image, alpha=(255.0 / 65535.0)),
            1,
            thresh_img,
            0.2,
            0,
        )

        np.testing.assert_array_equal(actual, expected)

    def test_contour_zebra_generation_supports_small_images(self):
        image = self.image[:40, :60]
        processor = make_processor(RawProcessing, image)
        processor.IMG = image
        processor.thresh = processor.get_threshold(image)
        processor.rect = None
        processor.largest_contour = None

        actual = processor.get_IMG('Contours', as_array=True)

        self.assertEqual(actual.shape, image.shape)

    def test_threshold_matches_reference_implementation(self):
        processor = make_processor(RawProcessing, self.image)

        for dark, light in ((0, 100), (25, 100), (25, 75), (100, 100), (75, 25)):
            with self.subTest(dark=dark, light=light):
                processor.dark_threshold = dark
                processor.light_threshold = light
                actual = processor.get_threshold(self.image)
                expected = self.reference_threshold(processor, self.image)
                np.testing.assert_array_equal(actual, expected)

    def test_process_dispatches_by_film_type(self):
        methods = (
            'bw_negative_processing',
            'colour_negative_processing',
            'slide_processing',
            'crop_only',
        )

        for film_type, expected_method in enumerate(methods):
            with self.subTest(film_type=film_type):
                processor = make_processor(RawProcessing, self.image, film_type=film_type)
                processor.rect = None
                processor.thresh = np.zeros(self.image.shape[:2], dtype=np.uint8)
                calls = []
                for method in methods:
                    setattr(
                        processor,
                        method,
                        lambda image, method=method: calls.append(method) or image,
                    )

                processor.process(skip_crop=True)

                self.assertEqual(calls, [expected_method])

    def test_process_restores_active_process_count_after_exception(self):
        processor = make_processor(RawProcessing, self.image)
        processor.find_optimal_crop = mock.Mock(side_effect=RuntimeError('processing failed'))

        with self.assertRaisesRegex(RuntimeError, 'processing failed'):
            processor.process()

        self.assertEqual(processor.active_processes, 0)

    def test_export_raises_when_opencv_cannot_write_file(self):
        processor = make_processor(RawProcessing, self.image)
        processor.IMG = self.image
        processor.class_parameters['filetype'] = 'PNG'

        with tempfile.TemporaryDirectory() as directory:
            filename = f'{directory}/output'
            with mock.patch.object(cv2, 'imwrite', return_value=False):
                with self.assertRaisesRegex(OSError, 'Failed to write exported image'):
                    processor.export(filename)

    def test_add_frame_preserves_pixels_and_adds_white_border(self):
        image = self.image[:20, :30]
        processor = make_processor(RawProcessing, image)
        processor.class_parameters['frame'] = 10

        actual = processor.add_frame(image)

        self.assertEqual(actual.shape, (24, 34, 3))
        np.testing.assert_array_equal(actual[2:-2, 2:-2], image)
        self.assertTrue(np.all(actual[:2] == 65535))
        self.assertTrue(np.all(actual[-2:] == 65535))
        self.assertTrue(np.all(actual[:, :2] == 65535))
        self.assertTrue(np.all(actual[:, -2:] == 65535))

    def test_add_frame_fits_requested_aspect_ratio(self):
        image = self.image[:20, :30]
        processor = make_processor(RawProcessing, image)
        processor.class_parameters['fit_aspect_ratio'] = '1:1 (Square)'

        actual = processor.add_frame(image)

        self.assertEqual(actual.shape, (32, 32, 3))
        np.testing.assert_array_equal(actual[6:26, 1:31], image)

    def test_pickle_excludes_reproducible_image_arrays(self):
        processor = make_processor(RawProcessing, self.image)
        processor.IMG = self.image.copy()
        processor.proxy_RAW_IMG = self.image[::2, ::2].copy()
        processor.thresh = processor.get_threshold(self.image)
        processor.dust_mask = np.zeros(self.image.shape[:2], dtype=np.uint8)
        processor._dust_signature = ('cached',)
        processor._histogram_stats_signature = ('cached',)

        serialized = pickle.dumps(processor)
        restored = pickle.loads(serialized)

        self.assertLess(len(serialized), 4096)
        self.assertEqual(restored.film_type, processor.film_type)
        self.assertFalse(restored.processed)
        self.assertFalse(restored.proxy)
        for attribute in RawProcessing.memory_attributes:
            self.assertFalse(hasattr(restored, attribute), attribute)

    @staticmethod
    def reference_find_dust(processor, image):
        height, width, _ = image.shape
        multiplier = ((width + height) / 2) / 800
        max_dust_size = multiplier ** 2 * processor.class_parameters['max_dust_area']
        kernel_size = max(round(multiplier) * 2 + 1, 1)
        kernel = np.ones((kernel_size, kernel_size), np.uint8)
        x, y = (
            np.array(processor.class_parameters['ignore_border']) / 100 * image.shape[:2][::-1]
        ).astype(np.int32)
        sample = np.s_[:] if x * y == 0 else np.s_[y:-y, x:-x]

        image8 = cv2.convertScaleAbs(image, alpha=(255.0 / 65535.0))
        gray = cv2.cvtColor(image8, cv2.COLOR_BGR2GRAY)
        minimum = np.percentile(gray[sample], 0.5)
        maximum = np.percentile(gray[sample], 99.5)
        threshold = (
            (maximum - minimum) * processor.class_parameters['dust_threshold'] / 100 + minimum
        )
        _, threshold_image = cv2.threshold(gray, threshold, 255, cv2.THRESH_BINARY_INV)
        threshold_image = cv2.dilate(
            threshold_image, kernel, iterations=processor.class_parameters['dust_iter']
        )
        threshold_image = cv2.erode(
            threshold_image, kernel, iterations=processor.class_parameters['dust_iter']
        )
        contours, _ = cv2.findContours(threshold_image, 1, 2)
        contours = sorted(contours, key=lambda contour: cv2.contourArea(contour))
        smallest = [
            contour for contour in contours if cv2.contourArea(contour) < max_dust_size
        ]
        dust_mask = np.zeros_like(gray)
        dust_mask = cv2.drawContours(dust_mask, smallest, -1, 255, cv2.FILLED)
        return cv2.dilate(dust_mask, kernel, iterations=1)

    @staticmethod
    def reference_threshold(processor, image):
        image = cv2.convertScaleAbs(image, alpha=(255.0 / 65535.0))
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        dark_threshold = int(processor.dark_threshold / 100 * 255)
        _, dark = cv2.threshold(gray, dark_threshold, 255, 0)
        light_threshold = int(processor.light_threshold / 100 * 255)
        _, light = cv2.threshold(gray, light_threshold, 255, cv2.THRESH_BINARY_INV)
        threshold = cv2.bitwise_and(dark, light)
        kernel = np.ones((7, 7), np.uint8)
        return cv2.erode(threshold, kernel, iterations=2)

    @staticmethod
    def reference_draw_histogram(processor, image):
        plot = np.zeros(processor.class_parameters['histogram_plt_size'], np.uint8)
        width = processor.class_parameters['histogram_plt_size'][1]
        height = processor.class_parameters['histogram_plt_size'][0] - 10
        channels = cv2.split(image)
        colors = [(255, 0, 0), (0, 255, 0), (0, 0, 255)]
        histograms = []
        maximums = []

        for channel in channels:
            histogram = cv2.calcHist([channel], [0], None, [256], [0, 65536])
            maximums.append(np.max(histogram))
            histogram[1:-1] = cv2.GaussianBlur(histogram[1:-1], (5, 5), 0)
            histograms.append(np.squeeze(histogram))

        for histogram, color in zip(histograms, colors):
            if np.max(maximums) != 0:
                histogram = histogram / np.max(maximums) * height
            points = np.stack(
                (np.linspace(0, width, len(histogram)), histogram), -1
            ).reshape(-1, 1, 2).squeeze().tolist()
            points.insert(0, [0, 0])
            points.append([width, 0])
            new_plot = np.zeros(processor.class_parameters['histogram_plt_size'], np.uint8)
            new_plot = cv2.fillPoly(
                new_plot, np.array([points]).astype(np.int32), color=color
            )
            plot = plot + new_plot

        return plot

    @staticmethod
    def reference_exposure(processor, image):
        dtype = np.min_scalar_type(image)
        if np.issubdtype(dtype, np.integer) or dtype.type is np.bool_:
            dtype = np.promote_types(dtype, np.float32)
        normalized = np.ma.array(
            np.asarray(image),
            mask=np.ma.getmask(image),
            dtype=dtype,
            copy=True,
        )
        mask = np.ma.getmask(normalized)
        normalized = np.ma.array(
            np.clip(normalized.filled(65535), 0, 65535),
            mask=mask,
        )
        data = normalized.data
        data -= 0.0
        data /= 65535.0
        normalized = np.ma.array(data, mask=normalized.mask, copy=False)
        normalized = normalized.astype(np.float32, copy=False)

        normalized = (
            normalized ** (2 ** (-processor.gamma / 100))
        ).astype(np.float32, copy=False)
        shadows_coefficient = 4.15e-5 * processor.shadows ** 2 + 0.02185 * processor.shadows
        normalized += (
            shadows_coefficient * np.minimum(normalized - 0.75, 0) ** 2
        ) * normalized
        highlights_coefficient = (
            -4.15e-5 * processor.highlights ** 2 + 0.02185 * processor.highlights
        )
        normalized += (
            highlights_coefficient * np.maximum(normalized - 0.25, 0) ** 2
        ) * (1 - normalized)
        return np.ma.getdata(normalized, False) * 65535

    @staticmethod
    def reference_histogram_equalization(processor, image):
        sensitivity = 0.2
        sample = processor.crop(image, processor.rect, include_EQ_ignore=True)

        if processor.base_detect and processor.film_type in (1, 2):
            if processor.film_type == 1:
                black_point = 65535 - np.array(processor.base_rgb, np.uint16)[::-1] * 256
            else:
                black_point = np.array(processor.base_rgb, np.uint16)[::-1] * 256
        else:
            black_point = np.percentile(
                sample,
                processor.class_parameters['black_point_percentile'],
                (0, 1),
            )
        black_offsets = processor.black_point / 100 * sensitivity * 65535 - black_point
        image = image.astype(np.float64, copy=False)
        sample = sample.astype(np.float32, copy=False)
        image[:, :] += black_offsets
        sample[:, :] += black_offsets

        maximums = np.ones_like(black_offsets)
        white_point = np.percentile(
            sample,
            processor.class_parameters['white_point_percentile'],
            (0, 1),
        )
        white_multipliers = np.divide(
            65535 + processor.white_point / 100 * sensitivity * 65535,
            white_point,
            out=maximums,
            where=white_point > 0,
        )
        return np.multiply(image, white_multipliers)
