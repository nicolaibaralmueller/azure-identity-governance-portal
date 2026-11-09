<#
.SYNOPSIS
    Regenerates the portal's PNG and ICO favicons from the shapes in src/web-app/favicon.svg.

.DESCRIPTION
    Modern browsers use favicon.svg directly. This script renders the same shield-and-check
    mark with System.Drawing for the fallbacks:
      favicon.ico           16, 32 and 48 px (PNG-encoded entries) — older browsers, /favicon.ico requests
      apple-touch-icon.png  180 px — iOS/iPadOS home screen
    Run it after changing favicon.svg, keeping the coordinates below in step with the SVG.
    Windows only (System.Drawing).

.EXAMPLE
    ./Tools/New-Favicon.ps1
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\src\web-app')
)

Add-Type -AssemblyName System.Drawing

$brand = [System.Drawing.ColorTranslator]::FromHtml('#0f6cbd')

# Draws the 64x64 design scaled to $Size and returns PNG bytes.
function New-IconPng {
    # -Square fills the whole canvas: iOS rounds the corners itself and shows transparent ones as black.
    param([int]$Size, [switch]$Square)
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = $Size / 64.0
    $g.ScaleTransform($s, $s)

    # Rounded square, rx 14
    $bg = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($Square) { $bg.AddRectangle((New-Object System.Drawing.RectangleF 0, 0, 64, 64)) }
    else {
        $r = 28
        $bg.AddArc(0, 0, $r, $r, 180, 90); $bg.AddArc(64 - $r, 0, $r, $r, 270, 90)
        $bg.AddArc(64 - $r, 64 - $r, $r, $r, 0, 90); $bg.AddArc(0, 64 - $r, $r, $r, 90, 90)
        $bg.CloseFigure()
    }
    $g.FillPath((New-Object System.Drawing.SolidBrush $brand), $bg)

    # Shield: M32 9 L51 15.5 V30 C51 42.5 42.5 51 32 55 C21.5 51 13 42.5 13 30 V15.5 Z
    $sh = New-Object System.Drawing.Drawing2D.GraphicsPath
    $sh.AddLine(32, 9, 51, 15.5); $sh.AddLine(51, 15.5, 51, 30)
    $sh.AddBezier(51, 30, 51, 42.5, 42.5, 51, 32, 55)
    $sh.AddBezier(32, 55, 21.5, 51, 13, 42.5, 13, 30)
    $sh.AddLine(13, 30, 13, 15.5); $sh.CloseFigure()
    $g.FillPath([System.Drawing.Brushes]::White, $sh)

    # Check: M22.5 32 L29 38.5 L42 25.5, stroke 5.5, round caps and joins
    $pen = New-Object System.Drawing.Pen $brand, 5.5
    $pen.StartCap = $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawLines($pen, [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF 22.5, 32), (New-Object System.Drawing.PointF 29, 38.5), (New-Object System.Drawing.PointF 42, 25.5)))

    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return , $ms.ToArray()
}

# ICO container holding PNG-encoded images (supported by every browser and Windows Vista+).
function Write-Ico {
    param([string]$Path, [int[]]$Sizes)
    $pngs = @($Sizes | ForEach-Object { , (New-IconPng $_) })
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $ms
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$Sizes.Count)
    $offset = 6 + 16 * $Sizes.Count
    for ($i = 0; $i -lt $Sizes.Count; $i++) {
        $dim = if ($Sizes[$i] -ge 256) { 0 } else { $Sizes[$i] }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $w.Write($p) }
    $w.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
}

$OutDir = (Resolve-Path $OutDir).Path
Write-Ico -Path (Join-Path $OutDir 'favicon.ico') -Sizes 16, 32, 48
[System.IO.File]::WriteAllBytes((Join-Path $OutDir 'apple-touch-icon.png'), (New-IconPng 180 -Square))
Write-Host "Wrote favicon.ico and apple-touch-icon.png to $OutDir"
