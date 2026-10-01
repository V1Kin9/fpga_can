param(
    [string]$VivadoBin = 'C:\Xilinx\Vivado\2020.1\bin',
    [string]$WorkRoot = $env:TEMP,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$implDir = Join-Path $root 'build\eth1_phy_impl'
$provenancePath = Join-Path $implDir 'provenance.json'
if (-not (Test-Path -LiteralPath $provenancePath)) { throw 'ETH1 provenance missing; rebuild bitstream' }
$provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
if ($provenance.SchemaVersion -ne 1 -or $provenance.Top -ne 'eth1_phy_probe_top' -or
    $provenance.Part -ne 'xc7k325tffg676-2' -or $provenance.SourceTreeDirty -or
    -not $provenance.SourceFilesSha256) {
    throw 'ETH1 bitstream provenance is incomplete or was built from uncommitted sources'
}
$gitSafeRoot = $root.Replace('\','/')
$currentHead = (& git -c "safe.directory=$gitSafeRoot" -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $currentHead -ne $provenance.SourceGitHead) {
    throw 'ETH1 bitstream Git HEAD does not match current checkout'
}
foreach ($property in $provenance.SourceFilesSha256.PSObject.Properties) {
    $path = Join-Path $root ($property.Name -replace '/', '\')
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $property.Value) {
        throw "ETH1 bitstream source mismatch: $($property.Name)"
    }
}
$bitstream = Join-Path $implDir 'eth1_phy.bit'
$probes = Join-Path $implDir 'eth1_phy.ltx'
if ((Get-FileHash -LiteralPath $bitstream -Algorithm SHA256).Hash -ne $provenance.BitstreamSha256 -or
    (Get-FileHash -LiteralPath $probes -Algorithm SHA256).Hash -ne $provenance.ProbesSha256) {
    throw 'ETH1 bitstream/probes hash mismatch'
}

$workRootPath = (New-Item -ItemType Directory -Path $WorkRoot -Force).FullName
$work = Join-Path $workRootPath ('fpga_can_eth1_board_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$work = (Resolve-Path -LiteralPath $work).Path
$success = $false
try {
    $captureTcl = Join-Path $root 'scripts\board_eth1_phy_capture.tcl'
    Copy-Item -LiteralPath @($bitstream,$probes,$provenancePath,$captureTcl) -Destination $work
    Push-Location $work
    try {
        & (Join-Path $VivadoBin 'vivado.bat') -mode batch -nolog -nojournal -source (Join-Path $work 'board_eth1_phy_capture.tcl') -tclargs $work 2>&1 |
            Tee-Object -FilePath 'board_console.log'
        if ($LASTEXITCODE -ne 0 -or
            -not (Select-String -LiteralPath 'board_console.log' -Pattern 'ETH1_PHY_BOARD_CAPTURE_PASS' -Quiet)) {
            throw 'ETH1 JTAG capture failed; see board_console.log'
        }
        foreach ($name in @('eth1_phy_snapshot_1.csv','eth1_phy_snapshot_2.csv')) {
            if (-not (Test-Path -LiteralPath $name)) { throw "Missing ILA capture: $name" }
        }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $output = Join-Path $root "build\board_test\eth1_phy_$stamp"
        New-Item -ItemType Directory -Force -Path $output | Out-Null
        Copy-Item -LiteralPath @('eth1_phy_snapshot_1.csv','eth1_phy_snapshot_2.csv','board_console.log','provenance.json') -Destination $output
        Write-Host "ETH1_PHY_BOARD_CAPTURE_PASS; outputs: $output"
        $success = $true
    } finally { Pop-Location }
} finally {
    if ($success -and -not $KeepArtifacts) {
        $resolved = (Resolve-Path -LiteralPath $work).Path
        $tempRoot = $workRootPath.TrimEnd('\')
        if ($resolved.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -match '^fpga_can_eth1_board_[0-9a-f]{32}$' -and
            -not ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            try { Remove-Item -LiteralPath $resolved -Recurse -Force }
            catch { Write-Warning "Capture succeeded; temporary Vivado files remain locked at $resolved" }
        }
    } else { Write-Host "ETH1 board files: $work" }
}
