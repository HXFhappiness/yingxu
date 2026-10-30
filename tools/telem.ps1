# telem.ps1 ????COM5 ??? 3 ???????????????
$sp = New-Object System.IO.Ports.SerialPort('COM5',115200,'None',8,'One')
$sp.ReadTimeout = 200
$sp.Open()
$deadline = (Get-Date).AddSeconds(3)
$lines = New-Object System.Collections.Generic.List[string]
while ((Get-Date) -lt $deadline) {
    try { $s = $sp.ReadLine(); if ($s.Trim()) { $lines.Add($s.Trim()) } }
    catch { }
}
$sp.Close()
# ????????? D ??????????$lines | ForEach-Object { $_ } | Select-Object -Last 16
