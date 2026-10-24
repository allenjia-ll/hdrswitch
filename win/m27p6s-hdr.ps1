#!/usr/bin/env pwsh
# Calls hdrctl with the M27P6S defaults (Windows).
#
#   .\m27p6s-hdr.ps1 on       HDR on  + local dimming Standard
#   .\m27p6s-hdr.ps1 off      HDR off + local dimming Off
#   .\m27p6s-hdr.ps1 toggle   flip between on and off
#   .\m27p6s-hdr.ps1 status   show HDR state and local dimming (default)
#
# Override the target display with the DISPLAY_NAME environment variable.
$ErrorActionPreference = 'Stop'

$action = if ($args.Count -gt 0) { $args[0] } else { 'status' }

$displayName = if ($env:DISPLAY_NAME) { $env:DISPLAY_NAME } else { 'M27P6S' }

$hdrctl = Join-Path $PSScriptRoot 'hdrctl.exe'
if (-not (Test-Path $hdrctl)) {
    $onPath = Get-Command hdrctl -ErrorAction SilentlyContinue
    if ($onPath) {
        $hdrctl = $onPath.Source
    } else {
        [Console]::Error.WriteLine("hdrctl.exe not found next to this script or on PATH. Run .\build.ps1 first.")
        exit 1
    }
}

switch ($action) {
    { $_ -in 'on', 'off', 'toggle', 'status' } {
        & $hdrctl --display $displayName $action
        exit $LASTEXITCODE
    }
    default {
        [Console]::Error.WriteLine("usage: m27p6s-hdr.ps1 [on|off|toggle|status]")
        exit 1
    }
}
