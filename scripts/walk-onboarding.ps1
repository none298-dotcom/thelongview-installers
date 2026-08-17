# Walks the ENTIRE onboarding to the main screen and proves the main screen is not blank.
#
# WHY THIS EXISTS
# verify-ui.ps1 clicks the primary button ONCE and proves it did something. That covers the welcome
# screen and the first transition. It does NOT reach the end of onboarding, and Microsoft Store
# certification failed 2026-08-17 with exactly that gap: "does not display any content after the
# first round of Q&A" - a blank white screen once the questions are answered. This walks every step
# and screenshots each, so where a blank first appears is visible, and it fails if the final screen
# is blank.
#
# HOW IT WALKS WITHOUT ACCESSIBILITY
# Same constraint as verify-ui.ps1: Compose Desktop publishes no semantics tree, so the only handle
# is the footer button found by appearance (the lowest wide, thick block of non-background colour).
# Click it, screenshot, repeat. One step (the sex question) has its Continue DISABLED until an
# option is chosen, so if a footer click does not change the screen, an option row is clicked and
# the footer retried. That adaptive retry only fires when the button is dead, so the photo step -
# whose "Skip for now" button is always live - advances before any content is clicked, and its
# file-picker is never opened.

param([int]$SettleMs = 1500, [string]$OutDir = "artifacts", [int]$MaxSteps = 9)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@

function Grab($rect) {
  $bmp = New-Object System.Drawing.Bitmap $rect.Width, $rect.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($rect.Location, [System.Drawing.Point]::Empty, $rect.Size)
  $g.Dispose(); return $bmp
}
function Click($x, $y) {
  [W]::SetCursorPos($x, $y) | Out-Null; Start-Sleep -Milliseconds 250
  [W]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 60
  [W]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  [W]::SetCursorPos(2, 2) | Out-Null; Start-Sleep -Milliseconds $SettleMs
}
function DiffFraction($a, $b) {
  if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) { return 1.0 }
  $d = 0; $t = 0
  for ($y = 0; $y -lt $a.Height; $y += 4) { for ($x = 0; $x -lt $a.Width; $x += 4) {
    $t++; $p = $a.GetPixel($x, $y); $q = $b.GetPixel($x, $y)
    if ([Math]::Abs($p.R-$q.R) -gt 8 -or [Math]::Abs($p.G-$q.G) -gt 8 -or [Math]::Abs($p.B-$q.B) -gt 8) { $d++ }
  } }
  return $d / [double]$t
}
# Fraction of pixels that are NOT the single most common colour. A blank screen is one flat colour,
# so this is near zero. A real screen (text, buttons, a hero number, cards) is well above it.
function ContentFraction($bmp) {
  $counts = @{}; $t = 0
  for ($y = 0; $y -lt $bmp.Height; $y += 5) { for ($x = 0; $x -lt $bmp.Width; $x += 5) {
    $p = $bmp.GetPixel($x, $y); $k = "$([int]($p.R/16))-$([int]($p.G/16))-$([int]($p.B/16))"
    $counts[$k] = 1 + ($counts[$k]); $t++
  } }
  $top = ($counts.Values | Measure-Object -Maximum).Maximum
  return 1.0 - ($top / [double]$t)
}
function LongestRun($bmp, $y, $bg) {
  $run = 0; $start = 0; $bestRun = 0; $bestStart = 0
  for ($x = 0; $x -lt $bmp.Width; $x++) {
    $p = $bmp.GetPixel($x, $y)
    $isBg = ([Math]::Abs($p.R-$bg.R) -le 12 -and [Math]::Abs($p.G-$bg.G) -le 12 -and [Math]::Abs($p.B-$bg.B) -le 12)
    if (-not $isBg) { if ($run -eq 0) { $start = $x }; $run++ }
    else { if ($run -gt $bestRun) { $bestRun = $run; $bestStart = $start }; $run = 0 }
  }
  if ($run -gt $bestRun) { $bestRun = $run; $bestStart = $start }
  return @($bestRun, $bestStart)
}
function FindFooter($bmp, $bg, $cw, $ch) {
  $MIN_RUN = 100; $MIN_ROWS = 20
  $curTop = -1; $curRuns = @(); $curStarts = @(); $blocks = @()
  for ($y = [int]($ch * 0.5); $y -lt $ch; $y++) {
    $r = LongestRun $bmp $y $bg
    if ($r[0] -ge $MIN_RUN) { if ($curTop -lt 0) { $curTop = $y; $curRuns = @(); $curStarts = @() }; $curRuns += $r[0]; $curStarts += $r[1] }
    elseif ($curTop -ge 0) { if (($y - $curTop) -ge $MIN_ROWS) { $blocks += [pscustomobject]@{ Top=$curTop; Bottom=$y; Width=($curRuns|Measure-Object -Maximum).Maximum; Start=($curStarts|Measure-Object -Minimum).Minimum } }; $curTop = -1 }
  }
  if ($curTop -ge 0 -and ($ch - $curTop) -ge $MIN_ROWS) { $blocks += [pscustomobject]@{ Top=$curTop; Bottom=$ch; Width=($curRuns|Measure-Object -Maximum).Maximum; Start=($curStarts|Measure-Object -Minimum).Minimum } }
  return ($blocks | Sort-Object Top -Descending | Select-Object -First 1)
}

# ── locate the window client rect ────────────────────────────────────────────
$proc = Get-Process -Name "The Long View" -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { throw "No 'The Long View' window" }
$h = $proc.MainWindowHandle
[W]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 900
$cr = New-Object W+RECT; [W]::GetClientRect($h, [ref]$cr) | Out-Null
$o = New-Object W+POINT; $o.X = 0; $o.Y = 0; [W]::ClientToScreen($h, [ref]$o) | Out-Null
$cw = $cr.Right - $cr.Left; $ch = $cr.Bottom - $cr.Top
$rect = New-Object System.Drawing.Rectangle $o.X, $o.Y, $cw, $ch
Write-Host "client ${cw}x${ch} at ($($o.X),$($o.Y))"

$blankAt = -1
for ($i = 1; $i -le $MaxSteps; $i++) {
  # Re-focus every step. Compose Desktop drops mouse input when its window is not the foreground
  # one, and the first click (or the parked cursor) can leave it not-foreground, which looks exactly
  # like a frozen app: the screen renders but never advances.
  [W]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 400
  $shot = Grab $rect; $shot.Save("$OutDir/walk-{0:D2}-a.png" -f $i)
  $content = ContentFraction $shot
  Write-Host ("step {0}: content {1:P2}" -f $i, $content)
  if ($content -lt 0.01) { Write-Host "::error::Step $i is BLANK (one flat colour, no content)."; $blankAt = $i; break }

  $bg = $shot.GetPixel([int]($cw * 0.5), [int]($ch * 0.45))
  $btn = FindFooter $shot $bg $cw $ch
  if (-not $btn) { Write-Host "step ${i}: no footer button found (may be the main screen already)"; break }
  $bx = $o.X + $btn.Start + [int]($btn.Width / 2); $by = $o.Y + [int](($btn.Top + $btn.Bottom) / 2)
  Click $bx $by
  $after = Grab $rect; $after.Save("$OutDir/walk-{0:D2}-b.png" -f $i)

  if ((DiffFraction $shot $after) -lt 0.01) {
    # Button was dead: the sex step, whose Continue is disabled until an option is chosen. Click the
    # first option row (upper-middle of the content column), then the footer again.
    Write-Host "step ${i}: footer inert, selecting an option (sex step) and retrying"
    Click ($o.X + [int]($cw * 0.5)) ($o.Y + [int]($ch * 0.42))
    $btn2 = FindFooter (Grab $rect) $bg $cw $ch
    if ($btn2) { Click ($o.X + $btn2.Start + [int]($btn2.Width/2)) ($o.Y + [int](($btn2.Top + $btn2.Bottom)/2)) }
    (Grab $rect).Save("$OutDir/walk-{0:D2}-c.png" -f $i)
  }
}

# ── final screen ─────────────────────────────────────────────────────────────
Start-Sleep -Milliseconds 1200
$final = Grab $rect; $final.Save("$OutDir/walk-final.png")
$finalContent = ContentFraction $final
Write-Host ("final screen content: {0:P2}" -f $finalContent)

# crash log, wherever the app wrote it
foreach ($p in @("$env:APPDATA\TheLongView\crash.log", "$env:LOCALAPPDATA\TheLongView\crash.log", "$env:USERPROFILE\.thelongview\crash.log")) {
  if (Test-Path $p) { Write-Host "=== crash.log ($p) ==="; Get-Content $p -Tail 80 | ForEach-Object { Write-Host $_ }; Copy-Item $p "$OutDir/crash.log" -Force }
}

if ($blankAt -ge 0) { Write-Host "::error::Onboarding went blank at step $blankAt. See walk-*.png."; exit 1 }
if ($finalContent -lt 0.02) { Write-Host "::error::The main screen after onboarding is blank ($([math]::Round($finalContent*100,2))% content). This is the 10.1.2.10 failure."; exit 1 }
Write-Host "Walked onboarding to a main screen that shows content."
