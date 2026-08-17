# Proves the Today screen - the one Microsoft reports blank after onboarding - actually renders on
# the installed Windows build.
#
# WHY SEED INSTEAD OF CLICK
# The runner will not accept repeated synthetic mouse clicks (walk-onboarding.ps1 advances exactly
# one screen then freezes), so onboarding cannot be walked here. Instead this writes a finished
# day-1 state to %APPDATA%\TheLongView\state.json, which makes the app skip onboarding and open
# straight on Today. That is the exact screen the certifier reaches, tested without any clicking.
# Mac renders this screen fine under both hardware and software rendering and even from a trimmed
# jpackage runtime, so if it is blank it is blank ONLY on the installed Windows build, which is what
# Microsoft saw.

param([string]$OutDir = "artifacts")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type @"
using System; using System.Runtime.InteropServices;
public class T {
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@

$dataDir = Join-Path $env:APPDATA "TheLongView"
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$stateFile = Join-Path $dataDir "state.json"
$crashFile = Join-Path $dataDir "crash.log"
if (Test-Path $crashFile) { Remove-Item $crashFile -Force }
$today = (Get-Date).ToString('yyyy-MM-dd')
# Hand-written to match kotlinx.serialization's shape exactly (a real state.json from a Mac install).
$state = @"
{
  "profile": { "currentAge": 40, "sex": "female", "yearsSmoking": 10.0, "baselineCigarettesPerDay": 10.0 },
  "ledger": {},
  "settings": { "dailyReminderTime": "20:00", "deadlineLocalTime": "00:00", "pricePerPack": 12.75, "cigarettesPerPack": 20.0 },
  "trackingStartDay": "$today"
}
"@
Set-Content -Path $stateFile -Value $state -Encoding UTF8
Write-Host "seeded $stateFile (trackingStartDay=$today)"

Get-Process -Name "The Long View" -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Seconds 3
$exe = Get-ChildItem "$env:LOCALAPPDATA\The Long View" -Recurse -Filter "The Long View.exe" -EA SilentlyContinue | Select-Object -First 1
if (-not $exe) { throw "no installed 'The Long View.exe' under $env:LOCALAPPDATA" }
Write-Host "launching $($exe.FullName)"
Start-Process -FilePath $exe.FullName
Start-Sleep -Seconds 14

$proc = Get-Process -Name "The Long View" -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) {
  Write-Host "::error::The app has no window after launching on the seeded Today state - it crashed or never drew."
} else {
  $h = $proc.MainWindowHandle
  [T]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 800
  $cr = New-Object T+RECT; [T]::GetClientRect($h, [ref]$cr) | Out-Null
  $o = New-Object T+POINT; $o.X = 0; $o.Y = 0; [T]::ClientToScreen($h, [ref]$o) | Out-Null
  $cw = $cr.Right - $cr.Left; $ch = $cr.Bottom - $cr.Top
  $bmp = New-Object System.Drawing.Bitmap $cw, $ch
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen((New-Object System.Drawing.Point $o.X, $o.Y), [System.Drawing.Point]::Empty, (New-Object System.Drawing.Size $cw, $ch))
  $g.Dispose()
  $bmp.Save("$OutDir/today.png")
  # content fraction: 1 - (share of the single most common colour). A blank screen is one flat colour.
  $counts = @{}; $tot = 0
  for ($y = 0; $y -lt $ch; $y += 5) { for ($x = 0; $x -lt $cw; $x += 5) {
    $p = $bmp.GetPixel($x, $y); $k = "$([int]($p.R/16))-$([int]($p.G/16))-$([int]($p.B/16))"
    $counts[$k] = 1 + $counts[$k]; $tot++
  } }
  $topShare = (($counts.Values | Measure-Object -Maximum).Maximum) / [double]$tot
  $content = 1.0 - $topShare
  Write-Host ("Today screen content: {0:P2} (client ${cw}x${ch})" -f $content)
  if ($content -lt 0.02) { Write-Host "::error::The Today screen is BLANK on Windows ($([math]::Round($content*100,2))% content). This is the 10.1.2.10 failure." }
  else { Write-Host "The Today screen renders content on Windows." }
}

if (Test-Path $crashFile) {
  Write-Host "=== crash.log ==="
  Get-Content $crashFile | ForEach-Object { Write-Host $_ }
  Copy-Item $crashFile "$OutDir/crash.log" -Force
} else { Write-Host "no crash.log written" }
