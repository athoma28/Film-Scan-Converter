"""Compare RawPy and native LibRaw corpus benchmark reports."""

import argparse
import json
import math
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rawpy', type=Path, required=True)
    parser.add_argument('--native', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()

    rawpy = load(args.rawpy)
    native = load(args.native)
    rows = []
    for file in sorted(rawpy):
        reference = rawpy[file]
        actual = native[file]
        exact = reference['sha256'] == actual['sha256']
        metric_delta = max(
            abs(reference[key] - actual[key])
            for key in ('minimum', 'maximum', 'blackClipPercent', 'whiteClipPercent')
        )
        mean_delta = max(
            abs(left - right)
            for left, right in zip(reference['channelMeansBGR'], actual['channelMeansBGR'])
        )
        rows.append(
            {
                'file': file,
                'exactPixels': exact,
                'shapeMatches': reference['shape'] == actual['shape'],
                'maxScalarMetricDelta': metric_delta,
                'maxChannelMeanDelta': mean_delta,
                'rawpyBestSeconds': reference['bestSeconds'],
                'nativeBestSeconds': actual['bestSeconds'],
                'speedup': reference['bestSeconds'] / actual['bestSeconds'],
            }
        )

    summary = {
        'allExactPixels': all(row['exactPixels'] for row in rows),
        'allShapesMatch': all(row['shapeMatches'] for row in rows),
        'meanSpeedup': sum(row['speedup'] for row in rows) / len(rows),
        'geometricMeanSpeedup': math.prod(row['speedup'] for row in rows) ** (1 / len(rows)),
        'rows': rows,
    }
    args.output.write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


def load(path):
    report = json.loads(path.read_text())
    return {entry['file']: entry for entry in report['results']}


if __name__ == '__main__':
    main()
