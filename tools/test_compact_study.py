"""Safety checks for lossless study compaction; no private scans are used."""

import ctypes
import errno
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("compact-study.py")
SPEC = importlib.util.spec_from_file_location("compact_study_under_test", SCRIPT)
compact = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = compact
SPEC.loader.exec_module(compact)
PAYLOAD = bytes(range(256)) * 8192


class CompactStudyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dist = compact.ROOT / "dist"
        cls.created_dist = not cls.dist.exists()
        cls.dist.mkdir(exist_ok=True)

    @classmethod
    def tearDownClass(cls):
        if cls.created_dist:
            cls.dist.rmdir()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="compact-test-", dir=self.dist)
        self.study = Path(self.temporary.name)
        self.source = self.study / "a.png"
        self.destination = self.study / "b.npy"
        self.source.write_bytes(PAYLOAD)
        self.destination.write_bytes(PAYLOAD)

    def tearDown(self):
        self.temporary.cleanup()

    def run_tool(self, *arguments):
        return subprocess.run([sys.executable, str(SCRIPT), *map(str, arguments)],
                              capture_output=True, text=True, timeout=30)

    def pair(self):
        return compact.duplicate_groups(compact.collect(self.study)[0])[0]

    def assert_no_temporary_files(self):
        self.assertFalse(list(self.study.rglob(".compact-study-*")))

    def test_scan_skips_small_other_suffix_and_symlink_assets(self):
        (self.study / "tiny.png").write_bytes(b"small")
        (self.study / "other.txt").write_bytes(PAYLOAD)
        (self.study / "link.png").symlink_to(self.source)
        with tempfile.TemporaryDirectory(prefix="compact-outside-") as outside:
            (Path(outside) / "private.png").write_bytes(PAYLOAD)
            (self.study / "linked-directory").symlink_to(outside, target_is_directory=True)
            assets, linked = compact.collect(self.study)
            self.assertEqual({asset.path for asset in assets}, {self.source, self.destination})
            self.assertEqual(linked, 0)

    def test_existing_hardlinks_are_skipped(self):
        os.link(self.source, self.study / "hardlink.jpg")
        assets, linked = compact.collect(self.study)
        self.assertEqual([asset.path for asset in assets], [self.destination])
        self.assertEqual(linked, 2)

    def test_dry_run_preserves_content_inode_and_modification_time(self):
        before = {path: (path.stat().st_ino, path.stat().st_mtime_ns)
                  for path in (self.source, self.destination)}
        result = self.run_tool(self.study)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Dry-run only", result.stdout)
        for path in before:
            self.assertEqual((path.stat().st_ino, path.stat().st_mtime_ns), before[path])
            self.assertEqual(path.read_bytes(), PAYLOAD)

    @unittest.skipUnless(sys.platform == "darwin", "macOS clonefile is required")
    def test_clones_preserve_metadata_and_support_independent_writes(self):
        third = self.study / "c.bgr16"
        third.write_bytes(PAYLOAD)
        paths = (self.source, self.destination, third)
        for index, path in enumerate(paths):
            os.chmod(path, (0o640, 0o600, 0o644)[index])
            os.utime(path, ns=(1_600_000_000_000_000_000 + index, 1_610_000_000_000_000_000 + index))
        before = {path: (path.stat().st_mode, path.stat().st_atime_ns, path.stat().st_mtime_ns)
                  for path in paths}
        result = self.run_tool(self.study, "--apply", "--report", self.study / "report.json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len({path.stat().st_ino for path in paths}), 3)
        for path in paths:
            value = path.stat()
            self.assertEqual((value.st_mode, value.st_atime_ns, value.st_mtime_ns), before[path])
            self.assertEqual(path.read_bytes(), PAYLOAD)
        with self.destination.open("r+b") as stream:
            stream.write(b"independent edit")
        self.assertEqual(self.source.read_bytes(), PAYLOAD)
        self.assertEqual(third.read_bytes(), PAYLOAD)
        self.assertNotEqual(self.destination.read_bytes(), PAYLOAD)
        self.assert_no_temporary_files()

    @unittest.skipUnless(sys.platform == "darwin", "macOS clonefile is required")
    def test_changed_destination_is_refused(self):
        source, destination = self.pair()
        self.destination.write_bytes(b"y" * len(PAYLOAD))
        with self.assertRaisesRegex(compact.CompactError, "changed"):
            compact.clone_duplicate(source, destination, compact.clone_api())
        self.assertEqual(self.destination.read_bytes(), b"y" * len(PAYLOAD))
        self.assert_no_temporary_files()

    def test_change_during_hashing_is_refused(self):
        asset = compact.Asset(self.source, self.source.stat())
        real_sha256 = compact.hashlib.sha256

        class MutatingHasher:
            def __init__(self):
                self.original = real_sha256()

            def update(inner, chunk):
                inner.original.update(chunk)
                self.source.write_bytes(b"z" * len(PAYLOAD))

            def hexdigest(inner):
                return inner.original.hexdigest()

        with mock.patch.object(compact.hashlib, "sha256", MutatingHasher):
            with self.assertRaisesRegex(compact.CompactError, "changed"):
                compact.digest(asset)

    @unittest.skipUnless(sys.platform == "darwin", "macOS metadata inspection is required")
    def test_unsupported_clone_keeps_original_and_removes_temporary_file(self):
        compact.clone_api()
        source, destination = self.pair()
        original_inode = self.destination.stat().st_ino

        def unsupported(*arguments):
            ctypes.set_errno(errno.EOPNOTSUPP)
            return -1

        with self.assertRaisesRegex(compact.CompactError, "clone failed"):
            compact.clone_duplicate(source, destination, unsupported)
        self.assertEqual(self.destination.stat().st_ino, original_inode)
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)
        self.assert_no_temporary_files()

    @unittest.skipUnless(sys.platform == "darwin", "macOS metadata inspection is required")
    def test_corrupt_clone_keeps_original(self):
        compact.clone_api()
        source, destination = self.pair()
        original_inode = self.destination.stat().st_ino

        def corrupt(source_name, destination_name, flags):
            Path(os.fsdecode(destination_name)).write_bytes(b"x" * len(PAYLOAD))
            return 0

        with self.assertRaisesRegex(compact.CompactError, "content verification failed"):
            compact.clone_duplicate(source, destination, corrupt)
        self.assertEqual(self.destination.stat().st_ino, original_inode)
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)
        self.assert_no_temporary_files()

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended attributes are required")
    def test_new_clone_attributes_are_removed_from_temporary_clone_only(self):
        actual_clone = compact.clone_api()
        source, destination = self.pair()
        original_source_attributes = compact.xattrs(self.source)
        original_destination_attributes = compact.xattrs(self.destination)

        def extra_attribute(source_name, destination_name, flags):
            result = actual_clone(source_name, destination_name, flags)
            if result == 0:
                subprocess.run(["/usr/bin/xattr", "-w", "fsc.clone-added-test", "new attribute",
                                os.fsdecode(destination_name)], check=True)
            return result

        compact.clone_duplicate(source, destination, extra_attribute)
        self.assertEqual(compact.xattrs(self.source), original_source_attributes)
        self.assertTrue(compact.matching_attributes(original_destination_attributes,
                                                    compact.xattrs(self.destination)))
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)
        self.assert_no_temporary_files()

    def test_attribute_policy_preserves_existing_values_and_only_allows_new_provenance(self):
        provenance = compact.PROVENANCE_ATTRIBUTE
        self.assertTrue(compact.matching_attributes({}, {provenance: b"new"}))
        self.assertTrue(compact.matching_attributes({"existing": b"same"},
                                                    {"existing": b"same", provenance: b"new"}))
        self.assertFalse(compact.matching_attributes({provenance: b"original"}, {provenance: b"changed"}))
        self.assertFalse(compact.matching_attributes({"existing": b"same"}, {"existing": b"changed"}))
        self.assertFalse(compact.matching_attributes({"existing": b"same"}, {}))
        self.assertFalse(compact.matching_attributes({}, {"unexpected": b"value"}))

    @unittest.skipUnless(sys.platform == "darwin", "macOS clonefile is required")
    def test_persistent_new_provenance_is_allowed_without_removal(self):
        actual_clone = compact.clone_api()
        source, destination = self.pair()
        actual_attributes = compact.xattrs
        actual_remove = compact.MAC_LIBRARY.removexattr

        def persistent_provenance(path):
            attributes = actual_attributes(path)
            attributes.pop(compact.PROVENANCE_ATTRIBUTE, None)
            if path.name.startswith(".compact-study-"):
                attributes[compact.PROVENANCE_ATTRIBUTE] = b"persistent native provenance"
            return attributes

        def refuse_provenance_removal(path, name, flags):
            self.assertNotEqual(os.fsdecode(name), compact.PROVENANCE_ATTRIBUTE)
            return actual_remove(path, name, flags)

        with mock.patch.object(compact, "xattrs", side_effect=persistent_provenance):
            with mock.patch.object(compact.MAC_LIBRARY, "removexattr", side_effect=refuse_provenance_removal):
                self.assertTrue(compact.clone_duplicate(source, destination, actual_clone))
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)
        self.assert_no_temporary_files()

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended attributes are required")
    def test_unremovable_clone_attribute_preserves_original(self):
        actual_clone = compact.clone_api()
        source, destination = self.pair()
        original_inode = self.destination.stat().st_ino

        def extra_attribute(source_name, destination_name, flags):
            result = actual_clone(source_name, destination_name, flags)
            if result == 0:
                subprocess.run(["/usr/bin/xattr", "-w", "fsc.clone-added-test", "new attribute",
                                os.fsdecode(destination_name)], check=True)
            return result

        with mock.patch.object(compact.MAC_LIBRARY, "removexattr", return_value=-1):
            with self.assertRaisesRegex(compact.CompactError, "Cannot restore clone extended attributes"):
                compact.clone_duplicate(source, destination, extra_attribute)
        self.assertEqual(self.destination.stat().st_ino, original_inode)
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)
        self.assert_no_temporary_files()

    @unittest.skipUnless(sys.platform == "darwin", "macOS ACLs are required")
    def test_custom_acl_is_skipped_without_changing_original(self):
        subprocess.run(["/bin/chmod", "+a", "everyone allow read", str(self.destination)], check=True)
        original_inode = self.destination.stat().st_ino
        compact.clone_api()
        source, destination = self.pair()
        with self.assertRaisesRegex(compact.MetadataMismatch, "ACL permissions"):
            compact.clone_duplicate(source, destination, compact.clone_api())
        report = self.study / "report.json"
        result = self.run_tool(self.study, "--apply", "--report", report)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(report.read_text())
        self.assertEqual(len(receipt["skippedMetadata"]), 1)
        self.assertIn("ACL permissions", receipt["skippedMetadata"][0]["reason"])
        self.assertEqual(receipt["clonedLogicalBytes"], 0)
        self.assertEqual(self.destination.stat().st_ino, original_inode)
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)

    @unittest.skipUnless(sys.platform == "darwin", "macOS extended attributes are required")
    def test_different_extended_attributes_are_skipped_without_changing_original(self):
        subprocess.run(["/usr/bin/xattr", "-w", "fsc.compactor-test", "different", str(self.destination)], check=True)
        original_inode = self.destination.stat().st_ino
        compact.clone_api()
        source, destination = self.pair()
        with self.assertRaisesRegex(compact.MetadataMismatch, "Different extended attributes"):
            compact.clone_duplicate(source, destination, compact.clone_api())
        report = self.study / "report.json"
        result = self.run_tool(self.study, "--apply", "--report", report)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(report.read_text())
        self.assertEqual(len(receipt["skippedMetadata"]), 1)
        self.assertIn("Different extended attributes", receipt["skippedMetadata"][0]["reason"])
        self.assertEqual(receipt["clonedLogicalBytes"], 0)
        self.assertEqual(self.destination.stat().st_ino, original_inode)
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)

    @unittest.skipUnless(sys.platform == "darwin", "macOS clonefile is required")
    def test_metadata_skip_allows_other_compatible_assets_to_finish(self):
        third = self.study / "c.bgr16"
        third.write_bytes(PAYLOAD)
        subprocess.run(["/usr/bin/xattr", "-w", "fsc.compactor-test", "different", str(self.destination)], check=True)
        original_inodes = {path: path.stat().st_ino for path in (self.source, self.destination, third)}
        report = self.study / "report.json"
        result = self.run_tool(self.study, "--apply", "--report", report)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(report.read_text())
        self.assertEqual(receipt["status"], "complete")
        self.assertEqual(receipt["clonedLogicalBytes"], len(PAYLOAD))
        self.assertEqual(len(receipt["applied"]), 1)
        self.assertEqual(receipt["applied"][0]["destination"], str(third))
        self.assertEqual(len(receipt["skippedMetadata"]), 1)
        self.assertEqual(receipt["skippedMetadata"][0]["path"], str(self.destination))
        self.assertEqual(self.destination.stat().st_ino, original_inodes[self.destination])
        self.assertNotEqual(third.stat().st_ino, original_inodes[third])
        for path in (self.source, self.destination, third):
            self.assertEqual(path.read_bytes(), PAYLOAD)
        self.assert_no_temporary_files()

    def test_study_root_and_symlink_scope_are_refused(self):
        (self.study / "study-link").symlink_to(self.study, target_is_directory=True)
        for path in (self.dist, self.study / "study-link"):
            self.assertEqual(self.run_tool(path).returncode, 1)
        with tempfile.TemporaryDirectory(prefix="compact-outside-") as outside:
            self.assertEqual(self.run_tool(outside).returncode, 1)
            (self.study / "report-link").symlink_to(outside, target_is_directory=True)
            report = self.study / "report-link" / "report.json"
            self.assertEqual(self.run_tool(self.study, "--report", report).returncode, 1)
            self.assertFalse((Path(outside) / "report.json").exists())

    def test_tracked_and_nonignored_studies_are_refused(self):
        with mock.patch.object(compact, "git", return_value=subprocess.CompletedProcess([], 1, b"", b"")):
            with self.assertRaisesRegex(compact.CompactError, "not Git-ignored"):
                compact.validate_study(str(self.study))
        responses = [subprocess.CompletedProcess([], 0, b"", b""),
                     subprocess.CompletedProcess([], 0, b"tracked.png\0", b"")]
        with mock.patch.object(compact, "git", side_effect=responses) as git:
            with self.assertRaisesRegex(compact.CompactError, "tracked paths"):
                compact.validate_study(str(self.study))
            self.assertTrue(git.call_args.args[-1].startswith(":(literal)"))

    def test_existing_report_is_never_overwritten(self):
        report = self.study / "report.json"
        report.write_text("keep existing report")
        self.assertEqual(self.run_tool(self.study, "--report", report).returncode, 1)
        self.assertEqual(report.read_text(), "keep existing report")

    def test_apply_is_refused_on_other_platforms(self):
        with mock.patch.object(compact.sys, "platform", "linux"):
            with self.assertRaisesRegex(compact.CompactError, "requires macOS"):
                compact.clone_api()


if __name__ == "__main__":
    unittest.main()
