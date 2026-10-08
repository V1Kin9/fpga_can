$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$runner = Join-Path $PSScriptRoot 'run_impl_eth1_udp.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('fpga_can_impl_test_' + [guid]::NewGuid().ToString('N'))
$originalTop = $env:FPGA_CAN_TOP
$originalBitrate = $env:FPGA_CAN_BITRATE
$originalLocation = (Get-Location).Path
$passed = 0

function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -cne $Expected) { throw "${Name}: expected '$Expected', got '$Actual'" }
    $script:passed++
}

# The fixture is not a Git checkout. Only the wrapper's read-only provenance
# queries are mocked; its staging, launch, checks, and finally blocks run intact.
function git {
    $global:LASTEXITCODE = 0
    if ($args -contains 'rev-parse') { '0000000000000000000000000000000000000000' }
    elseif ($args -notcontains 'status') { throw "Unexpected Git command: $args" }
}

try {
    $source = Join-Path $fixture 'source'
    $bin = Join-Path $fixture 'bin'
    foreach ($path in @($source, $bin, (Join-Path $source 'scripts'),
        (Join-Path $source 'rtl'), (Join-Path $source 'constraints'))) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    $fixtureRunner = Join-Path $source 'scripts/run_impl_eth1_udp.ps1'
    Copy-Item -LiteralPath $runner -Destination $fixtureRunner
    foreach ($path in @('rtl/fixture.v', 'constraints/kintex7_base_eth1_udp.xdc',
        'constraints/kintex7_base_eth1_can_udp.xdc', 'scripts/impl_eth1_udp.tcl')) {
        Set-Content -LiteralPath (Join-Path $source $path) -Value '# Synthetic test input only'
    }

    # These native stubs create synthetic reports and return a controlled status.
    # No Vivado installation, HDL tool, hardware, or actual Tcl is executed.
    $windows = [IO.Path]::DirectorySeparatorChar -eq '\'
    foreach ($outcome in @('success', 'nonzero', 'launch-error')) {
        $nativeExit = if ($outcome -eq 'nonzero') { 23 } else { 0 }
        if ($windows) {
            $stub = @'
@echo off
>vivado_environment.txt echo %FPGA_CAN_TOP%
>>vivado_environment.txt echo %FPGA_CAN_BITRATE%
>eth1_udp.bit echo synthetic bitstream
>routed_timing.rpt echo All user specified timing constraints are met
>routed_drc.rpt echo Violations found: 0
type nul >rgmii_setup.rpt
type nul >rgmii_hold.rpt
type nul >check_timing.rpt
type nul >fixture.dcp
echo ETH1_UDP_IMPL_PASS
exit /b NATIVE_EXIT
'@
        } else {
            $stub = @'
#!/bin/sh
printf '%s\n' "$FPGA_CAN_TOP" "$FPGA_CAN_BITRATE" >vivado_environment.txt
printf '%s\n' 'synthetic bitstream' >eth1_udp.bit
printf '%s\n' 'All user specified timing constraints are met' >routed_timing.rpt
printf '%s\n' 'Violations found: 0' >routed_drc.rpt
: >rgmii_setup.rpt
: >rgmii_hold.rpt
: >check_timing.rpt
: >fixture.dcp
printf '%s\n' 'ETH1_UDP_IMPL_PASS'
exit NATIVE_EXIT
'@
        }
        $stubPath = Join-Path $bin 'vivado.bat'
        Set-Content -LiteralPath $stubPath -Value ($stub.Replace('NATIVE_EXIT', [string]$nativeExit)) -Encoding ASCII
        if (-not $windows) {
            & chmod +x $stubPath
            if ($LASTEXITCODE -ne 0) { throw 'Cannot make the native test stub executable' }
        }
        $vivadoBin = if ($outcome -eq 'launch-error') { Join-Path $fixture 'missing-bin' } else { $bin }

        # Cover absent, present, and independently absent caller variables.
        foreach ($state in @('absent', 'present', 'top-only', 'bitrate-only')) {
            $expectedTop = if ($state -in @('present', 'top-only')) { 'caller_top' } else { $null }
            $expectedBitrate = if ($state -in @('present', 'bitrate-only')) { 'caller_bitrate' } else { $null }
            $env:FPGA_CAN_TOP = $expectedTop
            $env:FPGA_CAN_BITRATE = $expectedBitrate
            $caseName = "$outcome/$state"
            $workRoot = Join-Path $fixture "$outcome-$state"
            $output = & $fixtureRunner -VivadoBin $vivadoBin -WorkRoot $workRoot `
                -Top eth1_can_udp_top -CanBitrate 250000 -KeepArtifacts 6>&1 | Out-String
            $wrapperExit = $LASTEXITCODE

            Assert-Equal $wrapperExit $(if ($outcome -eq 'success') { 0 } else { 1 }) "$caseName exit status"
            Assert-Equal $env:FPGA_CAN_TOP $expectedTop "$caseName restores FPGA_CAN_TOP"
            Assert-Equal $env:FPGA_CAN_BITRATE $expectedBitrate "$caseName restores FPGA_CAN_BITRATE"
            Assert-Equal (Test-Path Env:FPGA_CAN_TOP) ($null -ne $expectedTop) "$caseName top presence"
            Assert-Equal (Test-Path Env:FPGA_CAN_BITRATE) ($null -ne $expectedBitrate) "$caseName bitrate presence"
            Assert-Equal (Get-Location).Path $originalLocation "$caseName restores location"
            Assert-Equal ($output -like '*ETH1_UDP_IMPL_PASS; outputs:*') ($outcome -eq 'success') "$caseName success marker"
            if ($outcome -eq 'nonzero') {
                Assert-Equal ($output -like '*Vivado ETH1 implementation failed*') $true "$caseName detects native failure"
            }
            $work = @(Get-ChildItem -LiteralPath $workRoot -Directory)
            Assert-Equal $work.Count 1 "$caseName staged directory"
            $environmentPath = Join-Path $work[0].FullName 'vivado_environment.txt'
            if ($outcome -eq 'launch-error') {
                Assert-Equal (Test-Path -LiteralPath $environmentPath) $false "$caseName never launched"
                Assert-Equal ($output -like '*ETH1 implementation failed:*') $true "$caseName reports launch failure"
            } else {
                $observed = @(Get-Content -LiteralPath $environmentPath)
                Assert-Equal $observed.Count 2 "$caseName observed environment"
                Assert-Equal $observed[0] 'eth1_can_udp_top' "$caseName passes selected top"
                Assert-Equal $observed[1] '250000' "$caseName passes selected bitrate"
            }
        }
    }
} finally {
    $env:FPGA_CAN_TOP = $originalTop
    $env:FPGA_CAN_BITRATE = $originalBitrate
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
Write-Host "[PASS] $passed ETH1 implementation environment regressions (synthetic native stubs only)"
exit 0
