on run
	try
		set osChoice to button returned of (display dialog "yo. where we locking in today?" & return & return & "pick your machine:" buttons {"🪟 Windows", "🍎 Mac"} default button "🍎 Mac" with title "Locked In 🔒")
	on error
		return
	end try

	if osChoice contains "Mac" then
		set appPath to POSIX path of (path to me)
		set scriptPath to appPath & "Contents/Resources/guided-access.command"
		tell application "Terminal"
			activate
			do script "chmod +x " & quoted form of scriptPath & " && " & quoted form of scriptPath
		end tell
	else
		display dialog "Windows selected 🪟" & return & return & "This Mac app can't run the Windows version. On your PC, drop LockedIn.bat + guided-access.ps1 in a folder and double-click LockedIn.bat." buttons {"bet"} default button "bet" with title "Locked In 🔒"
	end if
end run
