param(
    [string]$VivadoBin = 'C:\Xilinx\Vivado\2020.1\bin',
    [string]$PortName = 'COM7',
    [string[]]$Cases = @('std_dlc0', 'std_dlc1', 'std_dlc8', 'std_stuff', 'ext_data', 'std_rtr', 'ext_rtr'),
    [int]$ArmTimeoutSeconds = 120,
    [int]$CaptureTimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$catalog = @{
    std_dlc0 = @{ Command='t3210'; Id='00000321'; Ide='0'; Rtr='0'; Dlc='0'; Data='0000000000000000' }
    std_dlc1 = @{ Command='t1231A5'; Id='00000123'; Ide='0'; Rtr='0'; Dlc='1'; Data='00000000000000A5' }
    std_dlc8 = @{ Command='t10081122334455667788'; Id='00000100'; Ide='0'; Rtr='0'; Dlc='8'; Data='8877665544332211' }
    std_stuff = @{ Command='t00080000FFFF0000FFFF'; Id='00000000'; Ide='0'; Rtr='0'; Dlc='8'; Data='FFFF0000FFFF0000' }
    ext_data = @{ Command='T18DAF1102AABB'; Id='18DAF110'; Ide='1'; Rtr='0'; Dlc='2'; Data='000000000000BBAA' }
    std_rtr = @{ Command='r4564'; Id='00000456'; Ide='0'; Rtr='1'; Dlc='4'; Data='0000000000000000' }
    ext_rtr = @{ Command='R01ABCDE32'; Id='01ABCDE3'; Ide='1'; Rtr='1'; Dlc='2'; Data='0000000000000000' }
}
foreach ($name in $Cases) {
    if (-not $catalog.ContainsKey($name)) { throw "Unknown case: $name" }
}
if ($Cases.Count -eq 0) { throw 'At least one case is required' }
if (-not ([System.IO.Ports.SerialPort]::GetPortNames() -contains $PortName)) {
    throw "Serial port not present: $PortName"
}
$vivado = Join-Path $VivadoBin 'vivado.bat'
if (-not (Test-Path -LiteralPath $vivado)) { throw "Vivado not found: $vivado" }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$relativeOut = "build/board_test/matrix_$stamp"
$out = Join-Path $root ($relativeOut -replace '/', '\')
New-Item -ItemType Directory -Path $out -Force | Out-Null
[System.IO.File]::WriteAllLines((Join-Path $out 'cases.txt'), [string[]]$Cases, [System.Text.Encoding]::ASCII)
$stdout = Join-Path $out 'vivado_stdout.log'
$stderr = Join-Path $out 'vivado_stderr.log'
$process = $null
$summary = [System.Collections.Generic.List[object]]::new()

function Wait-Flag([string]$path, [int]$seconds, [System.Diagnostics.Process]$process) {
    $until = [DateTime]::UtcNow.AddSeconds($seconds)
    while ([DateTime]::UtcNow -lt $until) {
        if (Test-Path -LiteralPath $path) { return }
        if ($process.HasExited) { throw "Vivado exited before $(Split-Path -Leaf $path); see $stdout" }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out waiting for $(Split-Path -Leaf $path); see $stdout"
}

function Send-OneShot([string]$command) {
    $port = [System.IO.Ports.SerialPort]::new($PortName, 115200,
        [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
    try {
        $port.ReadTimeout = 500
        $port.WriteTimeout = 500
        $port.Open()
        Start-Sleep -Milliseconds 100
        $port.DiscardInBuffer()
        $port.Write("V`r")
        Start-Sleep -Milliseconds 150
        $version = $port.ReadExisting()
        if ($version -notmatch '2022 0726') { throw "Unexpected CANable firmware: $version" }
        foreach ($setup in @('C', 'S6', 'A0', 'M0', 'O')) {
            $port.Write($setup + "`r")
            Start-Sleep -Milliseconds 40
        }
        $port.DiscardInBuffer()
        $port.Write($command + "`r")
        Start-Sleep -Milliseconds 300
        $reply = $port.ReadExisting()
        if ($reply.Contains([char]7)) { throw "CANable rejected $command (BEL)" }
        return ($reply -replace "`r", '<CR>' -replace "`n", '<LF>')
    } finally {
        if ($port.IsOpen) {
            $port.Write("C`r")
            Start-Sleep -Milliseconds 50
            $port.Close()
        }
        $port.Dispose()
    }
}

function Probe([object]$row, [string]$name) {
    return [string]$row.PSObject.Properties[$name].Value
}

function Verify-Capture([string]$csv, [hashtable]$expected) {
    $rows = @(Import-Csv -LiteralPath $csv | Where-Object { $_.'Sample in Buffer' -match '^\d+$' })
    if ($rows.Count -ne 1024) { throw "Expected 1024 ILA samples, saw $($rows.Count) in $csv" }
    $valid = @($rows | Where-Object { (Probe $_ 'debug_frame_valid') -eq '1' })
    if ($valid.Count -ne 1) { throw "Expected one frame_valid pulse, saw $($valid.Count) in $csv" }
    foreach ($signal in @('debug_error', 'fifo_overflow')) {
        $faults = @($rows | Where-Object { (Probe $_ $signal) -eq '1' })
        if ($faults.Count -ne 0) { throw "$signal pulsed $($faults.Count) times in $csv" }
    }
    $frame = $valid[0]
    $index = [int]$frame.'Sample in Buffer'
    $fields = @{
        'debug_frame_id[28:0]'=$expected.Id
        'debug_frame_ide'=$expected.Ide
        'debug_frame_rtr'=$expected.Rtr
        'debug_dlc[3:0]'=$expected.Dlc
        'debug_frame_data[63:0]'=$expected.Data
        'debug_crc_ok'='1'
        'debug_error'='0'
        'fifo_overflow'='0'
    }
    foreach ($field in $fields.Keys) {
        $actual = (Probe $frame $field).ToUpperInvariant()
        if ($actual -ne $fields[$field].ToUpperInvariant()) {
            throw "$field expected $($fields[$field]) got $actual in $csv"
        }
    }
    $fifo = @($rows | Where-Object { (Probe $_ 'fifo_valid') -eq '1' })
    if ($fifo.Count -ne 1 -or [int]$fifo[0].'Sample in Buffer' -ne ($index + 1)) {
        throw "Expected one FIFO pulse one sample after frame_valid in $csv"
    }
    return (Probe $frame 'debug_timestamp[31:0]')
}

try {
    $process = Start-Process -FilePath $vivado -WorkingDirectory $root -WindowStyle Hidden `
        -ArgumentList @('-mode','batch','-nolog','-nojournal',
                        '-source','scripts/board_can_capture.tcl','-tclargs',$relativeOut) `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    foreach ($name in $Cases) {
        Wait-Flag (Join-Path $out "$name.armed") $ArmTimeoutSeconds $process
        $reply = Send-OneShot $catalog[$name].Command
        Wait-Flag (Join-Path $out "$name.captured") $CaptureTimeoutSeconds $process
        $csv = Join-Path $out "$name.csv"
        $timestamp = Verify-Capture $csv $catalog[$name]
        $summary.Add([pscustomobject]@{
            Case=$name; Command=$catalog[$name].Command; FrameId=$catalog[$name].Id
            Ide=$catalog[$name].Ide; Rtr=$catalog[$name].Rtr; Dlc=$catalog[$name].Dlc
            Data=$catalog[$name].Data; FpgaTimestamp=$timestamp; SerialReply=$reply
            Result='PASS'
        })
        Write-Host "BOARD_MATRIX_PASS $name id=$($catalog[$name].Id) dlc=$($catalog[$name].Dlc)"
    }
    if (-not $process.WaitForExit(30000) -or $process.ExitCode -ne 0) {
        throw "Vivado did not complete successfully; see $stdout"
    }
    $summary | Export-Csv -LiteralPath (Join-Path $out 'summary.csv') -NoTypeInformation
    [pscustomobject]@{
        GitHead = (& git -c "safe.directory=$($root.Replace('\','/'))" rev-parse HEAD).Trim()
        BitstreamSha256 = (Get-FileHash -LiteralPath (Join-Path $root 'build/impl_ila/can_ila.bit') -Algorithm SHA256).Hash
        ProbesSha256 = (Get-FileHash -LiteralPath (Join-Path $root 'build/impl_ila/can_ila.ltx') -Algorithm SHA256).Hash
        Port = $PortName
        CanBitrate = 500000
        RunUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'manifest.json') -Encoding UTF8
    Write-Host "BOARD_MATRIX_COMPLETE $out"
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
