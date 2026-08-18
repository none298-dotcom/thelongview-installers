# Renders each onboarding screen in isolation on the installed Windows build and reports which, if
# any, is blank. Uses the app's THE_LONG_VIEW_ONBOARDING_STEP env hook to open straight on a named
# step, so no clicking is needed (the runner will not accept the repeated clicks a walk needs).
# Microsoft failed the app with a blank screen "after the first round of Q&A"; welcome, age and the
# Today screen are already proven to render, so this pins down which middle question breaks.

param([string]$OutDir = "artifacts")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type @"
using System; using System.Runtime.InteropServices;
public class O {
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@

$exe = Get-ChildItem "$env:LOCALAPPDATA\The Long View" -Recurse -Filter "The Long View.exe" -EA SilentlyContinue | Select-Object -First 1
if (-not $exe) { throw "no installed 'The Long View.exe'" }
$dataDir = Join-Path $env:APPDATA "TheLongView"
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$crashFile = Join-Path $dataDir "crash.log"
$stateFile = Join-Path $dataDir "state.json"

function ContentFraction($bmp) {
  $counts = @{}; $tot = 0
  for ($y = 0; $y -lt $bmp.Height; $y += 5) { for ($x = 0; $x -lt $bmp.Width; $x += 5) {
    $p = $bmp.GetPixel($x, $y); $k = "$([int]($p.R/16))-$([int]($p.G/16))-$([int]($p.B/16))"
    $counts[$k] = 1 + $counts[$k]; $tot++
  } }
  return 1.0 - ((($counts.Values | Measure-Object -Maximum).Maximum) / [double]$tot)
}

$steps = @("WELCOME", "AGE", "SEX", "YEARS_SMOKING", "CIGARETTES_PER_DAY", "PHOTO", "CLOSING")
$blank = @()
foreach ($s in $steps) {
  Get-Process -Name "The Long View" -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
  Start-Sleep -Seconds 2
  if (Test-Path $stateFile) { Remove-Item $stateFile -Force }   # no state -> onboarding shows
  if (Test-Path $crashFile) { Remove-Item $crashFile -Force }
  $env:THE_LONG_VIEW_ONBOARDING_STEP = $s
  Start-Process -FilePath $exe.FullName
  Start-Sleep -Seconds 11

  $proc = Get-Process -Name "The Long View" -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $proc) {
    Write-Host "step ${s}: NO WINDOW (crashed or never drew)"
    $blank += $s
    if (Test-Path $crashFile) { Write-Host "--- crash.log ($s) ---"; Get-Content $crashFile | ForEach-Object { Write-Host $_ }; Copy-Item $crashFile "$OutDir/crash-$s.log" -Force }
    continue
  }
  $h = $proc.MainWindowHandle
  [O]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 700
  $cr = New-Object O+RECT; [O]::GetClientRect($h, [ref]$cr) | Out-Null
  $o = New-Object O+POINT; $o.X = 0; $o.Y = 0; [O]::ClientToScreen($h, [ref]$o) | Out-Null
  $cw = $cr.Right - $cr.Left; $ch = $cr.Bottom - $cr.Top
  $bmp = New-Object System.Drawing.Bitmap $cw, $ch
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen((New-Object System.Drawing.Point $o.X, $o.Y), [System.Drawing.Point]::Empty, (New-Object System.Drawing.Size $cw, $ch))
  $g.Dispose()
  $bmp.Save("$OutDir/step-$s.png")
  $content = ContentFraction $bmp
  $verdict = if ($content -lt 0.02) { "BLANK"; $blank += $s } else { "ok" }
  Write-Host ("step {0}: {1} ({2:P2} content, {3}x{4})" -f $s, $verdict, $content, $cw, $ch)
  if (Test-Path $crashFile) { Write-Host "--- crash.log ($s) ---"; Get-Content $crashFile | ForEach-Object { Write-Host $_ }; Copy-Item $crashFile "$OutDir/crash-$s.log" -Force }
}

Write-Host ""
if ($blank.Count -gt 0) { Write-Host "::error::Blank onboarding step(s) on Windows: $($blank -join ', ')" }
else { Write-Host "Every onboarding step rendered content on Windows." }
