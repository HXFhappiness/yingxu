param(
    [int]$Seconds = 6,
    [string]$Port = 'COM5',
    [string]$Out = 'C:\Users\HXF\Desktop\YX\out\telem_raw.txt'
)
# music_telem.ps1 - capture N seconds of UART telemetry lines to a file (ASCII only:
# PowerShell 5.1 reads .ps1 as ANSI, so non-ASCII comments corrupt the parse)
$sp = New-Object System.IO.Ports.SerialPort
$sp.PortName    = $Port
$sp.BaudRate    = 115200
$sp.Parity      = [System.IO.Ports.Parity]::None
$sp.DataBits    = 8
$sp.StopBits    = [System.IO.Ports.StopBits]::One
$sp.ReadTimeout = 200
try { $sp.Open() } catch { Write-Output ("OPEN FAIL {0} : {1}" -f $Port, $_.Exception.Message); exit 1 }
$lines = New-Object System.Collections.Generic.List[string]
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
    try { $s = $sp.ReadLine(); if ($s -and $s.Trim()) { $lines.Add($s.Trim()) } } catch { }
}
$sp.Close()
Set-Content -Path $Out -Value $lines -Encoding ASCII
Write-Output ("captured {0} lines -> {1}" -f $lines.Count, $Out)
