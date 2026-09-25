"""Regression checks for revision counting and separated capture/trace clocks."""

import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "interaction_study", Path(__file__).with_name("run-preview-interaction-study.py"))
STUDY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STUDY)


class InteractionSummaryTests(unittest.TestCase):
    def report(self):
        events = []
        for revision, start in [(1, 0), (2, 30), (3, 110)]:
            for stage, offset in [("requestSubmitted", 1), ("renderBegan", 2),
                                  ("renderReturned", 10), ("modelPublished", 12)]:
                events.append({"revision": revision, "stage": stage,
                               "milliseconds": start + offset,
                               "interactionMilliseconds": start})
        case = {"name": "fit-exposure", "repetition": 1,
                "gestureStartMilliseconds": 0, "releaseMilliseconds": 100,
                "finalRevision": 3, "events": events,
                "inputs": [{"scheduledMilliseconds": 0, "setterStartMilliseconds": 0,
                            "setterEndMilliseconds": .1}]}
        frames = [{"revision": revision, "callbackMilliseconds": time,
                   "presentationTimeSeconds": 1000 + time / 1000}
                  for revision, time in [(999, 5), (1, 20), (1, 25), (None, 30),
                                         (2, 50), (3, 140)]]
        return {"cases": [case], "compositorCapture": {"frames": frames}}

    def test_distinct_revisions_not_capture_callbacks(self):
        result = STUDY.summarize(self.report())
        case = result["cases"][0]
        self.assertEqual(case["distinctCompositorRevisionsDuringGesture"], 2)
        self.assertEqual(case["compositorObservedRevisionsPerSecond"], 20)
        self.assertFalse(case["meets40RevisionPerSecondTarget"])
        self.assertEqual(case["releaseToFinalCompositorCallbackMilliseconds"], 40)
        self.assertEqual(result["markerMissingCompleteFrames"], 1)

    def test_latency_never_subtracts_unrelated_pts_clock(self):
        case = STUDY.summarize(self.report())["cases"][0]
        self.assertEqual(case["setterToCompositorCallbackMilliseconds"]["median"], 20)
        self.assertAlmostEqual(case["compositorPTSInterRevisionGapMilliseconds"]["median"], 30)
        self.assertEqual(case["renderMilliseconds"]["median"], 8)

    def test_no_marker_evidence_does_not_pass_target(self):
        report = self.report()
        report["compositorCapture"]["frames"] = []
        result = STUDY.summarize(report)
        self.assertFalse(result["allCasesHaveCompositorEvidence"])
        self.assertFalse(result["allCasesMeet40Target"])
        self.assertIsNone(result["cases"][0]["releaseToFinalCompositorCallbackMilliseconds"])


if __name__ == "__main__":
    unittest.main()
