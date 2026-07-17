#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$SCRIPT_DIR/FilmScanEngine"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
RELEASE_LABEL="${RELEASE_LABEL:-}"
RELEASE_MODE="${RELEASE_MODE:-local}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP_NAME="Film Scan Converter"
EXECUTABLE_NAME="FilmScanConverterMac"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$PACKAGE_DIR/Sources/FilmScanConverterMac/Info.plist"
ENTITLEMENTS="$PACKAGE_DIR/Sources/FilmScanConverterMac/FilmScanConverter.entitlements"
APP_ICON="$PACKAGE_DIR/Sources/FilmScanConverterMac/Resources/AppIcon.icns"
LICENSE_FILE="$ROOT_DIR/LICENSE"
THIRD_PARTY_NOTICES="$ROOT_DIR/THIRD_PARTY_NOTICES.md"
RELEASE_NOTES="$ROOT_DIR/RELEASE_NOTES.md"
OPENMP_LICENSE="$ROOT_DIR/third_party/licenses/LLVM-OpenMP-LICENSE.txt"

case "$RELEASE_MODE" in
  local)
    ;;
  unsigned-beta)
    if [[ "$SIGNING_IDENTITY" != "-" ]]; then
      printf 'error: unsigned-beta mode requires the default ad-hoc identity (-)\n' >&2
      exit 1
    fi
    ;;
  public)
    if [[ "$SIGNING_IDENTITY" == "-" || -z "$NOTARY_PROFILE" ]]; then
      printf 'error: public mode requires SIGNING_IDENTITY and NOTARY_PROFILE\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'error: RELEASE_MODE must be local, unsigned-beta, or public\n' >&2
    exit 1
    ;;
esac

if [[ -n "$RELEASE_LABEL" && ! "$RELEASE_LABEL" =~ ^[0-9A-Za-z.-]+$ ]]; then
  printf 'error: RELEASE_LABEL may contain only letters, numbers, dots, and hyphens\n' >&2
  exit 1
fi

for required_file in "$INFO_PLIST" "$ENTITLEMENTS" "$APP_ICON" \
  "$LICENSE_FILE" "$THIRD_PARTY_NOTICES" "$RELEASE_NOTES" "$OPENMP_LICENSE"; do
  if [[ ! -f "$required_file" ]]; then
    printf 'error: required release input is missing: %s\n' "$required_file" >&2
    exit 1
  fi
done

if [[ "$RELEASE_MODE" != "local" && "${ALLOW_DIRTY:-0}" != "1" ]] \
  && [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  printf 'error: release artifacts must be built from a clean working tree\n' >&2
  exit 1
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/fsc-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/fsc-swiftpm-cache}"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  swift build --disable-sandbox -c release --package-path "$PACKAGE_DIR" --product "$EXECUTABLE_NAME"
  swift build --disable-sandbox -c release --package-path "$PACKAGE_DIR" --product FilmScanReleaseValidator
  BIN_DIR="$(swift build --disable-sandbox -c release --package-path "$PACKAGE_DIR" --show-bin-path)"
else
  BIN_DIR="${BIN_DIR:-$PACKAGE_DIR/.build/release}"
fi

APP_ARCHES="$(/usr/bin/lipo -archs "$BIN_DIR/$EXECUTABLE_NAME")"
if [[ "$APP_ARCHES" == *arm64* && "$APP_ARCHES" == *x86_64* ]]; then
  ARCH_LABEL="universal"
elif [[ "$APP_ARCHES" == "arm64" ]]; then
  ARCH_LABEL="apple-silicon"
elif [[ "$APP_ARCHES" == "x86_64" ]]; then
  ARCH_LABEL="intel"
else
  ARCH_LABEL="$(printf '%s' "$APP_ARCHES" | tr ' ' '-')"
fi
ARTIFACT_VERSION="$APP_VERSION"
if [[ -n "$RELEASE_LABEL" ]]; then
  ARTIFACT_VERSION="$ARTIFACT_VERSION-$RELEASE_LABEL"
fi
ARCHIVE_NAME="Film-Scan-Converter-$ARTIFACT_VERSION-$ARCH_LABEL"
ZIP_PATH="$DIST_DIR/$ARCHIVE_NAME.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

rm -rf "$APP_BUNDLE" "$ZIP_PATH" "$CHECKSUM_PATH"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"
cp "$LICENSE_FILE" "$RESOURCES_DIR/LICENSE.txt"
cp "$THIRD_PARTY_NOTICES" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
cp "$RELEASE_NOTES" "$RESOURCES_DIR/RELEASE_NOTES.md"
chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

is_external_dependency() {
  case "$1" in
    /System/*|/usr/lib/*|@rpath/*|@executable_path/*|@loader_path/*) return 1 ;;
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

list_dependencies() {
  /usr/bin/otool -L "$1" | tail -n +2 | awk '{print $1}'
}

queue_file="$(mktemp "${TMPDIR:-/tmp}/fsc-package-queue.XXXXXX")"
seen_file="$(mktemp "${TMPDIR:-/tmp}/fsc-package-seen.XXXXXX")"
archive_validation_dir="$(mktemp -d "${TMPDIR:-/tmp}/fsc-package-archive.XXXXXX")"
archive_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/fsc-package-build.XXXXXX")"
trap 'rm -f "$queue_file" "$seen_file"; rm -rf "$archive_validation_dir" "$archive_build_dir"' EXIT
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

LICENSES_DIR="$RESOURCES_DIR/ThirdPartyLicenses"
mkdir -p "$LICENSES_DIR"

copy_required_license() {
  source_path="$1"
  destination_name="$2"
  if [[ ! -s "$source_path" ]]; then
    printf 'error: required bundled-library license is missing: %s\n' "$source_path" >&2
    exit 1
  fi
  cp "$source_path" "$LICENSES_DIR/$destination_name"
}

if compgen -G "$FRAMEWORKS_DIR/libraw*.dylib" > /dev/null; then
  libraw_prefix="$(brew --prefix libraw)"
  copy_required_license "$libraw_prefix/LICENSE.LGPL" "LibRaw-LGPL-2.1.txt"
  copy_required_license "$libraw_prefix/LICENSE.CDDL" "LibRaw-CDDL-1.0.txt"
  copy_required_license "$libraw_prefix/COPYRIGHT" "LibRaw-COPYRIGHT.txt"
fi
if [[ -e "$FRAMEWORKS_DIR/libomp.dylib" ]]; then
  copy_required_license "$OPENMP_LICENSE" "LLVM-OpenMP-LICENSE.txt"
fi
if compgen -G "$FRAMEWORKS_DIR/libjpeg*.dylib" > /dev/null; then
  copy_required_license "$(brew --prefix jpeg-turbo)/LICENSE.md" "libjpeg-turbo-LICENSE.md"
fi
if compgen -G "$FRAMEWORKS_DIR/libjasper*.dylib" > /dev/null; then
  jasper_prefix="$(brew --prefix jasper)"
  copy_required_license "$jasper_prefix/LICENSE.txt" "JasPer-LICENSE.txt"
  copy_required_license "$jasper_prefix/COPYRIGHT.txt" "JasPer-COPYRIGHT.txt"
fi
if compgen -G "$FRAMEWORKS_DIR/liblcms2*.dylib" > /dev/null; then
  copy_required_license "$(brew --prefix little-cms2)/LICENSE" "Little-CMS-LICENSE.txt"
fi

rewrite_external_dependencies() {
  target="$1"
  while IFS= read -r dependency; do
    is_external_dependency "$dependency" || continue
    /usr/bin/install_name_tool -change "$dependency" "@executable_path/../Frameworks/$(basename "$dependency")" "$target"
  done < <(list_dependencies "$target")
}

rewrite_external_dependencies "$MACOS_DIR/$EXECUTABLE_NAME"
for library in "$FRAMEWORKS_DIR"/*.dylib; do
  [[ -e "$library" ]] || continue
  /usr/bin/install_name_tool -id "@executable_path/../Frameworks/$(basename "$library")" "$library"
  rewrite_external_dependencies "$library"
  for architecture in $APP_ARCHES; do
    if ! /usr/bin/lipo "$library" -verify_arch "$architecture" >/dev/null 2>&1; then
      printf 'error: bundled dependency %s does not contain app architecture %s\n' \
        "$library" "$architecture" >&2
      exit 1
    fi
  done
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
  /usr/bin/codesign "${sign_args[@]}" "$library"
done

# Record the exact signed library bytes users receive. The containing app is
# signed after this manifest is written so the manifest is covered by the app
# signature as well.
MANIFEST_PATH="$RESOURCES_DIR/BUNDLED-LIBRARIES.txt"
{
  printf 'Film Scan Converter %s (%s)\n' "$APP_VERSION" "$BUILD_NUMBER"
  printf 'Artifact: %s\n' "$ARCHIVE_NAME"
  printf 'Architectures: %s\n' "$APP_ARCHES"
  printf 'Release mode: %s\n' "$RELEASE_MODE"
  printf 'Source commit: %s\n' "$(git -C "$ROOT_DIR" rev-parse HEAD)"
  printf '\nResolved source libraries (Homebrew Cellar paths identify exact versions):\n'
  while IFS= read -r dependency; do
    is_external_dependency "$dependency" || continue
    printf '%s\n' "$(realpath "$dependency")"
  done < "$seen_file"
  printf '\nBundled non-system libraries (SHA-256 and load commands):\n'
  for library in "$FRAMEWORKS_DIR"/*.dylib; do
    [[ -e "$library" ]] || continue
    (
      cd "$FRAMEWORKS_DIR"
      /usr/bin/shasum -a 256 "$(basename "$library")"
    )
    /usr/bin/otool -L "$library" | sed "1s|$FRAMEWORKS_DIR/||"
  done
} > "$MANIFEST_PATH"

/usr/bin/codesign "${app_sign_args[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

"$BIN_DIR/FilmScanReleaseValidator" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

create_archive() {
  payload_dir="$archive_build_dir/$ARCHIVE_NAME"
  rm -rf "$payload_dir" "$ZIP_PATH"
  mkdir -p "$payload_dir"
  /usr/bin/ditto --norsrc "$APP_BUNDLE" "$payload_dir/$APP_NAME.app"
  cp "$LICENSE_FILE" "$payload_dir/LICENSE.txt"
  cp "$THIRD_PARTY_NOTICES" "$payload_dir/THIRD_PARTY_NOTICES.md"
  cp "$RELEASE_NOTES" "$payload_dir/RELEASE_NOTES.md"
  cp "$MANIFEST_PATH" "$payload_dir/BUNDLED-LIBRARIES.txt"
  /usr/bin/ditto --norsrc "$LICENSES_DIR" "$payload_dir/ThirdPartyLicenses"
  COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --keepParent "$payload_dir" "$ZIP_PATH"
}

create_archive

if [[ "$RELEASE_MODE" == "public" ]]; then
  /usr/bin/xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate "$APP_BUNDLE"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
  create_archive
fi

# Validate the artifact users will receive, not only the pre-archive bundle.
/usr/bin/ditto -x -k "$ZIP_PATH" "$archive_validation_dir"
archived_app="$archive_validation_dir/$ARCHIVE_NAME/$APP_NAME.app"
"$BIN_DIR/FilmScanReleaseValidator" "$archived_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$archived_app"

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

printf 'Created %s\n' "$APP_BUNDLE"
printf 'Created %s\n' "$ZIP_PATH"
printf 'Created %s\n' "$CHECKSUM_PATH"
