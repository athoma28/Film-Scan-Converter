"""Migration and fitting invariants; rendering is checked by the native probe."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


paired = module('paired-reference-study')
skin = module('skin-color-study')


class ColorContractTests(unittest.TestCase):
    def test_old_parameter_document_cannot_be_relabelled_as_a_recipe(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            paired.save(directory / 'trial.recipe.json', {'schemaVersion': 1, 'parameters': {}})
            with self.assertRaisesRegex(ValueError, 'Native recipe capture'):
                paired.correction_document(directory, 'trial')

    def test_preference_compatibility_only_fills_known_neutral_defaults(self):
        original = {'photoAdjustments': {'schemaVersion': 1, 'exposureEV': 0.1}}
        expanded = paired.preference_parameters(original)
        self.assertEqual(original, {'photoAdjustments': {'schemaVersion': 1, 'exposureEV': 0.1}})
        self.assertEqual(expanded, paired.preference_parameters(expanded))
        changed = copy.deepcopy(expanded)
        changed['photoAdjustments']['whites'] = 0.1
        self.assertNotEqual(expanded, paired.preference_parameters(changed))

    def test_public_color_trials_preserve_inversion_and_calibration(self):
        original = dict(filmType=1, filmDyeMixing={'redFromGreen': 0.13},
                        filmNegativeParams=dict(densityProfileID='c41', densityUnmixRGB=[1, 0, 0],
                                                densityCastRemovalStrength=0.5, densityUnmixStrength=0.45),
                        photoAdjustments=dict(temperatureShiftMired=0, tint=0, saturation=0, vibrance=0))
        changed = skin.public_delta(original, [2, -2, 2, -2, 2, -2])
        self.assertEqual(changed['filmDyeMixing'], original['filmDyeMixing'])
        self.assertEqual(changed['filmNegativeParams']['densityUnmixRGB'], [1, 0, 0])
        self.assertEqual(changed['photoAdjustments']['temperatureShiftMired'], 100)
        self.assertEqual(changed['filmNegativeParams']['densityUnmixStrength'], 0)
        self.assertEqual(original['photoAdjustments']['temperatureShiftMired'], 0)

    def test_selection_cannot_use_held_out_skin_or_background_scores(self):
        def variant(train, test):
            return dict(skinTrain=dict(rgbMAE=train, redMinusGreenMAE=train),
                        skinTest=dict(rgbMAE=test, redMinusGreenMAE=test),
                        backgroundChangeTrain=dict(rgbMAE=0.1),
                        backgroundChange=dict(rgbMAE=test),
                        backgroundChangeTest=dict(rgbMAE=test))
        row = dict(base='base', stock='example', preserveFavorite=False, variants={
            'base': variant(8, 1), 'skin-red': variant(2, 100),
            'skin-frame': variant(3, 0), 'skin-stock': variant(4, 0),
            'skin-red-stock': variant(5, 0)})
        self.assertEqual(skin.select_recipe(row), 'skin-red')
        row['variants']['skin-red']['skinTest']['rgbMAE'] = 1000
        row['variants']['skin-red']['backgroundChange']['rgbMAE'] = 1000
        self.assertEqual(skin.select_recipe(row), 'skin-red')
        row['variants']['skin-red']['backgroundChangeTrain']['rgbMAE'] = 5
        self.assertEqual(skin.select_recipe(row), 'skin-frame')


if __name__ == '__main__':
    unittest.main()
