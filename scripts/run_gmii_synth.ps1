param(
    [string]$VivadoBin = "C:\Xilinx\Vivado\2020.1\bin",
    [string]$WorkRoot = $env:TEMP,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$workRootResolved = (Resolve-Path -LiteralPath $WorkRoot).Path
$work = Join-Path $workRootResolved ("fpga_can_gmii_synth_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$exit = 1
try {
    Get-ChildItem (Join-Path $root "rtl") -Filter "*.v" -File |
        Copy-Item -Destination $work
    Copy-Item -LiteralPath (Join-Path $root "constraints\gmii_virtual_clocks.xdc") -Destination $work
    Copy-Item -LiteralPath (Join-Path $root "scripts\synth_gmii.tcl") -Destination $work
    Push-Location $work
    try {
        & (Join-Path $VivadoBin "vivado.bat") -mode batch -source synth_gmii.tcl -nolog -nojournal -tclargs $work 2>&1 |
            Tee-Object -FilePath "synth_console.log"
        if ($LASTEXITCODE -ne 0) { throw "Vivado GMII synthesis failed" }
        if (-not (Select-String -LiteralPath "synth_console.log" -Pattern 'GMII_SYNTH_PASS' -Quiet)) {
            throw "Vivado did not reach the GMII synthesis completion marker"
        }
        if (Select-String -LiteralPath "synth_console.log" -Pattern '(^ERROR:|^CRITICAL WARNING:)' -Quiet) {
            throw "Vivado reported an error or critical warning"
        }
        foreach ($name in @("utilization.rpt", "utilization_hierarchical.rpt",
                           "timing_summary.rpt", "check_timing.rpt", "clock_interaction.rpt",
                           "drc.rpt", "cdc.rpt")) {
            if (-not (Test-Path -LiteralPath $name)) { throw "Missing report: $name" }
        }
        $reports = Join-Path $root "build\gmii_synth"
        New-Item -ItemType Directory -Force -Path $reports | Out-Null
        Copy-Item -Path "*.rpt","*.dcp" -Destination $reports
        Copy-Item -LiteralPath "synth_console.log" -Destination $reports
        Write-Host "GMII_SYNTH_PASS; reports: $reports"
        $exit = 0
    } finally {
        Pop-Location
    }
} catch {
    Write-Host "GMII synthesis failed: $_"
} finally {
    if ($exit -eq 0 -and -not $KeepArtifacts) {
        $tempRoot = $workRootResolved.TrimEnd('\')
        $resolved = (Resolve-Path -LiteralPath $work).Path
        if ($resolved.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -match '^fpga_can_gmii_synth_[0-9a-f]{32}$' -and
            -not ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    } else {
        Write-Host "GMII synthesis files: $work"
    }
}
exit $exit
