# Security and privacy

Kenar uses its own provider web sessions or explicitly selected existing CLI login credentials to request usage information from the corresponding provider. It does not modify CLI credential stores, rotate refresh tokens, or send conversation content to a backend.

## Credential destinations

| Provider | Credential source | Request destination |
| --- | --- | --- |
| Claude account | Kenar-owned WebKit session; no external browser or Desktop cookies | `claude.ai` |
| Claude Code | Quota-only status line payload, or read-only Code OAuth credentials | Local file, or `api.anthropic.com` |
| OpenAI | Kenar-owned WebKit session; optional read-only `.codex/auth.json` | `chatgpt.com` |
| Cursor | Kenar-owned WebKit session; optional existing CLI login | `cursor.com` |
| Gemini / Antigravity web | Kenar-owned product web sessions; scoped visible usage cards only | `gemini.google.com` / `antigravity.google.com` |
| Antigravity bridge | No credentials read; local quota payload from authenticated agy | Local file only |

Requests use HTTPS to fixed provider hosts. HTTP disk caching is disabled. Credential-bearing requests cannot follow redirects to a different origin or to HTTP. App Transport Security is enabled.

## Local storage

`~/Library/Application Support/Kenar/` holds local analytics and, where needed, short-lived access-token caches. Credential cache files use mode `0600` inside a private directory. Refresh tokens are never copied or used.

Analytics records contain quota values, timestamps, opaque account identifiers, workspace/product/pool identities, provider/model identifiers, project paths, session/event identifiers, and token counters. They exclude conversation text, tool output, and attachments. There is no telemetry, remote analytics service, or crash reporting backend.

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

## Account separation

Provider API calls are fixed-path metadata GETs in the corresponding HTTPS origin, with redirects rejected. OpenAI's session access token stays in memory and is used only on `chatgpt.com`; it is not copied into analytics or a new token file. The Google web reader hashes an account identifier before passing it to native code and scans only explicit usage cards, excluding conversation containers. Generic percentages and model availability are rejected.

Changing a connection invalidates its in-flight requests. History and notification identities include account, workspace, product, pool and window; percentages across products are never added. Disconnect disables the selected reader and deletes that product's cookies, preserving unrelated provider sessions. Google SSO cookies are retained because they can serve the other Google product; disconnect does not sign out other accounts or applications.

The database migration uses SQLite's online backup API, including committed WAL data, and applies schema changes transactionally. Legacy measurements are not assigned to the currently signed-in account. Future database schema versions are rejected rather than downgraded.

Google web quota readers and ordinary ChatGPT numeric quotas have not been live validated. Embedded-login restrictions are surfaced, never bypassed. No third-party OAuth application identity or refresh token is borrowed to fabricate an independent connection.

Turnstile sign-in frames may load HTTPS `challenges.cloudflare.com` and browser-local `about:blank` / `about:srcdoc` subframes. Local frame URLs are never top-level account pages or quota request destinations. The native WebKit user agent is preserved and users complete any interactive verification themselves.
