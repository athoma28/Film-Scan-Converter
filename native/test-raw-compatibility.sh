#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/fsc-raw-compatibility.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
libraw_include_dir="$(pkg-config --variable=includedir libraw_r)"

# The production helper is shared by the C metadata/compatibility bridge and
# the C++ camera-scan bridge. Exercise both without a local RAW corpus.
"${CC:-clang}" -std=c11 -Wall -Wextra -Werror -I "$libraw_include_dir" \
  "$script_dir/tests/RawDecodeCompatibilityTests.c" -o "$test_dir/c-test"
"$test_dir/c-test"
"${CXX:-clang++}" -x c++ -std=c++14 -Wall -Wextra -Werror -I "$libraw_include_dir" \
  "$script_dir/tests/RawDecodeCompatibilityTests.c" -o "$test_dir/cpp-test"
"$test_dir/cpp-test"

# Exact directional X-Trans homogeneity, including NaN/Inf and truncated tiles.
"${CXX:-clang++}" -std=c++14 -O3 -Wall -Wextra -Werror \
  "$script_dir/tests/XTransHomogeneityTests.cpp" -o "$test_dir/xtrans-homogeneity-test"
"$test_dir/xtrans-homogeneity-test"
