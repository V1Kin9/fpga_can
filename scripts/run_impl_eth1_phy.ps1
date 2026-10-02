param(
    [string]$VivadoBin = "C:\Xilinx\Vivado\2020.1\bin",
    [string]$WorkRoot = $env:TEMP,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$workRootPath = (New-Item -ItemType Directory -Path $WorkRoot -Force).FullName
$work = Join-Path $workRootPath ("fpga_can_eth1_phy_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$work = (Resolve-Path -LiteralPath $work).Path
$files = @(
    'rtl/reset_sync.v',
    'rtl/mdio_clause22_reader.v',
    'rtl/eth1_phy_probe_core.v',
    'rtl/eth1_phy_probe_top.v',
    'constraints/kintex7_base_eth1_phy.xdc',
    'scripts/impl_eth1_phy.tcl'
)
$exit = 1
try {
    $hashes = [ordered]@{}
    foreach ($path in $files) {
        $source = Join-Path $root $path
        $target = Join-Path $work (Split-Path -Leaf $path)
        Copy-Item -LiteralPath $source -Destination $target
        $hashes[$path] = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    }
    $hashes['scripts/run_impl_eth1_phy.ps1'] =
        (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    $gitSafeRoot = $root.Replace('\','/')
    $sourceHead = (& git -c "safe.directory=$gitSafeRoot" -C $root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify source Git HEAD' }
    $trackedPaths = $files + @('scripts/run_impl_eth1_phy.ps1')
    $sourceDirty = @(& git -c "safe.directory=$gitSafeRoot" -C $root status --porcelain -- $trackedPaths).Count -ne 0
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect source Git status' }

    Push-Location $work
    try {
        & (Join-Path $VivadoBin 'vivado.bat') -mode batch -source (Join-Path $work 'impl_eth1_phy.tcl') -nolog -nojournal 2>&1 |
            Tee-Object -FilePath 'impl_console.log'
        if ($LASTEXITCODE -ne 0) { throw 'Vivado ETH1 implementation failed' }
        if (-not (Select-String -LiteralPath 'impl_console.log' -Pattern 'ETH1_PHY_IMPL_PASS' -Quiet)) {
            throw 'Vivado did not reach the completion marker'
        }
        $blocking = @(Select-String -LiteralPath 'impl_console.log' -Pattern '^(ERROR:|CRITICAL WARNING:)' |
            Where-Object { $_.Line -notmatch '^CRITICAL WARNING: \[Common 17-741\] No write access right to the local Tcl store' })
        if ($blocking.Count -ne 0) { throw 'Vivado reported an error or critical warning' }
        foreach ($name in @('eth1_phy.bit','eth1_phy.ltx','routed_timing.rpt','routed_drc.rpt','routed_bus_skew.rpt','check_timing.rpt')) {
            if (-not (Test-Path -LiteralPath $name)) { throw "Missing output: $name" }
        }
        if (-not (Select-String -LiteralPath 'routed_timing.rpt' -Pattern 'All user specified timing constraints are met' -Quiet)) {
            throw 'Routed timing constraints are not met'
        }
        if (Select-String -LiteralPath 'routed_bus_skew.rpt' -Pattern 'Slack \(VIOLATED\)' -Quiet) {
            throw 'Routed bus skew constraint violated'
        }
        foreach ($path in $files) {
            $target = Join-Path $work (Split-Path -Leaf $path)
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $hashes[$path]) {
                throw "Staged source changed during implementation: $path"
            }
        }
        $provenance = [pscustomobject]@{
            SchemaVersion = 1
            SourceGitHead = $sourceHead
            SourceTreeDirty = $sourceDirty
            SourceFilesSha256 = $hashes
            Part = 'xc7k325tffg676-2'
            Top = 'eth1_phy_probe_top'
            BitstreamSha256 = (Get-FileHash -LiteralPath 'eth1_phy.bit' -Algorithm SHA256).Hash
            ProbesSha256 = (Get-FileHash -LiteralPath 'eth1_phy.ltx' -Algorithm SHA256).Hash
            BuildUtc = [DateTime]::UtcNow.ToString('o')
        }
        $provenance | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath 'provenance.json' -Encoding UTF8
        $output = Join-Path $root 'build\eth1_phy_impl'
        New-Item -ItemType Directory -Force -Path $output | Out-Null
        Copy-Item -Path '*.rpt','*.bit','*.ltx','*.dcp' -Destination $output
        Copy-Item -LiteralPath 'impl_console.log','provenance.json' -Destination $output
        Write-Host "ETH1_PHY_IMPL_PASS; outputs: $output"
        $exit = 0
    } finally { Pop-Location }
} catch {
    Write-Host "ETH1 implementation failed: $_"
} finally {
    if ($exit -eq 0 -and -not $KeepArtifacts) {
        $resolved = (Resolve-Path -LiteralPath $work).Path
        $tempRoot = $workRootPath.TrimEnd('\')
        if ($resolved.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -match '^fpga_can_eth1_phy_[0-9a-f]{32}$' -and
            -not ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    } else { Write-Host "ETH1 implementation files: $work" }
}
exit $exit
