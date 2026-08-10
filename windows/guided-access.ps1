<#
  guided-access.ps1  —  a Chrome "Guided Access" / single-site lockdown for Windows

  Local focus/kiosk tool (Windows version of guided-access.command). It:
    1. Locks Chrome via registry policy: incognito OFF, DevTools OFF, only allowed sites
    2. Force-quits other visible apps
    3. Opens Chrome in --kiosk mode at the one allowed URL
    4. Relaunches Chrome instantly if closed; you CANNOT quit without the passcode
    5. The unlock prompt keeps returning until the correct passcode is entered
    6. On exit: policy removed, Chrome closed

  NOTE: This is a "soft" lockdown for focus/self-control, NOT a secure exam browser.
  Task Manager, a reboot, Win+Tab, or a second device can still defeat it. Needs
  Administrator rights (for the Chrome registry policy) — the script self-elevates.

  Run it:  right-click the file  ->  "Run with PowerShell"
  (or from an elevated PowerShell:  powershell -ExecutionPolicy Bypass -File .\guided-access.ps1)
#>

# ===================== CONFIG =====================
$AllowedUrl      = "https://rsm-django-02.ucsd.edu/video-exam/station/"
# Hosts allowed to load (target site + UCSD SSO + Duo 2FA so login works):
$AllowHosts      = @("rsm-django-02.ucsd.edu", "ucsd.edu", "duosecurity.com")
# Fixed unlock passcode — change this. Stored in PLAIN TEXT here (fine for
# self-control, not a real secret).
$UnlockPasscode  = "letmeout"
# =================================================

# ---------- Self-elevate to Administrator ----------
$curr = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $curr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- Locate Chrome ----------
$chromeCandidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
)
$ChromeExe = $chromeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ChromeExe) {
    [System.Windows.Forms.MessageBox]::Show("Google Chrome was not found. Install it first.", "Guided Access") | Out-Null
    exit 1
}

# ---------- Chrome managed policy (registry) ----------
$PolicyBase = "HKLM:\SOFTWARE\Policies\Google\Chrome"

function Apply-Policy {
    New-Item -Path $PolicyBase -Force | Out-Null
    Set-ItemProperty -Path $PolicyBase -Name "IncognitoModeAvailability" -Value 1 -Type DWord
    Set-ItemProperty -Path $PolicyBase -Name "DeveloperToolsAvailability" -Value 2 -Type DWord

    $block = Join-Path $PolicyBase "URLBlocklist"
    $allow = Join-Path $PolicyBase "URLAllowlist"
    Remove-Item $block -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $allow -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $block -Force | Out-Null
    New-Item -Path $allow -Force | Out-Null
    Set-ItemProperty -Path $block -Name "1" -Value "*" -Type String   # block everything
    $i = 1
    foreach ($h in $AllowHosts) {
        Set-ItemProperty -Path $allow -Name "$i" -Value $h -Type String
        $i++
    }
}

function Remove-Policy {
    Remove-Item (Join-Path $PolicyBase "URLBlocklist") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $PolicyBase "URLAllowlist") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $PolicyBase -Name "IncognitoModeAvailability"  -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $PolicyBase -Name "DeveloperToolsAvailability" -ErrorAction SilentlyContinue
}

# ---------- Keep Chrome in front / hide others ----------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

# Processes we never kill (system + the script host + Chrome itself)
$KeepProcs = @("chrome","explorer","powershell","pwsh","WindowsTerminal","conhost",
               "ApplicationFrameHost","SystemSettings","TextInputHost","dwm","csrss",
               "winlogon","fontdrvhost","sihost","ctfmon","StartMenuExperienceHost",
               "SearchHost","LockApp","ShellExperienceHost")

function Kill-OtherWindows {
    Get-Process | Where-Object {
        $_.MainWindowHandle -ne 0 -and
        $_.MainWindowTitle -ne "" -and
        $KeepProcs -notcontains $_.ProcessName
    } | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
}

function Launch-Chrome-Kiosk {
    Start-Process -FilePath $ChromeExe -ArgumentList "--kiosk", "--disable-features=Translate", $AllowedUrl
}

function Bring-Chrome-Front {
    $c = Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($c) { [Win]::ShowWindow($c.MainWindowHandle, 3) | Out-Null; [Win]::SetForegroundWindow($c.MainWindowHandle) | Out-Null }
}

# ---------- Persistent passcode prompt (no cancel; keeps returning) ----------
function Show-PasscodePrompt {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Guided Access"
    $form.TopMost = $true
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(440, 190)
    $form.FormBorderStyle = "FixedDialog"
    $form.ControlBox = $false
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Guided Access is ON. You cannot quit Chrome without the passcode.`r`nEnter your passcode to end Guided Access:"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(15, 15)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.UseSystemPasswordChar = $true
    $tb.Location = New-Object System.Drawing.Point(15, 70)
    $tb.Size = New-Object System.Drawing.Size(400, 25)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Unlock"
    $btn.Location = New-Object System.Drawing.Point(15, 110)
    $btn.Add_Click({ $form.Tag = $tb.Text; $form.Close() })

    $form.AcceptButton = $btn
    $form.Controls.AddRange(@($label, $tb, $btn))
    [void]$form.ShowDialog()
    return [string]$form.Tag
}

# ================= RUN =================
try {
    Apply-Policy
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    Kill-OtherWindows
    Launch-Chrome-Kiosk
    Start-Sleep -Seconds 2

    while ($true) {
        $chrome = Get-Process chrome -ErrorAction SilentlyContinue
        if (-not $chrome) {
            # Chrome closed -> relaunch immediately, then DEMAND the passcode.
            Launch-Chrome-Kiosk
            Start-Sleep -Seconds 1
            do { $entry = Show-PasscodePrompt } until ($entry -eq $UnlockPasscode)
            break   # correct passcode -> leave the loop and clean up
        }
        else {
            Kill-OtherWindows
            Bring-Chrome-Front
        }
        Start-Sleep -Milliseconds 400
    }
}
finally {
    Remove-Policy
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    [System.Windows.Forms.MessageBox]::Show("Guided Access ended. Chrome is unlocked again.", "Guided Access") | Out-Null
}
