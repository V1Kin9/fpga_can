param(
    [string]$Top = "tb_can_rx_top",
    [string]$VivadoBin = "C:\Xilinx\Vivado\2020.1\bin",
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$work = Join-Path $env:TEMP ("fpga_can_sim_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$exit = 1
try {
    $sources = @(Get-ChildItem (Join-Path $projectRoot "rtl") -Filter "*.v" -File) +
               @(Get-ChildItem (Join-Path $projectRoot "tb") -Filter "*.sv" -File)
    foreach ($source in $sources) {
        Copy-Item -LiteralPath $source.FullName -Destination $work
    }
    Push-Location $work
    try {
        & (Join-Path $VivadoBin "xvlog.bat") -sv @($sources.Name)
        if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }
        & (Join-Path $VivadoBin "xelab.bat") $Top -s "${Top}_sim"
        if ($LASTEXITCODE -ne 0) { throw "xelab failed" }
        & (Join-Path $VivadoBin "xsim.bat") "${Top}_sim" -runall 2>&1 |
            Tee-Object -FilePath "xsim_console.log"
        if ($LASTEXITCODE -ne 0) { throw "xsim failed" }
        if (Select-String -LiteralPath "xsim_console.log" -Pattern '^(Fatal:|\[FAIL\])' -Quiet) {
            throw "testbench reported failure"
        }
        if (-not (Select-String -LiteralPath "xsim_console.log" -Pattern '^\[PASS\]' -Quiet)) {
            throw "testbench did not report PASS"
        }
        $exit = 0
    } catch {
        Write-Host $_
        throw
    } finally {
        Pop-Location
    }
} catch {
    Write-Host "Simulation failed: $_"
} finally {
    if ($exit -eq 0 -and -not $KeepArtifacts) {
        $tempRoot = (Resolve-Path -LiteralPath $env:TEMP).Path.TrimEnd('\')
        $resolved = (Resolve-Path -LiteralPath $work).Path
        if ($resolved.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -match '^fpga_can_sim_[0-9a-f]{32}$' -and
            -not ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    } else {
        Write-Host "Simulation files: $work"
    }
}
exit $exit
