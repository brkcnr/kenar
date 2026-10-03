# Security and privacy

Kenar uses its own Claude web login or reads existing CLI login credentials to request usage information from the corresponding provider. It does not modify CLI credential stores, rotate refresh tokens, or send conversation content to a backend.

## Credential destinations

| Provider | Credential source | Request destination |
| --- | --- | --- |
| Claude account | Kenar-owned WebKit session; no external browser or Desktop cookies | `claude.ai` |
| Claude Code | Quota-only status line payload, or read-only Code OAuth credentials | Local file, or `api.anthropic.com` |
| Codex | `.codex/auth.json` | `chatgpt.com` |
| Cursor | Existing Cursor CLI login | `cursor.com` |
| Antigravity | No credentials read; local quota payload from an authenticated `agy` session | Local file only; no Google requests from Kenar |

Requests use HTTPS to fixed provider hosts. HTTP disk caching is disabled. Credential-bearing requests cannot follow redirects to a different origin or to HTTP. App Transport Security is enabled.

## Local storage

`~/Library/Application Support/Kenar/` holds local analytics and, where needed, short-lived access-token caches. Credential cache files use mode `0600` inside a private directory. Refresh tokens are never copied or used.

Analytics records contain quota values, timestamps, provider/model identifiers, project paths, session/event identifiers, and token counters. They exclude conversation text, tool output, and attachments. There is no telemetry, remote analytics service, or crash reporting backend.

## Antigravity bridge

The explicit connection action registers a command in `~/.gemini/antigravity-cli/settings.json` and installs `kenar-statusline.sh`; unrelated settings and custom commands are preserved. The launcher invokes Kenar with `--antigravity-statusline`. This mode reads bounded JSON on stdin and exits without starting the macOS UI or requesting provider data. Only validated quota bucket identifiers, fractions, reset times, and the receipt timestamp are atomically stored in `antigravity-usage.json` with mode `0600`. It discards the rest of the payload, including email, workspace paths, conversation identifiers, context token counts, and credentials. Repeated repaint payloads are deduplicated, with a two-minute receipt heartbeat. Kenar does not access the Antigravity Keychain profile or send prompts.

## Claude account and quota bridge

A user completes web login in Kenar’s own WKWebView. WebKit stores that session in Kenar’s app data; Kenar sends its Claude session cookie only to fixed HTTPS `claude.ai` endpoints. It does not read or decrypt Claude Desktop tokens or other browsers’ cookie stores. Account/workspace IDs and display names support workspace selection. Changing connection source clears the displayed Claude quota and discards in-flight responses from the previous source.

Explicit Code bridge setup writes a launcher and `statusLine` configuration in the selected Claude config directory, preserving unrelated settings and refusing custom-command replacement. `--claude-statusline` filters bounded stdin to five-hour/seven-day subscription quotas only; session IDs, transcript paths, prompts and context counters are discarded. Measurements older than five minutes and expired windows are not accepted as fresh. The receiver does not start the UI, read credentials or send requests.

Antigravity analytics opens CLI SQLite databases read-only and extracts bounded usage/timestamp protobuf fields and workspace URIs. The decoder does not interpret prompt/tool payloads, and analytics stores no conversation content. WAL changes trigger imports; stable session/generation identifiers prevent repeated scans from counting events again.

## Claude Keychain access

Automatic Claude reads set both `LAContext.interactionNotAllowed` and `kSecUseAuthenticationUIFail` so a legacy macOS Keychain permission dialog cannot appear in the background. A manual connection retry can show macOS's permission dialog for the existing Claude Code credential item. Kenar does not alter the item's access control list or unlock the Keychain itself. Read failures are distinguished from missing and expired logins, and unsuccessful reads are not negatively cached.

For ongoing access, choose **Always Allow** in the macOS dialog rather than **Allow**. An ad-hoc rebuild can change the app identity and require permission again. A blocked or expired login is checked locally every five seconds; only a usable credential triggers a quota request. An access token rejected with HTTP 401 is excluded until Claude Code supplies a different one. These probes never launch Claude Code, modify its settings, or refresh its tokens.

## Limitations and reporting

Some provider usage endpoints are internal interfaces and may change or stop working. Builds are currently ad-hoc signed, not Apple-notarized.

Do not include access tokens, credential files, raw authorization headers, or private conversation logs in public bug reports. Report credential exposure or other security problems privately to the repository maintainer rather than posting the sensitive details in an issue.
