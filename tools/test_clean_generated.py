#!/usr/bin/env python3
"""Safety checks for the cleanup plan using disposable Git repositories."""

import hashlib
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "clean_generated", Path(__file__).with_name("clean-generated.py")
)
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class CleanupPlanTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fsc-cleanup-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".gitignore").write_text(".build/\ndist/\n")

    def write(self, relative, data=b"retained evidence"):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def native_cache(self):
        self.write("native/FilmScanEngine/.build/objects/compiler.o", b"rebuildable")
        return self.root / "native/FilmScanEngine/.build"

    def study(self, name="xt5-study"):
        study = self.root / "dist" / name
        hashes = {}
        for arm in ("baseline", "matrix"):
            data = f"pinned {arm} executable".encode()
            self.write(f"dist/{name}/renderer/{arm}/XT5MatrixProbe", data)
            hashes[arm] = hashlib.sha256(data).hexdigest()
        self.write(f"dist/{name}/snapshot/FilmScanEngine/Package.swift")
        self.write(f"dist/{name}/gallery/frame.jpg")
        self.write(f"dist/{name}/report.json", b'{"evidence": true}')
        self.write(f"dist/{name}/build/objects/compiler.o", b"rebuildable")
        state = {
            "candidateDefine": "FSC_DIAGNOSTIC_UPSTREAM_XT5_MATRIX",
            "status": "render-complete",
            "completed": ["frame"],
            "rendererHashes": hashes,
        }
        (study / "study.json").write_text(json.dumps(state))
        return study

    def change_state(self, study, **changes):
        path = study / "study.json"
        state = json.loads(path.read_text())
        state.update(changes)
        path.write_text(json.dumps(state))

    def test_only_known_rebuildable_caches_are_selected(self):
        native = self.native_cache()
        study = self.study()
        self.write("dist/unrecognized/build/evidence.o")
        other = self.study("different-study")
        self.change_state(other, candidateDefine="OTHER_DIAGNOSTIC")
        self.write("dist/baseline-objects/compiler.o")
        self.write("sample-raw/scan.RAF")
        self.assertEqual(cleanup.candidates(self.root), [native, study / "build"])

    def test_planning_leaves_every_file_unchanged(self):
        self.native_cache()
        self.study()
        self.write("dist/old-study/build/baseline.o")
        self.write("sample-raw/scan.RAF")
        before = {p.relative_to(self.root): p.read_bytes()
                  for p in self.root.rglob("*") if p.is_file()}
        for cache in cleanup.candidates(self.root):
            self.assertGreater(cleanup.cache_size(cache), 0)
        after = {p.relative_to(self.root): p.read_bytes()
                 for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_native_cache_symlink_is_refused(self):
        target = self.root / "outside"
        target.mkdir()
        cache = self.root / "native/FilmScanEngine/.build"
        cache.parent.mkdir(parents=True)
        cache.symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinked"):
            cleanup.candidates(self.root)

    def test_native_cache_symlinked_parent_is_refused(self):
        target = self.root / "outside"
        (target / ".build").mkdir(parents=True)
        (self.root / "native").mkdir()
        (self.root / "native/FilmScanEngine").symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinked"):
            cleanup.candidates(self.root)

    def test_study_build_symlink_is_refused(self):
        study = self.study()
        (study / "build").rename(study / "original-build")
        (study / "build").symlink_to(study / "original-build", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinked"):
            cleanup.candidates(self.root)

    def test_dist_symlink_is_refused(self):
        target = self.root / "outside"
        target.mkdir()
        (self.root / "dist").symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinked dist"):
            cleanup.candidates(self.root)

    def test_tracked_cache_is_refused(self):
        self.native_cache()
        subprocess.run(
            ["git", "add", "--force", "native/FilmScanEngine/.build/objects/compiler.o"],
            cwd=self.root, check=True,
        )
        with self.assertRaisesRegex(ValueError, "tracked files"):
            cleanup.candidates(self.root)

    def test_unignored_cache_is_refused(self):
        self.native_cache()
        (self.root / ".gitignore").write_text("")
        with self.assertRaisesRegex(ValueError, "not ignored"):
            cleanup.candidates(self.root)

    def test_changed_pinned_renderer_is_refused(self):
        study = self.study()
        (study / "renderer/matrix/XT5MatrixProbe").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "missing or changed"):
            cleanup.candidates(self.root)

    def test_incomplete_pinned_hash_pair_is_refused(self):
        study = self.study()
        self.change_state(study, rendererHashes={"baseline": "0" * 64})
        with self.assertRaisesRegex(ValueError, "complete pinned renderer pair"):
            cleanup.candidates(self.root)

    def test_invalid_pinned_hash_pair_is_refused(self):
        study = self.study()
        self.change_state(study, rendererHashes={"baseline": "0" * 64, "matrix": "1" * 64})
        with self.assertRaisesRegex(ValueError, "missing or changed"):
            cleanup.candidates(self.root)

    def test_symlinked_pinned_renderer_is_refused(self):
        study = self.study()
        renderer = study / "renderer/baseline/XT5MatrixProbe"
        renderer.rename(study / "original-renderer")
        renderer.symlink_to(study / "original-renderer")
        with self.assertRaises(ValueError):
            cleanup.candidates(self.root)

    def test_retained_renderer_parent_symlink_is_refused(self):
        study = self.study()
        (study / "renderer").rename(study / "build" / "renderer")
        (study / "renderer").symlink_to(study / "build" / "renderer", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinked"):
            cleanup.candidates(self.root)

    def test_retained_snapshot_parent_symlink_is_refused(self):
        study = self.study()
        (study / "snapshot").rename(study / "build" / "snapshot")
        (study / "snapshot").symlink_to(study / "build" / "snapshot", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinked"):
            cleanup.candidates(self.root)

    def test_unfinished_study_is_refused(self):
        study = self.study()
        self.change_state(study, status="rendering", completed=[])
        with self.assertRaisesRegex(ValueError, "resumable rendered output"):
            cleanup.candidates(self.root)

    def test_missing_source_snapshot_is_refused(self):
        study = self.study()
        (study / "snapshot/FilmScanEngine/Package.swift").unlink()
        with self.assertRaisesRegex(ValueError, "source snapshot is missing"):
            cleanup.candidates(self.root)

    def test_malformed_manifest_type_is_refused(self):
        study = self.study()
        for value in ([], None, "study"):
            with self.subTest(value=value):
                (study / "study.json").write_text(json.dumps(value))
                with self.assertRaisesRegex(ValueError, "Invalid study manifest"):
                    cleanup.candidates(self.root)

    def test_malformed_hash_field_type_is_refused(self):
        study = self.study()
        for value in ([], None, "hashes"):
            with self.subTest(value=value):
                self.change_state(study, rendererHashes=value)
                with self.assertRaisesRegex(ValueError, "complete pinned renderer pair"):
                    cleanup.candidates(self.root)

    def test_symlinked_receipt_parent_prevents_any_deletion(self):
        cache = self.native_cache()
        outside = self.root / "external-receipts"
        outside.mkdir()
        (self.root / "dist").mkdir()
        (self.root / "dist/cleanup-receipts").symlink_to(outside, target_is_directory=True)
        with mock.patch.object(cleanup, "ROOT", self.root), \
                mock.patch.object(cleanup, "require_idle"), \
                mock.patch.object(cleanup.shutil, "rmtree") as remove, \
                mock.patch("sys.argv", ["clean-generated.py", "--apply"]), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(ValueError, "symlinked"):
                cleanup.main()
            remove.assert_not_called()
        self.assertTrue(cache.is_dir())
        self.assertEqual(list(outside.iterdir()), [])

    def test_busy_cache_prevents_partial_deletion(self):
        native = self.native_cache()
        study = self.study()
        with mock.patch.object(cleanup, "ROOT", self.root), \
                mock.patch.object(cleanup, "require_idle", side_effect=[None, ValueError("busy")]), \
                mock.patch.object(cleanup.shutil, "rmtree") as remove, \
                mock.patch("sys.argv", ["clean-generated.py", "--apply"]), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(ValueError, "busy"):
                cleanup.main()
            remove.assert_not_called()
        self.assertTrue(native.is_dir())
        self.assertTrue((study / "build").is_dir())
        self.assertFalse((self.root / "dist/cleanup-receipts").exists())


if __name__ == "__main__":
    unittest.main()
