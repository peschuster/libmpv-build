# libmpv-build

Builds [libmpv](https://mpv.io) as an LGPL library for the psStreamPlay player, with GitHub Actions: a DLL for Windows x64 and a universal library (arm64 and x86_64) for macOS.

## Why

The common Windows builds of libmpv are GPL: mpv has its GPL parts on, FFmpeg is configured with `--enable-gpl --enable-version3`, and x264, x265 and rubberband are linked in. A program that links such a DLL has to follow the GPL as a whole.

This build leaves all of that out. mpv is built with `-Dgpl=false`, FFmpeg without `gpl`, `version3` and `nonfree`. The build script stops if FFmpeg's generated `config.h` reports any licence other than LGPL 2.1.

It also leaves out what a player with its own window does not use, which keeps the build at about a dozen libraries.

## What is in the library

| Part | From | Licence |
|---|---|---|
| mpv | `sources.json` | LGPL 2.1 or later |
| FFmpeg, Meson port of GStreamer | `sources.json` | LGPL 2.1 or later |
| libass | `sources.json` | ISC |
| libplacebo | `sources.json` | LGPL 2.1 or later |
| dav1d | `sources.json` | BSD 2-clause |
| harfbuzz, freetype, fribidi, zlib | Meson WrapDB | MIT, FreeType licence, LGPL 2.1 or later, zlib |
| win-iconv, dlfcn-win32 | Meson WrapDB, pulled in by the above, Windows only | public domain, MIT |

In, on both systems: all of FFmpeg's own decoders and demuxers, HTTP and HTTPS through the system's TLS (Schannel, Secure Transport) and the OpenGL render API.

In, on Windows: WASAPI, D3D11VA and DXVA2 hardware decoding.

In, on macOS: CoreAudio, VideoToolbox hardware decoding with copied frames (`hwdec=videotoolbox-copy`), CoreText for subtitle fonts.

Out: Vulkan and D3D11 video output, Lua and JavaScript, DVD, Blu-ray, CD, libarchive, libcurl, rubberband, zimg, lcms2, uchardet and every encoder library.

The macOS library has no Cocoa and no Swift code. mpv then has no window of its own and no zero-copy path from VideoToolbox to OpenGL. A player that brings its own window and renders through the render API needs neither, and the build stays free of the Swift runtime. It loads only libraries and frameworks that are part of macOS, and the build script stops if that changes.

The exact list for a build is in its `BUILD-INFO.txt`.

## A release

A release has these files:

- `libmpv-<commit>-windows-x64.zip` holds the DLL, the MSVC import library `mpv.lib`, `include\mpv\`, `LICENSES\` and `BUILD-INFO.txt`.
- `libmpv-<commit>-windows-x64-pdb.zip` holds the debug symbols.
- `libmpv-<commit>-windows-x64-sources.tar.gz` holds the source of everything in the DLL, as it was built.
- `libmpv-<commit>-macos-universal.zip` holds `lib/libmpv.2.dylib`, `include/mpv/`, `LICENSES/` and `BUILD-INFO.txt`.
- `libmpv-<commit>-macos-universal-sources.tar.gz` holds the source of everything in that library.

`<commit>` is the mpv commit. On Windows the C runtime is linked statically, so the DLL needs no Visual C++ redistributable.

The macOS library runs on macOS 11 and later. Its install name is `@rpath/libmpv.2.dylib`: put it into the app's `Contents/Frameworks` and give the program the rpath `@executable_path/../Frameworks`. It is signed ad hoc. An app that is signed with a Developer ID signs it again.

## Build

A push to `main` builds and keeps the files as a workflow artifact for 14 days. A tag `build-<date>` makes a release, which both workflows fill. A change that touches only one system's script builds only that system.

Locally, with Visual Studio (C++ and clang components), Python, Meson, NASM and git:

```powershell
git config --global core.autocrlf false
.\windows\build.ps1
```

The first run clones into `work\` and takes a while. The packages go to `out\`.

On a Mac, with Xcode's command line tools, Python, Meson, Ninja and git, and NASM on an Intel Mac:

```bash
macos/build.sh
```

That builds for the Mac's own architecture. The workflow runs it once on an Apple Silicon and once on an Intel runner, and `macos/universal.sh` joins the two packages with `lipo`.

## Change a version

Edit the revision in `sources.json` and push. The WrapDB libraries are not pinned yet. They come in the version WrapDB has on the day of the build, and `BUILD-INFO.txt` records which one that was.

## Licence

The scripts follow mpv's `ci/build-win32.ps1` and `ci/build-macos.sh` and are under the LGPL, version 2.1 or later, like mpv. See [LICENSE](LICENSE).
