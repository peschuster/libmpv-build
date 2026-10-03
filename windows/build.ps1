<#
.SYNOPSIS
  Builds libmpv for Windows x64 as an LGPL DLL and packs it with headers,
  import library, licences and a list of the sources.

.DESCRIPTION
  Follows mpv's own ci/build-win32.ps1: clang from Visual Studio, Meson, and
  every dependency built from source as a Meson subproject and linked
  statically. What differs:
    - mpv with -Dgpl=false, FFmpeg without gpl, version3 and nonfree
    - only what a player with the OpenGL render API needs: no Vulkan, no
      D3D11 output, no scripting, no disc or network extras
    - the revisions come from sources.json, not from moving branches

  Needs Visual Studio with the C++ and clang components, Python with Meson,
  NASM and git. Run from any directory:
    .\windows\build.ps1

  -Work   where mpv is cloned and built (default: work\ in the repo)
  -Out    where the packages go (default: out\ in the repo)
#>
param(
    [string]$Work = (Join-Path $PSScriptRoot "..\work"),
    [string]$Out = (Join-Path $PSScriptRoot "..\out")
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pins = Get-Content (Join-Path $root "sources.json") -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force $Work, $Out | Out-Null
$Work = (Resolve-Path $Work).Path
$Out = (Resolve-Path $Out).Path
$mpv = Join-Path $Work "mpv"

# ------------------------------------------------------------------------------
# Compiler: clang from the Visual Studio installation, as mpv's CI does. A
# standalone LLVM, CMake or Strawberry Perl in PATH would shadow VS's tools.
# ------------------------------------------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "No Visual Studio with C++ tools found" }
$env:PATH = ($env:PATH -split ';' | Where-Object {
        $_ -ne 'C:\Program Files\LLVM\bin' -and $_ -ne 'C:\Program Files\CMake\bin' -and $_ -ne 'C:\Strawberry\c\bin'
    }) -join ';'
$env:PATH += ';C:\Program Files\NASM'
Import-Module "$vs\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments "-arch=x64 -host_arch=x64"
$env:CC = "clang"
$env:CXX = "clang++"
$env:CC_LD = "lld-link"
$env:CXX_LD = "lld-link"
$env:WINDRES = "llvm-rc"
foreach ($tool in "clang", "lld-link", "llvm-rc", "nasm", "meson", "ninja", "git") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found in PATH" }
}
clang --version

# ------------------------------------------------------------------------------
# mpv source at the pinned commit
# ------------------------------------------------------------------------------
if (-not (Test-Path (Join-Path $mpv ".git"))) {
    git init -q $mpv
    git -C $mpv config core.autocrlf false
    git -C $mpv remote add origin $pins.mpv.url
    git -C $mpv fetch -q --depth 1 origin $pins.mpv.revision
    git -C $mpv checkout -q FETCH_HEAD
}
$head = git -C $mpv rev-parse HEAD
if ($head -ne $pins.mpv.revision) { throw "mpv is at $head, sources.json wants $($pins.mpv.revision). Delete $mpv." }
$short = $head.Substring(0, 10)

# mpv builds libmpv with library(), which follows default_library. That has to
# stay "static" for the subprojects, so the DLL is asked for by name.
#
# vf_d3d11vpp.c, part of d3d-hwaccel, uses d3d11_helpers.c. mpv compiles that
# file only with the D3D11 output, ANGLE or Vulkan, all of which are off here.
$patches = @(
    @{ Old = "libmpv = library('mpv',"; New = "libmpv = shared_library('mpv'," }
    @{ Old = "'video/filter/vf_d3d11vpp.c')"
       New = "'video/filter/vf_d3d11vpp.c', 'video/out/gpu/d3d11_helpers.c')`n" +
             "    features += {'dxgi-debug-d3d11': cc.has_header_symbol('d3d11sdklayers.h', 'DXGI_DEBUG_D3D11')}" }
)
$mesonBuild = Join-Path $mpv "meson.build"
$text = Get-Content $mesonBuild -Raw
foreach ($patch in $patches) {
    if ($text.Contains($patch.New)) { continue }
    if (-not $text.Contains($patch.Old)) { throw "meson.build of mpv has no line to patch: $($patch.Old)" }
    $text = $text.Replace($patch.Old, $patch.New)
}
Set-Content $mesonBuild -Value $text -NoNewline

# ------------------------------------------------------------------------------
# Subprojects. The four below come from git at the pinned revision; zlib,
# harfbuzz, freetype and fribidi come from Meson's WrapDB.
# ------------------------------------------------------------------------------
$subprojects = Join-Path $mpv "subprojects"
New-Item -ItemType Directory -Force $subprojects | Out-Null

$provides = @{
    ffmpeg = @(
        "dependency_names = libavcodec, libavdevice, libavfilter, libavformat, libavutil, libswresample, libswscale"
        "program_names = ffmpeg"
    )
    dav1d  = @("dav1d = dav1d_dep")
}
foreach ($name in "ffmpeg", "libass", "libplacebo", "dav1d") {
    $content = @"
[wrap-git]
url = $($pins.$name.url)
revision = $($pins.$name.revision)
depth = 1
clone-recursive = true
"@
    if ($provides.ContainsKey($name)) { $content += "`n[provide]`n$($provides[$name] -join "`n")" }
    Set-Content -Path (Join-Path $subprojects "$name.wrap") -Value $content
}

Push-Location $mpv
try {
    meson wrap update-db
    # Explicitly, as nested projects may bring older versions of them
    foreach ($wrap in "zlib", "harfbuzz", "freetype2", "fribidi") {
        if (-not (Test-Path "subprojects/$wrap.wrap")) { meson wrap install $wrap }
    }

    if (-not (Test-Path "build/build.ninja")) {
        meson setup build `
            --wrap-mode=forcefallback `
            -Ddefault_library=static `
            -Db_vscrt=mt `
            -Dlibmpv=true `
            -Dcplayer=false `
            -Dgpl=false `
            -Dtests=false `
            -Dbuild-date=false `
            -Dmanpage-build=disabled `
            -Dffmpeg:gpl=disabled `
            -Dffmpeg:version3=disabled `
            -Dffmpeg:nonfree=disabled `
            -Dffmpeg:tests=disabled `
            -Dffmpeg:programs=disabled `
            -Dffmpeg:checkasm=disabled `
            -Dffmpeg:avdevice=disabled `
            -Dffmpeg:postproc=disabled `
            -Dffmpeg:sdl2=disabled `
            -Dffmpeg:vulkan=disabled `
            -Dffmpeg:bzlib=disabled `
            -Dffmpeg:lzma=disabled `
            -Dffmpeg:iconv=disabled `
            -Dffmpeg:libdav1d=enabled `
            -Ddav1d:enable_tools=false `
            -Ddav1d:enable_tests=false `
            -Dharfbuzz:freetype=enabled `
            -Dharfbuzz:glib=disabled `
            -Dharfbuzz:gobject=disabled `
            -Dharfbuzz:cairo=disabled `
            -Dharfbuzz:icu=disabled `
            -Dharfbuzz:tests=disabled `
            -Dharfbuzz:docs=disabled `
            -Dharfbuzz:utilities=disabled `
            -Dfreetype2:png=disabled `
            -Dfreetype2:bzip2=disabled `
            -Dfreetype2:brotli=disabled `
            -Dfreetype2:harfbuzz=disabled `
            -Dfribidi:docs=false `
            -Dfribidi:tests=false `
            -Dfribidi:bin=false `
            -Dlibass:test=disabled `
            -Dlibass:fontconfig=disabled `
            -Dlibass:libunibreak=disabled `
            -Dlibplacebo:demos=false `
            -Dlibplacebo:tests=false `
            -Dlibplacebo:opengl=enabled `
            -Dlibplacebo:vulkan=disabled `
            -Dlibplacebo:d3d11=disabled `
            -Dlibplacebo:shaderc=disabled `
            -Dlibplacebo:glslang=disabled `
            -Dlibplacebo:lcms=disabled `
            -Dlibplacebo:libdovi=disabled `
            -Dlibplacebo:unwind=disabled `
            -Dlibplacebo:xxhash=disabled `
            -Dgl=enabled `
            -Dwasapi=enabled `
            -Dd3d-hwaccel=enabled `
            -Dd3d9-hwaccel=enabled `
            -Dvulkan=disabled `
            -Dshaderc=disabled `
            -Dspirv-cross=disabled `
            -Dd3d11=disabled `
            -Degl-angle=disabled `
            -Damf=disabled `
            -Dcaca=disabled `
            -Dsixel=disabled `
            -Dlua=disabled `
            -Djavascript=disabled `
            -Dsubrandr=disabled `
            -Dwin32-smtc=disabled `
            -Dlcms2=disabled `
            -Dlibarchive=disabled `
            -Dlibavdevice=disabled `
            -Dlibbluray=disabled `
            -Dlibcurl=disabled `
            -Dcdda=disabled `
            -Ddvdnav=disabled `
            -Drubberband=disabled `
            -Duchardet=disabled `
            -Dvapoursynth=disabled `
            -Dzimg=disabled `
            -Djpeg=disabled `
            -Diconv=disabled `
            -Ddrm=disabled `
            -Dwayland=disabled `
            -Dx11=disabled
    }
    # Only the DLL. The default target would also build test programs and
    # libraries of the subprojects that nothing links.
    meson compile -C build mpv
} finally {
    Pop-Location
}

# ------------------------------------------------------------------------------
# Checks on what came out
# ------------------------------------------------------------------------------
$build = Join-Path $mpv "build"
$dlls = @(Get-ChildItem $build -Recurse -Filter *.dll)
if ($dlls.Count -ne 1) { throw "Expected one DLL, found $($dlls.Count): $($dlls.FullName -join ', ')" }
$dll = $dlls[0]
$implib = Get-ChildItem $build -File -Filter *.lib | Where-Object { $_.BaseName -eq "mpv" } | Select-Object -First 1
if (-not $implib) { throw "No import library mpv.lib in $build" }

$exports = @(dumpbin /nologo /exports $dll.FullName | Select-String '\smpv_[a-z0-9_]+\s*$')
if ($exports.Count -lt 20) { throw "Only $($exports.Count) mpv_ exports in $($dll.Name)" }
$imports = @(dumpbin /nologo /dependents $dll.FullName | Select-String '^\s+\S+\.dll\s*$' | ForEach-Object { $_.Line.Trim() })

# The C runtime has to be inside the DLL, a site PC has no Visual C++ redistributable
$runtime = @($imports | Where-Object { $_ -match '^(vcruntime|msvcp|msvcr|ucrtbase|api-ms-win-crt)' })
if ($runtime.Count -gt 0) { throw "$($dll.Name) loads the C runtime as DLLs: $($runtime -join ', ')" }

# FFmpeg states its licence in the generated config.h
$ffLicence = Get-ChildItem (Join-Path $build "subprojects") -Recurse -Filter config.h |
    Select-String '#define\s+FFMPEG_LICENSE\s+"([^"]+)"' | Select-Object -First 1
if (-not $ffLicence) { throw "No FFMPEG_LICENSE found in the generated config.h" }
$ffLicence = $ffLicence.Matches[0].Groups[1].Value
if ($ffLicence -notmatch '^LGPL version 2\.1') { throw "FFmpeg is not an LGPL 2.1 build: $ffLicence" }

# ------------------------------------------------------------------------------
# Package, in the layout of the usual mpv-dev archives: DLL and include\ at the
# top, plus the MSVC import library
# ------------------------------------------------------------------------------
$name = "libmpv-$short-windows-x64"
$pkg = Join-Path $Out $name
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-Item -ItemType Directory -Force "$pkg\include\mpv", "$pkg\LICENSES" | Out-Null
Copy-Item $dll.FullName, $implib.FullName $pkg
Copy-Item (Join-Path $mpv "include\mpv\*.h") "$pkg\include\mpv"

# Licence files of mpv and of every subproject linked into the DLL
function Copy-Licences([string]$From, [string]$Name) {
    $files = @(Get-ChildItem $From -File | Where-Object { $_.Name -match '^(LICEN[CS]E|COPYING|COPYRIGHT|Copyright|NOTICE|AUTHORS)' })
    if ($files.Count -eq 0) {
        Write-Warning "No licence file found for $Name in $From"
        $script:noLicence += $Name
        return
    }
    New-Item -ItemType Directory -Force "$pkg\LICENSES\$Name" | Out-Null
    $files | Copy-Item -Destination "$pkg\LICENSES\$Name"
}
$noLicence = @()
Copy-Licences $mpv "mpv"
$sources = @("mpv  $($pins.mpv.url)  $head")
# Only subprojects with an object or library among the inputs of the DLL
$linked = @(ninja -C $build -t inputs $dll.Name |
    Select-String '^subprojects[\\/]([^\\/]+)[\\/].*\.(a|lib|obj|o)$' |
    ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique)
if ($linked.Count -lt 5) { throw "Only $($linked.Count) subprojects among the inputs of $($dll.Name): $($linked -join ', ')" }
foreach ($dir in Get-ChildItem $subprojects -Directory | Where-Object { $linked -contains $_.Name }) {
    Copy-Licences $dir.FullName $dir.Name
    if (Test-Path (Join-Path $dir.FullName ".git")) {
        $url = git -C $dir.FullName remote get-url origin
        $rev = git -C $dir.FullName rev-parse HEAD
        $sources += "$($dir.Name)  $url  $rev"
    } else {
        $wrap = Get-ChildItem $subprojects -Filter *.wrap | Where-Object { (Get-Content $_.FullName -Raw) -match "directory\s*=\s*$([regex]::Escape($dir.Name))\s" } | Select-Object -First 1
        $url = if ($wrap) { ((Get-Content $wrap.FullName) -match '^source_url\s*=') -replace '^source_url\s*=\s*', '' } else { "Meson WrapDB" }
        $sources += "$($dir.Name)  $url"
    }
}

# Smoke test: link against the import library, load the DLL, start mpv
Push-Location $pkg
try {
    clang (Join-Path $PSScriptRoot "smoke.c") -Iinclude -o smoke.exe $implib.Name
    $smoke = .\smoke.exe
    $smoke
} finally {
    Remove-Item smoke.exe -ErrorAction SilentlyContinue
    Pop-Location
}

@"
libmpv for Windows x64, LGPL build
https://github.com/peschuster/libmpv-build

Licence
  mpv is built with -Dgpl=false, FFmpeg without gpl, version3 and nonfree.
  FFmpeg reports: $ffLicence
  The DLL as a whole is under the GNU Lesser General Public License, version
  2.1 or later. LICENSES\ has the licence files of mpv and of every library
  linked into the DLL.
  Subprojects without a licence file at their top level: $(if ($noLicence) { $noLicence -join ', ' } else { 'none' })

Sources (name, origin, revision)
  $($sources -join "`n  ")
  The source archive of this build, $name-sources.tar.gz, is in the same
  release. It holds exactly these sources.

What the DLL reports
  $($smoke -join "`n  ")

DLLs it loads
  $($imports -join "`n  ")

Compiler
  $((clang --version | Select-Object -First 1))
"@ | Set-Content (Join-Path $pkg "BUILD-INFO.txt")

Compress-Archive -Path "$pkg\*" -DestinationPath (Join-Path $Out "$name.zip") -Force
$pdb = Get-ChildItem $build -File -Filter *.pdb | Where-Object { $_.BaseName -like "*mpv*" } | Select-Object -First 1
if ($pdb) { Compress-Archive -Path $pdb.FullName -DestinationPath (Join-Path $Out "$name-pdb.zip") -Force }

# The source of everything in the DLL, without the build directory and git data
& "$env:SystemRoot\System32\tar.exe" -czf (Join-Path $Out "$name-sources.tar.gz") -C $Work --exclude "mpv/build" --exclude ".git" --exclude "*.wraplock" mpv

Get-Content (Join-Path $pkg "BUILD-INFO.txt")
Get-ChildItem $Out -File | Format-Table Name, Length -AutoSize
