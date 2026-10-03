#!/bin/bash
# Joins the arm64 and the x86_64 package of macos/build.sh into the universal
# package of a release:
#   macos/universal.sh <arm64 package dir> <x86_64 package dir>
#
# Writes libmpv-<commit>-macos-universal.zip into OUT (default: out/ in the
# repo). Headers and licence files come from the arm64 package; both builds
# use the same sources. BUILD-INFO.txt holds both reports.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$root/out}"
arm="${1:?arm64 package directory}"
intel="${2:?x86_64 package directory}"

name="$(basename "$arm")"
name="${name%-arm64}-universal"
pkg="$OUT/$name"
rm -rf "$pkg"
mkdir -p "$pkg/lib"
cp -R "$arm/include" "$arm/LICENSES" "$pkg/"

lipo -create "$arm/lib/libmpv.2.dylib" "$intel/lib/libmpv.2.dylib" -output "$pkg/lib/libmpv.2.dylib"
# lipo keeps the two signatures; one over the whole file is what codesign checks
codesign --force --sign - "$pkg/lib/libmpv.2.dylib"
archs="$(lipo -archs "$pkg/lib/libmpv.2.dylib")"
case "$archs" in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *) echo "The joined library has only: $archs" >&2; exit 1 ;;
esac
otool -D "$pkg/lib/libmpv.2.dylib"

{
    echo "libmpv for macOS, universal (arm64 and x86_64), LGPL build"
    echo "https://github.com/peschuster/libmpv-build"
    echo
    echo "lib/libmpv.2.dylib has the two builds below in one file. Its install name is"
    echo "@rpath/libmpv.2.dylib."
    echo
    echo "================================ arm64 ================================"
    cat "$arm/BUILD-INFO.txt"
    echo
    echo "================================ x86_64 ==============================="
    cat "$intel/BUILD-INFO.txt"
} > "$pkg/BUILD-INFO.txt"

rm -f "$OUT/$name.zip"
(cd "$pkg" && zip -qr "$OUT/$name.zip" .)
shasum -a 256 "$OUT/$name.zip"
