param(
    [string]$VivadoBin = "C:\Xilinx\Vivado\2020.1\bin",
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$work = Join-Path $env:TEMP ("fpga_can_synth_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$exit = 1
try {
    Copy-Item -LiteralPath (Join-Path $root "constraints\kintex7_base_can.xdc") -Destination $work
    Get-ChildItem (Join-Path $root "rtl") -Filter "*.v" -File |
        Copy-Item -Destination $work
    Set-Content -LiteralPath (Join-Path $work "synth.tcl") -Encoding Ascii -Value @(
        'read_verilog [glob *.v]'
        'read_xdc kintex7_base_can.xdc'
        'synth_design -top can_sniffer_top -part xc7k325tffg676-2'
        'report_utilization -file utilization.rpt'
        'report_timing_summary -file timing_summary.rpt'
        'report_drc -file drc.rpt'
        'puts "CAN_SYNTH_PASS"'
        'exit'
    )
    Push-Location $work
    try {
        & (Join-Path $VivadoBin "vivado.bat") -mode batch -source synth.tcl -nolog -nojournal 2>&1 |
            Tee-Object -FilePath "synth_console.log"
        if ($LASTEXITCODE -ne 0) { throw "Vivado synthesis failed" }
        if (-not (Select-String -LiteralPath "synth_console.log" -Pattern 'CAN_SYNTH_PASS' -Quiet)) {
            throw "Vivado did not reach the synthesis completion marker"
        }
        if (Select-String -LiteralPath "synth_console.log" -Pattern '(^ERROR:|^CRITICAL WARNING:)' -Quiet) {
            throw "Vivado reported an error or critical warning"
        }
        $reports = Join-Path $root "build\synth"
        New-Item -ItemType Directory -Force -Path $reports | Out-Null
        Copy-Item -LiteralPath "synth_console.log","utilization.rpt","timing_summary.rpt","drc.rpt" -Destination $reports
        Write-Host "CAN_SYNTH_PASS; reports: $reports"
        $exit = 0
    } finally {
        Pop-Location
    }
} catch {
    Write-Host "Synthesis failed: $_"
} finally {
    if ($exit -eq 0 -and -not $KeepArtifacts) {
        $tempRoot = (Resolve-Path -LiteralPath $env:TEMP).Path.TrimEnd('\')
        $resolved = (Resolve-Path -LiteralPath $work).Path
        if ($resolved.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -match '^fpga_can_synth_[0-9a-f]{32}$' -and
            -not ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    } else {
        Write-Host "Synthesis files: $work"
    }
}
exit $exit
