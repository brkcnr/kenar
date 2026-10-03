# Security and privacy

Kenar reads existing CLI login credentials to request usage information from the corresponding provider. It does not modify CLI credential stores, rotate refresh tokens, or send conversation content to a backend.

## Credential destinations

| Provider | Credential source | Request destination |
| --- | --- | --- |
| Claude | macOS Keychain `Claude Code-credentials`, or `.claude/.credentials.json` | `api.anthropic.com` |
| Codex | `.codex/auth.json` | `chatgpt.com` |
| Cursor | Existing Cursor CLI login | `cursor.com` |
| Antigravity | No credentials read; local quota payload from an authenticated `agy` session | Local file only; no Google requests from Kenar |

Requests use HTTPS to fixed provider hosts. HTTP disk caching is disabled. Credential-bearing requests cannot follow redirects to a different origin or to HTTP. App Transport Security is enabled.

## Local storage

`~/Library/Application Support/Kenar/` holds local analytics and, where needed, short-lived access-token caches. Credential cache files use mode `0600` inside a private directory. Refresh tokens are never copied or used.

Analytics records contain quota values, timestamps, provider/model identifiers, project paths, session/event identifiers, and token counters. They exclude conversation text, tool output, and attachments. There is no telemetry, remote analytics service, or crash reporting backend.

## Antigravity bridge

The explicit connection action registers a command in `~/.gemini/antigravity-cli/settings.json` and installs `kenar-statusline.sh`; unrelated settings and custom commands are preserved. The launcher invokes Kenar with `--antigravity-statusline`. This mode reads bounded JSON on stdin and exits without starting the macOS UI or requesting provider data. Only validated quota bucket identifiers, fractions, reset times, and the receipt timestamp are atomically stored in `antigravity-usage.json` with mode `0600`. It discards the rest of the payload, including email, workspace paths, conversation identifiers, context token counts, and credentials. Repeated repaint payloads are deduplicated, with a two-minute receipt heartbeat. Kenar does not access the Antigravity Keychain profile or send prompts.

## Claude Keychain access

Automatic Claude reads set both `LAContext.interactionNotAllowed` and `kSecUseAuthenticationUIFail` so a legacy macOS Keychain permission dialog cannot appear in the background. A manual connection retry can show macOS's permission dialog for the existing Claude Code credential item. Kenar does not alter the item's access control list or unlock the Keychain itself. Read failures are distinguished from missing and expired logins, and unsuccessful reads are not negatively cached.

For ongoing access, choose **Always Allow** in the macOS dialog rather than **Allow**. An ad-hoc rebuild can change the app identity and require permission again. A blocked or expired login is checked locally every five seconds; only a usable credential triggers a quota request. An access token rejected with HTTP 401 is excluded until Claude Code supplies a different one. These probes never launch Claude Code, modify its settings, or refresh its tokens.

## Limitations and reporting

Some provider usage endpoints are internal interfaces and may change or stop working. Builds are currently ad-hoc signed, not Apple-notarized.

Do not include access tokens, credential files, raw authorization headers, or private conversation logs in public bug reports. Report credential exposure or other security problems privately to the repository maintainer rather than posting the sensitive details in an issue.
