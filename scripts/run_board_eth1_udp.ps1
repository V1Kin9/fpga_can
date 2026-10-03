param(
    [ValidateSet('eth1_fixed_udp_top','eth1_can_udp_top')]
    [string]$Top = 'eth1_fixed_udp_top',
    [ValidateSet(250000,500000)][int]$CanBitrate = 500000,
    [string]$VivadoBin = 'C:\Xilinx\Vivado\2020.1\bin',
    [string]$WorkRoot = $env:TEMP
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($Top -ne 'eth1_can_udp_top' -and $CanBitrate -ne 500000) {
    throw 'CanBitrate applies only to eth1_can_udp_top'
}
$implName = if ($Top -eq 'eth1_can_udp_top' -and $CanBitrate -ne 500000) {
    "${Top}_${CanBitrate}_impl"
} else { "${Top}_impl" }
$implDir = Join-Path $root ("build\$implName")
$provenancePath = Join-Path $implDir 'provenance.json'
if (-not (Test-Path -LiteralPath $provenancePath)) { throw 'ETH1 UDP provenance missing; rebuild bitstream' }
$provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
if ($provenance.SchemaVersion -ne 1 -or $provenance.Top -ne $Top -or
    $provenance.Part -ne 'xc7k325tffg676-2' -or
    -not $provenance.SourceFilesSha256) {
    throw 'ETH1 UDP bitstream provenance is incomplete'
}
if ($Top -eq 'eth1_can_udp_top' -and $provenance.CanBitrate -ne $CanBitrate) {
    throw "ETH1 CAN bitstream bitrate mismatch: expected $CanBitrate"
}
foreach ($property in $provenance.SourceFilesSha256.PSObject.Properties) {
    $path = Join-Path $root ($property.Name -replace '/', '\')
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $property.Value) {
        throw "ETH1 UDP bitstream source mismatch: $($property.Name)"
    }
}
$bitstream = Join-Path $implDir 'eth1_udp.bit'
if ((Get-FileHash -LiteralPath $bitstream -Algorithm SHA256).Hash -ne $provenance.BitstreamSha256) {
    throw 'ETH1 UDP bitstream hash mismatch'
}
if (-not (Select-String -LiteralPath (Join-Path $implDir 'routed_timing.rpt') -Pattern 'All user specified timing constraints are met' -Quiet)) {
    throw 'ETH1 UDP routed timing did not pass'
}
if (-not (Select-String -LiteralPath (Join-Path $implDir 'routed_drc.rpt') -Pattern 'Violations found: 0' -Quiet)) {
    throw 'ETH1 UDP routed DRC did not pass'
}

$workRootPath = (New-Item -ItemType Directory -Path $WorkRoot -Force).FullName
$work = Join-Path $workRootPath ('fpga_can_eth1_program_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$work = (Resolve-Path -LiteralPath $work).Path
Copy-Item -LiteralPath $bitstream,(Join-Path $root 'scripts\program_eth1_udp.tcl'),$provenancePath -Destination $work
Push-Location $work
try {
    $bitTcl = (Join-Path $work 'eth1_udp.bit').Replace('\','/')
    & (Join-Path $VivadoBin 'vivado.bat') -mode batch -nolog -nojournal -source (Join-Path $work 'program_eth1_udp.tcl') -tclargs $bitTcl 2>&1 |
        Tee-Object -FilePath 'program_console.log'
    if ($LASTEXITCODE -ne 0 -or
        -not (Select-String -LiteralPath 'program_console.log' -Pattern 'ETH1_UDP_JTAG_PROGRAM_PASS' -Quiet)) {
        throw 'ETH1 UDP JTAG programming failed; see program_console.log'
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $output = Join-Path $root "build\board_test\${implName}_$stamp"
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    Copy-Item -LiteralPath 'program_console.log','provenance.json' -Destination $output
    Write-Host "ETH1_UDP_JTAG_PROGRAM_PASS; log: $output"
} finally {
    Pop-Location
    Write-Host "ETH1 UDP program staging: $work"
}
