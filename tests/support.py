import sys
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'source'


def import_raw_processing():
    try:
        import rawpy  # noqa: F401
    except ImportError:
        sys.modules['rawpy'] = types.ModuleType('rawpy')

    source_path = str(SOURCE)
    if source_path not in sys.path:
        sys.path.insert(0, source_path)

    from RawProcessing import RawProcessing

    return RawProcessing


def import_gui():
    import_raw_processing()

    from GUI import GUI

    return GUI


def make_processor(raw_processing, image, **settings):
    processor = raw_processing.__new__(raw_processing)
    processor.class_parameters = raw_processing.default_parameters.copy()
    processor.RAW_IMG = image
    processor.FileReadError = False
    processor.active_processes = 0
    processor.proxy = False
    processor._raw_revision = 1

    defaults = {
        'dark_threshold': 25,
        'light_threshold': 100,
        'border_crop': 0,
        'flip': False,
        'rotation': 0,
        'film_type': 3,
        'white_point': 0,
        'black_point': 0,
        'gamma': 0,
        'shadows': 0,
        'highlights': 0,
        'temp': 0,
        'tint': 0,
        'sat': 100,
        'reject': False,
        'base_detect': 0,
        'base_rgb': (255, 255, 255),
        'remove_dust': False,
        'pick_wb': False,
    }
    defaults.update(settings)
    for key, value in defaults.items():
        setattr(processor, key, value)

    return processor
