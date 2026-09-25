"""Runner safety tests; no RAW decoding, native compilation, or app state access."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('color_study', Path(__file__).with_name('color-study.py'))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class ColorStudyTests(unittest.TestCase):
    def test_rejects_legacy_outputs_and_different_resume_options(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            (out / 'results.json').write_text('{}')
            with self.assertRaisesRegex(ValueError, 'empty'):
                runner.resume_state(out, False, 'paired', False)
            with self.assertRaisesRegex(ValueError, 'Legacy'):
                runner.resume_state(out, True, 'paired', False)
            runner.write(out / runner.STATE, dict(schemaVersion=1, workflow='paired', full=False))
            with self.assertRaisesRegex(ValueError, '--resume'):
                runner.resume_state(out, False, 'paired', False)
            with self.assertRaisesRegex(ValueError, 'same workflow'):
                runner.resume_state(out, True, 'skin', False)
            with self.assertRaisesRegex(ValueError, 'same workflow'):
                runner.resume_state(out, True, 'paired', True)

    def test_provenance_catches_same_size_input_edit_even_with_preserved_mtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / 'native/FilmScanEngine'
            (package / 'Sources').mkdir(parents=True)
            binary = package / 'renderer'
            binary.write_bytes(b'renderer')
            here = root / 'diagnostics'
            here.mkdir()
            checkpoint = root / 'preferences.json'
            checkpoint.write_text('{}')
            sample = root / 'sample-raw'
            sample.mkdir()
            frame = {'stock': 'example', 'stem': 'frame'}
            for key, ext in [('raw', 'RAF'), ('target', 'jpg'), ('xmp', 'xmp')]:
                file = sample / ('frame.' + ext)
                file.write_bytes(b'original')
                frame[key] = str(file)
            with patch.multiple(runner, ROOT=root, PACKAGE=package, HERE=here,
                                BINARY=binary, CHECKPOINTS=checkpoint):
                before = runner.provenance([frame], {'python': 'test'})
                target = Path(frame['target'])
                stat = target.stat()
                target.write_bytes(b'modified')
                os.utime(target, ns=(stat.st_atime_ns, stat.st_mtime_ns))
                after = runner.provenance([frame], {'python': 'test'})
                with self.assertRaisesRegex(ValueError, 'inputs'):
                    runner.require_same_provenance(before, after)
                runner.require_same_provenance(before, before)

    def test_interrupted_run_retries_failed_stage_and_preserves_completed_stage(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary) / 'study'
            options = argparse.Namespace(output=out, resume=False, workflow='paired', full=False)
            calls = []

            def first_run(command, **kwargs):
                if 'trial.py' in command[1]:
                    calls.append(command[2])
                    if command[2] == 'second':
                        raise subprocess.CalledProcessError(1, command)

            with patch.object(runner, 'preflight', return_value=([], {})), \
                 patch.object(runner, 'provenance', return_value={'inputs': 'frozen'}), \
                 patch.object(runner, 'freeze_renderer', return_value=out / 'renderer'), \
                 patch.object(runner, 'stages', return_value=[('trial.py', 'first'), ('trial.py', 'second')]), \
                 patch.object(runner.subprocess, 'run', side_effect=first_run):
                with self.assertRaises(subprocess.CalledProcessError):
                    runner.run(options)
                state = runner.read(out / runner.STATE)
                self.assertEqual(state['completed'], ['01-trial-first'])
                self.assertEqual(state['status'], 'interrupted')
                options.resume = True
                with patch.object(runner.subprocess, 'run', side_effect=lambda command, **kwargs:
                                  calls.append(command[2]) if 'trial.py' in command[1] else None):
                    runner.run(options)
                self.assertEqual(calls, ['first', 'second', 'second'])
                self.assertEqual(runner.read(out / runner.STATE)['status'], 'complete')

    def test_pinned_renderer_survives_another_build_and_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / 'build-renderer'
            binary.write_bytes(b'original renderer')
            with patch.object(runner, 'BINARY', binary):
                frozen = runner.freeze_renderer(root / 'study')
                previous = {'provenance': {'rendererSHA256': runner.digest(frozen)}}
                binary.write_bytes(b'unrelated build')
                self.assertEqual(frozen.read_bytes(), b'original renderer')
                self.assertEqual(runner.freeze_renderer(root / 'study', previous), frozen)
                frozen.write_bytes(b'changed pinned executable')
                with self.assertRaisesRegex(ValueError, 'pinned renderer'):
                    runner.freeze_renderer(root / 'study', previous)

    def test_discovery_prefers_exact_reference_and_never_substitutes_neighbor(self):
        paired = runner.paired_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stock = root / 'sample-raw/stock'
            stock.mkdir(parents=True)
            for stem in ['DSCF5671', 'DSCF5800']:
                (stock / (stem + '.xmp')).write_text('<root/>')
                (stock / (stem + '.RAF')).touch()
            for name in ['DSCF5672.jpg', 'DSCF5800-adobe.jpg', 'DSCF5800_cnegprofile.jpg', 'DSCF5800.jpg']:
                (stock / name).touch()
            with patch.object(paired, 'ROOT', root):
                frames, incomplete = paired.discover(root / 'output')
            self.assertEqual(len(frames), 1)
            self.assertEqual(Path(frames[0]['target']).name, 'DSCF5800.jpg')
            self.assertEqual(incomplete, ['stock/DSCF5671.xmp'])
            self.assertFalse((root / 'output').exists())


if __name__ == '__main__':
    unittest.main()
