# Runs the WHOLE onboarding as one continuous session on the installed Windows build and captures a
# frame every ~1.5s, so a screen that only goes blank mid-flow (a transition, not a screen rendered
# in isolation) is caught. Uses the app's THE_LONG_VIEW_ONBOARDING_AUTOPLAY hook, which advances
# every step on a timer and hands off to Today - no clicking, which the runner refuses to repeat.

param([string]$OutDir = "artifacts")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type @"
using System; using System.Runtime.InteropServices;
public class A {
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@
function ContentFraction($bmp) {
  $counts = @{}; $tot = 0
  for ($y = 0; $y -lt $bmp.Height; $y += 5) { for ($x = 0; $x -lt $bmp.Width; $x += 5) {
    $p = $bmp.GetPixel($x, $y); $k = "$([int]($p.R/16))-$([int]($p.G/16))-$([int]($p.B/16))"
    $counts[$k] = 1 + $counts[$k]; $tot++
  } }
  return 1.0 - ((($counts.Values | Measure-Object -Maximum).Maximum) / [double]$tot)
}

$exe = Get-ChildItem "$env:LOCALAPPDATA\The Long View" -Recurse -Filter "The Long View.exe" -EA SilentlyContinue | Select-Object -First 1
if (-not $exe) { throw "no installed exe" }
$dataDir = Join-Path $env:APPDATA "TheLongView"
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$crashFile = Join-Path $dataDir "crash.log"
$stateFile = Join-Path $dataDir "state.json"
if (Test-Path $stateFile) { Remove-Item $stateFile -Force }   # fresh -> onboarding runs
if (Test-Path $crashFile) { Remove-Item $crashFile -Force }

Get-Process -Name "The Long View" -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Seconds 2
$env:THE_LONG_VIEW_ONBOARDING_AUTOPLAY = "1"
Start-Process -FilePath $exe.FullName
Start-Sleep -Seconds 4

$minContent = 1.0; $minFrame = 0; $sawWindow = $false
for ($f = 1; $f -le 12; $f++) {
  Start-Sleep -Milliseconds 1500
  $proc = Get-Process -Name "The Long View" -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $proc) { Write-Host "frame ${f}: no window"; continue }
  $sawWindow = $true
  $h = $proc.MainWindowHandle
  [A]::SetForegroundWindow($h) | Out-Null
  $cr = New-Object A+RECT; [A]::GetClientRect($h, [ref]$cr) | Out-Null
  $o = New-Object A+POINT; $o.X = 0; $o.Y = 0; [A]::ClientToScreen($h, [ref]$o) | Out-Null
  $cw = $cr.Right - $cr.Left; $ch = $cr.Bottom - $cr.Top
  if ($cw -le 0 -or $ch -le 0) { Write-Host "frame ${f}: zero-size client"; continue }
  $bmp = New-Object System.Drawing.Bitmap $cw, $ch
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen((New-Object System.Drawing.Point $o.X, $o.Y), [System.Drawing.Point]::Empty, (New-Object System.Drawing.Size $cw, $ch))
  $g.Dispose()
  $bmp.Save("$OutDir/auto-{0:D2}.png" -f $f)
  $c = ContentFraction $bmp
  if ($c -lt $minContent) { $minContent = $c; $minFrame = $f }
  Write-Host ("frame {0}: {1:P2} content" -f $f, $c)
}

Write-Host ""
if (Test-Path $crashFile) { Write-Host "--- crash.log ---"; Get-Content $crashFile | ForEach-Object { Write-Host $_ }; Copy-Item $crashFile "$OutDir/crash.log" -Force } else { Write-Host "no crash.log" }
Write-Host ("lowest content across the run: {0:P2} at frame {1}" -f $minContent, $minFrame)
if (-not $sawWindow) { Write-Host "::error::No window at any point during autoplay - the app died." }
elseif ($minContent -lt 0.02) { Write-Host "::error::A frame during the continuous onboarding flow was BLANK ($([math]::Round($minContent*100,2))% at frame $minFrame). See auto-*.png." }
else { Write-Host "The continuous onboarding flow never went blank; it walked to a populated screen." }
