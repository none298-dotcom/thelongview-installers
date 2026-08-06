# Clicks the installed app's primary button and proves the click did something.
#
# WHY THIS IS NOT DONE THROUGH UI AUTOMATION
# The first run asked UIA what it could see inside the window. The answer was one nameless
# Pane and nothing else: Compose Desktop renders through Skia and, without the Java Access
# Bridge, publishes no semantics tree at all. So there is no element to find by name and no
# InvokePattern to call. (That is also an accessibility defect in its own right, recorded
# separately; it is not this script's job.)
#
# What is left is what a person does: move the real mouse, press the real button, and look at
# the screen afterwards.
#
# HOW A DEAD BUTTON IS CAUGHT
# By comparing pixels before and after. A button that runs no handler leaves the screen
# identical. That comparison is only trustworthy if "identical" is achievable at all, so the
# script runs a NEGATIVE CONTROL first: it clicks a patch of empty background and requires the
# screen NOT to change. If that control shows a difference, the screen is noisy (an animation,
# a caret, a clock) and any later "it changed" would be meaningless, so the script fails rather
# than reporting a green it has not earned.

param(
  [int]$SettleMs = 1500,
  [string]$OutDir = "artifacts"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

function Grab($rect) {
  $bmp = New-Object System.Drawing.Bitmap $rect.Width, $rect.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  # Cursor is deliberately NOT drawn, so moving the mouse cannot by itself register as a change.
  $g.CopyFromScreen($rect.Location, [System.Drawing.Point]::Empty, $rect.Size)
  $g.Dispose()
  return $bmp
}

# Fraction of pixels that differ beyond a small per-channel tolerance. Tolerance absorbs
# subpixel text antialiasing; it does not absorb a screen that actually changed.
function DiffFraction($a, $b) {
  if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) { return 1.0 }
  $differing = 0; $total = 0
  for ($y = 0; $y -lt $a.Height; $y += 3) {
    for ($x = 0; $x -lt $a.Width; $x += 3) {
      $total++
      $p = $a.GetPixel($x, $y); $q = $b.GetPixel($x, $y)
      if ([Math]::Abs($p.R - $q.R) -gt 8 -or [Math]::Abs($p.G - $q.G) -gt 8 -or [Math]::Abs($p.B - $q.B) -gt 8) { $differing++ }
    }
  }
  return $differing / [double]$total
}

function Click($x, $y) {
  [Win32]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 200
  [Win32]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)   # left down
  Start-Sleep -Milliseconds 60
  [Win32]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)   # left up
  Start-Sleep -Milliseconds $SettleMs
}

# ── Locate the window ────────────────────────────────────────────────────────
$proc = Get-Process -Name "The Long View" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { throw "No process named 'The Long View' with a visible window" }
[Win32]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 800

$r = New-Object Win32+RECT
[Win32]::GetWindowRect($proc.MainWindowHandle, [ref]$r) | Out-Null
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Write-Host "screen:  $($screen.Width)x$($screen.Height)"
Write-Host "window:  ($($r.Left),$($r.Top)) to ($($r.Right),$($r.Bottom))  = $($r.Right-$r.Left)x$($r.Bottom-$r.Top)"

# A window bigger than the screen means the parts of the UI nearest the bottom edge, which is
# where primary actions live, were never on screen to be clicked. Say so rather than hunting
# for a button in the visible remainder and reporting whatever turns up.
if ($r.Bottom -gt $screen.Bottom -or $r.Right -gt $screen.Right) {
  Write-Host "::error::The window opens larger than the display ($($r.Right-$r.Left)x$($r.Bottom-$r.Top) on $($screen.Width)x$($screen.Height)). Its bottom edge, and the footer button with it, is off screen."
  exit 1
}

$rect = New-Object System.Drawing.Rectangle $r.Left, $r.Top, ($r.Right-$r.Left), ($r.Bottom-$r.Top)
$before = Grab $rect
$before.Save("$OutDir/01-before-click.png")

# ── Find the primary button by its colour, not by guessed coordinates ────────
# It is the only full width block of flat non background colour in the lower part of the
# window. Locating it by appearance means the check keeps working when padding changes, and
# means a button that renders invisibly is a failure here rather than a silent pass.
$bg = $before.GetPixel([int]($before.Width * 0.5), [int]($before.Height * 0.5))
Write-Host "background sample: R$($bg.R) G$($bg.G) B$($bg.B)"
$best = $null
for ($y = [int]($before.Height * 0.55); $y -lt $before.Height - 4; $y += 2) {
  $run = 0; $runStart = 0; $bestRunOnRow = 0; $bestStart = 0
  for ($x = 0; $x -lt $before.Width; $x++) {
    $p = $before.GetPixel($x, $y)
    $isBg = ([Math]::Abs($p.R-$bg.R) -le 12 -and [Math]::Abs($p.G-$bg.G) -le 12 -and [Math]::Abs($p.B-$bg.B) -le 12)
    if (-not $isBg) { if ($run -eq 0) { $runStart = $x }; $run++ }
    else { if ($run -gt $bestRunOnRow) { $bestRunOnRow = $run; $bestStart = $runStart }; $run = 0 }
  }
  if ($run -gt $bestRunOnRow) { $bestRunOnRow = $run; $bestStart = $runStart }
  if ($bestRunOnRow -gt ($before.Width * 0.5) -and ($null -eq $best -or $bestRunOnRow -gt $best.Run)) {
    $best = [pscustomobject]@{ Y = $y; Run = $bestRunOnRow; Start = $bestStart }
  }
}
if (-not $best) {
  Write-Host "::error::No primary button found. Nothing in the lower half of the window is a wide block of colour distinct from the background, so there is nothing a user could press."
  exit 1
}
$btnX = $r.Left + $best.Start + [int]($best.Run / 2)
$btnY = $r.Top + $best.Y
Write-Host "primary button: row y=$($best.Y), width $($best.Run)px, clicking screen ($btnX,$btnY)"

# ── Negative control, before trusting any positive result ────────────────────
# Empty background well above the button. If clicking here changes the screen, the screen is
# not stable and the positive test below would prove nothing.
$controlX = $r.Left + [int](($r.Right-$r.Left) * 0.08)
$controlY = $r.Top + [int](($r.Bottom-$r.Top) * 0.75)
Write-Host "negative control: clicking empty background at ($controlX,$controlY)"
Click $controlX $controlY
$afterControl = Grab $rect
$afterControl.Save("$OutDir/02-after-control-click.png")
$controlDiff = DiffFraction $before $afterControl
Write-Host ("control diff: {0:P3} of sampled pixels" -f $controlDiff)
if ($controlDiff -gt 0.002) {
  Write-Host "::error::Clicking empty background changed the screen. Something is animating or repainting, so a pixel comparison cannot tell a live button from a dead one here. Not reporting a result from an unreliable measurement."
  exit 1
}

# ── The real click ───────────────────────────────────────────────────────────
Click $btnX $btnY
$after = Grab $rect
$after.Save("$OutDir/03-after-primary-click.png")
$diff = DiffFraction $afterControl $after
Write-Host ("primary click diff: {0:P3} of sampled pixels" -f $diff)

if ($diff -lt 0.02) {
  Write-Host "::error::The primary button did nothing. The screen is unchanged after a real mouse press on it, which is the defect that failed Microsoft Store certification twice on the other app. Compare 02-after-control-click.png with 03-after-primary-click.png."
  exit 1
}
Write-Host "The primary button is live: a real click advanced the UI."
