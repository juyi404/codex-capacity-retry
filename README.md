# Codex capacity retry wrapper

`codex-capacity-retry.ps1` wraps `codex exec` and retries only capacity-style responses. It suppresses those transient capacity messages while the retry window is active. Lifecycle/tool events do not count as a model reply; after ten minutes without an assistant reply, it prints exactly:

```text
Selected model is at capacity. Please try a different model.
```

By default it uses `--ignore-user-config`, so stale or custom entries in `%USERPROFILE%\.codex\config.toml` do not participate in the clean test. It still uses the existing Codex login from `CODEX_HOME`.

Example:

```powershell
& ".\codex-capacity-retry.ps1" `
  -Prompt "检查当前项目的构建错误，只读分析，不修改文件" `
  -Model "gpt-6.1-sol"
```

For a prompt file:

```powershell
.\codex-capacity-retry.ps1 -PromptFile .\prompt.txt -Model gpt-6.1-sol
```

Useful switches:

- `-MaxWaitMinutes 10` — total retry window.
- `-MaxAttempts 12` — maximum attempts inside that window. The wrapper still waits for the full `-MaxWaitMinutes` before showing the final capacity message if this guard is reached first.
- `-UseUserConfig` — include the normal user config; omit this for a clean OpenAI-provider test.
- `-DisableProxy` — remove proxy variables only from the child Codex process.
- `-ShowEvents` — print the full JSONL lifecycle/tool event stream. By default only assistant replies and errors are printed, reducing terminal I/O.
- `-CodexBinary <path>` — optionally use a specific Codex executable instead of PATH resolution.
- `-Sandbox workspace-write` — allow file changes. The default is `read-only`.
- `-DryRun` — validate the resolved Codex binary and options without sending a request.

Automatic retries are safest for read-only or idempotent prompts. A model may have executed a tool before a connection fails, so do not use blind retries for prompts that create deployments, send messages, delete data, or perform other non-idempotent actions.

The implementation keeps retry-invariant arguments and compiled matchers outside the retry loop. It consumes stdout/stderr with `ReadLineAsync`, waits with `WhenAny` and `WaitForExitAsync`, and avoids PowerShell event-job queues and 200 ms polling. Output remains on the main PowerShell runspace, which also avoids background Runspace failures.
