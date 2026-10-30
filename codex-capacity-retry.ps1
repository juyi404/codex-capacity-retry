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

$ErrorActionPreference = 'Stop'

if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
        throw "Prompt file was not found: $PromptFile"
    }
    $Prompt = Get-Content -LiteralPath $PromptFile -Raw
}

if ([string]::IsNullOrWhiteSpace($Prompt)) {
    throw 'Pass a prompt as the first argument or use -PromptFile.'
}

if ($CodexBinary) {
    if (-not (Test-Path -LiteralPath $CodexBinary -PathType Leaf)) {
        throw "Codex binary was not found: $CodexBinary"
    }
    $codexPath = (Resolve-Path -LiteralPath $CodexBinary).Path
} else {
    $codexCommand = Get-Command codex.exe -ErrorAction SilentlyContinue
    if (-not $codexCommand) {
        $codexCommand = Get-Command codex.cmd -ErrorAction SilentlyContinue
    }
    if (-not $codexCommand) {
        throw 'Codex CLI was not found on PATH.'
    }
    $codexPath = $codexCommand.Source
}
$deadline = [DateTime]::UtcNow.AddMinutes($MaxWaitMinutes)
$backoffSeconds = $InitialBackoffSeconds
$attempt = 0

# Compile these once. Reusing Regex objects avoids reparsing the expressions
# for every JSONL event and every retry attempt.
$capacityRegex = [regex]::new(
    'selected model is at capacity|model(?: is)? at capacity|try a different model|model.{0,40}(?:overloaded|temporarily unavailable)|\b(?:429|503|529)\b',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
)
$quotaRegex = [regex]::new(
    'insufficient[_ -]?quota|quota exceeded|billing|payment required|spend limit',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
)
$replyRegex = [regex]::new(
    '"type"\s*:\s*"(?:agent_message|message)"',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
)
$errorEventRegex = [regex]::new(
    '"type"\s*:\s*"error"|"error"\s*:',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
)

$codexArguments = [System.Collections.Generic.List[string]]::new()
[void]$codexArguments.Add('exec')
[void]$codexArguments.Add('--json')
[void]$codexArguments.Add('--ephemeral')
[void]$codexArguments.Add('--skip-git-repo-check')
[void]$codexArguments.Add('--model')
[void]$codexArguments.Add($Model)
[void]$codexArguments.Add('--sandbox')
[void]$codexArguments.Add($Sandbox)
if (-not $UseUserConfig) {
    [void]$codexArguments.Add('--ignore-user-config')
}
[void]$codexArguments.Add('-')

function New-CodexProcess {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $codexPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    foreach ($argument in $codexArguments) {
        [void]$psi.ArgumentList.Add($argument)
    }

    if ($DisableProxy) {
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
            [void]$psi.Environment.Remove($name)
        }
        [void]$psi.Environment.Remove('http_proxy')
        [void]$psi.Environment.Remove('https_proxy')
        [void]$psi.Environment.Remove('all_proxy')
        [void]$psi.Environment.Remove('no_proxy')
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    return $process
}

function Stop-CodexProcess {
    param([Diagnostics.Process]$Process)

    if ($null -eq $Process -or $Process.HasExited) { return }
    try { $Process.Kill($true) } catch { try { $Process.Kill() } catch {} }
}

function Handle-CodexLine {
    param(
        [string]$Line,
        [bool]$IsError,
        [hashtable]$State
    )

    if ($null -eq $Line) { return }

    $State.OutputSeen = $true
    if ($replyRegex.IsMatch($Line)) { $State.ReplySeen = $true }
    if ((-not $quotaRegex.IsMatch($Line)) -and $capacityRegex.IsMatch($Line)) {
        $State.CapacitySeen = $true
        return
    }

    $isReply = $replyRegex.IsMatch($Line)
    $shouldPrint = $IsError -or $ShowEvents -or $isReply -or $errorEventRegex.IsMatch($Line)
    if (-not $shouldPrint) { return }

    if ($IsError) {
        [Console]::Error.WriteLine($Line)
    } else {
        [Console]::Out.WriteLine($Line)
    }
}

if ($DryRun) {
    $mode = if ($UseUserConfig) { 'user config' } else { 'clean OpenAI config' }
    $outputMode = if ($ShowEvents) { 'all events' } else { 'replies and errors' }
    Write-Output "codex-retry: model=$Model, max_wait=${MaxWaitMinutes}m, max_attempts=$MaxAttempts, sandbox=$Sandbox, mode=$mode, output=$outputMode"
    Write-Output "codex binary: $codexPath"
    exit 0
}

while ($attempt -lt $MaxAttempts -and [DateTime]::UtcNow -lt $deadline) {
    $attempt++
    $state = [hashtable]::Synchronized(@{
        CapacitySeen = $false
        OutputSeen = $false
        ReplySeen = $false
        Exited = $false
    })

    $process = New-CodexProcess

    $exitCode = -1

    try {
        if (-not $process.Start()) {
            throw 'Codex process did not start.'
        }
        $process.StandardInput.Write($Prompt)
        $process.StandardInput.Close()

        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()
        $exitTask = $process.WaitForExitAsync()
        $stdoutDone = $false
        $stderrDone = $false
        $exitSeen = $false

        while (-not ($stdoutDone -and $stderrDone -and $exitSeen)) {
            # If the server has already returned a capacity refusal, stop this
            # attempt quickly and use the remaining retry window.
            if ($state.CapacitySeen) {
                Stop-CodexProcess $process
            }

            # A completely silent attempt is treated as unavailable only after
            # the caller's full ten-minute window has elapsed.
            if (-not $state.ReplySeen -and [DateTime]::UtcNow -ge $deadline) {
                $state.CapacitySeen = $true
                Stop-CodexProcess $process
            }

            $tasks = [System.Collections.Generic.List[Threading.Tasks.Task]]::new()
            if (-not $stdoutDone) { [void]$tasks.Add($stdoutTask) }
            if (-not $stderrDone) { [void]$tasks.Add($stderrTask) }
            if (-not $exitSeen) { [void]$tasks.Add($exitTask) }

            if ($tasks.Count -eq 0) { break }

            $remainingMs = [Math]::Max(1, [int][Math]::Min(1000, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
            $delayTask = [Threading.Tasks.Task]::Delay($remainingMs)
            [void]$tasks.Add($delayTask)
            $completed = [Threading.Tasks.Task]::WhenAny([Threading.Tasks.Task[]]$tasks).GetAwaiter().GetResult()

            if ($completed.Equals($delayTask)) { continue }
            if ($completed.Equals($exitTask)) {
                $exitSeen = $true
                continue
            }
            if ($completed.Equals($stdoutTask)) {
                $line = $stdoutTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $stdoutDone = $true
                } else {
                    Handle-CodexLine -Line $line -IsError:$false -State $state
                    $stdoutTask = $process.StandardOutput.ReadLineAsync()
                }
                continue
            }
            if ($completed.Equals($stderrTask)) {
                $line = $stderrTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $stderrDone = $true
                } else {
                    Handle-CodexLine -Line $line -IsError:$true -State $state
                    $stderrTask = $process.StandardError.ReadLineAsync()
                }
            }
        }
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        Stop-CodexProcess $process
        $process.Dispose()
    }

    if (-not $state.CapacitySeen -and $exitCode -eq 0 -and $state.OutputSeen) {
        exit 0
    }

    if (-not $state.CapacitySeen) {
        # A non-capacity error is not safe to retry blindly.
        exit ([Math]::Max(1, [int]$exitCode))
    }

    $remaining = ($deadline - [DateTime]::UtcNow).TotalSeconds
    if ($remaining -le 0) { break }

    $wait = [Math]::Min($backoffSeconds, [Math]::Floor($remaining))
    if ($wait -gt 0) {
        Write-Host "Codex model capacity response; retrying in ${wait}s (attempt $attempt/$MaxAttempts)." -ForegroundColor DarkYellow
        Start-Sleep -Seconds $wait
    }
    $backoffSeconds = [Math]::Min(60, $backoffSeconds * 2)
}

# The retry-count guard must not shorten the user's ten-minute window. If the
# guard is reached first, stay quiet until the deadline before showing the
# final capacity message.
$remainingAfterAttempts = ($deadline - [DateTime]::UtcNow).TotalSeconds
if ($remainingAfterAttempts -gt 0) {
    Write-Host "Retry attempt guard reached; waiting $([Math]::Floor($remainingAfterAttempts))s before reporting capacity." -ForegroundColor DarkYellow
    Start-Sleep -Seconds ([Math]::Floor($remainingAfterAttempts))
}

[Console]::Error.WriteLine('Selected model is at capacity. Please try a different model.')
exit 2
