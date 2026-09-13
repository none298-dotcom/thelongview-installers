# Run the real NVDA screen reader against the installed app and read back what it said.
#
# jab-probe.py reads the Java Access Bridge tree the way a screen reader does. This goes one step
# further and runs an actual screen reader: NVDA starts with a silent synthesizer and IO logging,
# the app window is brought to the front, Tab moves focus, and every utterance NVDA produced is
# read from its log. The assertion is on speech, which is the thing a blind customer receives.
param(
  [string]$Title = "The Long View",
  [string[]]$MustSay = @("Begin"),
  [string[]]$MustNotSay = @("unknown"),
  [string]$OutDir = "artifacts"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

choco install nvda -y --no-progress | Out-Null
$nvda = @("${env:ProgramFiles(x86)}\NVDA\nvda.exe", "$env:ProgramFiles\NVDA\nvda.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $nvda) { throw "NVDA did not install" }

# The runner has no audio device, so the synthesizer is silence. Speech still passes through
# NVDA's speech pipeline and is written to the log at IO level, which is what is read below.
# The welcome and usage-statistics dialogs are pre-answered so they cannot steal focus.
$cfg = Join-Path $env:APPDATA "nvda"
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
@"
schemaVersion = 11
[general]
	showWelcomeDialogAtStartup = False
	playStartAndExitSounds = False
[speech]
	synth = silence
[update]
	autoCheck = False
	askedAllowUsageStats = True
	allowUsageStats = False
"@ | Set-Content -Encoding UTF8 (Join-Path $cfg "nvda.ini")

$log = Join-Path (Resolve-Path $OutDir) "nvda.log"
Start-Process -FilePath $nvda -ArgumentList @("-m", "--log-file=$log", "--log-level=12", "--disable-addons", "-c", $cfg)
Start-Sleep -Seconds 15

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Fg {
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
}
"@
# By the app's own process rather than FindWindow's exact title match, which found nothing on the
# runner even with the app open: the process with a visible main window whose title names the app.
$app = Get-Process | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -like "*$Title*" } |
       Select-Object -First 1
if (-not $app) {
  Get-Process | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
    ForEach-Object { Write-Host "  window: $($_.ProcessName) '$($_.MainWindowTitle)'" }
  throw "No window titled like '$Title'"
}
$hwnd = $app.MainWindowHandle
Write-Host "app window: $($app.ProcessName) '$($app.MainWindowTitle)'"
# A synthetic Alt press lets a background process take the foreground.
[Fg]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [Fg]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
[Fg]::ShowWindow($hwnd, 9) | Out-Null
[Fg]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Seconds 4

$shell = New-Object -ComObject WScript.Shell
for ($i = 0; $i -lt 6; $i++) { $shell.SendKeys("{TAB}"); Start-Sleep -Seconds 2 }

& $nvda -q
Start-Sleep -Seconds 5

if (-not (Test-Path $log)) { throw "NVDA wrote no log" }
$spoken = Select-String -Path $log -Pattern "Speaking \[" | ForEach-Object { $_.Line }
Write-Host "NVDA spoke $($spoken.Count) time(s):"
$spoken | ForEach-Object { Write-Host "  $_" }
$spoken | Set-Content (Join-Path $OutDir "nvda-speech.txt")

$missing = $MustSay | Where-Object { $w = $_; -not ($spoken | Where-Object { $_ -match [regex]::Escape($w) }) }
if ($missing) { throw "NVDA never said: $($missing -join ', ')" }
$bad = $MustNotSay | Where-Object { $w = $_; $spoken | Where-Object { $_ -match "'$([regex]::Escape($w))'" } }
if ($bad) { throw "NVDA said: $($bad -join ', ') (a focus stop with no name)" }
Write-Host "NVDA said every required phrase: $($MustSay -join ', ')"
