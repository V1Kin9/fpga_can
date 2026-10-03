param(
    [string]$PortName = 'COM7',
    [ValidateRange(1,64)][int]$Count = 3,
    [string]$FrameCommand = 't1231A5'
)

$ErrorActionPreference = 'Stop'
if (-not ([System.IO.Ports.SerialPort]::GetPortNames() -contains $PortName)) {
    throw "CANable serial port not present: $PortName"
}

function Wait-FirmwareBarrier([System.IO.Ports.SerialPort]$port, [string]$command) {
    $port.DiscardInBuffer()
    if ($command) { $port.Write($command + "`rV`r") }
    else { $port.Write("V`r") }
    $response = ''
    $until = [DateTime]::UtcNow.AddSeconds(2)
    while ([DateTime]::UtcNow -lt $until) {
        $response += $port.ReadExisting()
        if ($response.Contains([char]7)) { throw "CANable rejected $command (BEL)" }
        if ($response.EndsWith("2022 0726`r")) {
            if ($response -notmatch '^(?:\r|\n)*2022 0726\r$') {
                throw "Unexpected CANable reply after ${command}: $response"
            }
            return
        }
        Start-Sleep -Milliseconds 10
    }
    throw "CANable did not reach firmware barrier after ${command}: $response"
}

$port = [System.IO.Ports.SerialPort]::new($PortName, 115200,
    [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
try {
    $port.ReadTimeout = 500
    $port.WriteTimeout = 500
    $port.Open()
    Start-Sleep -Milliseconds 100
    Wait-FirmwareBarrier $port ''
    foreach ($setup in @('C', 'S6', 'A0', 'M0', 'O')) {
        Wait-FirmwareBarrier $port $setup
    }
    for ($i = 0; $i -lt $Count; $i++) {
        Wait-FirmwareBarrier $port $FrameCommand
        Start-Sleep -Milliseconds 300
    }
    # The firmware's V barrier confirms command parsing, not CAN bus ACK.
    Write-Host "CANABLE_COMMAND_SENT $Count $FrameCommand $PortName"
} finally {
    if ($port.IsOpen) {
        $port.Write("C`r")
        Start-Sleep -Milliseconds 50
        $port.Close()
    }
    $port.Dispose()
}
