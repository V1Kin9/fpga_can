param(
    [string]$VivadoBin = "C:\Xilinx\Vivado\2020.1\bin"
)

$ErrorActionPreference = "Stop"
$tops = @(
    "tb_bit_timing",
    "tb_bit_timing_resync",
    "tb_destuff",
    "tb_parser_standard",
    "tb_crc15",
    "tb_fifo_if",
    "tb_can_frame_queue",
    "tb_can_udp_payload_packetizer",
    "tb_can_udp_pipeline_top",
    "tb_udp_ipv4_eth_frame_builder",
    "tb_can_udp_ipv4_eth_pipeline_top",
    "tb_eth_frame_cdc_buffer",
    "tb_ethernet_mac_tx",
    "tb_sniffer_top",
    "tb_can_rx_top"
)
foreach ($top in $tops) {
    Write-Host "=== $top ==="
    & (Join-Path $PSScriptRoot "run_sim.ps1") -Top $top -VivadoBin $VivadoBin
    if ($LASTEXITCODE -ne 0) {
        throw "$top failed"
    }
}
Write-Host "[PASS] All $($tops.Count) CAN simulation tops"
