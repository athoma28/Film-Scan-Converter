import unittest
from unittest import mock

import tkinter as tk

from tests.support import import_gui


GUI = import_gui()


class FakeWidget:
    def __init__(self):
        self.calls = []

    def configure(self, **kwargs):
        self.calls.append(('configure', kwargs))

    def pack(self, **kwargs):
        self.calls.append(('pack', kwargs))

    def pack_forget(self):
        self.calls.append(('pack_forget', {}))


class FakeMenu:
    def __init__(self):
        self.calls = []

    def entryconfigure(self, entry, **kwargs):
        self.calls.append((entry, kwargs))


class FakePhoto:
    reject = False
    use_global_settings = False

    def __init__(self, export_error=None):
        self.export_error = export_error
        self.export_calls = 0
        self.clear_calls = 0

    def __str__(self):
        return 'photo.raw'

    def load(self, full_res):
        self.FileReadError = False

    def process(self, full_res):
        pass

    def export(self, filename):
        self.export_calls += 1
        if self.export_error:
            raise self.export_error

    def clear_memory(self):
        self.clear_calls += 1


class FakeEvent:
    def is_set(self):
        return False


class FakeManager:
    def __init__(self):
        self.event = FakeEvent()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def Event(self):
        return self.event


class FakePool:
    def __init__(self, results):
        self.results = results

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def imap(self, function, inputs):
        return iter(self.results)


class GUITests(unittest.TestCase):
    def test_export_worker_retries_write_failures(self):
        photo = FakePhoto(OSError('write failed'))

        with mock.patch('GUI.RawProcessing.class_parameters', {}):
            result = GUI.export_async((photo, '/tmp/output', FakeEvent(), {}))

        self.assertIsInstance(result, OSError)
        self.assertEqual(str(result), 'write failed')
        self.assertEqual(photo.export_calls, 5)
        self.assertEqual(photo.clear_calls, 0)

    def test_batch_export_dialog_separates_title_and_details(self):
        gui = self.make_batch_gui()
        error = OSError('write failed')

        with (
            mock.patch('GUI.multiprocessing.Manager', return_value=FakeManager()),
            mock.patch('GUI.multiprocessing.Pool', return_value=FakePool([error])),
            mock.patch('GUI.messagebox.showerror') as showerror,
        ):
            gui.export_multiple()

        showerror.assert_called_once_with(
            'Export Error: 1 export(s) failed.',
            'Details:\n 1. write failed',
        )

    def test_batch_export_restores_controls_when_setup_raises(self):
        gui = self.make_batch_gui()

        with mock.patch('GUI.multiprocessing.Manager', side_effect=RuntimeError('setup failed')):
            with self.assertRaisesRegex(RuntimeError, 'setup failed'):
                gui.export_multiple()

        self.assertIn(('configure', {'state': tk.NORMAL}), gui.current_photo_button.calls)
        self.assertIn(('pack_forget', {}), gui.abort_button.calls)
        self.assertIn(('pack', {'side': tk.LEFT, 'padx': 2, 'pady': 5}), gui.all_photo_button.calls)
        self.assertIn(('configure', {'state': tk.NORMAL}), gui.import_button.calls)
        self.assertIn(('Import...', {'state': tk.NORMAL}), gui.filemenu.calls)
        gui.hide_progress.assert_called_once_with()

    @staticmethod
    def make_batch_gui():
        gui = GUI.__new__(GUI)
        gui.photos = [FakePhoto()]
        gui.destination_folder = '/tmp'
        gui.advanced_settings = {'max_processors_override': 1}
        gui.global_settings = {}
        gui.current_photo_button = FakeWidget()
        gui.all_photo_button = FakeWidget()
        gui.abort_button = FakeWidget()
        gui.import_button = FakeWidget()
        gui.filemenu = FakeMenu()
        gui.hide_progress = mock.Mock()
        gui.show_progress = mock.Mock()
        gui.update_progress = mock.Mock()
        return gui


if __name__ == '__main__':
    unittest.main()
