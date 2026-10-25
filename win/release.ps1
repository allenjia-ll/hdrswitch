#!/usr/bin/env pwsh
# Build hdrctl.exe and package a binary release:
#   dist/hdrswitch-<version>-windows-x64.zip
# Usage: .\win\release.ps1 <version>    e.g. .\win\release.ps1 0.1.3
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Version
)
$ErrorActionPreference = 'Stop'

$winDir   = $PSScriptRoot
$repoRoot = Split-Path $winDir -Parent

$Version = $Version -replace '^v', ''
if ($Version -notmatch '^\d+\.\d+\.\d+') {
    throw "version should look like 0.1.3, got '$Version'"
}

$name  = "hdrswitch-$Version-windows-x64"
$dist  = Join-Path $repoRoot 'dist'
$stage = Join-Path $dist $name
$exe   = Join-Path $winDir 'hdrctl.exe'

# ---------------------------------------------------------------------------
# PE inspection, so the release can't ship a binary that won't load on the
# versions of Windows the README claims support for.
# ---------------------------------------------------------------------------

function Get-NullTerminatedAscii([byte[]]$Bytes, [int]$Offset) {
    $end = $Offset
    while ($end -lt $Bytes.Length -and $Bytes[$end] -ne 0) { $end++ }
    return [Text.Encoding]::ASCII.GetString($Bytes, $Offset, $end - $Offset)
}

function Get-PeInfo([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 0x40 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) {
        throw "$Path is not a PE image (no MZ header)"
    }
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ([BitConverter]::ToUInt32($b, $pe) -ne 0x00004550) {
        throw "$Path has a bad PE signature"
    }

    $machine     = [BitConverter]::ToUInt16($b, $pe + 4)
    $numSections = [BitConverter]::ToUInt16($b, $pe + 6)
    $optSize     = [BitConverter]::ToUInt16($b, $pe + 20)
    $opt         = $pe + 24
    $magic       = [BitConverter]::ToUInt16($b, $opt)
    $is64        = ($magic -eq 0x20B)

    # Offsets inside the optional header are the same for PE32 and PE32+ up to
    # the data directories, which sit at +96 (PE32) or +112 (PE32+).
    $majSubsystem = [BitConverter]::ToUInt16($b, $opt + 48)
    $minSubsystem = [BitConverter]::ToUInt16($b, $opt + 50)
    $subsystem    = [BitConverter]::ToUInt16($b, $opt + 68)
    $ddOff        = if ($is64) { $opt + 112 } else { $opt + 96 }
    $importRva    = [BitConverter]::ToUInt32($b, $ddOff + 8)   # directory 1

    # Map an RVA to a file offset through the section table.
    $sectionTable = $opt + $optSize
    $sections = @()
    for ($i = 0; $i -lt $numSections; $i++) {
        $s = $sectionTable + $i * 40
        $sections += [pscustomobject]@{
            VirtualSize    = [BitConverter]::ToUInt32($b, $s + 8)
            VirtualAddress = [BitConverter]::ToUInt32($b, $s + 12)
            RawSize        = [BitConverter]::ToUInt32($b, $s + 16)
            RawOffset      = [BitConverter]::ToUInt32($b, $s + 20)
        }
    }

    $imports = @()
    if ($importRva -ne 0) {
        $descOff = 0
        foreach ($s in $sections) {
            $span = [Math]::Max($s.VirtualSize, $s.RawSize)
            if ($importRva -ge $s.VirtualAddress -and $importRva -lt ($s.VirtualAddress + $span)) {
                $descOff = $s.RawOffset + ($importRva - $s.VirtualAddress)
                break
            }
        }
        while ($descOff -ne 0) {
            # IMAGE_IMPORT_DESCRIPTOR is 20 bytes; a zeroed one ends the list.
            $nameRva = [BitConverter]::ToUInt32($b, $descOff + 12)
            if ($nameRva -eq 0) { break }
            $nameOff = 0
            foreach ($s in $sections) {
                $span = [Math]::Max($s.VirtualSize, $s.RawSize)
                if ($nameRva -ge $s.VirtualAddress -and $nameRva -lt ($s.VirtualAddress + $span)) {
                    $nameOff = $s.RawOffset + ($nameRva - $s.VirtualAddress)
                    break
                }
            }
            if ($nameOff -eq 0) { break }
            $imports += Get-NullTerminatedAscii $b $nameOff
            $descOff += 20
        }
    }

    return [pscustomobject]@{
        Machine          = $machine
        Is64Bit          = $is64
        Subsystem        = $subsystem
        SubsystemVersion = "$majSubsystem.$('{0:00}' -f $minSubsystem)"
        MajSubsystem     = $majSubsystem
        MinSubsystem     = $minSubsystem
        Imports          = $imports
    }
}

# ---------------------------------------------------------------------------

# The version must be described in the changelog before it can be released.
$changelog = Join-Path $repoRoot 'CHANGELOG.md'
$pattern = '^## \[' + [regex]::Escape($Version) + '\]'
if (-not (Select-String -Path $changelog -Pattern $pattern -Quiet)) {
    throw "CHANGELOG.md has no [$Version] section"
}

& (Join-Path $winDir 'build.ps1')
if (-not (Test-Path $exe)) { throw "build did not produce $exe" }

$pe = Get-PeInfo $exe

if ($pe.Machine -ne 0x8664) {
    throw ("hdrctl.exe is machine 0x{0:X4}, expected 0x8664 (AMD64/x64)" -f $pe.Machine)
}
if (-not $pe.Is64Bit) { throw "hdrctl.exe is not a 64-bit (PE32+) image" }
if ($pe.Subsystem -ne 3) {
    throw "hdrctl.exe subsystem is $($pe.Subsystem), expected 3 (console)"
}

# Must not demand a Windows newer than 10.0, or it won't load on Windows 10.
if ($pe.MajSubsystem -gt 10 -or ($pe.MajSubsystem -eq 10 -and $pe.MinSubsystem -gt 0)) {
    throw ("hdrctl.exe requires Windows subsystem $($pe.SubsystemVersion), " +
           "which is newer than 10.0 and would not load on Windows 10")
}

# The CRT must be linked statically (/MT), so no VC++ redistributable is needed.
$crt = $pe.Imports | Where-Object {
    $_ -match '^(vcruntime|msvcp|msvcr|ucrtbase|api-ms-win-crt)'
}
if ($crt) {
    throw ("hdrctl.exe imports the C runtime dynamically ($($crt -join ', ')); " +
           "it must be built with /MT so no redistributable is needed")
}

Write-Host "verified hdrctl.exe:"
Write-Host "  machine           x64 (AMD64)"
Write-Host "  subsystem         console, version $($pe.SubsystemVersion)"
Write-Host "  imports           $($pe.Imports -join ', ')"

# ---------------------------------------------------------------------------

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
Remove-Item (Join-Path $dist "$name.zip") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $dist "$name.zip.sha256") -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item $exe                                   $stage
Copy-Item (Join-Path $winDir   'm27p6s-hdr.ps1') $stage
Copy-Item (Join-Path $repoRoot 'monitor_db.json') $stage
Copy-Item (Join-Path $repoRoot 'README.md')      $stage
Copy-Item (Join-Path $repoRoot 'CHANGELOG.md')   $stage
Copy-Item (Join-Path $repoRoot 'LICENSE')        $stage

# -Path on the directory keeps the folder inside the zip, like ditto --keepParent.
Compress-Archive -Path $stage -DestinationPath (Join-Path $dist "$name.zip") -Force

$zip  = Join-Path $dist "$name.zip"
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
# Same two-space layout as `shasum -a 256`, so it verifies with sha256sum -c.
"$hash  $name.zip" | Set-Content -Path "$zip.sha256" -Encoding ascii

Remove-Item $stage -Recurse -Force

Write-Host ""
Write-Host "Built dist/$name.zip"
Write-Host "$hash  $name.zip"
