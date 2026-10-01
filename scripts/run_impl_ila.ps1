param(
    [string]$VivadoBin = "C:\Xilinx\Vivado\2020.1\bin",
    [switch]$KeepArtifacts,
    [string]$WorkRoot = $env:TEMP
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$workRootPath = (New-Item -ItemType Directory -Path $WorkRoot -Force).FullName
$work = Join-Path $workRootPath ("fpga_can_impl_ila_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$work = (Resolve-Path -LiteralPath $work).Path
$exit = 1
try {
    Get-ChildItem (Join-Path $root "rtl") -Filter "*.v" -File | Copy-Item -Destination $work
    Copy-Item -LiteralPath (Join-Path $root "constraints\kintex7_base_can.xdc") -Destination $work
    Copy-Item -LiteralPath (Join-Path $root "scripts\impl_ila.tcl") -Destination $work
    $sourceHashes = [ordered]@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $work -Filter '*.v' -File | Sort-Object Name)) {
        $sourceHashes["rtl/$($file.Name)"] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    foreach ($entry in @(
        @{ Path='constraints/kintex7_base_can.xdc'; Name='kintex7_base_can.xdc' },
        @{ Path='scripts/impl_ila.tcl'; Name='impl_ila.tcl' }
    )) {
        $sourceHashes[$entry.Path] = (Get-FileHash -LiteralPath (Join-Path $work $entry.Name) -Algorithm SHA256).Hash
    }
    $sourceHashes['scripts/run_impl_ila.ps1'] = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    $gitSafeRoot = $root.Replace('\','/')
    $sourceGitHead = (& git -c "safe.directory=$gitSafeRoot" -C $root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify source Git HEAD' }
    $sourceTreeDirty = @(& git -c "safe.directory=$gitSafeRoot" -C $root status --porcelain -- rtl constraints/kintex7_base_can.xdc scripts/impl_ila.tcl scripts/run_impl_ila.ps1).Count -ne 0
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect source Git status' }
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
        foreach ($path in $sourceHashes.Keys) {
            $sourceFile = if ($path -eq 'scripts/run_impl_ila.ps1') { $PSCommandPath }
                else { Join-Path $work (Split-Path -Leaf $path) }
            $actual = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
            if ($actual -ne $sourceHashes[$path]) { throw "Staged source changed during implementation: $path" }
        }
        [pscustomobject]@{
            SchemaVersion = 1
            SourceGitHead = $sourceGitHead
            SourceTreeDirty = $sourceTreeDirty
            SourceFilesSha256 = $sourceHashes
            Part = 'xc7k325tffg676-2'
            Top = 'can_sniffer_top'
            BitstreamSha256 = (Get-FileHash -LiteralPath 'can_ila.bit' -Algorithm SHA256).Hash
            ProbesSha256 = (Get-FileHash -LiteralPath 'can_ila.ltx' -Algorithm SHA256).Hash
            BuildUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath 'provenance.json' -Encoding UTF8
        $reports = Join-Path $root "build\impl_ila"
        New-Item -ItemType Directory -Force -Path $reports | Out-Null
        Copy-Item -Path "*.rpt","*.bit","*.ltx","*.dcp" -Destination $reports
        Copy-Item -LiteralPath "impl_console.log","provenance.json" -Destination $reports
        Write-Host "CAN_ILA_IMPL_PASS; outputs: $reports"
        $exit = 0
    } finally {
        Pop-Location
    }
} catch {
    Write-Host "ILA implementation failed: $_"
} finally {
    if ($exit -eq 0 -and -not $KeepArtifacts) {
        $tempRoot = $workRootPath.TrimEnd('\')
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
