' Started by the CodexGptRetryProxy scheduled task:
'   wscript.exe //B //Nologo start-hidden.vbs <node.exe> <port>
' Runs the proxy without a console window and waits for it, so the task
' instance lives exactly as long as the proxy (MultipleInstances=IgnoreNew
' then relaunches it within a minute if it ever exits).
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
nodeExe = WScript.Arguments(0)
If WScript.Arguments.Count > 1 Then
    shell.Environment("PROCESS")("GPT_RETRY_PORT") = WScript.Arguments(1)
End If
shell.Run """" & nodeExe & """ """ & scriptDir & "\codex-gpt-retry-proxy.mjs""", 0, True
