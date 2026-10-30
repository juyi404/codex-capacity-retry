[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 18798
)

# Reverses install.ps1: point Codex back at chatgpt.com first, then stop and
# remove the background proxy.
$ErrorActionPreference = 'Stop'

$taskName = 'CodexGptRetryProxy'
$utf8NoBom = [Text.UTF8Encoding]::new($false)

$configDir = Join-Path $env:ProgramData 'OpenAI\Codex'
$configFile = Join-Path $configDir 'config.toml'
if (Test-Path -LiteralPath $configFile) {
    $lines = @([IO.File]::ReadAllLines($configFile, $utf8NoBom) | Where-Object {
        $_ -notmatch '^\s*openai_base_url\s*=' -and $_ -notmatch '^# (Added by codex-capacity-retry|Only the built-in OpenAI/ChatGPT provider)'
    })
    if (($lines | Where-Object { $_.Trim() }).Count -eq 0) {
        Remove-Item -LiteralPath $configFile
        Write-Host "Removed $configFile"
        if (-not (Get-ChildItem -LiteralPath $configDir -Force)) { Remove-Item -LiteralPath $configDir }
    } else {
        [IO.File]::WriteAllText($configFile, ($lines -join "`r`n") + "`r`n", $utf8NoBom)
        Write-Host "Removed openai_base_url from $configFile"
    }
}

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed scheduled task $taskName"
}

$listeners = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
foreach ($listener in $listeners) {
    $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    if ($process -and $process.ProcessName -eq 'node') {
        Stop-Process -Id $process.Id -Force
        Write-Host "Stopped proxy process $($process.Id)"
    }
}
Write-Host 'Restart Codex Desktop so it connects to chatgpt.com directly again.'
