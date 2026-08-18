# exit-button.ps1 — the floating "End exam" button, Windows side.
#
# The counterpart of macos/src/overlay.swift, and it does the same job: one small
# always-on-top pill that can be dragged anywhere, click it to enter the exit code,
# and on a correct code it touches the release file that guided-access.ps1 watches
# for. Without it the only way out is to close Chrome and wait for the passcode
# prompt, which is fine if you know the trick and alarming if you don't.
#
# It runs as its own process so the lockdown loop keeps enforcing while this sits
# on screen waiting to be used.
#
#     powershell -File exit-button.ps1 -ReleaseFile ... -PromptFile ... `
#         -PyExe ... -PyArgs ... -ConfigPy ... [-CloudPy ... -ExamId ... -TokenFile ...]
#
# The typed code is piped to the verifier on stdin and never written to disk. That
# matters more here than it looks: an exam's exit code is the proctor's, and the
# whole point of checking it server-side is that it never lands on a student's PC.
#
# UNTESTED, like the rest of the Windows half — see docs/TROUBLESHOOTING.md.

param(
    [Parameter(Mandatory = $true)][string]$ReleaseFile,
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$PyExe,
    [string]$PyArgs = "",
    [Parameter(Mandatory = $true)][string]$ConfigPy,
    [string]$CloudPy = "",
    [string]$ExamId = "",
    [string]$TokenFile = ""
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$runnerArgs = if ($PyArgs) { $PyArgs.Split(" ") | Where-Object { $_ } } else { @() }

function Quote-One([string]$value) { '"' + ($value -replace '"', '\"') + '"' }

function Invoke-Verifier([string[]]$arguments, [string]$entry) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PyExe
    $psi.Arguments = ($arguments | ForEach-Object { Quote-One $_ }) -join " "
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Write($entry)
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        return $proc.ExitCode
    } catch { return 2 }
}

# Same order as guided-access.ps1: the exam's own code first, the machine's local
# passcode as the fallback for when the network is down.
function Test-Entry([string]$entry) {
    if (-not $entry) { return $false }
    if ($CloudPy -and $ExamId -and $TokenFile -and (Test-Path $TokenFile)) {
        $code = Invoke-Verifier ($runnerArgs + @($CloudPy, "verify-exit", $ExamId, $TokenFile)) $entry
        if ($code -eq 0) { return $true }
        if ($code -eq 1) { return $false }
    }
    return ((Invoke-Verifier ($runnerArgs + @($ConfigPy, "verify-passcode")) $entry) -eq 0)
}

$dark   = [System.Drawing.Color]::FromArgb(11, 24, 16)
$green  = [System.Drawing.Color]::FromArgb(126, 240, 165)

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = "None"
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = $dark
$form.Size = New-Object System.Drawing.Size(180, 46)
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.StartPosition = "Manual"
$form.Location = New-Object System.Drawing.Point(($screen.Right - 220), ($screen.Bottom - 90))

$label = New-Object System.Windows.Forms.Label
$label.Text = "End exam"
$label.ForeColor = $green
$label.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$label.TextAlign = "MiddleCenter"
$label.Dock = "Fill"

$box = New-Object System.Windows.Forms.TextBox
$box.UseSystemPasswordChar = $true
$box.Visible = $false
$box.Location = New-Object System.Drawing.Point(12, 44)
$box.Size = New-Object System.Drawing.Size(232, 24)

$note = New-Object System.Windows.Forms.Label
$note.ForeColor = [System.Drawing.Color]::FromArgb(140, 184, 158)
$note.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$note.Location = New-Object System.Drawing.Point(12, 72)
$note.Size = New-Object System.Drawing.Size(232, 18)
$note.TextAlign = "MiddleCenter"
$note.Visible = $false

$form.Controls.AddRange(@($label, $box, $note))

# Drag to move, click to open. Same gesture as the Mac pill: whichever the student
# does, the button does the obvious thing.
$script:dragging = $false
$script:moved = $false
$script:origin = New-Object System.Drawing.Point(0, 0)
$script:prompting = $false

$down = {
    $script:dragging = $true
    $script:moved = $false
    $script:origin = [System.Windows.Forms.Cursor]::Position
}
$move = {
    if (-not $script:dragging) { return }
    $now = [System.Windows.Forms.Cursor]::Position
    $dx = $now.X - $script:origin.X
    $dy = $now.Y - $script:origin.Y
    if ([Math]::Abs($dx) -gt 3 -or [Math]::Abs($dy) -gt 3) {
        $script:moved = $true
        $form.Location = New-Object System.Drawing.Point(($form.Location.X + $dx),
                                                         ($form.Location.Y + $dy))
        $script:origin = $now
    }
}
$up = {
    $script:dragging = $false
    if (-not $script:moved -and -not $script:prompting) {
        $script:prompting = $true
        New-Item -ItemType File -Path $PromptFile -Force | Out-Null
        $form.Size = New-Object System.Drawing.Size(256, 100)
        $label.Dock = "None"
        $label.Location = New-Object System.Drawing.Point(12, 12)
        $label.Size = New-Object System.Drawing.Size(232, 24)
        $label.Text = "Enter the exit code"
        $box.Visible = $true
        $note.Text = "Enter to unlock - Esc to go back"
        $note.Visible = $true
        $box.Focus() | Out-Null
    }
}
foreach ($control in @($form, $label)) {
    $control.Add_MouseDown($down); $control.Add_MouseMove($move); $control.Add_MouseUp($up)
}

function Close-Prompt {
    $script:prompting = $false
    Remove-Item $PromptFile -Force -ErrorAction SilentlyContinue
    $box.Visible = $false; $note.Visible = $false; $box.Text = ""
    $label.Text = "End exam"
    $label.Location = New-Object System.Drawing.Point(0, 0)
    $label.Dock = "Fill"
    $form.Size = New-Object System.Drawing.Size(180, 46)
}

$box.Add_KeyDown({
    if ($_.KeyCode -eq "Escape") { Close-Prompt; return }
    if ($_.KeyCode -ne "Enter") { return }
    $_.SuppressKeyPress = $true
    $entry = $box.Text
    $note.Text = "checking..."
    $form.Refresh()
    if (Test-Entry $entry) {
        New-Item -ItemType File -Path $ReleaseFile -Force | Out-Null
        Remove-Item $PromptFile -Force -ErrorAction SilentlyContinue
        $form.Close()
    } else {
        $box.Text = ""
        $note.Text = "That code was not accepted."
    }
})

# If the lockdown ends some other way — Chrome closed, passcode typed there — this
# should not be left floating over an unlocked machine.
$watch = New-Object System.Windows.Forms.Timer
$watch.Interval = 1000
$watch.Add_Tick({ if (Test-Path $ReleaseFile) { $form.Close() } })
$watch.Start()

[void]$form.ShowDialog()
Remove-Item $PromptFile -Force -ErrorAction SilentlyContinue
