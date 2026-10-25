#!/usr/bin/env pwsh
# Builds hdrctl.exe (x64) with MSVC. Needs Visual Studio or Build Tools with
# the "Desktop development with C++" workload.
$ErrorActionPreference = 'Stop'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found. Install Visual Studio 2017+ or the Build Tools."
}

$vsPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vsPath) {
    throw "No Visual Studio installation with the C++ toolset found. Install the 'Desktop development with C++' workload."
}

$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found at $vcvars" }

$src = Join-Path $PSScriptRoot 'hdrctl.cpp'
$exe = Join-Path $PSScriptRoot 'hdrctl.exe'
$obj = Join-Path $PSScriptRoot 'hdrctl.obj'

# /W4 but not /WX: the SDK headers warn under /W4 on some versions.
$clArgs = @(
    '/nologo', '/std:c++17', '/W4', '/O2', '/EHsc', '/MT', '/DNDEBUG',
    "`"$src`"",
    "/Fe:`"$exe`"", "/Fo:`"$obj`"",
    '/link', 'user32.lib', 'dxva2.lib', 'bcrypt.lib'
) -join ' '

Write-Host "building hdrctl.exe ..."
& cmd /c "`"$vcvars`" >nul 2>nul && cl $clArgs"
if ($LASTEXITCODE -ne 0) { throw "build failed (exit $LASTEXITCODE)" }

Remove-Item $obj -ErrorAction SilentlyContinue

# hdrctl.exe reads monitor_db.json from its own folder; the repo keeps one copy at the root.
Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'monitor_db.json') (Join-Path $PSScriptRoot 'monitor_db.json') -Force
Write-Host "built $exe"
