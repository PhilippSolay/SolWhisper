-- One-click beta installer for SolWhisper.
--
-- Lives as "Install SolWhisper.app" inside the DMG, with the real
-- SolWhisper.app embedded at Contents/Resources/SolWhisper.app. On launch it:
--   1. copies the app to /Applications (admin)
--   2. strips the com.apple.quarantine flag so Gatekeeper won't block it
--   3. re-signs ad-hoc (keeps Sparkle.framework's Team ID consistent)
--   4. launches the app
-- The tester only has to clear Gatekeeper once — for this installer.

on run
	set appName to "SolWhisper"
	set mePosix to POSIX path of (path to me)
	if mePosix does not end with "/" then set mePosix to mePosix & "/"
	set srcApp to mePosix & "Contents/Resources/" & appName & ".app"
	set destApp to "/Applications/" & appName & ".app"

	-- Confirm before touching /Applications.
	try
		display dialog "Install " & appName & " into your Applications folder?" & return & return & "macOS may ask for your password, and may prompt you to approve this installer once — that's expected for a beta build." buttons {"Cancel", "Install"} default button "Install" cancel button "Cancel" with title (appName & " Beta Installer") with icon note
	on error number -128
		return
	end try

	-- Quit a running copy so the replace doesn't fail on a busy bundle.
	try
		do shell script "/usr/bin/pkill -x " & quoted form of appName
	end try

	-- One privileged shell call: replace, dequarantine, re-sign.
	set shellCmd to "set -e; " & ¬
		"/bin/rm -rf " & quoted form of destApp & "; " & ¬
		"/usr/bin/ditto " & quoted form of srcApp & " " & quoted form of destApp & "; " & ¬
		"/usr/bin/xattr -dr com.apple.quarantine " & quoted form of destApp & " 2>/dev/null || true; " & ¬
		"/usr/bin/codesign --force --deep --sign - " & quoted form of destApp & " >/dev/null 2>&1 || true"
	try
		do shell script shellCmd with administrator privileges
	on error errMsg number errNum
		if errNum is -128 then return -- user cancelled the auth prompt
		display dialog "Install failed:" & return & return & errMsg buttons {"OK"} default button "OK" with title (appName & " Beta Installer") with icon stop
		return
	end try

	-- Launch the freshly installed copy.
	try
		do shell script "/usr/bin/open " & quoted form of destApp
	end try

	display dialog appName & " is installed and starting up." & return & return & "Look for it in your menu bar. You can now eject and delete this disk image." & return & return & "First run will ask for Microphone, Speech Recognition, Accessibility and Automation permissions — grant them so dictation and paste work." buttons {"Done"} default button "Done" with title (appName & " Beta") with icon note
end run
