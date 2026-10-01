# Security and privacy

Kenar reads existing CLI login credentials to request usage information from the corresponding provider. It does not modify CLI credential stores, rotate refresh tokens, or send conversation content to a backend.

## Credential destinations

| Provider | Credential source | Request destination |
| --- | --- | --- |
| Claude | macOS Keychain `Claude Code-credentials`, or `.claude/.credentials.json` | `api.anthropic.com` |
| Codex | `.codex/auth.json` | `chatgpt.com` |
| Cursor | Existing Cursor CLI login | `cursor.com` |
| Gemini | Existing Gemini CLI Google-account login | `cloudcode-pa.googleapis.com` |

Requests use HTTPS to fixed provider hosts. HTTP disk caching is disabled. Credential-bearing requests cannot follow redirects to a different origin or to HTTP. App Transport Security is enabled.

## Local storage

`~/Library/Application Support/Kenar/` holds local analytics and, where needed, short-lived access-token caches. Credential cache files use mode `0600` inside a private directory. Refresh tokens are never copied or used.

Analytics records contain quota values, timestamps, provider/model identifiers, project paths, session/event identifiers, and token counters. They exclude conversation text, tool output, and attachments. There is no telemetry, remote analytics service, or crash reporting backend.

## Claude Keychain access

Automatic Claude reads are noninteractive. A manual connection retry can show macOS's permission dialog for the existing Claude Code credential item. Kenar does not alter the item's access control list or unlock the Keychain itself. Read failures are distinguished from missing and expired logins, and unsuccessful reads are not negatively cached.

## Limitations and reporting

Some provider usage endpoints are internal interfaces and may change or stop working. Builds are currently ad-hoc signed, not Apple-notarized.

Do not include access tokens, credential files, raw authorization headers, or private conversation logs in public bug reports. Report credential exposure or other security problems privately to the repository maintainer rather than posting the sensitive details in an issue.
