[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 18798
)

# Installs the GPT retry proxy:
#   1. scheduled task CodexGptRetryProxy (logon + every minute, no window)
#   2. openai_base_url in C:\ProgramData\OpenAI\Codex\config.toml
# The system config layer only fills keys missing from ~/.codex/config.toml,
# so CC Switch / Codex Desktop rewriting the user config does not remove it.
# openai_base_url only affects the built-in OpenAI (ChatGPT) provider; custom
# providers chosen in CC Switch ignore it.
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$taskName = 'CodexGptRetryProxy'
$vbs = Join-Path $here 'start-hidden.vbs'
$baseUrl = "http://127.0.0.1:$Port/backend-api/codex"
$utf8NoBom = [Text.UTF8Encoding]::new($false)

$nodeCommand = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $nodeCommand) { throw 'node.exe was not found on PATH.' }
$node = $nodeCommand.Source

# 1. Background task. Start the proxy before pointing Codex at it.
$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\wscript.exe') -Argument "//B //Nologo `"$vbs`" `"$node`" $Port"
$triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $user),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650))
)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal `
    -Description 'Retries capacity errors for Codex official ChatGPT channel (codex-capacity-retry/proxy).' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

$healthy = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/__health" -TimeoutSec 2
        if ($health.ok) { $healthy = $true; break }
    } catch {}
}
if (-not $healthy) {
    throw "The proxy did not answer on port $Port. Codex config was not changed. See $env:USERPROFILE\.codex\gpt-retry-proxy.log"
}
Write-Host "Proxy is running on 127.0.0.1:$Port (task $taskName)."

# 2. Codex system config layer.
$configDir = Join-Path $env:ProgramData 'OpenAI\Codex'
$configFile = Join-Path $configDir 'config.toml'
$block = @(
    '# Added by codex-capacity-retry proxy/install.ps1 (uninstall.ps1 removes it).',
    '# Only the built-in OpenAI/ChatGPT provider uses openai_base_url.',
    "openai_base_url = `"$baseUrl`""
)
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
$lines = @()
if (Test-Path -LiteralPath $configFile) {
    $backup = "$configFile.bak-before-gpt-retry-proxy-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item -LiteralPath $configFile -Destination $backup
    $lines = @([IO.File]::ReadAllLines($configFile, $utf8NoBom) | Where-Object {
        $_ -notmatch '^\s*openai_base_url\s*=' -and $_ -notmatch '^# (Added by codex-capacity-retry|Only the built-in OpenAI/ChatGPT provider)'
    })
}
# Top-level keys must come before any [table], so prepend.
[IO.File]::WriteAllText($configFile, (($block + $lines) -join "`r`n") + "`r`n", $utf8NoBom)
Write-Host "Set openai_base_url in $configFile"

$userConfig = Join-Path $env:USERPROFILE '.codex\config.toml'
if ((Test-Path -LiteralPath $userConfig) -and (Select-String -LiteralPath $userConfig -Pattern '^\s*openai_base_url\s*=' -Quiet)) {
    Write-Warning "$userConfig sets its own openai_base_url, which overrides the system layer."
}
Write-Host 'Restart Codex Desktop so it picks up the new base URL.'
