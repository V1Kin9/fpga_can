$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot 'check_eth1_phy_capture.ps1'

# Load the actual helpers without executing the capture checker entry point.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($checker, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Cannot parse capture checker: $parseErrors" }
foreach ($name in @('Hex-Value', 'Get-HighBit')) {
    $definition = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Missing checker helper: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$passed = 0
function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -cne $Expected) { throw "${Name}: expected '$Expected', got '$Actual'" }
    $script:passed++
}
function Assert-Throws([scriptblock]$Action, [string]$Message, [string]$Name) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    if (-not $caught -or $caught -notlike "*$Message*") {
        throw "${Name}: expected '$Message', got '$caught'"
    }
    $script:passed++
}
function New-Sample([string]$Bit, [string]$Mdc = '1', [string]$Busy = '1', [int]$Index = 47) {
    [pscustomobject]@{
        debug_mdio_in = $Bit
        debug_mdc = $Mdc
        debug_mdio_busy = $Busy
        'debug_mdio_bit_index[6:0]' = $Index.ToString('x2')
    }
}

foreach ($bit in @('0', '1')) {
    Assert-Equal (Get-HighBit @((New-Sample $bit), (New-Sample $bit)) 47) $bit "stable $bit, run ends at EOF"
}
foreach ($bits in @(@('1', '0'), @('0', '1'))) {
    Assert-Equal (Get-HighBit @((New-Sample $bits[0]), (New-Sample $bits[1])) 47) $bits[1] "late $($bits[0])->$($bits[1])"
}
Assert-Equal (Get-HighBit @(
    (New-Sample '1' -Mdc '0'), (New-Sample '1' -Busy '0'),
    (New-Sample '1' -Index 46), (New-Sample '0')
) 47) '0' 'skip nonmatches before first run'
foreach ($boundary in @(
    (New-Sample '1' -Mdc '0'), (New-Sample '1' -Busy '0'), (New-Sample '1' -Index 48)
)) {
    Assert-Equal (Get-HighBit @(
        (New-Sample '1'), (New-Sample '0'), $boundary, (New-Sample '1'), (New-Sample '1')
    ) 47) '0' "first run ends at MDC=$($boundary.debug_mdc) busy=$($boundary.debug_mdio_busy) index=$($boundary.'debug_mdio_bit_index[6:0]')"
}
Assert-Throws { Get-HighBit @() 47 } 'Missing MDC-high bit 47' 'empty input'
Assert-Throws { Get-HighBit @(
    (New-Sample '0' -Mdc '0'), (New-Sample '0' -Busy '0'), (New-Sample '0' -Index 48)
) 47 } 'Missing MDC-high bit 47' 'missing matching bit'

# Exercise the full checker on synthetic 4096-row ILA CSVs. These fixtures
# verify decoding and rejection behavior; they provide no hardware evidence.
$capture = Join-Path ([IO.Path]::GetTempPath()) ('fpga_can_capture_test_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $capture | Out-Null
try {
    $statusPath = Join-Path $capture 'eth1_phy_status.csv'
    $idPath = Join-Path $capture 'eth1_phy_mdio_1.csv'
    $bmsrPath = Join-Path $capture 'eth1_phy_mdio_2.csv'
    $statusRows = @(for ($i = 0; $i -lt 4096; $i++) {
        [pscustomobject]@{
            'Sample in Buffer' = $i
            debug_snapshot_pulse = $(if ($i -eq 0) { '1' } else { '0' })
            'debug_found_mask[31:0]' = '00000002'
            'debug_found_addr[4:0]' = '01'
            debug_found_valid = '1'
            'debug_phy_id1[15:0]' = '001c'
            'debug_phy_id2[15:0]' = 'c915'
            'debug_bmcr[15:0]' = '1140'
            'debug_bmsr[15:0]' = '7949'
            'debug_physr[15:0]' = '4040'
            debug_mmcm_locked = '1'
            debug_phy_rstn = '1'
            debug_clk125_toggle = ($i % 2).ToString()
            debug_link_up = '0'
        }
    })
    $statusRows | Export-Csv -LiteralPath $statusPath -NoTypeInformation

    function Write-RawCapture([string]$Path, [int]$Register, [int]$Value, [switch]$Late) {
        $command = '011000001' + [Convert]::ToString($Register, 2).PadLeft(5, '0')
        $bits = $command + '0' + [Convert]::ToString($Value, 2).PadLeft(16, '0')
        $previous = '1'
        $rows = [System.Collections.Generic.List[object]]::new()
        for ($slot = 0; $slot -lt $bits.Length; $slot++) {
            for ($cycle = 0; $cycle -lt 40; $cycle++) {
                $bit = $bits[$slot].ToString()
                if ($Late -and $slot -ge 14 -and $cycle -lt 39) { $bit = $previous }
                $rows.Add([pscustomobject]@{
                    'Sample in Buffer' = $rows.Count
                    debug_mdc = $(if ($cycle -lt 20) { '0' } else { '1' })
                    debug_mdio_busy = '1'
                    'debug_mdio_bit_index[6:0]' = ($slot + 32).ToString('x2')
                    debug_mdio_in = $bit
                    'debug_mdio_phy_addr[4:0]' = '01'
                    'debug_mdio_reg_addr[4:0]' = $Register.ToString('x2')
                })
            }
            $previous = $bits[$slot].ToString()
        }
        while ($rows.Count -lt 4096) {
            # Later transaction bits 32-37 must not override the first command.
            $later = $rows.Count - 2000
            $rows.Add([pscustomobject]@{
                'Sample in Buffer' = $rows.Count
                debug_mdc = $(if ($later -ge 0 -and $later -lt 240 -and $later % 40 -ge 20) { '1' } else { '0' })
                debug_mdio_busy = $(if ($later -ge 0 -and $later -lt 240) { '1' } else { '0' })
                'debug_mdio_bit_index[6:0]' = $(if ($later -ge 0 -and $later -lt 240) { (32 + [int][Math]::Floor($later / 40)).ToString('x2') } else { '00' })
                debug_mdio_in = '1'
                'debug_mdio_phy_addr[4:0]' = '01'
                'debug_mdio_reg_addr[4:0]' = $Register.ToString('x2')
            })
        }
        $rows | Export-Csv -LiteralPath $Path -NoTypeInformation
    }
    function Assert-CapturePass([string]$Name) {
        $output = & $checker -CaptureDir $capture 6>&1 | Out-String
        if ($output -notlike '*ETH1_PHY_CAPTURE_VERIFIED*') { throw "${Name}: checker did not verify capture" }
        $script:passed++
    }

    Write-RawCapture $idPath 2 0x001c
    Write-RawCapture $bmsrPath 1 0x7949
    Assert-CapturePass 'stable capture with a following transaction'
    Write-RawCapture $idPath 2 0x001c -Late
    Write-RawCapture $bmsrPath 1 0x7949 -Late
    Assert-CapturePass 'late turnaround/data capture'

    Write-RawCapture $idPath 2 0x000e
    Assert-Throws { & $checker -CaptureDir $capture } 'ETH1 raw PHYID1 mismatch: 0x000e' 'shifted PHYID1'
    Write-RawCapture $idPath 2 0x001c
    foreach ($value in @(0, 0xffff)) {
        Write-RawCapture $bmsrPath 1 $value
        Assert-Throws { & $checker -CaptureDir $capture } 'ETH1 raw BMSR is invalid' "invalid raw BMSR $value"
        Write-RawCapture $bmsrPath 1 $value -Late
        Assert-Throws { & $checker -CaptureDir $capture } 'ETH1 raw BMSR is invalid' "late invalid raw BMSR $value"
    }
    Write-RawCapture $bmsrPath 1 0x7949
    foreach ($register in @('bmcr', 'bmsr', 'physr')) {
        $column = "debug_${register}[15:0]"
        $original = $statusRows[0].$column
        $statusRows[0].$column = 'ffff'
        $statusRows | Export-Csv -LiteralPath $statusPath -NoTypeInformation
        Assert-Throws { & $checker -CaptureDir $capture } "ETH1 $($register.ToUpperInvariant()) status read is invalid" "failed snapshot $register"
        $statusRows[0].$column = $original
    }
    $statusRows[0].'debug_bmsr[15:0]' = '0000'
    $statusRows | Export-Csv -LiteralPath $statusPath -NoTypeInformation
    Assert-Throws { & $checker -CaptureDir $capture } 'ETH1 BMSR status read is invalid' 'zero snapshot BMSR'
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolved = (Resolve-Path -LiteralPath $capture).Path
    if ($resolved.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -match '^fpga_can_capture_test_[0-9a-f]{32}$' -and
        -not ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host "[PASS] $passed ETH1 capture checker regressions (synthetic samples only)"
