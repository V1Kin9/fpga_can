param(
    [string]$VivadoBin = "C:\Xilinx\Vivado\2020.1\bin",
    [switch]$KeepArtifacts,
    [string]$WorkRoot = $env:TEMP
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$work = Join-Path $WorkRoot ("fpga_can_impl_ila_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$exit = 1
try {
    Get-ChildItem (Join-Path $root "rtl") -Filter "*.v" -File | Copy-Item -Destination $work
    Copy-Item -LiteralPath (Join-Path $root "constraints\kintex7_base_can.xdc") -Destination $work
    Copy-Item -LiteralPath (Join-Path $root "scripts\impl_ila.tcl") -Destination $work
    Push-Location $work
    try {
        & (Join-Path $VivadoBin "vivado.bat") -mode batch -source (Join-Path $work "impl_ila.tcl") -nolog -nojournal 2>&1 |
            Tee-Object -FilePath "impl_console.log"
        if ($LASTEXITCODE -ne 0) { throw "Vivado implementation failed" }
        if (-not (Select-String -LiteralPath "impl_console.log" -Pattern 'CAN_ILA_IMPL_PASS' -Quiet)) {
            throw "Vivado did not reach the implementation completion marker"
        }
        # This host reports a Tcl Store cache permission warning at Vivado startup.
        # It is unrelated to the design; keep rejecting every other critical warning.
        $blocking = @(Select-String -LiteralPath "impl_console.log" -Pattern '^(ERROR:|CRITICAL WARNING:)' |
            Where-Object { $_.Line -notmatch '^CRITICAL WARNING: \[Common 17-741\] No write access right to the local Tcl store' })
        if ($blocking.Count -ne 0) {
            throw "Vivado reported an error or critical warning"
        }
        foreach ($name in @("can_ila.bit", "can_ila.ltx", "routed_timing.rpt", "routed_drc.rpt", "routed_bus_skew.rpt")) {
            if (-not (Test-Path -LiteralPath $name)) { throw "Missing output: $name" }
        }
        $reports = Join-Path $root "build\impl_ila"
        New-Item -ItemType Directory -Force -Path $reports | Out-Null
        Copy-Item -Path "*.rpt","*.bit","*.ltx","*.dcp" -Destination $reports
        Copy-Item -LiteralPath "impl_console.log" -Destination $reports
        Write-Host "CAN_ILA_IMPL_PASS; outputs: $reports"
        $exit = 0
    } finally {
        Pop-Location
    }
} catch {
    Write-Host "ILA implementation failed: $_"
} finally {
    if ($exit -eq 0 -and -not $KeepArtifacts) {
        $tempRoot = (Resolve-Path -LiteralPath $WorkRoot).Path.TrimEnd('\')
        $resolved = (Resolve-Path -LiteralPath $work).Path
        if ($resolved.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -match '^fpga_can_impl_ila_[0-9a-f]{32}$' -and
            -not ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    } else {
        Write-Host "ILA implementation files: $work"
    }
}
exit $exit
