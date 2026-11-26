# make_video.ps1
#
# Packs an animated GIF (or a synthetic test clip) into the .yxv container the
# FPGA video mode plays: 16-byte header + raw RGB565 frames, 32-bit words with
# two pixels each (high half = left pixel, low half = right pixel).
#
# The player upscales by an integer factor at read time, so the source size
# must divide 1280x720 exactly: 320x180 (4x), 256x144 (5x), 160x90 (8x).
#
#   .\make_video.ps1 -GifPath clip.gif -SrcW 320 -SrcH 180
#   .\make_video.ps1                      # synthetic test clip

param(
    [string]$GifPath = '',
    [string]$OutFile = 'D:\yingxu_work\media\video\clip.yxv',
    [ValidateSet(320,256,160)][int]$SrcW = 320,
    [int]$SrcH = 180,
    [int]$Fps = 15,
    [int]$MaxFrames = 52
)

Add-Type -AssemblyName System.Drawing

function Convert-ToRGB565([System.Drawing.Color]$c) {
    $r = [int]($c.R -shr 3); $g = [int]($c.G -shr 2); $b = [int]($c.B -shr 3)
    return [uint16](($r -shl 11) -bor ($g -shl 5) -bor $b)
}

# ---- collect source frames as 320x180 bitmaps ------------------------------
$frames = New-Object System.Collections.ArrayList

if ($GifPath -ne '' -and (Test-Path $GifPath)) {
    $img = [System.Drawing.Image]::FromFile((Resolve-Path $GifPath))
    $dim = New-Object System.Drawing.Imaging.FrameDimension($img.FrameDimensionsList[0])
    $n = $img.GetFrameCount($dim)
    "GIF frames: $n"
    for ($i = 0; $i -lt [Math]::Min($n, $MaxFrames); $i++) {
        [void]$img.SelectActiveFrame($dim, $i)
        $bmp = New-Object System.Drawing.Bitmap $SrcW, $SrcH, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Black)
        $g.DrawImage($img, 0, 0, $SrcW, $SrcH)
        $g.Dispose()
        [void]$frames.Add($bmp)
    }
    $img.Dispose()
}
else {
    "No GIF given - generating a synthetic test clip."
    $font = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold)
    for ($i = 0; $i -lt $MaxFrames; $i++) {
        $bmp = New-Object System.Drawing.Bitmap $SrcW, $SrcH, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
        # colour bars that slide
        $bars = @(192,224,248,176,96,64)
        for ($b = 0; $b -lt $bars.Count; $b++) {
            $x = (($b * [int]($SrcW / $bars.Count)) + ($i * 4)) % $SrcW
            $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($bars[$b] * 0.45, $bars[$b] * 0.6, $bars[$b]))
            $g.FillRectangle($brush, $x, 0, [int]($SrcW / $bars.Count), [int]($SrcH * 0.55))
            if ($x + [int]($SrcW / $bars.Count) -gt $SrcW) {
                $g.FillRectangle($brush, $x - $SrcW, 0, [int]($SrcW / $bars.Count), [int]($SrcH * 0.55))
            }
            $brush.Dispose()
        }
        # bouncing ball
        $t = $i / [double]$MaxFrames
        $bx = [int](($SrcW - 24) * (0.5 - 0.5 * [Math]::Cos(2 * [Math]::PI * $t)))
        $by = [int](($SrcH * 0.55) + ($SrcH * 0.35) * [Math]::Abs([Math]::Sin(3 * [Math]::PI * $t)))
        $wb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $g.FillEllipse($wb, $bx, $by, 24, 24)
        $wb.Dispose()
        # frame counter
        $txt = "YXV {0:d2}/{1:d2}  {2}x{3} {4}fps" -f ($i+1), $MaxFrames, $SrcW, $SrcH, $Fps
        $g.DrawString($txt, $font, [System.Drawing.Brushes]::White, 6, ($SrcH - 28))
        $g.Dispose()
        [void]$frames.Add($bmp)
    }
}

"frames to encode: $($frames.Count)"

# ---- write the container ---------------------------------------------------
$dir = Split-Path $OutFile -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$wordPerFrame = [int]($SrcW * $SrcH / 2)
$scale = [int](1280 / $SrcW)

$fs = [System.IO.File]::Create($OutFile)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([System.Text.Encoding]::ASCII.GetBytes('YXV1'))
$bw.Write([uint16]$SrcW); $bw.Write([uint16]$SrcH)
$bw.Write([uint16]$frames.Count); $bw.Write([byte]$Fps); $bw.Write([byte]$scale)
$bw.Write([uint32]0)          # reserved -> 16-byte header

foreach ($bmp in $frames) {
    $rect = New-Object System.Drawing.Rectangle 0,0,$SrcW,$SrcH
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $stride = $data.Stride
    $buf = New-Object byte[] ($stride * $SrcH)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
    $bmp.UnlockBits($data)
    for ($y = 0; $y -lt $SrcH; $y++) {
        $row = $y * $stride
        for ($x = 0; $x -lt $SrcW; $x += 2) {
            $o1 = $row + $x * 3
            $c1 = [System.Drawing.Color]::FromArgb($buf[$o1+2], $buf[$o1+1], $buf[$o1])
            $o2 = $row + ($x + 1) * 3
            $c2 = [System.Drawing.Color]::FromArgb($buf[$o2+2], $buf[$o2+1], $buf[$o2])
            $w = ([uint32](Convert-ToRGB565 $c1) -shl 16) -bor [uint32](Convert-ToRGB565 $c2)
            $bw.Write($w)
        }
    }
    $bmp.Dispose()
}
$bw.Close(); $fs.Close()

$size = (Get-Item $OutFile).Length
$sectors = [math]::Ceiling($size / 512)
[pscustomobject]@{
    File      = $OutFile
    Frames    = $frames.Count
    SrcSize   = "$SrcW x $SrcH"
    Scale     = "${scale}x"
    WordsPerFrame = $wordPerFrame
    Bytes     = $size
    Sectors   = $sectors
    Duration  = "{0:N1} s @ {1} fps" -f ($frames.Count / $Fps), $Fps
    LoadTime  = "{0:N1} s @ 0.7 MB/s" -f ($size / 0.7e6)
} | Format-List