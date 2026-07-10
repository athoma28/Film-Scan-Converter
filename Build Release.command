#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Building & Packaging Release ==="
echo ""

"$DIR/native/package-release.sh"

echo ""
echo "=== Done ==="
