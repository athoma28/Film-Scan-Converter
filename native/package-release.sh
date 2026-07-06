#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$SCRIPT_DIR/FilmScanEngine"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
APP_NAME="Film Scan Converter"
EXECUTABLE_NAME="FilmScanConverterMac"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/Film-Scan-Converter-$APP_VERSION.zip"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$PACKAGE_DIR/Sources/FilmScanConverterMac/Info.plist"
ENTITLEMENTS="$PACKAGE_DIR/Sources/FilmScanConverterMac/FilmScanConverter.entitlements"
APP_ICON="$PACKAGE_DIR/Sources/FilmScanConverterMac/Resources/AppIcon.icns"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/fsc-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/fsc-swiftpm-cache}"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  swift build --disable-sandbox -c release --package-path "$PACKAGE_DIR" --product "$EXECUTABLE_NAME"
  swift build --disable-sandbox -c release --package-path "$PACKAGE_DIR" --product FilmScanReleaseValidator
  BIN_DIR="$(swift build --disable-sandbox -c release --package-path "$PACKAGE_DIR" --show-bin-path)"
else
  BIN_DIR="${BIN_DIR:-$PACKAGE_DIR/.build/release}"
fi

rm -rf "$APP_BUNDLE" "$ZIP_PATH"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"
chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

is_external_dependency() {
  case "$1" in
    /System/*|/usr/lib/*|@rpath/*|@executable_path/*|@loader_path/*) return 1 ;;
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

list_dependencies() {
  otool -L "$1" | tail -n +2 | awk '{print $1}'
}

queue_file="$(mktemp "${TMPDIR:-/tmp}/fsc-package-queue.XXXXXX")"
seen_file="$(mktemp "${TMPDIR:-/tmp}/fsc-package-seen.XXXXXX")"
archive_validation_dir="$(mktemp -d "${TMPDIR:-/tmp}/fsc-package-archive.XXXXXX")"
trap 'rm -f "$queue_file" "$seen_file"; rm -rf "$archive_validation_dir"' EXIT
list_dependencies "$MACOS_DIR/$EXECUTABLE_NAME" > "$queue_file"

while IFS= read -r dependency; do
  is_external_dependency "$dependency" || continue
  grep -Fqx "$dependency" "$seen_file" && continue
  printf '%s\n' "$dependency" >> "$seen_file"
  library_name="$(basename "$dependency")"
  destination="$FRAMEWORKS_DIR/$library_name"
  if [[ ! -e "$destination" ]]; then
    cp -L "$dependency" "$destination"
    chmod u+w "$destination"
    list_dependencies "$destination" >> "$queue_file"
  fi
done < "$queue_file"

rewrite_external_dependencies() {
  target="$1"
  while IFS= read -r dependency; do
    is_external_dependency "$dependency" || continue
    install_name_tool -change "$dependency" "@executable_path/../Frameworks/$(basename "$dependency")" "$target"
  done < <(list_dependencies "$target")
}

rewrite_external_dependencies "$MACOS_DIR/$EXECUTABLE_NAME"
for library in "$FRAMEWORKS_DIR"/*.dylib; do
  [[ -e "$library" ]] || continue
  install_name_tool -id "@executable_path/../Frameworks/$(basename "$library")" "$library"
  rewrite_external_dependencies "$library"
done

validate_dependency_closure() {
  target="$1"
  while IFS= read -r dependency; do
    if is_external_dependency "$dependency"; then
      printf 'error: unbundled dependency in %s: %s\n' "$target" "$dependency" >&2
      return 1
    fi
  done < <(list_dependencies "$target")
}

validate_dependency_closure "$MACOS_DIR/$EXECUTABLE_NAME"
for library in "$FRAMEWORKS_DIR"/*.dylib; do
  [[ -e "$library" ]] || continue
  validate_dependency_closure "$library"
done

sign_args=(--force --sign "$SIGNING_IDENTITY")
app_sign_args=("${sign_args[@]}")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  sign_args+=(--timestamp)
  app_sign_args+=(--timestamp --options runtime)
fi
for library in "$FRAMEWORKS_DIR"/*.dylib; do
  [[ -e "$library" ]] || continue
  codesign "${sign_args[@]}" "$library"
done
codesign "${app_sign_args[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

"$BIN_DIR/FilmScanReleaseValidator" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# Validate the artifact users will receive, not only the pre-archive bundle.
ditto -x -k "$ZIP_PATH" "$archive_validation_dir"
archived_app="$archive_validation_dir/$APP_NAME.app"
"$BIN_DIR/FilmScanReleaseValidator" "$archived_app"
codesign --verify --deep --strict --verbose=2 "$archived_app"

printf 'Created %s\n' "$APP_BUNDLE"
printf 'Created %s\n' "$ZIP_PATH"
