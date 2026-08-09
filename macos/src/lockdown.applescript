
on run argv
	set allowedURL to item 1 of argv
	set pass1 to item 2 of argv
	set targetApp to "Google Chrome"
	-- allowed hosts = every arg from the third onward
	set allowedHosts to {}
	repeat with i from 3 to (count of argv)
		set end of allowedHosts to item i of argv
	end repeat

	-- ---------- Force-quit every other app ----------
	-- Keep only Chrome, Finder, and the terminal running this script alive.
	set keepApps to {"Google Chrome", "Finder", "Terminal", "iTerm2", "osascript"}
	set otherApps to {}
	tell application "System Events"
		set otherApps to name of (every application process whose background only is false)
	end tell
	repeat with a in otherApps
		set a to a as string
		if a is not in keepApps then
			try
				tell application a to quit
			end try
		end if
	end repeat
	delay 1

	-- ---------- Open Chrome at the allowed URL, fullscreen ----------
	tell application "Google Chrome"
		activate
		if (count of windows) is 0 then make new window
		set URL of active tab of front window to allowedURL
	end tell
	delay 1
	-- Enter macOS fullscreen so the Dock + menu bar are hidden (kiosk feel).
	try
		tell application "System Events" to keystroke "f" using {control down, command down}
	end try
	delay 1

	-- ---------- Lockdown loop ----------
	repeat
		try
			set runningNames to {}
			tell application "System Events"
				set runningNames to name of (every application process whose background only is false)
			end tell

			if targetApp is not in runningNames then
				-- Chrome was closed: relaunch INSTANTLY and force it back to the site...
				tell application "Google Chrome"
					activate
					if (count of windows) is 0 then make new window
					set URL of active tab of front window to allowedURL
				end tell
				delay 1
				-- put it back into fullscreen kiosk mode
				try
					tell application "System Events" to keystroke "f" using {control down, command down}
				end try
				-- ...then DEMAND the passcode. The prompt keeps coming back until the
				-- correct passcode is entered — it cannot be cancelled or escaped.
				set unlocked to false
				repeat until unlocked
					set entry to ""
					try
						set entry to text returned of (display dialog "Guided Access is ON. You cannot quit Chrome without the passcode." & return & return & "Enter your passcode to end Guided Access:" & return & "(This prompt will keep returning until you do.)" default answer "" with hidden answer with title "Guided Access" buttons {"Unlock"} default button "Unlock")
					on error
						set entry to "" -- dismissed / Escape: just ask again
					end try
					if entry is pass1 then set unlocked to true
				end repeat
				-- correct passcode: restore everything and end Guided Access
				try
					tell application "System Events" to set visible of (every application process whose background only is false) to true
				end try
				exit repeat
			else
				-- Keep Chrome frontmost; hide everything else.
				set frontApp to ""
				tell application "System Events"
					set frontApp to name of first application process whose frontmost is true
				end tell
				if frontApp is not targetApp then
					repeat with pName in runningNames
						set pName to pName as string
						if pName is not targetApp then
							try
								tell application "System Events" to set visible of (first application process whose name is pName) to false
							end try
						end if
					end repeat
					tell application "Google Chrome" to activate
				end if

				-- Enforce the whitelist across every tab / window.
				try
					tell application "Google Chrome"
						set wCount to count of windows
						repeat with wi from 1 to wCount
							set tCount to count of tabs of window wi
							repeat with ti from 1 to tCount
								set u to URL of tab ti of window wi
								set okURL to false
								repeat with h in allowedHosts
									if u contains (h as string) then set okURL to true
								end repeat
								if not okURL then set URL of tab ti of window wi to allowedURL
							end repeat
						end repeat
					end tell
				end try
			end if
		end try
		delay 0.3
	end repeat
end run

