# libmpv-build

Builds [libmpv](https://mpv.io) as an LGPL library for the psStreamPlay player, with GitHub Actions. Windows x64 comes first. macOS (universal) is planned.

## Why

The common Windows builds of libmpv are GPL: mpv has its GPL parts on, FFmpeg is configured with `--enable-gpl --enable-version3`, and x264, x265 and rubberband are linked in. A program that links such a DLL has to follow the GPL as a whole.

This build leaves all of that out. mpv is built with `-Dgpl=false`, FFmpeg without `gpl`, `version3` and `nonfree`. The build script stops if FFmpeg's generated `config.h` reports any licence other than LGPL 2.1.

It also leaves out what a player with its own window does not use, which keeps the build at about a dozen libraries.

## What is in the DLL

| Part | From | Licence |
|---|---|---|
| mpv | `sources.json` | LGPL 2.1 or later |
| FFmpeg, Meson port of GStreamer | `sources.json` | LGPL 2.1 or later |
| libass | `sources.json` | ISC |
| libplacebo | `sources.json` | LGPL 2.1 or later |
| dav1d | `sources.json` | BSD 2-clause |
| harfbuzz, freetype, fribidi, zlib | Meson WrapDB | MIT, FreeType licence, LGPL 2.1 or later, zlib |
| win-iconv, dlfcn-win32 | Meson WrapDB, pulled in by the above | public domain, MIT |

In: all of FFmpeg's own decoders and demuxers, HTTP and HTTPS (through Windows' Schannel), the OpenGL render API, WASAPI, D3D11VA and DXVA2 hardware decoding.

Out: Vulkan and D3D11 video output, Lua and JavaScript, DVD, Blu-ray, CD, libarchive, libcurl, rubberband, zimg, lcms2, uchardet and every encoder library.

The exact list for a build is in its `BUILD-INFO.txt`.

## A release

A release has three files:

- `libmpv-<commit>-windows-x64.zip` holds the DLL, the MSVC import library `mpv.lib`, `include\mpv\`, `LICENSES\` and `BUILD-INFO.txt`.
- `libmpv-<commit>-windows-x64-pdb.zip` holds the debug symbols.
- `libmpv-<commit>-windows-x64-sources.tar.gz` holds the source of everything in the DLL, as it was built.

`<commit>` is the mpv commit. The C runtime is linked statically, so the DLL needs no Visual C++ redistributable.

## Build

A push to `main` builds and keeps the files as a workflow artifact for 14 days. A tag `build-<date>` makes a release.

Locally, with Visual Studio (C++ and clang components), Python, Meson, NASM and git:

```powershell
git config --global core.autocrlf false
.\windows\build.ps1
```

The first run clones into `work\` and takes a while. The packages go to `out\`.

## Change a version

Edit the revision in `sources.json` and push. The WrapDB libraries are not pinned yet. They come in the version WrapDB has on the day of the build, and `BUILD-INFO.txt` records which one that was.

## Licence

The scripts follow mpv's `ci/build-win32.ps1` and are under the LGPL, version 2.1 or later, like mpv. See [LICENSE](LICENSE).
