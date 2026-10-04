' Start-Hidden.vbs - start KeepAlive.ps1 with NO console window at all.
'
' Why a VBS shim is needed:
'   "powershell.exe -WindowStyle Hidden" only hides a console window that Windows has ALREADY
'   created, so the daemon's own console can still become visible - and closing that window
'   kills the daemon (Windows terminates every process attached to a closed console).
'   The window style passed to WScript.Shell.Run below goes straight into the child process's
'   STARTUPINFO, so the console is created hidden from the very beginning:
'   nothing to see, nothing to close, and no terminal it could be attached to.
'
' Launched by Manage.ps1 (autostart entry or the "Start keep-alive now" action).
' Requires nothing but the Windows Script Host that ships with Windows.
'
' NOTE: this shim deliberately IGNORES its own command-line arguments - everything is derived
' from WScript.ScriptFullName. Passing parameters to it (e.g. a future -LogLevel) therefore has
' no effect; that would have to be implemented here.
Option Explicit

Dim fso, shell, here, target, cmd, ps, q

Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

' Resolve the target from THIS file's own location, so the shortcut keeps working even if the
' whole main folder is moved or copied (no hard-coded path anywhere).
here   = fso.GetParentFolderName(WScript.ScriptFullName)
target = fso.BuildPath(here, "KeepAlive.ps1")

If Not fso.FileExists(target) Then
    WScript.Quit 2          ' nothing to start (Manage.ps1 verifies this at install time)
End If

' Full path on purpose: a bare name would let a stray powershell.exe in the current directory be
' launched instead (CreateProcess searches the working directory before PATH).
ps = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(ps) Then
    WScript.Quit 3
End If

' Build the command line with Chr(34) instead of counting escaped quotes. A miscounted run of
' double quotes silently closes the string literal, turning the rest into invalid code - and
' with "//B" the resulting syntax error is suppressed, so the daemon would simply never start.
q = Chr(34)
cmd = q & ps & q & " -NoProfile -ExecutionPolicy Bypass -File " & q & target & q

' 0 = hidden window style, False = do not wait for the child to exit
shell.Run cmd, 0, False

WScript.Quit 0
