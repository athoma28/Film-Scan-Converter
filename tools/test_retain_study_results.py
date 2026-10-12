#!/usr/bin/env python3
"""Retention safety checks using disposable repositories and synthetic data."""

import contextlib
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("retain-study-results.py")
SPEC = importlib.util.spec_from_file_location("retain_study_results_under_test", SCRIPT)
retention = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = retention
SPEC.loader.exec_module(retention)


class RetainStudyResultsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fsc-retention-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".gitignore").write_text("dist/\n")
        (self.root / "dist").mkdir()

    def write(self, relative, data=b"synthetic evidence"):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def inventory(self):
        return {str(p.relative_to(self.root)): p.read_bytes()
                for p in self.root.rglob("*") if p.is_file() and ".git" not in p.parts}

    def apply(self, plan):
        with mock.patch.object(retention, "require_idle"):
            return retention.apply_plan(self.root, plan)

    def report(self):
        data = (json.dumps({"observations": "measurements " * 110000}) + "\n").encode()
        self.assertGreater(len(data), retention.MIB)
        return self.write("dist/study/measurements.json", data), data

    def test_default_cli_is_read_only(self):
        self.write("dist/study/render.png")
        self.report()
        before = self.inventory()
        output = io.StringIO()
        with mock.patch.object(retention, "ROOT", self.root), \
                mock.patch("sys.argv", [str(SCRIPT)]), \
                mock.patch.object(retention, "require_idle") as idle, \
                contextlib.redirect_stdout(output):
            retention.main()
        self.assertIn("Dry run", output.getvalue())
        idle.assert_not_called()
        self.assertEqual(self.inventory(), before)

    def test_source_results_unknown_and_private_originals_are_retained(self):
        retained = {
            "dist/study/probe.swift", "dist/study/source.cpp", "dist/study/engine.before",
            "dist/study/source.patch", "dist/study/scores.csv", "dist/study/frame.json",
            "dist/study/report.md", "dist/study/metadata.json", "dist/study/private.RAF",
            "dist/study/evidence.custom", "dist/study/reference.bin",
        }
        for relative in retained:
            self.write(relative)
        original = self.write("sample-raw/private.RAF", b"private original")
        receipt = self.apply(retention.make_plan(self.root))
        self.assertTrue(receipt.is_file())
        for relative in retained:
            self.assertEqual((self.root / relative).read_bytes(), b"synthetic evidence")
        self.assertEqual(original.read_bytes(), b"private original")

    def test_only_known_generated_outputs_are_removed(self):
        generated = {"image.png", "frame.jpg", "frame.jpeg", "scan.bgr16", "scores.npy",
                     "render.u8", "gallery.html", "cache.pyc", "probe.o", "probe.swiftmodule",
                     "probe.swiftdoc", "probe.swiftsourceinfo", ".DS_Store"}
        for name in generated:
            self.write(f"dist/study/{name}")
        self.write("dist/study/rebuildable", b"\xcf\xfa\xed\xfe" + b"executable")
        self.write("dist/study/unknown", b"not an executable")
        plan = retention.make_plan(self.root)
        removed = {Path(row["path"]).name for row in plan["files"] if row["action"] == "remove"}
        self.assertEqual(removed, generated | {"rebuildable"})
        self.apply(plan)
        self.assertEqual((self.root / "dist/study/unknown").read_bytes(), b"not an executable")
        for name in generated | {"rebuildable"}:
            self.assertFalse((self.root / "dist/study" / name).exists())

    def test_critical_subtrees_buffers_and_masks_override_suffix_rules(self):
        retained = {
            f"dist/{retention.XT5}/snapshot/FilmScanEngine/Tests/fixture.npy",
            f"dist/{retention.XT5}/snapshot/FilmScanEngine/AppIcon.png",
            f"dist/{retention.XT5}/renderer/baseline/XT5MatrixProbe",
            "dist/performance-implementation-2026-10-02/baseline-build/probe.o",
            "dist/performance-implementation-2026-10-02/baseline-build/probe.swiftmodule",
            "dist/release-0.2.0-beta.3/icon.png", "dist/study/skin-mask.png",
            "dist/study/fixed-masks.npz",
        } | {"dist/" + relative for relative in retention.BUFFERS}
        for relative in retained:
            self.write(relative, b"\xcf\xfa\xed\xfe" + b"critical harness data")
        plan = retention.make_plan(self.root)
        self.assertTrue(all(row["action"] == "keep" for row in plan["files"]))
        self.apply(plan)
        self.assertTrue(all((self.root / relative).is_file() for relative in retained))

    def test_archived_reports_restore_byte_for_byte_and_receipt_records_all_hashes(self):
        report, data = self.report()
        image = self.write("dist/study/render.png", b"generated image")
        plan = retention.make_plan(self.root)
        receipt = self.apply(plan)
        archive = report.with_name(report.name + ".gz")
        self.assertFalse(report.exists())
        self.assertFalse(image.exists())
        self.assertEqual(gzip.decompress(archive.read_bytes()), data)
        recorded = json.loads(gzip.decompress(receipt.read_bytes()))
        rows = {row["path"]: row for row in recorded["files"]}
        self.assertEqual(rows["dist/study/render.png"]["sha256"],
                         hashlib.sha256(b"generated image").hexdigest())
        self.assertEqual(rows["dist/study/measurements.json"]["sha256"],
                         hashlib.sha256(data).hexdigest())
        restored = retention.restore_results(self.root, str(archive.relative_to(self.root)))
        self.assertEqual(restored, report)
        self.assertEqual(restored.read_bytes(), data)
        self.assertTrue(archive.exists())

    def test_large_input_metadata_and_state_are_never_archived(self):
        _, data = self.report()
        for name in ("manifest.json", "study.json", "metadata.json"):
            self.write(f"dist/unrecognized-study/{name}", data)
        plan = retention.make_plan(self.root)
        actions = {Path(row["path"]).name: row["action"] for row in plan["files"]}
        for name in ("manifest.json", "study.json", "metadata.json"):
            self.assertEqual(actions[name], "keep")

    def test_removing_hardlinked_outputs_preserves_retained_sibling(self):
        source = self.write("dist/study/a-render.png", b"shared bytes")
        sibling = self.root / "dist/study/b-render.png"
        sibling.hardlink_to(source)
        retained = self.root / "dist/study/evidence.bin"
        retained.hardlink_to(source)
        receipt = self.apply(retention.make_plan(self.root))
        self.assertFalse(source.exists())
        self.assertFalse(sibling.exists())
        self.assertEqual(retained.read_bytes(), b"shared bytes")
        record = json.loads(gzip.decompress(receipt.read_bytes()))
        self.assertEqual(record["status"], "complete")

    def test_nonfinite_and_nonpositive_budget_are_refused(self):
        for budget in (float("nan"), float("inf"), 0, -1):
            with self.subTest(budget=budget), self.assertRaises(ValueError):
                retention.make_plan(self.root, budget)

    def test_restore_cannot_escape_dist_with_parent_path(self):
        self.write("sample-raw/result.json.gz", gzip.compress(b"{}"))
        with self.assertRaisesRegex(ValueError, "restricted to dist"):
            retention.restore_results(self.root, "dist/../sample-raw/result.json.gz")
        self.assertFalse((self.root / "sample-raw/result.json").exists())

    def test_restored_working_report_can_be_retired_without_overwriting_archive(self):
        report, data = self.report()
        self.apply(retention.make_plan(self.root))
        archive = report.with_name(report.name + ".gz")
        packed = archive.read_bytes()
        retention.restore_results(self.root, str(archive.relative_to(self.root)))
        self.apply(retention.make_plan(self.root))
        self.assertFalse(report.exists())
        self.assertEqual(archive.read_bytes(), packed)
        self.assertEqual(gzip.decompress(archive.read_bytes()), data)

    def test_changed_restored_report_is_never_deleted(self):
        report, data = self.report()
        self.write(str(report.relative_to(self.root)) + ".gz", gzip.compress(data))
        report.write_bytes(data + b" ")
        before = self.inventory()
        with self.assertRaisesRegex(ValueError, "different content"):
            retention.make_plan(self.root)
        self.assertEqual(self.inventory(), before)

    def test_budget_refusal_precedes_every_write_or_removal(self):
        self.write("dist/study/render.png")
        self.write("dist/study/irreplaceable.custom", b"x" * retention.MIB)
        before = self.inventory()
        with self.assertRaisesRegex(ValueError, "budget"):
            retention.make_plan(self.root, max_mib=1)
        self.assertEqual(self.inventory(), before)
        self.assertFalse((self.root / "dist/cleanup-receipts").exists())

    def test_busy_preflight_prevents_all_mutation(self):
        self.write("dist/study/render.png")
        self.report()
        plan = retention.make_plan(self.root)
        before = self.inventory()
        with mock.patch.object(retention, "require_idle", side_effect=ValueError("busy")):
            with self.assertRaisesRegex(ValueError, "busy"):
                retention.apply_plan(self.root, plan)
        self.assertEqual(self.inventory(), before)

    def test_changed_file_after_plan_prevents_all_mutation(self):
        self.write("dist/study/render.png")
        changed = self.write("dist/study/report.json")
        plan = retention.make_plan(self.root)
        changed.write_bytes(b"changed evidence")
        before = self.inventory()
        with self.assertRaisesRegex(ValueError, "changed"):
            self.apply(plan)
        self.assertEqual(self.inventory(), before)

    def test_archive_collision_during_planning_is_refused(self):
        report, _ = self.report()
        self.write(str(report.relative_to(self.root)) + ".gz", b"existing archive")
        before = self.inventory()
        with self.assertRaisesRegex(ValueError, "already exists"):
            retention.make_plan(self.root)
        self.assertEqual(self.inventory(), before)

    def test_archive_collision_after_plan_prevents_all_mutation(self):
        self.write("dist/study/a-render.png")
        report, _ = self.report()
        plan = retention.make_plan(self.root)
        self.write(str(report.relative_to(self.root)) + ".gz", b"new archive")
        before = self.inventory()
        with self.assertRaises(ValueError):
            self.apply(plan)
        self.assertEqual(self.inventory(), before)

    def test_new_unplanned_file_prevents_all_mutation(self):
        self.write("dist/study/render.png")
        plan = retention.make_plan(self.root, max_mib=2)
        self.write("dist/study/new.custom", b"x" * (3 * retention.MIB))
        before = self.inventory()
        with self.assertRaises(ValueError):
            self.apply(plan)
        self.assertEqual(self.inventory(), before)

    def test_tracked_dist_file_is_refused(self):
        self.write("dist/study/render.png")
        subprocess.run(["git", "add", "--force", "dist/study/render.png"],
                       cwd=self.root, check=True)
        before = self.inventory()
        with self.assertRaisesRegex(ValueError, "Tracked files"):
            retention.make_plan(self.root)
        self.assertEqual(self.inventory(), before)

    def test_unignored_dist_is_refused(self):
        self.write("dist/study/render.png")
        (self.root / ".gitignore").write_text("")
        with self.assertRaisesRegex(ValueError, "not ignored"):
            retention.make_plan(self.root)

    def test_symlinked_dist_is_refused(self):
        (self.root / "dist").rmdir()
        target = self.root / "outside"
        target.mkdir()
        (self.root / "dist").symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            retention.make_plan(self.root)

    def test_symlinked_file_and_subdirectory_are_refused(self):
        target = self.write("outside/render.png")
        for relative, directory in (("dist/linked.png", False), ("dist/linked-dir", True)):
            with self.subTest(relative=relative):
                link = self.root / relative
                link.symlink_to(target.parent if directory else target, target_is_directory=directory)
                with self.assertRaisesRegex(ValueError, "symlink"):
                    retention.make_plan(self.root)
                link.unlink()
        self.assertEqual(target.read_bytes(), b"synthetic evidence")

    def test_missing_idle_checker_is_refused(self):
        with mock.patch.object(retention.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "lsof is required"):
                retention.require_idle(self.root / "dist")

    def test_idle_checker_errors_or_open_files_are_refused(self):
        for result in (subprocess.CompletedProcess([], 0, "123\n", ""),
                       subprocess.CompletedProcess([], 1, "", "failed traversal"),
                       subprocess.CompletedProcess([], 2, "", "")):
            with self.subTest(result=result), \
                    mock.patch.object(retention.shutil, "which", return_value="/usr/sbin/lsof"), \
                    mock.patch.object(retention.subprocess, "run", return_value=result):
                with self.assertRaisesRegex(ValueError, "idle check"):
                    retention.require_idle(self.root / "dist")

    def test_restore_refuses_existing_destination(self):
        self.write("dist/study/report.json", b"existing result")
        self.write("dist/study/report.json.gz", gzip.compress(b'{"result":true}\n'))
        before = self.inventory()
        with self.assertRaisesRegex(ValueError, "already exists"):
            retention.restore_results(self.root, "dist/study/report.json.gz")
        self.assertEqual(self.inventory(), before)

    def test_restore_refuses_symlink_and_out_of_scope_paths(self):
        target = self.write("outside/report.json.gz", gzip.compress(b'{"result":true}\n'))
        (self.root / "dist/report.json.gz").symlink_to(target)
        with self.assertRaisesRegex(ValueError, "symlink"):
            retention.restore_results(self.root, "dist/report.json.gz")
        with self.assertRaisesRegex(ValueError, "restricted to dist"):
            retention.restore_results(self.root, "outside/report.json.gz")
        self.assertFalse((target.parent / "report.json").exists())

    def test_restore_refuses_invalid_json_without_creating_destination(self):
        self.write("dist/study/report.json.gz", gzip.compress(b"not JSON"))
        with self.assertRaises(ValueError):
            retention.restore_results(self.root, "dist/study/report.json.gz")
        self.assertFalse((self.root / "dist/study/report.json").exists())

    def historical_inputs(self):
        inputs = {}
        for relative in retention.BUFFERS:
            for name in ("scan.bgr16", "metadata.json"):
                path = self.write("dist/" + str(Path(relative).with_name(name)))
                inputs[str(path.relative_to(self.root))] = retention.digest(path)
        self.write("dist/tone-response-separated-final-2026-09-25/manifest.json",
                   json.dumps({"inputs": inputs}).encode())

    def test_changed_historical_harness_input_prevents_planning(self):
        self.historical_inputs()
        buffer = self.root / "dist" / sorted(retention.BUFFERS)[0]
        buffer.write_bytes(b"changed historical input")
        with self.assertRaisesRegex(ValueError, "historical harness input"):
            retention.make_plan(self.root)

    def test_complete_historical_harness_inputs_are_verified_and_preserved(self):
        self.historical_inputs()
        before = self.inventory()
        self.apply(retention.make_plan(self.root))
        for relative, data in before.items():
            self.assertEqual((self.root / relative).read_bytes(), data)

    def xt5_capsule(self):
        study = self.root / "dist" / retention.XT5
        hashes = {}
        for arm in ("baseline", "matrix"):
            path = self.write(f"dist/{retention.XT5}/renderer/{arm}/XT5MatrixProbe",
                              f"pinned {arm} engine".encode())
            hashes[arm] = retention.digest(path)
        source = self.write(
            f"dist/{retention.XT5}/supplemental/reproduction-inputs/native/diagnostics/xt5-matrix-state.cpp",
            b"archived matrix-state source",
        )
        expected = retention.digest(source)
        self.write(f"dist/{retention.XT5}/supplemental/reproduction-inputs/manifest.json",
                   json.dumps({"sha256": {"native/diagnostics/xt5-matrix-state.cpp": expected}}).encode())
        package = self.write(f"dist/{retention.XT5}/snapshot/FilmScanEngine/Package.swift")
        diagnostic = self.write(f"dist/{retention.XT5}/snapshot/diagnostics/run-study.py")
        self.write(f"dist/{retention.XT5}/study.json", json.dumps({
            "rendererHashes": hashes, "matrixState": {"sourceSHA256": expected},
            "snapshotSources": {"Package.swift": retention.digest(package)},
            "diagnosticHashes": {"run-study.py": retention.digest(diagnostic)},
        }).encode())
        return study

    def test_changed_pinned_renderer_prevents_planning(self):
        study = self.xt5_capsule()
        (study / "renderer/matrix/XT5MatrixProbe").write_bytes(b"changed renderer")
        with self.assertRaisesRegex(ValueError, "pinned renderer"):
            retention.make_plan(self.root)

    def test_changed_reproduction_source_prevents_planning(self):
        study = self.xt5_capsule()
        (study / "supplemental/reproduction-inputs/native/diagnostics/xt5-matrix-state.cpp").write_bytes(b"changed source")
        with self.assertRaisesRegex(ValueError, "reproduction input"):
            retention.make_plan(self.root)

    def test_missing_engine_snapshot_prevents_planning(self):
        study = self.xt5_capsule()
        (study / "snapshot/FilmScanEngine/Package.swift").unlink()
        with self.assertRaisesRegex(ValueError, "snapshot"):
            retention.make_plan(self.root)

    def test_changed_engine_snapshot_prevents_planning(self):
        study = self.xt5_capsule()
        (study / "snapshot/FilmScanEngine/Package.swift").write_bytes(b"changed snapshot source")
        with self.assertRaisesRegex(ValueError, "snapshot source"):
            retention.make_plan(self.root)

    def test_changed_snapshot_diagnostic_prevents_planning(self):
        study = self.xt5_capsule()
        (study / "snapshot/diagnostics/run-study.py").write_bytes(b"changed diagnostic")
        with self.assertRaisesRegex(ValueError, "snapshot diagnostic"):
            retention.make_plan(self.root)

    def test_complete_reproduction_capsule_is_verified_and_preserved(self):
        self.xt5_capsule()
        before = self.inventory()
        self.apply(retention.make_plan(self.root))
        for relative, data in before.items():
            self.assertEqual((self.root / relative).read_bytes(), data)


if __name__ == "__main__":
    unittest.main()
