#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$DIR/native/FilmScanEngine"

echo "Building FilmScanConverterMac..."
swift build \
  --package-path "$PROJECT_DIR" \
  --configuration release \
  --product FilmScanConverterMac

echo "Launching..."
exec "$PROJECT_DIR/.build/release/FilmScanConverterMac"
