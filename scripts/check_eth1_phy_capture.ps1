param([Parameter(Mandatory)][string]$CaptureDir)

$ErrorActionPreference = 'Stop'
$paths = @{
    status = Join-Path $CaptureDir 'eth1_phy_status.csv'
    id1 = Join-Path $CaptureDir 'eth1_phy_mdio_1.csv'
    bmsr = Join-Path $CaptureDir 'eth1_phy_mdio_2.csv'
}
foreach ($entry in $paths.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value)) {
        throw "Missing ETH1 ILA capture: $($entry.Value)"
    }
}

function Read-Samples([string]$Path) {
    $rows = @(Import-Csv -LiteralPath $Path | Where-Object { $_.'Sample in Buffer' -match '^\d+$' })
    if ($rows.Count -ne 4096) { throw "Incomplete ETH1 ILA capture: $Path" }
    return $rows
}

function Hex-Value([string]$Value) {
    return [Convert]::ToUInt32($Value, 16)
}

function Get-HighBit($Samples, [int]$Index) {
    $lastMatch = $null
    foreach ($row in $Samples) {
        if ($row.debug_mdc -eq '1' -and $row.debug_mdio_busy -eq '1' -and
            (Hex-Value $row.'debug_mdio_bit_index[6:0]') -eq $Index) {
            $lastMatch = $row
        } elseif ($null -ne $lastMatch) {
            break
        }
    }
    # Match the RTL's falling-edge sample without crossing into a later read.
    if ($null -ne $lastMatch) { return $lastMatch.debug_mdio_in }
    throw "Missing MDC-high bit $Index in raw ETH1 MDIO capture"
}

$statusRows = Read-Samples $paths.status
$status = $statusRows | Where-Object { $_.debug_snapshot_pulse -eq '1' } | Select-Object -First 1
if (-not $status) { throw 'ETH1 status snapshot did not trigger' }
if ((Hex-Value $status.'debug_found_mask[31:0]') -ne 2 -or
    (Hex-Value $status.'debug_found_addr[4:0]') -ne 1 -or
    $status.debug_found_valid -ne '1' -or
    (Hex-Value $status.'debug_phy_id1[15:0]') -ne 0x001c -or
    ((Hex-Value $status.'debug_phy_id2[15:0]') -band 0xfff0) -ne 0xc910 -or
    $status.debug_mmcm_locked -ne '1' -or $status.debug_phy_rstn -ne '1') {
    throw "ETH1 PHY identity/reset mismatch: mask=$($status.'debug_found_mask[31:0]') addr=$($status.'debug_found_addr[4:0]') ID=$($status.'debug_phy_id1[15:0]'):$($status.'debug_phy_id2[15:0]')"
}
foreach ($register in @('bmcr', 'bmsr', 'physr')) {
    $column = "debug_${register}[15:0]"
    $value = Hex-Value $status.$column
    if ($value -eq 0xffff -or ($register -eq 'bmsr' -and $value -eq 0)) {
        throw "ETH1 $($register.ToUpperInvariant()) status read is invalid: $($status.$column)"
    }
}
if (@($statusRows | Select-Object -ExpandProperty debug_clk125_toggle -Unique).Count -ne 2) {
    throw 'ETH1 125 MHz heartbeat did not toggle in the ILA window'
}

$idRows = Read-Samples $paths.id1
$bmsrRows = Read-Samples $paths.bmsr
if ((Hex-Value $idRows[0].'debug_mdio_phy_addr[4:0]') -ne 1 -or
    (Hex-Value $idRows[0].'debug_mdio_reg_addr[4:0]') -ne 2 -or
    (Hex-Value $bmsrRows[0].'debug_mdio_phy_addr[4:0]') -ne 1 -or
    (Hex-Value $bmsrRows[0].'debug_mdio_reg_addr[4:0]') -ne 1) {
    throw 'ETH1 raw MDIO captures are not PHY 1 ID1 and BMSR reads'
}
$command = -join (32..45 | ForEach-Object { Get-HighBit $idRows $_ })
if ($command -ne '01100000100010' -or (Get-HighBit $idRows 46) -ne '0') {
    throw "ETH1 MDIO read command/turnaround mismatch: $command"
}
$idBits = -join (47..62 | ForEach-Object { Get-HighBit $idRows $_ })
$rawId = [Convert]::ToUInt16($idBits, 2)
if ($rawId -ne 0x001c) { throw ('ETH1 raw PHYID1 mismatch: 0x{0:x4}' -f $rawId) }
$bmsrBits = -join (47..62 | ForEach-Object { Get-HighBit $bmsrRows $_ })
$rawBmsr = [Convert]::ToUInt16($bmsrBits, 2)
if ($rawBmsr -eq 0 -or $rawBmsr -eq 0xffff) {
    throw ('ETH1 raw BMSR is invalid: 0x{0:x4}' -f $rawBmsr)
}

Write-Host ('ETH1_PHY_CAPTURE_VERIFIED addr=1 PHYID=001c:{0} BMCR={1} BMSR={2} PHYSR={3} link={4}' -f
    $status.'debug_phy_id2[15:0]', $status.'debug_bmcr[15:0]',
    $status.'debug_bmsr[15:0]', $status.'debug_physr[15:0]', $status.debug_link_up)
