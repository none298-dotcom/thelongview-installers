# Asserts the window's title bar icon is the app's own icon.
#
# WHY THIS CHECK EXISTS
# The packaged Windows build shipped with the stock Java placeholder in its title bar and in
# Alt+Tab. The owner has failed store submissions over exactly this before. It was found by a
# human looking at a screenshot; nothing here caught it.
#
# It hid well. jpackage's `iconFile` sets the icon on the EXE, the Start Menu shortcut and the
# taskbar button, so every surface the packaging config reaches was already correct and looked
# right in a desktop screenshot. The window's own icon is the one surface it does not reach:
# that comes from the toolkit, and Compose falls back to AWT's default when the app does not
# set one.
#
# HOW IT IS CHECKED
# Against the app's OWN shipped EXE icon rather than against a hardcoded colour or a checked in
# reference image. The rule being encoded is "the title bar shows the same icon as the
# application", so comparing the two is the check, and it keeps working when the artwork is
# redesigned. A hardcoded swatch would have to be updated with every icon change, and would go
# green on the day someone forgot.
#
# Both icons are also saved as artifacts, because the eye is the final authority here.

param(
  [Parameter(Mandatory=$true)][string]$ExePath,
  [string]$OutDir = "artifacts",
  [int]$MaxMeanDiff = 40
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class IconApi {
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll", EntryPoint="GetClassLongPtr")] public static extern IntPtr GetClassLongPtr(IntPtr h, int i);
}
"@

$proc = Get-Process -Name "The Long View" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { throw "No process named 'The Long View' with a visible window" }
$h = $proc.MainWindowHandle

# WM_GETICON: ICON_SMALL2 (2) is what the title bar draws, and Windows synthesises it from the
# big icon when no small one is set. Falling back through ICON_BIG and then the window class
# covers every way an icon can have been attached.
$hIcon = [IntPtr]::Zero
foreach ($which in 2, 1, 0) {
  $hIcon = [IconApi]::SendMessage($h, 0x007F, [IntPtr]$which, [IntPtr]::Zero)
  if ($hIcon -ne [IntPtr]::Zero) { Write-Host "window icon from WM_GETICON($which)"; break }
}
if ($hIcon -eq [IntPtr]::Zero) {
  $hIcon = [IconApi]::GetClassLongPtr($h, -34)   # GCLP_HICONSM
  if ($hIcon -ne [IntPtr]::Zero) { Write-Host "window icon from the window class" }
}
if ($hIcon -eq [IntPtr]::Zero) {
  Write-Host "::error::The window has no icon at all, so the title bar and Alt+Tab fall back to the toolkit default."
  exit 1
}

function Normalise($img) {
  $b = New-Object System.Drawing.Bitmap 32, 32
  $g = [System.Drawing.Graphics]::FromImage($b)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  # Flattened onto white. Comparing premultiplied alpha across two different sources is not
  # meaningful, and both icons get identical treatment.
  $g.Clear([System.Drawing.Color]::White)
  $g.DrawImage($img, 0, 0, 32, 32)
  $g.Dispose()
  return $b
}

$windowIcon = Normalise ([System.Drawing.Icon]::FromHandle($hIcon).ToBitmap())
$windowIcon.Save("$OutDir/icon-window.png")

$exeIcon = Normalise ([System.Drawing.Icon]::ExtractAssociatedIcon($ExePath).ToBitmap())
$exeIcon.Save("$OutDir/icon-exe.png")

$sum = 0
for ($y = 0; $y -lt 32; $y++) {
  for ($x = 0; $x -lt 32; $x++) {
    $p = $windowIcon.GetPixel($x, $y); $q = $exeIcon.GetPixel($x, $y)
    $sum += [Math]::Abs($p.R-$q.R) + [Math]::Abs($p.G-$q.G) + [Math]::Abs($p.B-$q.B)
  }
}
$mean = $sum / (32.0 * 32.0 * 3.0)
Write-Host ("mean per channel difference, window icon vs EXE icon: {0:N1} (fails above {1})" -f $mean, $MaxMeanDiff)

if ($mean -gt $MaxMeanDiff) {
  Write-Host "::error::The title bar icon is not the app's icon. Compare icon-window.png with icon-exe.png in the artifacts. This is what shipped as the stock Java placeholder, and it is visible to a store reviewer in the first screenshot they take."
  exit 1
}
Write-Host "The title bar icon matches the application icon."
