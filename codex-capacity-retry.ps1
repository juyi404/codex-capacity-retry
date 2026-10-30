[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Prompt,

    [string]$PromptFile,
    [string]$CodexBinary,
    [string]$Model = 'gpt-6.1-sol',

    [ValidateRange(1, 120)]
    [int]$MaxWaitMinutes = 10,

    [ValidateRange(1, 20)]
    [int]$MaxAttempts = 12,

    [ValidateRange(1, 120)]
    [int]$InitialBackoffSeconds = 5,

    [ValidateSet('read-only', 'workspace-write')]
    [string]$Sandbox = 'read-only',

    [switch]$UseUserConfig,
    [switch]$DisableProxy,
    [switch]$ShowEvents,
    [switch]$DryRun
)

# Works on Windows PowerShell 5.1 (.NET Framework) and PowerShell 7+. Avoid
# .NET Core-only APIs such as ProcessStartInfo.ArgumentList,
# Process.WaitForExitAsync and Process.Kill(bool).
$ErrorActionPreference = 'Stop'

$utf8NoBom = [Text.UTF8Encoding]::new($false)

if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
        throw "Prompt file was not found: $PromptFile"
    }
    # Get-Content in Windows PowerShell 5.1 reads BOM-less files as ANSI;
    # ReadAllText defaults to UTF-8 and still honors a BOM if present.
    $promptPath = (Resolve-Path -LiteralPath $PromptFile).ProviderPath
    $Prompt = [IO.File]::ReadAllText($promptPath, $utf8NoBom)
}

if ([string]::IsNullOrWhiteSpace($Prompt)) {
    throw 'Pass a prompt as the first argument or use -PromptFile.'
}

# The model name ends up on a command line that may pass through cmd.exe, so
# keep it free of shell metacharacters.
if ($Model -notmatch '^[A-Za-z0-9._:/+-]+$') {
    throw "Model name contains unsupported characters: $Model"
}

if ($CodexBinary) {
    if (-not (Test-Path -LiteralPath $CodexBinary -PathType Leaf)) {
        throw "Codex binary was not found: $CodexBinary"
    }
    $codexPath = (Resolve-Path -LiteralPath $CodexBinary).ProviderPath
} else {
    $codexCommand = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $codexCommand) {
        $codexCommand = Get-Command codex.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $codexCommand) {
        throw 'Codex CLI was not found on PATH.'
    }
    $codexPath = $codexCommand.Source
}

# Matchers are only applied to error events and plain-text stderr, never to
# replies, tool output or usage counters, so bare numbers like 529 in
# "output_tokens":529 can no longer trigger a retry.
$regexOptions = [Text.RegularExpressions.RegexOptions]'IgnoreCase, Compiled'
$capacityRegex = [regex]::new(
    'model is at capacity|try a different model|server[_ ]is[_ ]overloaded|\boverloaded\b|temporarily unavailable|service unavailable|too many requests|(?:status|http|code)\W{0,3}(?:429|503|529)\b',
    $regexOptions
)
$quotaRegex = [regex]::new(
    'insufficient[_ -]?quota|exceeded your current quota|quota exceeded|usage[_ ]limit|payment required|spend(?:ing)? limit|billing (?:hard )?limit|purchase more credits',
    $regexOptions
)

function ConvertTo-CommandLineArgument {
    param([string]$Value)

    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    # CommandLineToArgvW rules: double backslashes that precede a quote.
    $escaped = $Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

$codexArguments = @(
    'exec', '--json', '--ephemeral', '--skip-git-repo-check',
    '--model', $Model,
    '--sandbox', $Sandbox
)
if (-not $UseUserConfig) {
    $codexArguments += '--ignore-user-config'
}
$codexArguments += '-'
$argumentLine = ($codexArguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '

# npm installs codex as codex.cmd. Launch batch files through cmd.exe
# explicitly so paths with spaces are quoted reliably.
if ($codexPath -match '\.(?:cmd|bat)$') {
    $launchFile = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
    $launchArguments = '/d /s /c ""' + $codexPath + '" ' + $argumentLine + '"'
} else {
    $launchFile = $codexPath
    $launchArguments = $argumentLine
}

function Start-CodexProcess {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $launchFile
    $psi.Arguments = $launchArguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # Codex speaks UTF-8; without this the console code page (e.g. 936)
    # would be used and Chinese text would be garbled.
    $psi.StandardOutputEncoding = $utf8NoBom
    $psi.StandardErrorEncoding = $utf8NoBom
    $hasStdinEncoding = $null -ne $psi.PSObject.Properties['StandardInputEncoding']
    if ($hasStdinEncoding) {
        $psi.StandardInputEncoding = $utf8NoBom
    }

    if ($DisableProxy) {
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')) {
            $psi.EnvironmentVariables.Remove($name)
        }
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi

    # .NET Framework builds the stdin writer from Console.InputEncoding and
    # may emit its BOM at start. Switch to BOM-less UTF-8 just for Start().
    $savedInputEncoding = $null
    if (-not $hasStdinEncoding) {
        try {
            $savedInputEncoding = [Console]::InputEncoding
            [Console]::InputEncoding = $utf8NoBom
        } catch {}
    }
    try {
        if (-not $process.Start()) {
            throw 'Codex process did not start.'
        }
    } finally {
        if ($null -ne $savedInputEncoding) {
            try { [Console]::InputEncoding = $savedInputEncoding } catch {}
        }
    }

    # Write raw UTF-8 bytes so the result does not depend on the writer's
    # encoding. Codex may exit before reading stdin; its output explains why.
    try {
        $bytes = $utf8NoBom.GetBytes($Prompt)
        $stdin = $process.StandardInput
        $stdin.Flush()
        $stdin.BaseStream.Write($bytes, 0, $bytes.Length)
        $stdin.BaseStream.Flush()
        $stdin.Close()
    } catch [IO.IOException] {}

    return $process
}

function Stop-CodexTree {
    param([Diagnostics.Process]$Process)

    if ($null -eq $Process) { return }
    try { if ($Process.HasExited) { return } } catch { return }

    # codex.cmd -> node -> codex.exe: kill the whole tree, not just cmd.exe.
    try {
        $killInfo = [Diagnostics.ProcessStartInfo]::new('taskkill.exe', "/PID $($Process.Id) /T /F")
        $killInfo.UseShellExecute = $false
        $killInfo.CreateNoWindow = $true
        $killInfo.RedirectStandardOutput = $true
        $killInfo.RedirectStandardError = $true
        $killer = [Diagnostics.Process]::Start($killInfo)
        [void]$killer.WaitForExit(5000)
        $killer.Dispose()
    } catch {}
    try { if (-not $Process.HasExited) { $Process.Kill() } } catch {}
}

function Test-CapacityText {
    param([string]$Text)

    return [bool]($Text -and $capacityRegex.IsMatch($Text) -and -not $quotaRegex.IsMatch($Text))
}

function Get-EventErrorText {
    param($CodexEvent)

    switch ([string]$CodexEvent.type) {
        'error' { return [string]$CodexEvent.message }
        'turn.failed' { if ($CodexEvent.error) { return [string]$CodexEvent.error.message } }
    }
    if ($CodexEvent.item -and [string]$CodexEvent.item.type -eq 'error') {
        return [string]$CodexEvent.item.message
    }
    return $null
}

function Handle-CodexLine {
    param(
        [string]$Line,
        [bool]$IsStdErr,
        [hashtable]$State
    )

    $codexEvent = $null
    if (-not $IsStdErr -and $Line.StartsWith('{')) {
        try { $codexEvent = ConvertFrom-Json -InputObject $Line } catch { $codexEvent = $null }
    }

    if ($null -eq $codexEvent) {
        if (Test-CapacityText $Line) {
            if (-not $State.Progress) {
                $State.RetryableCapacity = $true
                return
            }
            $State.CapacityAfterProgress = $true
        }
        if ($IsStdErr) { [Console]::Error.WriteLine($Line) } else { [Console]::Out.WriteLine($Line) }
        return
    }

    $type = [string]$codexEvent.type
    $item = $codexEvent.item
    # Any non-error item (reasoning, command, agent message, ...) means the
    # model is serving this turn: stop treating the attempt as retryable.
    if ($type -like 'item.*' -and $null -ne $item -and [string]$item.type -ne 'error') {
        $State.Progress = $true
    }

    $errorText = Get-EventErrorText $codexEvent
    if (Test-CapacityText $errorText) {
        if (-not $State.Progress) {
            $State.RetryableCapacity = $true
            return
        }
        $State.CapacityAfterProgress = $true
    }

    if ($ShowEvents) {
        [Console]::Out.WriteLine($Line)
        return
    }
    if ($type -eq 'item.completed' -and [string]$item.type -eq 'agent_message') {
        [Console]::Out.WriteLine([string]$item.text)
        return
    }
    if ($errorText) {
        [Console]::Error.WriteLine($errorText)
    }
}

if ($DryRun) {
    $mode = if ($UseUserConfig) { 'user config' } else { 'clean OpenAI config' }
    $outputMode = if ($ShowEvents) { 'all events' } else { 'replies and errors' }
    Write-Output "codex-retry: model=$Model, max_wait=${MaxWaitMinutes}m, max_attempts=$MaxAttempts, sandbox=$Sandbox, mode=$mode, output=$outputMode"
    Write-Output "powershell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Output "codex binary: $codexPath"
    Write-Output "launch: $launchFile $launchArguments"
    exit 0
}

$deadline = [DateTime]::UtcNow.AddMinutes($MaxWaitMinutes)
$backoffSeconds = $InitialBackoffSeconds
$attempt = 0
$timedOut = $false

while ($attempt -lt $MaxAttempts -and [DateTime]::UtcNow -lt $deadline) {
    $attempt++
    $state = @{
        Progress = $false
        RetryableCapacity = $false
        CapacityAfterProgress = $false
    }
    $exitCode = -1
    $process = $null

    try {
        $process = Start-CodexProcess
        $readers = @{
            out = $process.StandardOutput
            err = $process.StandardError
        }
        $pendingReads = @{
            out = $readers.out.ReadLineAsync()
            err = $readers.err.ReadLineAsync()
        }

        while ($pendingReads.Count -gt 0) {
            # Before the model makes progress, the attempt is bounded by the
            # retry window. After that, let Codex finish however long it takes.
            if (-not $state.Progress -and -not $state.RetryableCapacity -and [DateTime]::UtcNow -ge $deadline) {
                $state.RetryableCapacity = $true
                $timedOut = $true
                Stop-CodexTree $process
            }

            # Wake at most once per second so Ctrl+C and the deadline are
            # honored; reads themselves are event-driven.
            $timeoutMs = 1000
            if (-not $state.Progress -and -not $state.RetryableCapacity) {
                $untilDeadline = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
                $timeoutMs = [int][Math]::Max(1, [Math]::Min(1000, [Math]::Ceiling($untilDeadline)))
            }

            $names = @($pendingReads.Keys)
            $tasks = [Threading.Tasks.Task[]]@($names | ForEach-Object { $pendingReads[$_] })
            $index = [Threading.Tasks.Task]::WaitAny($tasks, $timeoutMs)
            if ($index -lt 0) { continue }

            $name = $names[$index]
            $line = $pendingReads[$name].GetAwaiter().GetResult()
            if ($null -eq $line) {
                $pendingReads.Remove($name)
                continue
            }

            Handle-CodexLine -Line $line -IsStdErr ($name -eq 'err') -State $state
            if ($state.RetryableCapacity) {
                # The server already refused this attempt; free the retry
                # window instead of waiting for Codex's own retries.
                Stop-CodexTree $process
            }
            $pendingReads[$name] = $readers[$name].ReadLineAsync()
        }

        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        Stop-CodexTree $process
        if ($null -ne $process) { $process.Dispose() }
    }

    if (-not $state.RetryableCapacity) {
        if ($exitCode -eq 0) { exit 0 }
        if ($state.CapacityAfterProgress) {
            # The model had already started working (and may have run tools),
            # so a blind retry is unsafe. Codex's own error is already shown.
            exit 2
        }
        # A non-capacity error is not safe to retry blindly.
        exit ([Math]::Max(1, [int]$exitCode))
    }

    if ($timedOut) { break }

    $remaining = ($deadline - [DateTime]::UtcNow).TotalSeconds
    if ($remaining -le 0) { break }

    $wait = [Math]::Min($backoffSeconds, [Math]::Floor($remaining))
    if ($wait -gt 0) {
        Write-Host "Codex model capacity response; retrying in ${wait}s (attempt $attempt/$MaxAttempts)." -ForegroundColor DarkYellow
        Start-Sleep -Seconds $wait
    }
    $backoffSeconds = [Math]::Min(60, $backoffSeconds * 2)
}

# The retry-count guard must not shorten the user's retry window. If the
# guard is reached first, stay quiet until the deadline before showing the
# final capacity message.
$remainingAfterAttempts = ($deadline - [DateTime]::UtcNow).TotalSeconds
if ($remainingAfterAttempts -gt 0) {
    Write-Host "Retry attempt guard reached; waiting $([Math]::Floor($remainingAfterAttempts))s before reporting capacity." -ForegroundColor DarkYellow
    Start-Sleep -Seconds ([Math]::Floor($remainingAfterAttempts))
}

[Console]::Error.WriteLine('Selected model is at capacity. Please try a different model.')
exit 2
