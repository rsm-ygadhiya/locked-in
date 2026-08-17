<#
  guided-access.ps1  —  a Chrome "Guided Access" / single-site lockdown for Windows

  Local focus/kiosk tool (Windows version of guided-access.command). It:
    0. If this PC is set up for proctored exams, runs the check-in first
       (student_session.py): sign in, join code, consent, photograph the student ID,
       then wait for a proctor to approve. Nothing below happens without approval.
    1. Shows the recording notice and waits for the student to agree (nothing below
       this point happens if they decline; skipped when the check-in already got it)
    2. Starts recording the screen, the webcam and the microphone (recorder.py), plus
       the live feed to the proctor's dashboard (uploader.py) in a proctored exam
    3. Locks Chrome via registry policy: incognito OFF, DevTools OFF, only allowed sites
    4. Force-quits other visible apps
    5. Opens Chrome in --kiosk mode at the one allowed URL
    6. Relaunches Chrome instantly if closed; you CANNOT quit without the passcode
    7. The unlock prompt keeps returning until the right code is entered — the
       exam's own exit code in a proctored exam, or this PC's passcode
    8. On exit: uploads stopped, recordings finalized, policy removed, Chrome closed

  The allowed URL, allowed hosts, unlock passcode and recording options all come from
  the settings file, written from the launcher under Faculty > Exam settings (or:
  uv run --script admin_panel.py). They are the same settings, in the same file
  format, as on a Mac. The passcode is stored only as a PBKDF2 hash, so it is not
  sitting in plain text in this script any more.

  In a proctored exam the exam record decides the allowed site, overriding whatever
  this PC has configured locally.

  NOTE: This is a "soft" lockdown for focus/self-control, NOT a secure exam browser.
  Task Manager, a reboot, Win+Tab, or a second device can still defeat it. Needs
  Administrator rights (for the Chrome registry policy) — the script self-elevates.

  Needs Python, for the settings and the recorder. Easiest is uv:
      winget install --id=astral-sh.uv -e

  Run it:  right-click the file  ->  "Run with PowerShell"
  (or from an elevated PowerShell:  powershell -ExecutionPolicy Bypass -File .\guided-access.ps1)
#>

# ===================== CONFIG =====================
# Where session recordings are written (one dated folder per session).
$RecordDir = Join-Path ([Environment]::GetFolderPath("Desktop")) "LockedIn-Recordings"
# Set to $false to start recording without asking. Only do that where the students
# have already been told, in writing, that the session is recorded.
$RequireConsent = $true
# =================================================

# ---------- Self-elevate to Administrator ----------
$curr = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $curr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $PSCommandPath

# ---------- Locate the Python helpers and a runner ----------
# In the repo the .py files sit at the top level, one directory up from windows/;
# alongside the script is also supported, for a flattened copy on a USB stick.
function Find-Helper([string]$name) {
    foreach ($candidate in @((Join-Path $ScriptDir $name), (Join-Path (Split-Path -Parent $ScriptDir) $name))) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}
$ConfigPy   = Find-Helper "lockedin_config.py"
$RecorderPy = Find-Helper "recorder.py"
$CheckinPy  = Find-Helper "student_session.py"
$UploaderPy = Find-Helper "uploader.py"
$CloudPy    = Find-Helper "lockedin_cloud.py"

# uv reads the dependency block inside recorder.py and installs on first run, so it is
# much the better runner; a plain python works if the packages are already installed.
$PyExe = $null
$PyArgs = @()
$uv = Get-Command uv -ErrorAction SilentlyContinue
if ($uv) {
    $PyExe = $uv.Source
    $PyArgs = @("run", "--script")
} else {
    foreach ($candidate in @("$env:LOCALAPPDATA\Programs\uv\uv.exe", "$env:USERPROFILE\.local\bin\uv.exe")) {
        if (Test-Path $candidate) { $PyExe = $candidate; $PyArgs = @("run", "--script"); break }
    }
}
if (-not $PyExe) {
    foreach ($name in @("python", "py")) {
        $found = Get-Command $name -ErrorAction SilentlyContinue
        if ($found) { $PyExe = $found.Source; break }
    }
}

# Every argument gets quoted: these are full paths and any of them may contain spaces.
function Quote-Args([string[]]$items) {
    ($items | ForEach-Object { '"' + $_ + '"' }) -join ' '
}

# ---------- Read the settings ----------
# The settings file holds the passcode hash, so there is no safe way to carry on
# without it — better to stop with an explanation than to run a session nobody can
# unlock.
if (-not $ConfigPy -or -not $PyExe) {
    $message = if (-not $PyExe) {
        "Locked In needs Python. Install uv, then run this again:`r`n`r`n    winget install --id=astral-sh.uv -e"
    } else {
        "lockedin_config.py was not found next to this script."
    }
    [System.Windows.Forms.MessageBox]::Show($message, "Locked In", "OK", "Error") | Out-Null
    exit 1
}

# Reading settings goes through the call operator with a splatted argument array, so
# PowerShell passes each path as one argument no matter what it contains.
function Invoke-Py([string[]]$cmdArgs) {
    $all = $PyArgs + $cmdArgs
    & $PyExe @all 2>$null
}

& $PyExe @($PyArgs + @($ConfigPy, "init")) 2>$null | Out-Null
$AllowedUrl = (Invoke-Py @($ConfigPy, "get-url") | Select-Object -First 1)
$AllowHosts = @(Invoke-Py @($ConfigPy, "get-hosts") | Where-Object { $_ -and $_.Trim() })
$recFlags   = (Invoke-Py @($ConfigPy, "get-recording") | Select-Object -First 1)
$RecScreen = $true; $RecCamera = $true; $RecAudio = $true
if ($recFlags) {
    $parts = $recFlags.Trim() -split '\s+'
    if ($parts.Count -ge 3) {
        $RecScreen = $parts[0] -eq "true"
        $RecCamera = $parts[1] -eq "true"
        $RecAudio  = $parts[2] -eq "true"
    }
}

if (-not $AllowedUrl -or $AllowHosts.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show(
        "Could not read the Locked In settings.`r`n`r`nOpen the launcher, choose Faculty > Exam settings, and check the allowed URL and hosts.",
        "Locked In", "OK", "Error") | Out-Null
    exit 1
}

# ---------- Proctored check-in ----------
# The Windows half of the same gate the Mac lockdown runs. With a Supabase project
# configured, a student cannot reach the lockdown by themselves: student_session.py
# signs them in, photographs their ID and waits for a proctor. It exits non-zero if
# that does not happen, and this script stops there - before the registry policy is
# written, so a student who was not admitted leaves with their PC untouched.
#
# With no project configured this whole block is skipped and the lockdown behaves
# exactly as it always did.
$SessionDir  = Join-Path $RecordDir (Get-Date -Format "yyyyMMdd-HHmmss")
$Proctored   = $false
$LiveSession = ""
$LiveExam    = ""

& $PyExe @($PyArgs + @($ConfigPy, "cloud-enabled")) 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    if (-not $CheckinPy) {
        [System.Windows.Forms.MessageBox]::Show(
            "This PC is configured for proctored exams, but student_session.py is missing next to the lockdown script.`r`n`r`n" +
            "Reinstall Locked In, or clear the Supabase settings under Faculty > Exam settings to run it standalone.",
            "Locked In", "OK", "Error") | Out-Null
        exit 1
    }

    New-Item -ItemType Directory -Path $SessionDir -Force | Out-Null
    Write-Host "Opening check-in (sign in, photograph your ID, wait for your proctor)..."
    $checkin = Start-Process -FilePath $PyExe `
        -ArgumentList (Quote-Args ($PyArgs + @($CheckinPy, "--session-dir", $SessionDir))) `
        -PassThru -Wait
    if ($checkin.ExitCode -ne 0) {
        Write-Host "Check-in was not completed - the exam was not started, and nothing on this PC was changed."
        # An empty session folder is just clutter on the Desktop.
        try { Remove-Item $SessionDir -ErrorAction SilentlyContinue } catch {}
        exit 1
    }

    $handoffPath = Join-Path $SessionDir "handoff.json"
    if (-not (Test-Path $handoffPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Check-in finished but left no approval on disk. Not starting the exam.",
            "Locked In", "OK", "Error") | Out-Null
        exit 1
    }
    $handoff = Get-Content $handoffPath -Raw | ConvertFrom-Json
    $LiveSession = [string]$handoff.session_id
    $LiveExam    = [string]$handoff.exam_id
    if (-not $LiveSession -or -not $handoff.allowed_url) {
        [System.Windows.Forms.MessageBox]::Show(
            "The approval file was unreadable. Not starting the exam.",
            "Locked In", "OK", "Error") | Out-Null
        exit 1
    }

    # The exam decides the allowed site, not this PC's local settings.
    $AllowedUrl = [string]$handoff.allowed_url
    try {
        $examHost = ([System.Uri]$AllowedUrl).Host
        if ($examHost) { $AllowHosts += $examHost }
    } catch {}
    $Proctored = $true
    Write-Host "Approved. Session $LiveSession"
}

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

# ---------- Recording ----------
# $SessionDir is set further up, before the check-in, because the check-in writes its
# approval and token into that same folder.
$RecProc = $null
$UploadProc = $null

function Start-Recording {
    if (-not ($RecScreen -or $RecCamera -or $RecAudio)) { return }

    # A proctored student already read the consent text and ticked the box during
    # check-in; asking again in a different dialog just trains people to click through.
    if ($RequireConsent -and -not $Proctored) {
        $streams = @()
        if ($RecScreen) { $streams += "  -  everything on your screen" }
        if ($RecCamera) { $streams += "  -  your webcam" }
        if ($RecAudio)  { $streams += "  -  your microphone" }
        $notice = "This session will be RECORDED.`r`n`r`n" +
                  "The following are captured for the whole session:`r`n" +
                  ($streams -join "`r`n") + "`r`n`r`n" +
                  "Recordings are saved on this PC, in:`r`n$SessionDir`r`n`r`n" +
                  "Recording starts when you click Yes and stops when the session ends. " +
                  "If you do not agree, click No - nothing is recorded and nothing on this PC is changed."
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $notice, "Locked In - recording notice", "YesNo", "Warning")
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            [System.Windows.Forms.MessageBox]::Show(
                "Declined - nothing was recorded and nothing was changed.", "Locked In") | Out-Null
            exit 0
        }
    }

    if (-not $RecorderPy) {
        [System.Windows.Forms.MessageBox]::Show(
            "recorder.py was not found - continuing WITHOUT recording.", "Locked In", "OK", "Warning") | Out-Null
        return
    }

    New-Item -ItemType Directory -Path $SessionDir -Force | Out-Null
    $recArgs = @($RecorderPy, "--out-dir", $SessionDir)
    if (-not $RecScreen) { $recArgs += "--no-screen" }
    if (-not $RecCamera) { $recArgs += "--no-camera" }
    if (-not $RecAudio)  { $recArgs += "--no-audio" }
    # In a proctored exam the recorder also keeps two small JPEGs current for
    # uploader.py to publish to the proctor's dashboard.
    if ($Proctored)      { $recArgs += "--live-tiles" }

    $script:RecProc = Start-Process -FilePath $PyExe `
        -ArgumentList (Quote-Args ($PyArgs + $recArgs)) `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $SessionDir "recorder.log") `
        -RedirectStandardError  (Join-Path $SessionDir "recorder.err")

    # Give it a moment to fall over loudly (no camera, permission denied) rather than
    # silently recording nothing for the whole exam.
    Start-Sleep -Seconds 3
    if ($script:RecProc.HasExited) {
        $detail = Get-Content (Join-Path $SessionDir "recorder.err") -Tail 5 -ErrorAction SilentlyContinue
        $script:RecProc = $null
        [System.Windows.Forms.MessageBox]::Show(
            "The recorder could not start, so this session is NOT being recorded.`r`n`r`n" +
            "Check Camera and Microphone access for desktop apps in Settings > Privacy.`r`n`r`n" +
            ($detail -join "`r`n"), "Locked In", "OK", "Error") | Out-Null
    }
}

function Stop-Recording {
    if (-not $script:RecProc) { return }
    # The STOP sentinel is the graceful route: PowerShell has no clean way to raise
    # SIGINT in another process, and a hard Kill would truncate the video files.
    New-Item -ItemType File -Path (Join-Path $SessionDir "STOP") -Force | Out-Null
    if (-not $script:RecProc.WaitForExit(20000)) {
        try { $script:RecProc.Kill() } catch {}
    }
    $script:RecProc = $null
}

# ---------- Live feed to the proctor ----------
# Separate process from the recorder on purpose: the camera can only be held by one
# process, and a stalled upload must never cost frames of the exam recording. If this
# dies the recording carries on and the dashboard just shows the student as stale.
function Start-Uploading {
    if (-not $Proctored -or -not $UploaderPy -or -not $script:RecProc) {
        if ($Proctored -and -not $script:RecProc) {
            Write-Host "WARNING: nothing is being recorded, so there is no live feed either."
        }
        return
    }
    $upArgs = @($UploaderPy, "--session-dir", $SessionDir,
                "--session-id", $LiveSession,
                "--token-file", (Join-Path $SessionDir "token.json"))
    $script:UploadProc = Start-Process -FilePath $PyExe `
        -ArgumentList (Quote-Args ($PyArgs + $upArgs)) `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $SessionDir "uploader.log") `
        -RedirectStandardError  (Join-Path $SessionDir "uploader.err")
    Start-Sleep -Seconds 1
    if ($script:UploadProc.HasExited) {
        $script:UploadProc = $null
        Write-Host "WARNING: the live feed to your proctor could not start. The exam is"
        Write-Host "         still being recorded locally. See uploader.err."
    } else {
        Write-Host "Live feed to the proctor: on"
    }
}

function Stop-Uploading {
    if (-not $script:UploadProc) { return }
    # Killed rather than left to notice the STOP file: the recorder deletes that file
    # when it finishes, so whichever of the two looks second might never see it.
    try { $script:UploadProc.Kill() } catch {}
    try { $script:UploadProc.WaitForExit(5000) | Out-Null } catch {}
    $script:UploadProc = $null
}

# The token file is the student's credential for the whole session. uploader.py
# deletes it as soon as it has read it; this is the safety net for the paths where
# the uploader never ran.
function Remove-Token {
    Remove-Item (Join-Path $SessionDir "token.json") -Force -ErrorAction SilentlyContinue
}

# ---------- Passcode check ----------
# The typed entry goes to the verifier on stdin - never as an argument, which would be
# visible to every other process - and the exit code is the answer.
# In a proctored exam the exam has its own exit code, checked by the server so the
# code itself never reaches the student's PC. An unreachable server falls through to
# the machine's local passcode rather than trapping a student in a locked browser.
function Test-ExitCode([string]$entry) {
    if ($Proctored -and $CloudPy -and $LiveExam) {
        $tokenFile = Join-Path $SessionDir "token.json"
        if (Test-Path $tokenFile) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $PyExe
            $psi.Arguments = Quote-Args ($PyArgs + @($CloudPy, "verify-exit", $LiveExam, $tokenFile))
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Write($entry)
            $proc.StandardInput.Close()
            $proc.WaitForExit()
            if ($proc.ExitCode -eq 0) { return $true }
            if ($proc.ExitCode -eq 1) { return $false }
            # exit 2 = could not ask; fall through to the local passcode below.
        }
    }
    return (Test-Passcode $entry)
}

function Test-Passcode([string]$entry) {
    if (-not $entry) { return $false }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PyExe
    $psi.Arguments = Quote-Args ($PyArgs + @($ConfigPy, "verify-passcode"))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Write($entry)
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        return ($proc.ExitCode -eq 0)
    } catch {
        return $false
    }
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

# Processes we never kill (system + the script host + Chrome + the recorder itself)
$KeepProcs = @("chrome","explorer","powershell","pwsh","WindowsTerminal","conhost",
               "ApplicationFrameHost","SystemSettings","TextInputHost","dwm","csrss",
               "winlogon","fontdrvhost","sihost","ctfmon","StartMenuExperienceHost",
               "SearchHost","LockApp","ShellExperienceHost",
               "python","pythonw","py","uv")

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
    # Consent and recording come first, so declining leaves the PC untouched.
    Start-Recording
    Start-Uploading

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
            do { $entry = Show-PasscodePrompt } until (Test-ExitCode $entry)
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
    # Uploader first: it needs the live tiles to still exist to publish a last frame,
    # and it is what marks the session ended for the proctor.
    Stop-Uploading
    Stop-Recording
    Remove-Token
    Remove-Policy
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $saved = if (Test-Path $SessionDir) { "`r`n`r`nRecording saved to:`r`n$SessionDir" } else { "" }
    [System.Windows.Forms.MessageBox]::Show("Guided Access ended. Chrome is unlocked again.$saved", "Guided Access") | Out-Null
}
