"""Same-pixel display-output measurements, never perceptual preference scores.

The photographic CPU output is 16-bit encoded sRGB. All memberships are frozen
from a named baseline. The Gaussian band-pass signals include texture, edges and
grain; their RMS does not establish recovered scene detail or image quality.
"""

from dataclasses import dataclass
import math

import cv2
import numpy as np


LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float64)
DETAIL_SCALES = {"fine": (0.8, 3.0), "coarse": (3.0, 12.0)}


def decode_srgb(rgb):
    return np.where(rgb <= 0.04045, rgb / 12.92,
                    ((rgb + 0.055) / 1.055) ** 2.4)


def oklab(linear_rgb):
    """OKLab coordinates using the published linear-sRGB matrices, D65.

    Coordinates use L approximately 0..1; chroma is sqrt(a*a+b*b). This is a
    display-color descriptor, not colorimetry of the original photographed scene.
    https://bottosson.github.io/posts/oklab/#converting-from-linear-srgb-to-oklab
    """
    lms = np.einsum("...c,rc->...r", linear_rgb, np.array([
        [0.4122214708, 0.5363325363, 0.0514459929],
        [0.2119034982, 0.6806995451, 0.1073969566],
        [0.0883024619, 0.2817188376, 0.6299787005],
    ]))
    return np.einsum("...c,rc->...r", np.cbrt(lms), np.array([
        [0.2104542553, 0.7936177850, -0.0040720468],
        [1.9779984951, -2.4285922050, 0.4505937099],
        [0.0259040371, 0.7827717662, -0.8086757660],
    ]))


def wrapped_hue_delta(before, after):
    """Signed shortest difference between angles, in degrees, [-180,180)."""
    return (np.degrees(after - before) + 180) % 360 - 180


def read_render(path):
    image = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if image is None or image.dtype != np.uint16 or image.ndim != 3 or image.shape[2] != 3:
        raise ValueError(f"Expected 16-bit three-channel production PNG: {path}")
    return image[..., ::-1].astype(np.float64) / 65535.0


@dataclass
class Features:
    rgb: np.ndarray
    linear: np.ndarray
    luma: np.ndarray
    y: np.ndarray
    lab: np.ndarray
    chroma: np.ndarray
    hue: np.ndarray
    detail: dict


def features(rgb):
    linear = decode_srgb(rgb)
    luma = np.einsum("...c,c->...", rgb, LUMA)
    lab = oklab(linear)
    detail = {}
    for name, (low, high) in DETAIL_SCALES.items():
        # Explicit finite support makes the content erosion exact and auditable.
        def blur(sigma):
            radius = math.ceil(3 * sigma)
            return cv2.GaussianBlur(luma, (2 * radius + 1, 2 * radius + 1), sigma,
                                    borderType=cv2.BORDER_REFLECT_101)
        detail[name] = blur(low) - blur(high)
    return Features(rgb, linear, luma, np.einsum("...c,c->...", linear, LUMA), lab,
                    np.hypot(lab[..., 1], lab[..., 2]),
                    np.arctan2(lab[..., 2], lab[..., 1]), detail)


def rectangle_mask(shape, rectangle):
    height, width = shape
    if (len(rectangle) != 4 or any(type(x) is not int for x in rectangle)
            or not 0 <= rectangle[0] < rectangle[2] <= width
            or not 0 <= rectangle[1] < rectangle[3] <= height):
        raise ValueError(f"Invalid rectangle {rectangle} for {width}x{height}")
    x0, y0, x1, y1 = rectangle
    mask = np.zeros(shape, dtype=bool)
    mask[y0:y1, x0:x1] = True
    return mask


def fixed_masks(frame, canonical):
    """Regions and baseline-luma quintiles, never recomputed from an edit."""
    masks = {}
    for region in frame["regions"]:
        if region["id"] in masks:
            raise ValueError(f"Duplicate region {region['id']}")
        masks[region["id"]] = rectangle_mask(canonical.luma.shape, region["rect"])
    if "content" not in masks:
        raise ValueError("Each frame needs an explicitly inspected content rectangle")
    content = masks["content"]
    for name, mask in masks.items():
        if np.any(mask & ~content):
            raise ValueError(f"Region {name} extends outside content")
    thresholds = np.quantile(canonical.luma[content], [.2, .4, .6, .8])
    bins = np.searchsorted(thresholds, canonical.luma, side="right")
    for i in range(5):
        masks[f"baseline_luma_q{i * 20:02d}_{(i + 1) * 20:03d}"] = content & (bins == i)
    safe_detail = {}
    for name, (_, high) in DETAIL_SCALES.items():
        radius = math.ceil(3 * high)
        safe_detail[name] = cv2.erode(content.astype(np.uint8),
            np.ones((2 * radius + 1, 2 * radius + 1), dtype=np.uint8),
            borderType=cv2.BORDER_CONSTANT, borderValue=0).astype(bool)
    return masks, thresholds.tolist(), safe_detail


def distribution(values):
    if values.size == 0:
        return None
    return {"mean": float(values.mean()),
            "p05": float(np.quantile(values, .05)),
            "median": float(np.median(values)),
            "p95": float(np.quantile(values, .95))}


def reliable_chroma_mask(baseline):
    return ((baseline.chroma >= .025) & (baseline.lab[..., 0] >= .08)
            & (baseline.luma > .03) & (baseline.luma < .97)
            & (baseline.y > 1e-6))


def measure(baseline, edited, mask, color_mask, safe_detail, erode_selection_for_detail=True):
    count = int(mask.sum())
    if not count:
        return {"pixelCount": 0, "status": "empty-fixed-selection"}
    delta_luma = edited.luma - baseline.luma
    delta_y = edited.y - baseline.y
    luminance_valid = mask & (baseline.y > 1e-6) & (edited.y > 1e-6)
    reliable = mask & color_mask
    hue_valid = reliable & (edited.chroma >= .005) & (edited.lab[..., 0] >= .02)
    hue_delta = wrapped_hue_delta(baseline.hue[hue_valid], edited.hue[hue_valid])
    relative_before = baseline.chroma[reliable] / baseline.lab[..., 0][reliable]
    relative_after = edited.chroma[reliable] / np.maximum(edited.lab[..., 0][reliable], 1e-9)
    relative_delta = (relative_after / relative_before - 1) * 100
    # Reference follows each baseline RGB color ray to the edited linear Y. No
    # channel clamp is applied; this is an analytical reference, not a new render.
    ray = (baseline.linear[reliable]
           * (edited.y[reliable] / baseline.y[reliable])[:, None])
    ray_delta = np.linalg.norm(edited.lab[reliable] - oklab(ray), axis=-1) * 100
    detail = {}
    for name, (_, high) in DETAIL_SCALES.items():
        selected = mask & safe_detail[name]
        if erode_selection_for_detail:
            radius = math.ceil(3 * high)
            selected &= cv2.erode(mask.astype(np.uint8),
                np.ones((2 * radius + 1, 2 * radius + 1), dtype=np.uint8),
                borderType=cv2.BORDER_CONSTANT, borderValue=0).astype(bool)
        n = int(selected.sum())
        if n:
            base_rms = float(np.sqrt(np.mean(baseline.detail[name][selected] ** 2)))
            edit_rms = float(np.sqrt(np.mean(edited.detail[name][selected] ** 2)))
        else:
            base_rms = edit_rms = 0.0
        detail[name] = {
            "pixelCount": n, "excludedForKernelBoundaryPixels": count - n,
            "status": "measured" if n and base_rms > 1e-6 else "insufficient-baseline-signal",
            "baselineRMS255": 255 * base_rms if n else None,
            "editedRMS255": 255 * edit_rms if n else None,
            "ratio": edit_rms / base_rms if n and base_rms > 1e-6 else None,
        }
    clip = lambda rgb: {
        "blackChannelPercent": float(100 * np.mean(rgb[mask] <= 0)),
        "nearWhiteChannelPercent": float(100 * np.mean(rgb[mask] >= 65534 / 65535)),
    }
    return {
        "status": "measured", "pixelCount": count,
        "encodedLumaDelta255": distribution(255 * delta_luma[mask]),
        "linearYDelta": distribution(delta_y[mask]),
        "medianLinearYChangeEV": float(np.median(np.log2(
            edited.y[luminance_valid] / baseline.y[luminance_valid])))
            if luminance_valid.any() else None,
        "luminanceRatioPixelCount": int(luminance_valid.sum()),
        "brightenedPixelPercent": float(100 * np.mean(delta_luma[mask] > 1 / 65535)),
        "darkenedPixelPercent": float(100 * np.mean(delta_luma[mask] < -1 / 65535)),
        "rgbMeanAbsoluteDelta255": float(255 * np.mean(np.abs(edited.rgb[mask] - baseline.rgb[mask]))),
        "color": {
            "baselineReliablePixelCount": int(reliable.sum()),
            "excludedBaselineUnreliablePixelCount": count - int(reliable.sum()),
            "huePixelCount": int(hue_valid.sum()),
            "excludedEditedNearNeutralOrBlackPixelCount": int(reliable.sum() - hue_valid.sum()),
            "wrappedHueDeltaDegrees": distribution(hue_delta),
            "absoluteHueDeltaDegrees": distribution(np.abs(hue_delta)),
            "chromaDelta100": distribution(100 * (edited.chroma[reliable] - baseline.chroma[reliable])),
            "relativeChromaCLChangePercent": distribution(relative_delta),
            "matchedYColorRayDistanceOKLab100": distribution(ray_delta),
            "matchedYColorRayOutsideDisplayGamutPercent":
                float(100 * np.mean(np.any((ray < 0) | (ray > 1), axis=-1))) if ray.size else None,
        },
        "detailBandpass": detail,
        "baselineClipping": clip(baseline.rgb), "editedClipping": clip(edited.rgb),
    }


METHOD = {
    "input": "Production CPU 16-bit sRGB PNG decoded without color conversion; same pixels and dimensions for every edit. No ACR reference or fitting.",
    "regions": "Fixed inspected sensor-coordinate rectangles. Named material samples are partial interiors, not exhaustive semantic masks. Content includes difficult photographic material but excludes film border/holder.",
    "tonalCohorts": "Five content quintiles from encoded Rec.709-weighted luma in the first profile's baseline; ties go to the upper bin, so counts need not be equal. These exact masks are shared by all profiles and variants.",
    "deltaBaseline": "Each variant is compared to its own profile's baseline; the variant adjustments are increments, including against Clean Invert's nonzero Highlights/Shadows/Vibrance. Exact parameters are saved for every render.",
    "luminance": "Linear Y uses decoded sRGB with weights .2126,.7152,.0722. Encoded luma uses those weights before decoding. Delta255 is display-code scale, not scene exposure. Median EV is log2(edited linear Y/baseline linear Y), excluding either <=1e-6.",
    "colorReliability": "Mask fixed separately from each profile baseline: OKLab C>=.025, L>=.08, encoded luma strictly .03..97, linear Y>1e-6. Wrapped hue additionally excludes edited C<.005 or L<.02 and reports the exclusion count. Tiny neutral color is never treated as a reliable hue.",
    "color": "OKLab describes display output. Raw delta C naturally changes with lightness; relative chroma C/L percentage and wrapped hue are also reported. Matched-Y ray distance compares the edit with unclamped baseline linear RGB multiplied by editedY/baselineY, then measures Euclidean OKLab distance times 100. It measures departure from proportional baseline color at the same output luminance, not aesthetic correctness or calibrated scene accuracy.",
    "detail": "Encoded-luma bandpass = Gaussian(sigma .8)-Gaussian(3) (fine), or Gaussian(3)-Gaussian(12) (coarse), sigma in 900px raster pixels. Kernels have radius ceil(3*sigma), BORDER_REFLECT_101. All selection centers intersect content eroded by the larger radius, so no filter reaches holder. Named material rectangles are additionally eroded by that radius; no kernel reaches another material outside the authored rectangle. Small face/skin rectangles therefore often have no coarse-scale measurement. Tonal quintiles sample neighborhood contrast centered on that tonal cohort, allowing adjacent content tones into the kernel. RMS ratio is edited/baseline; baseline RMS<=1e-6 or empty selection yields null. This contains texture, grain and edges and is not recovered detail, sharpness or a preference score.",
    "clipping": "Channel occupancy only: black=0 and near-white>=65534/65535. A channel occupancy change is not a count of completely clipped pixels and does not establish source clipping.",
    "limits": "900px archived scan inputs; no full-resolution export, scene fidelity, unseen-profile validation, native input-to-display timing or subjective quality claim. Review full images and each named region; do not optimize a single aggregate score.",
}
