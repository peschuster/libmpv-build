#!/bin/bash
# Builds libmpv for macOS as an LGPL library, for the architecture of the Mac
# it runs on, and packs it with headers, licences and a list of the sources.
# macos/universal.sh joins an arm64 and an x86_64 package into the universal
# one that a release carries.
#
# The same build as windows/build.ps1: every dependency from source as a Meson
# subproject and linked statically, mpv with -Dgpl=false, FFmpeg without gpl,
# version3 and nonfree, the revisions from sources.json. What differs:
#   - no Cocoa and no Swift. libmpv then has no window code of its own, which
#     a player with its own window does not use, and OpenGL comes in through
#     mpv's plain-gl, the backend for the render API.
#   - the linker refuses undefined symbols (b_lundef), which mpv's own build
#     allows. One that is missing would otherwise show only when it is called.
#   - CoreAudio for sound, VideoToolbox for hardware decoding. Without mpv's
#     Cocoa OpenGL backend the decoded frames are copied (hwdec=videotoolbox-copy,
#     which auto-copy-safe picks); there is no zero-copy path.
#
# Needs Xcode's command line tools, Python with Meson, Ninja, git, and NASM on
# an Intel Mac. Run from any directory:
#   macos/build.sh
#
# WORK  where mpv is cloned and built (default: work/ in the repo)
# OUT   where the package goes (default: out/ in the repo)

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$root/work}"
OUT="${OUT:-$root/out}"
mkdir -p "$WORK" "$OUT"
mpv="$WORK/mpv"
arch="$(uname -m)"

# The oldest macOS the library runs on. 11 is the first with Apple Silicon,
# and the player is built for the same version.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

pin() { python3 -c "import json,sys; print(json.load(open('$root/sources.json'))['$1']['$2'])"; }

for tool in clang meson ninja git python3 otool lipo; do
    command -v "$tool" >/dev/null || { echo "$tool not found in PATH" >&2; exit 1; }
done
if [ "$arch" = "x86_64" ]; then
    command -v nasm >/dev/null || { echo "nasm not found in PATH" >&2; exit 1; }
fi
clang --version

# ------------------------------------------------------------------------------
# mpv source at the pinned commit
# ------------------------------------------------------------------------------
revision="$(pin mpv revision)"
if [ ! -d "$mpv/.git" ]; then
    git init -q "$mpv"
    git -C "$mpv" remote add origin "$(pin mpv url)"
    git -C "$mpv" fetch -q --depth 1 origin "$revision"
    git -C "$mpv" checkout -q FETCH_HEAD
fi
head="$(git -C "$mpv" rev-parse HEAD)"
if [ "$head" != "$revision" ]; then
    echo "mpv is at $head, sources.json wants $revision. Delete $mpv." >&2
    exit 1
fi
short="${head:0:10}"

# Two patches to mpv's meson.build.
#
# mpv builds libmpv with library(), which follows default_library. That has to
# stay "static" for the subprojects, so the shared library is asked for by name.
#
# osdep/utils-mac.c has the CFString helpers that the CoreAudio output uses.
# mpv compiles it only with Cocoa, which is off here. Without it the library
# still links, because mpv allows undefined symbols, and then calls address 0
# as soon as it lists the audio devices.
python3 - "$mpv/meson.build" <<'EOF'
import sys
path = sys.argv[1]
text = open(path).read()
patches = [
    ("libmpv = library('mpv',", "libmpv = shared_library('mpv',"),
    ("    sources += files('osdep/language-posix.c')\n",
     "    sources += files('osdep/language-posix.c')\n"
     "    if darwin\n"
     "        sources += files('osdep/utils-mac.c')\n"
     "    endif\n"),
]
for old, new in patches:
    if new in text:
        continue
    if old not in text:
        sys.exit("meson.build of mpv has no line to patch: " + old)
    text = text.replace(old, new, 1)
open(path, "w").write(text)
EOF

# ------------------------------------------------------------------------------
# Subprojects. The four below come from git at the pinned revision; zlib,
# harfbuzz, freetype and fribidi come from Meson's WrapDB.
# ------------------------------------------------------------------------------
subprojects="$mpv/subprojects"
mkdir -p "$subprojects"
for name in ffmpeg libass libplacebo dav1d; do
    {
        echo "[wrap-git]"
        echo "url = $(pin $name url)"
        echo "revision = $(pin $name revision)"
        echo "depth = 1"
        echo "clone-recursive = true"
        case "$name" in
            ffmpeg)
                echo "[provide]"
                echo "dependency_names = libavcodec, libavdevice, libavfilter, libavformat, libavutil, libswresample, libswscale"
                echo "program_names = ffmpeg"
                ;;
            dav1d)
                echo "[provide]"
                echo "dav1d = dav1d_dep"
                ;;
        esac
    } > "$subprojects/$name.wrap"
done

cd "$mpv"
meson wrap update-db
# Explicitly, as nested projects may bring older versions of them
for wrap in zlib harfbuzz freetype2 fribidi; do
    [ -f "subprojects/$wrap.wrap" ] || meson wrap install "$wrap"
done

if [ ! -f build/build.ninja ]; then
    meson setup build \
        --wrap-mode=forcefallback \
        --buildtype=release \
        -Db_lundef=true \
        -Ddefault_library=static \
        -Dlibmpv=true \
        -Dcplayer=false \
        -Dgpl=false \
        -Dtests=false \
        -Dbuild-date=false \
        -Dmanpage-build=disabled \
        -Dffmpeg:gpl=disabled \
        -Dffmpeg:version3=disabled \
        -Dffmpeg:nonfree=disabled \
        -Dffmpeg:tests=disabled \
        -Dffmpeg:programs=disabled \
        -Dffmpeg:checkasm=disabled \
        -Dffmpeg:avdevice=disabled \
        -Dffmpeg:postproc=disabled \
        -Dffmpeg:sdl2=disabled \
        -Dffmpeg:vulkan=disabled \
        -Dffmpeg:metal=disabled \
        -Dffmpeg:bzlib=disabled \
        -Dffmpeg:lzma=disabled \
        -Dffmpeg:iconv=disabled \
        -Dffmpeg:appkit=disabled \
        -Dffmpeg:avfoundation=disabled \
        -Dffmpeg:coreimage=disabled \
        -Dffmpeg:libdav1d=enabled \
        -Dffmpeg:videotoolbox=enabled \
        -Dffmpeg:audiotoolbox=enabled \
        -Dffmpeg:securetransport=enabled \
        -Ddav1d:enable_tools=false \
        -Ddav1d:enable_tests=false \
        -Dharfbuzz:freetype=enabled \
        -Dharfbuzz:coretext=disabled \
        -Dharfbuzz:glib=disabled \
        -Dharfbuzz:gobject=disabled \
        -Dharfbuzz:cairo=disabled \
        -Dharfbuzz:icu=disabled \
        -Dharfbuzz:tests=disabled \
        -Dharfbuzz:docs=disabled \
        -Dharfbuzz:utilities=disabled \
        -Dfreetype2:png=disabled \
        -Dfreetype2:bzip2=disabled \
        -Dfreetype2:brotli=disabled \
        -Dfreetype2:harfbuzz=disabled \
        -Dfribidi:docs=false \
        -Dfribidi:tests=false \
        -Dfribidi:bin=false \
        -Dlibass:test=disabled \
        -Dlibass:fontconfig=disabled \
        -Dlibass:coretext=enabled \
        -Dlibass:libunibreak=disabled \
        -Dlibplacebo:demos=false \
        -Dlibplacebo:tests=false \
        -Dlibplacebo:opengl=enabled \
        -Dlibplacebo:vulkan=disabled \
        -Dlibplacebo:shaderc=disabled \
        -Dlibplacebo:glslang=disabled \
        -Dlibplacebo:lcms=disabled \
        -Dlibplacebo:libdovi=disabled \
        -Dlibplacebo:unwind=disabled \
        -Dlibplacebo:xxhash=disabled \
        -Dgl=enabled \
        -Dplain-gl=enabled \
        -Dcoreaudio=enabled \
        -Dcocoa=disabled \
        -Dgl-cocoa=disabled \
        -Dswift-build=disabled \
        -Dmacos-cocoa-cb=disabled \
        -Dmacos-media-player=disabled \
        -Dmacos-touchbar=disabled \
        -Dvideotoolbox-gl=disabled \
        -Dvideotoolbox-pl=disabled \
        -Davfoundation=disabled \
        -Daudiounit=disabled \
        -Dvulkan=disabled \
        -Dshaderc=disabled \
        -Dspirv-cross=disabled \
        -Dcaca=disabled \
        -Dsixel=disabled \
        -Dlua=disabled \
        -Djavascript=disabled \
        -Dlcms2=disabled \
        -Dlibarchive=disabled \
        -Dlibavdevice=disabled \
        -Dlibbluray=disabled \
        -Dlibcurl=disabled \
        -Dcdda=disabled \
        -Ddvdnav=disabled \
        -Drubberband=disabled \
        -Duchardet=disabled \
        -Dvapoursynth=disabled \
        -Dzimg=disabled \
        -Djpeg=disabled \
        -Diconv=disabled \
        -Ddrm=disabled \
        -Dwayland=disabled \
        -Dx11=disabled \
        -Dsdl2-audio=disabled \
        -Dsdl2-video=disabled \
        -Dsdl2-gamepad=disabled \
        -Dopenal=disabled \
        -Djack=disabled \
        -Dpulse=disabled \
        -Dpipewire=disabled
fi
# Only the library. The default target would also build test programs and
# libraries of the subprojects that nothing links.
meson compile -C build mpv
cd "$root"

# ------------------------------------------------------------------------------
# Checks on what came out
# ------------------------------------------------------------------------------
build="$mpv/build"
dylib="$(find "$build" -maxdepth 1 -type f -name 'libmpv.*.dylib' | head -1)"
[ -n "$dylib" ] || { echo "No libmpv dylib in $build" >&2; exit 1; }

exports="$(nm -gU "$dylib" | grep -c ' _mpv_[a-z0-9_]*$' || true)"
[ "$exports" -ge 20 ] || { echo "Only $exports mpv_ exports in $dylib" >&2; exit 1; }

# Nothing but what macOS itself has: a site's Mac has no Homebrew
imports="$(otool -L "$dylib" | tail -n +2 | awk '{print $1}' | grep -v '^@rpath/libmpv' || true)"
foreign="$(echo "$imports" | grep -v -e '^/usr/lib/' -e '^/System/Library/' || true)"
[ -z "$foreign" ] || { echo "$dylib loads libraries that are not part of macOS: $foreign" >&2; exit 1; }

# And nothing newer than the deployment target
minos="$(otool -l "$dylib" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')"
[ "$minos" = "$MACOSX_DEPLOYMENT_TARGET" ] || echo "warning: the library says minos $minos, wanted $MACOSX_DEPLOYMENT_TARGET" >&2

# FFmpeg states its licence in the generated config.h
ff_licence="$(grep -rhE '#define[[:space:]]+FFMPEG_LICENSE[[:space:]]+"' "$build/subprojects" --include=config.h | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
[ -n "$ff_licence" ] || { echo "No FFMPEG_LICENSE found in the generated config.h" >&2; exit 1; }
case "$ff_licence" in
    "LGPL version 2.1"*) ;;
    *) echo "FFmpeg is not an LGPL 2.1 build: $ff_licence" >&2; exit 1 ;;
esac

# ------------------------------------------------------------------------------
# Package: lib/, include/, LICENSES/, BUILD-INFO.txt
# ------------------------------------------------------------------------------
name="libmpv-$short-macos-$arch"
pkg="$OUT/$name"
rm -rf "$pkg"
mkdir -p "$pkg/lib" "$pkg/include/mpv" "$pkg/LICENSES"
cp "$dylib" "$pkg/lib/libmpv.2.dylib"
# The player's bundle carries the library in Contents/Frameworks and finds it
# through its rpath.
install_name_tool -id "@rpath/libmpv.2.dylib" "$pkg/lib/libmpv.2.dylib"
strip -x "$pkg/lib/libmpv.2.dylib"
codesign --force --sign - "$pkg/lib/libmpv.2.dylib"
cp "$mpv"/include/mpv/*.h "$pkg/include/mpv/"

# Licence files of mpv and of every subproject linked into the library.
# Without the GPL and LGPL 3 texts that mpv and FFmpeg carry for their other
# configurations. This build uses neither, and LICENSE.build is the licence of
# WrapDB's build files, not of the library.
no_licence=""
copy_licences() {
    local from="$1" to="$2" found=0 f base
    for f in "$from"/LICEN[CS]E* "$from"/COPYING* "$from"/COPYRIGHT* "$from"/Copyright* "$from"/NOTICE* "$from"/AUTHORS*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        case "$base" in
            COPYING.GPLv2|COPYING.GPLv3|COPYING.LGPLv3|LICENSE.GPL|LICENSE.build) continue ;;
        esac
        mkdir -p "$pkg/LICENSES/$to"
        cp "$f" "$pkg/LICENSES/$to/"
        found=1
    done
    if [ "$found" = 0 ]; then
        echo "warning: no licence file found for $to in $from" >&2
        no_licence="$no_licence $to"
    fi
}
copy_licences "$mpv" mpv
sources="mpv  $(pin mpv url)  $head"
# Only subprojects with an object or library among the inputs of the library
linked="$(ninja -C "$build" -t inputs "$(basename "$dylib")" | sed -nE 's#^subprojects/([^/]+)/.*\.(a|o)$#\1#p' | sort -u)"
[ "$(echo "$linked" | wc -l)" -ge 5 ] || { echo "Too few subprojects among the inputs of the library: $linked" >&2; exit 1; }
for dir in "$subprojects"/*/; do
    sub="$(basename "$dir")"
    echo "$linked" | grep -qx "$sub" || continue
    copy_licences "${dir%/}" "$sub"
    # FreeType's LICENSE.TXT only points to the text in docs/
    [ -f "$dir/docs/FTL.TXT" ] && cp "$dir/docs/FTL.TXT" "$pkg/LICENSES/$sub/"
    if [ -e "$dir/.git" ]; then
        sources="$sources
  $sub  $(git -C "$dir" remote get-url origin)  $(git -C "$dir" rev-parse HEAD)"
    else
        url="$(grep -l "^directory *= *$sub *$" "$subprojects"/*.wrap 2>/dev/null | head -1 | xargs -I{} sed -nE 's/^source_url *= *//p' {} || true)"
        sources="$sources
  $sub  ${url:-Meson WrapDB}"
    fi
done

# Smoke test: link against the library, load it, start mpv
clang "$root/windows/smoke.c" -I"$pkg/include" -L"$pkg/lib" -lmpv.2 -Wl,-rpath,"$pkg/lib" -o "$OUT/smoke-$arch"
smoke="$("$OUT/smoke-$arch")"
rm -f "$OUT/smoke-$arch"
echo "$smoke"

cat > "$pkg/BUILD-INFO.txt" <<EOF
libmpv for macOS $arch, LGPL build
https://github.com/peschuster/libmpv-build

Licence
  mpv is built with -Dgpl=false, FFmpeg without gpl, version3 and nonfree.
  FFmpeg reports: $ff_licence
  The library as a whole is under the GNU Lesser General Public License,
  version 2.1 or later. LICENSES/ has the licence files of mpv and of every
  library linked into it.
  Subprojects without a licence file at their top level:${no_licence:- none}

Sources (name, origin, revision)
  $sources
  The source archive of this build, libmpv-$short-macos-universal-sources.tar.gz,
  is in the same release. It holds exactly these sources.

Runs on macOS $MACOSX_DEPLOYMENT_TARGET and later.

What the library reports
$(echo "$smoke" | sed 's/^/  /')

Libraries it loads
$(echo "$imports" | sed 's/^/  /')

Compiler
  $(clang --version | head -1)
EOF

# The source of everything in the library, without the build directory and git data
tar -czf "$OUT/$name-sources.tar.gz" -C "$WORK" --exclude "mpv/build" --exclude ".git" --exclude "*.wraplock" mpv

cat "$pkg/BUILD-INFO.txt"
ls -l "$OUT"
