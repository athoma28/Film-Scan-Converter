import os
import pickle
import time
import unittest

import numpy as np

from tests.support import import_raw_processing, make_processor


RawProcessing = import_raw_processing()


@unittest.skipUnless(
    os.environ.get('RUN_PERFORMANCE_TESTS') == '1',
    'set RUN_PERFORMANCE_TESTS=1 to run benchmarks',
)
class RawProcessingPerformanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rng = np.random.default_rng(20260613)
        cls.image = rng.integers(0, 65536, (2000, 3000, 3), dtype=np.uint16)

    def test_report_core_pipeline_timings(self):
        processor = make_processor(RawProcessing, self.image)
        default_process = self.benchmark(lambda: processor.process(), repetitions=8)

        processor = make_processor(RawProcessing, self.image, remove_dust=True)
        dust_process = self.benchmark_fresh_dust(processor, repetitions=5)
        cached_dust_process = self.benchmark(
            lambda: processor.process(skip_crop=True), repetitions=10
        )

        processor.IMG = self.image
        histogram = self.benchmark(lambda: processor.draw_histogram(self.image), repetitions=5)
        exposure = self.benchmark(lambda: processor.exposure(self.image), repetitions=8)
        threshold = self.benchmark(lambda: processor.get_threshold(self.image), repetitions=8)

        modes = []
        for film_type in range(4):
            mode_processor = make_processor(RawProcessing, self.image, film_type=film_type)
            mode_processor.rect = None
            mode_processor.thresh = np.zeros(self.image.shape[:2], np.uint8)
            cold = self.benchmark(
                lambda processor=mode_processor: self.process_without_caches(processor),
                repetitions=4,
            )
            warm = self.benchmark(
                lambda processor=mode_processor: processor.process(skip_crop=True),
                repetitions=8,
            )
            modes.append((film_type, cold, warm))

        serialized_processor = make_processor(RawProcessing, self.image)
        serialized_processor.IMG = self.image.copy()
        optimized_pickle_size = len(pickle.dumps(serialized_processor))
        raw_array_bytes = serialized_processor.RAW_IMG.nbytes + serialized_processor.IMG.nbytes

        print(
            '\nPerformance report'
            f'\n  default process: {default_process:.6f}s'
            f'\n  dust process: {dust_process:.6f}s'
            f'\n  cached dust process: {cached_dust_process:.6f}s'
            f'\n  histogram: {histogram:.6f}s'
            f'\n  neutral exposure: {exposure:.6f}s'
            f'\n  threshold: {threshold:.6f}s'
            f'\n  export task pickle: {optimized_pickle_size:,} bytes'
            f'\n  excluded image arrays: {raw_array_bytes:,} bytes'
            + ''.join(
                f'\n  film mode {film_type} cold/warm: {cold:.6f}s / {warm:.6f}s'
                for film_type, cold, warm in modes
            )
        )

    @staticmethod
    def benchmark(function, repetitions):
        times = []
        for _ in range(repetitions):
            start = time.perf_counter()
            function()
            times.append(time.perf_counter() - start)
        return min(times)

    @staticmethod
    def benchmark_fresh_dust(processor, repetitions):
        times = []
        for _ in range(repetitions):
            for attribute in ('dust_mask', '_dust_signature'):
                if hasattr(processor, attribute):
                    delattr(processor, attribute)
            start = time.perf_counter()
            processor.process()
            times.append(time.perf_counter() - start)
        return min(times)

    @staticmethod
    def process_without_caches(processor):
        for attribute in (
            '_histogram_stats_signature',
            '_histogram_black_offsets',
            '_histogram_white_point',
        ):
            if hasattr(processor, attribute):
                delattr(processor, attribute)
        processor.process(skip_crop=True)
