"""Small scientific-analysis contract checks; no Swift build or private inputs."""

import unittest
import warnings
import importlib.util
from pathlib import Path

import numpy as np

from tone_response_metrics import (features, fixed_masks, measure, oklab,
                                   rectangle_mask, reliable_chroma_mask, wrapped_hue_delta)

runner_spec = importlib.util.spec_from_file_location(
    "tone_response_runner", Path(__file__).with_name("run-tone-response-study.py"))
runner = importlib.util.module_from_spec(runner_spec)
runner_spec.loader.exec_module(runner)


def encode_srgb(linear):
    return np.where(linear <= .0031308, linear * 12.92,
                    1.055 * np.power(linear, 1 / 2.4) - .055)


class ToneResponseMetricsTests(unittest.TestCase):
    def setUp(self):
        self.warning_context = warnings.catch_warnings()
        self.warning_context.__enter__()
        warnings.simplefilter("error", RuntimeWarning)

    def tearDown(self):
        self.warning_context.__exit__(None, None, None)

    def fixture(self, color):
        gradient = np.linspace(.2, .8, 100)[None, :, None]
        return np.broadcast_to(gradient * np.array(color)[None, None, :], (90, 100, 3)).copy()

    def measured(self, before, after):
        baseline, edited = features(before), features(after)
        frame = {"regions": [{"id": "content", "rect": [0, 0, 100, 90]}]}
        masks, _, safe = fixed_masks(frame, baseline)
        return measure(baseline, edited, masks["content"], reliable_chroma_mask(baseline), safe)

    def test_oklab_white_and_black(self):
        actual = oklab(np.array([[0., 0., 0.], [1., 1., 1.]]))
        np.testing.assert_allclose(actual[0], [0, 0, 0], atol=1e-10)
        np.testing.assert_allclose(actual[1], [1, 0, 0], atol=4e-8)

    def test_hue_wrap_uses_short_arc(self):
        before = np.radians([179, -179, 20])
        after = np.radians([-179, 179, 25])
        np.testing.assert_allclose(wrapped_hue_delta(before, after), [2, -2, 5], atol=1e-10)

    def test_proportional_light_change_does_not_become_color_error(self):
        linear = self.fixture([.8, .35, .12])
        row = self.measured(encode_srgb(linear), encode_srgb(linear * 1.1))
        self.assertGreater(row["color"]["chromaDelta100"]["mean"], 0)
        self.assertAlmostEqual(row["color"]["relativeChromaCLChangePercent"]["mean"], 0, places=9)
        self.assertLess(row["color"]["absoluteHueDeltaDegrees"]["p95"], 1e-9)
        self.assertLess(row["color"]["matchedYColorRayDistanceOKLab100"]["p95"], 1e-10)
        self.assertAlmostEqual(row["medianLinearYChangeEV"], np.log2(1.1), places=10)

    def test_channel_clipping_is_detected_against_unclamped_ray(self):
        linear = self.fixture([1.0, .35, .1])
        row = self.measured(encode_srgb(linear), encode_srgb(np.clip(linear * 2, 0, 1)))
        self.assertGreater(row["color"]["matchedYColorRayDistanceOKLab100"]["p95"], .1)
        self.assertGreater(row["color"]["matchedYColorRayOutsideDisplayGamutPercent"], 0)

    def test_no_spurious_hue_for_gray_and_no_flat_detail_ratio(self):
        baseline = np.full((90, 100, 3), .4)
        row = self.measured(baseline, baseline * 1.1)
        self.assertEqual(row["color"]["baselineReliablePixelCount"], 0)
        self.assertIsNone(row["color"]["absoluteHueDeltaDegrees"])
        self.assertIsNone(row["color"]["relativeChromaCLChangePercent"])
        self.assertIsNone(row["detailBandpass"]["fine"]["ratio"])
        self.assertEqual(row["detailBandpass"]["fine"]["status"], "insufficient-baseline-signal")

    def test_edited_neutral_is_explicitly_excluded_from_hue(self):
        before = encode_srgb(self.fixture([.8, .35, .12]))
        after = np.full_like(before, .4)
        row = self.measured(before, after)
        self.assertGreater(row["color"]["baselineReliablePixelCount"], 0)
        self.assertEqual(row["color"]["huePixelCount"], 0)
        self.assertEqual(row["color"]["excludedEditedNearNeutralOrBlackPixelCount"],
                         row["color"]["baselineReliablePixelCount"])

    def test_fixed_quintiles_partition_content_and_kernels_stay_inside_it(self):
        baseline = features(self.fixture([1, 1, 1]))
        frame = {"regions": [{"id": "content", "rect": [5, 5, 95, 85]}]}
        masks, boundaries, safe = fixed_masks(frame, baseline)
        cohorts = [mask for name, mask in masks.items() if name.startswith("baseline_luma_")]
        np.testing.assert_array_equal(np.stack(cohorts).sum(axis=0), masks["content"].astype(int))
        self.assertTrue(all(a < b for a, b in zip(boundaries, boundaries[1:])))
        self.assertFalse(safe["coarse"][40, 40])
        self.assertTrue(safe["coarse"][42, 45])
        self.assertFalse(np.any(safe["fine"] & ~masks["content"]))

    def test_invalid_regions_fail_without_clamping_or_skipping(self):
        with self.assertRaises(ValueError):
            rectangle_mask((90, 100), [-1, 0, 101, 90])
        baseline = features(np.full((90, 100, 3), .5))
        with self.assertRaises(ValueError):
            fixed_masks({"regions": [{"id": "content", "rect": [10, 10, 90, 80]},
                                       {"id": "skin", "rect": [0, 0, 20, 20]}]}, baseline)

    def test_small_material_sample_does_not_borrow_surrounding_edge_contrast(self):
        rgb = np.full((90, 100, 3), .4)
        rgb[:, 50:] = .9
        baseline = features(rgb)
        frame = {"regions": [{"id": "content", "rect": [0, 0, 100, 90]},
                              {"id": "small_skin", "rect": [39, 39, 49, 49]}]}
        masks, _, safe = fixed_masks(frame, baseline)
        row = measure(baseline, baseline, masks["small_skin"],
                      reliable_chroma_mask(baseline), safe)
        self.assertEqual(row["detailBandpass"]["fine"]["pixelCount"], 0)
        self.assertEqual(row["detailBandpass"]["coarse"]["pixelCount"], 0)
        self.assertIsNone(row["detailBandpass"]["fine"]["ratio"])


class SameEditComparisonTests(unittest.TestCase):
    def test_trial_pairs_only_with_identical_color_context(self):
        profiles = [
            {"name": "clean-v2", "schemaVersion": 2, "photoOverrides": {}},
            {"name": "color-v2", "schemaVersion": 2, "photoOverrides": {"tint": .08}},
            {"name": "color-v3", "schemaVersion": 3, "photoOverrides": {"tint": .08}},
        ]
        self.assertEqual(runner.same_edit_pairs(profiles), [
            {"referenceProfile": "color-v2", "candidateProfile": "color-v3"}])

    def test_ambiguous_or_incomplete_reference_is_rejected(self):
        base = {"name": "clean-v2", "schemaVersion": 2, "photoOverrides": {},
                "variantIDs": ["baseline"]}
        trial = {"name": "clean-v3", "schemaVersion": 3, "photoOverrides": {},
                 "variantIDs": ["baseline", "shadows_p0_25"]}
        with self.assertRaises(ValueError):
            runner.same_edit_pairs([base, trial])
        trial["variantIDs"] = ["baseline"]
        duplicate = {**base, "name": "other-v2"}
        with self.assertRaises(ValueError):
            runner.same_edit_pairs([base, duplicate, trial])
        trial["sameEditReferenceProfile"] = "clean-v2"
        self.assertEqual(runner.same_edit_pairs([base, duplicate, trial])[0]["referenceProfile"], "clean-v2")

    def test_version_four_pairs_with_identical_version_two_context(self):
        profiles = [
            {"name": "clean-v2", "schemaVersion": 2, "photoOverrides": {},
             "variantIDs": ["baseline", "blacks_p0_25", "shadowFloor_p0_25"]},
            {"name": "clean-v4", "schemaVersion": 4, "photoOverrides": {},
             "variantIDs": ["baseline", "blacks_p0_25", "shadowFloor_p0_25"]},
        ]
        runner.validate_profiles(profiles, {v["id"] for v in runner.variants()})
        self.assertEqual(runner.same_edit_pairs(profiles), [
            {"referenceProfile": "clean-v2", "candidateProfile": "clean-v4"}])


if __name__ == "__main__":
    unittest.main()
