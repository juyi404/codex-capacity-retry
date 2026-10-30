# Codex capacity retry wrapper

`codex-capacity-retry.ps1` wraps `codex exec` and retries only capacity-style responses. It suppresses those transient capacity messages while the retry window is active. If no attempt gets the model working within ten minutes, it prints exactly:

```text
Selected model is at capacity. Please try a different model.
```

By default it uses `--ignore-user-config`, so stale or custom entries in `%USERPROFILE%\.codex\config.toml` do not participate in the clean test. It still uses the existing Codex login from `CODEX_HOME`.

Runs on Windows PowerShell 5.1 and PowerShell 7+. `codex-capacity-retry.cmd` prefers `pwsh.exe` and falls back to `powershell.exe`.

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
- `-ShowEvents` — print the full JSONL lifecycle/tool event stream. By default only the text of assistant replies and error messages is printed.
- `-CodexBinary <path>` — optionally use a specific Codex executable instead of PATH resolution.
- `-Sandbox workspace-write` — allow file changes. The default is `read-only`.
- `-DryRun` — validate the resolved Codex binary and options without sending a request.

How an attempt is classified:

- Each stdout line is parsed as a Codex JSONL event. Capacity patterns (`at capacity`, `overloaded`, `503 Service Unavailable`, `429 Too Many Requests`, ...) are matched only against `error` / `turn.failed` messages and plain-text stderr, never against replies, tool output or token counts. Quota and usage-limit errors are never retried.
- Any non-error `item.*` event (reasoning, command, agent message, ...) means the model is serving the turn. From then on the attempt is never stopped by the retry window and never retried; a later capacity error exits with code 2 after Codex's own message.
- An attempt that produces no items before the window ends is stopped and reported as capacity.

Exit codes: `0` success, `2` capacity, otherwise Codex's own exit code.

Automatic retries are safest for read-only or idempotent prompts. Retries only happen before the model starts working, but do not rely on them for prompts that create deployments, send messages, delete data, or perform other non-idempotent actions.

Implementation notes: the prompt is written to stdin as BOM-less UTF-8 and stdout/stderr are decoded as UTF-8, so non-ASCII prompts and replies are not mangled by the console code page (for example 936). Stdout/stderr are consumed with `ReadLineAsync` and `Task.WaitAny`, waking at most once per second so Ctrl+C and the deadline are honored. Stopping an attempt kills the whole process tree (`taskkill /T`), since npm's `codex.cmd` starts node and the native binary underneath it.

## Background proxy for Codex Desktop (official ChatGPT channel)

The wrapper above only covers `codex exec`. `proxy/` keeps Codex Desktop (and the CLI) from showing capacity errors on the official ChatGPT channel:

- `proxy/codex-gpt-retry-proxy.mjs` listens on `127.0.0.1:18798` and forwards to `https://chatgpt.com` through `HTTPS_PROXY`. A `429` (other than plan usage limits), `5xx`, or an SSE `server_is_overloaded` / `error` event that arrives before any model output is retried in the background for up to 10 minutes; Codex just waits. Errors after output started, usage-limit errors and everything else pass through. WebSocket upgrades get `426`, which makes Codex switch to HTTPS silently.
- `proxy/install.ps1` registers the hidden scheduled task `CodexGptRetryProxy` (at logon, re-checked every minute, single instance) and sets `openai_base_url` in `C:\ProgramData\OpenAI\Codex\config.toml`. That system layer only fills keys missing from `~/.codex/config.toml`, so CC Switch and Codex Desktop rewriting the user config do not remove it, and only the built-in OpenAI provider reads it — custom providers selected in CC Switch are unaffected. Restart Codex Desktop afterwards.
- `proxy/uninstall.ps1` removes the config line, the task and the process.
- Log: `%USERPROFILE%\.codex\gpt-retry-proxy.log` (`retry`, `recovered`, `gave_up`, `late_error_passed`). Status: `http://127.0.0.1:18798/__health`.
- Tests: `node --test proxy/test.mjs`.

Environment overrides: `GPT_RETRY_PORT`, `GPT_RETRY_MAX_WAIT_SECONDS`, `GPT_RETRY_UPSTREAM_PROXY`, `GPT_RETRY_LOG`.
