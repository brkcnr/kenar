# Kenar

A native macOS usage monitor for **Claude, Codex, Cursor, and Antigravity CLI (`agy`)**. Kenar lives in a small, Dynamic Island–style glass panel attached to the left or right edge of your display.

Built with SwiftUI and AppKit. Requires **macOS 13 or later** and supports both Apple Silicon and Intel Macs.

## Preview

<img src="assets/kenar-demo.gif" alt="Kenar expanding from an edge island, displaying Codex and Claude quota windows separately, and collapsing when the pointer leaves" width="360">

*Rendered from Kenar’s native SwiftUI interface with labeled sample data. Codex shows session and weekly limits; Claude shows session, all-model weekly, and model-specific limits when reported by the account.*

## Features

- **An unobtrusive edge island.** The collapsed island shows only providers with a successful, recent connection. Hover to expand it and inspect every enabled provider, including connection errors. Pin the panel to keep it open.
- **Quota details and reset countdowns.** See session, weekly, and model-specific limits when the provider exposes them. Unknown usage and reset times remain unknown.
- **Configurable alerts.** Default thresholds are 75%, 90%, and 100%, with separate settings for each provider. Alerts are deduplicated within each quota period, including across app restarts.
- **Local usage history.** Explore daily and weekly charts with provider and quota/model filters. History starts when Kenar runs and retains 90 days of successful measurements. Reset periods are drawn separately.
- **Project analytics.** Import token counters from local Claude Code, Codex, and Antigravity sessions, plus legacy Gemini CLI records. Antigravity generation records provide actual input, output, and cache counters; context percentages are never treated as consumption. Group projects by Git root and filter by session, week, month, or all time. Estimated quota attribution is clearly labeled where supported; it is not shown for Antigravity because model-to-quota-bucket mapping is unverified.
- **Display and appearance controls.** Choose a monitor, left or right edge, light/dark/system appearance, width, surface opacity, accent color, and text size. The panel falls back to the main display when its selected monitor disconnects.
- **English and Turkish.** Switch languages in Settings → Appearance → Language. The selection persists across restarts.
- **A background companion.** No Dock icon, optional launch at login, automatic quota refresh every two minutes, and manual refresh or connection retry. Antigravity updates arrive from an active `agy` session.

## Build and install

Install Xcode Command Line Tools if needed:

```sh
xcode-select --install
```

Clone and build:

```sh
git clone https://github.com/brkcnr/kenar.git
cd kenar
bash build.sh
```

The build produces a universal `dist/Kenar.app` and `dist/Kenar.dmg`. Open the disk image, drag Kenar into Applications, then launch it. Move your pointer onto the island at the right edge of your main display to open the panel.

The app is **ad-hoc signed and not notarized by Apple**. If macOS blocks it, review the app notice in System Settings → Privacy & Security.

## Connect your tools

Claude can connect directly through a web login owned by Kenar, or use Claude Code’s quota bridge and subscription OAuth login. Codex and Cursor use existing CLI logins. Antigravity connects through its documented local status line; Kenar does not read Google's credentials. API-key billing and the Gemini web app are outside this version's scope.

| Provider | Required login | Project analytics |
| --- | --- | --- |
| Claude | Kenar-owned web login, or Claude Code subscription quota bridge/OAuth | Local Claude Code assistant token counters; other surfaces share account quotas |
| Codex | Codex OAuth login in `.codex/auth.json` | Local `sessions` and `archived_sessions` records |
| Cursor | Cursor CLI login via `cursor-agent login` | Account totals; reliable project breakdown is unavailable from this source |
| Antigravity | Existing `agy` login and the Kenar status line connection | Local SQLite generation counters with workspace/Git-root grouping |

**Claude account:** web, Desktop, Claude Code and Cowork on the same account share limits. Kenar shows the account quota once; opening Desktop is not itself a login to Kenar. See [Anthropic’s explanation of shared usage](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work).

Choose **Settings → Providers → Connect Claude account**, then complete the login in Kenar’s window. Choose a workspace if your account has more than one. This selects **Claude account · Web login** and can refresh account usage while Claude Code is closed. Kenar keeps its own WebKit session; it does not import cookies or credentials from Safari, Chrome or Claude Desktop. Session expiry and website verification are reported explicitly. Claude’s web usage endpoints are internal and may change.

Alternatively choose **Connect Code quota bridge**. Kenar registers a small command in `~/.claude/settings.json` and installs `kenar-statusline.sh`, preserving unrelated settings and refusing to replace a custom status line. Claude Code reloads these settings automatically. Its [official status line payload](https://code.claude.com/docs/en/statusline) reports subscription limits after the first model response. The bridge retains only quota values and reset times, without reading Keychain credentials or sending prompts. A custom status line changes Claude Code’s footer; remove Kenar’s `statusLine` entry to restore the default footer.

**Automatic · Code bridge and OAuth** prefers a bridge measurement received within five minutes, then falls back to the existing Code OAuth source. Bridge data is the last measurement published by Code, not an independent account query. **Code credentials** uses the OAuth source directly. OAuth reads suppress automatic Keychain dialogs; a manual retry can request permission. Choose **Always Allow** for ongoing access, but an ad-hoc rebuild may require permission again. Kenar never refreshes or changes CLI tokens. Direct web login and the quota bridge avoid this Keychain dependency.

**Antigravity:** install and sign in to [Antigravity CLI](https://antigravity.google/docs/cli/install/), then choose **Settings → Providers → Connect Antigravity**. Kenar adds a small launcher to `~/.gemini/antigravity-cli/` and a `statusLine` command to its settings. Existing settings and the built-in status line are preserved; an unrelated custom status line is never overwritten.

For an already-running `agy` session, activate the connection once inside its prompt:

```text
/statusline ~/.gemini/antigravity-cli/kenar-statusline.sh
/usage
```

The [status line interface](https://antigravity.google/docs/cli/statusline/) supplies account quota buckets and reset hints as the CLI state changes. Kenar shows the most used bucket in the compact island and every reported bucket in expanded details. New bucket names are accepted without hardcoding model generations. The receiver retains only quota IDs, remaining fractions, reset times, and the receipt timestamp; email, credentials, conversation content, and context counters are discarded.

Kenar picks up changed local quota data within its one-second check interval. Refresh in Kenar reads the latest published measurement; [`/usage` in agy](https://antigravity.google/docs/cli/commands/usage/) refreshes it from Google. Measurements older than five minutes are marked stale and hidden from the compact island. The bridge needs an active CLI session and does not query Google independently or send prompts. Legacy Gemini history remains under **Gemini (legacy)** in analytics.

**Antigravity project analytics:** Kenar opens local `conversations/*.db` and `conversation_summaries.db` read-only, importing generation token counters, model IDs and timestamps. Output already includes reasoning; cache reads are separate from the main total. A session with one workspace is grouped by its Git root. Missing or multiple workspaces remain unassigned instead of guessing a repository. Session, week, month and all-time filters use the same analytics screen as Claude and Codex. SQLite/protobuf formats are internal; unsupported or malformed records are skipped. No conversation titles, prompts, tool output or attachments are imported.

To remove the connection, run `/statusline delete` in `agy`; the launcher and Kenar's local quota file can then be deleted. Keep an active session's status line enabled while using this connection.

Expired tokens should be renewed in the corresponding CLI. Kenar does not use refresh tokens. A failed request preserves the last successful measurement and marks it stale; it never substitutes sample percentages. The collapsed island hides failed connections, while the expanded panel retains their details.

## Using the panel

Click a provider to inspect its quota windows and model details. Use the pin to keep the panel open and the edge-facing arrow to collapse it. The sliders button opens Settings; the clock and folder buttons open usage history and project analytics.

Right-click the island to refresh, retry a failed provider, open Settings, or quit. Opening and closing use the same pointer polling interval; closing has no extra cooldown. Only left and right edges are supported.

Enable notifications when prompted if you want threshold and reset reminders. A reset reminder reports the provider's scheduled time; Kenar fetches again rather than assuming that the quota has reset.

## Privacy and data

All analytics are local. Kenar has no telemetry, crash reporting service, or third-party backend.

- SQLite stores quota measurements, timestamps, provider/model identifiers, project paths, session/event identifiers, and token counters. Conversation text, tool output, and attachments are not stored.
- Data lives in `~/Library/Application Support/Kenar/`. Quota history retains 90 days; older local CLI token records can be imported for project analysis.
- Claude and Cursor may cache only a short-lived access token in Kenar's private data directory. Refresh tokens are neither used nor copied. CLI credential stores are read-only. Explicit bridge setup modifies only the selected CLI’s status-line settings and launcher.
- Requests use HTTPS to the respective provider. HTTP disk caching is disabled, and credentials cannot follow redirects to a different origin or to HTTP.
- Token counts are not directly comparable across providers and do not represent billing. Cache reads are reported separately.
- Project quota attribution is an **estimate** based on quota increases between measurements and matching local token events. Initial measurements and resets are not counted as consumption. Unexplained usage is kept separate; activity on another device cannot be assigned reliably to a local project.

`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `AGY_CONFIG_DIR` (Kenar bridge configuration directory), and `GEMINI_CLI_HOME` (legacy transcript import) are honored when present in the app's process environment. An app launched from Finder does not automatically inherit your terminal's environment.

See [SECURITY.md](SECURITY.md) for credential handling and endpoint limitations.

## Development and verification

No external Swift package dependencies are required. The scripts preserve the native SwiftPM output layout. Set `KENAR_SDK` to an installed SDK path when your toolchain needs an SDK override (for example, an older SDK if Command Line Tools lacks the new SwiftUI macro plugin). Run:

```sh
bash test.sh
bash build.sh
```

`test.sh` uses XCTest with full Xcode, or a standalone assertion runner for the same scenarios when only Command Line Tools are installed. The current suite contains **62 scenarios**. `build.sh` compiles both architectures, combines them into a universal app, signs it ad hoc, and verifies the disk image.

Inspect a live provider connection without printing tokens or raw response bodies:

```sh
bash verify.sh codex
bash verify.sh claude cursor antigravity
# Inspect actual Antigravity token totals in a separate local database:
bash inspect-antigravity.sh /tmp/kenar-antigravity-check.sqlite
```

Run an explicitly labeled preview with sample data:

```sh
KENAR_PREVIEW=1 dist/Kenar.app/Contents/MacOS/Kenar
```

Preview mode makes no provider requests, scans no local token records, and writes no history. [VALIDATION.md](VALIDATION.md) records tested behavior and remaining verification limits.

Regenerate the README animation on macOS using the same native views:

```sh
bash render-demo.sh
```

The renderer uses an isolated settings domain and sample data. It writes the GIF to `assets/kenar-demo.gif` and inspection frames to `.build/demo/`.

Some usage endpoints are internal provider interfaces rather than documented public APIs. Account compatibility and response formats may change.

## License and credits

Kenar is based on [Brink](https://github.com/semihtalii/brink), created by **Semih Tali** and released under the MIT license. The original copyright notice is preserved in [LICENSE](LICENSE) and the application bundle.

[UPSTREAM.md](UPSTREAM.md) identifies the upstream commit and adapted components.

The Antigravity generation field mapping was informed by the original [Tokdash parser](https://github.com/JingbiaoMei/Tokdash) and independently checked against installed CLI records. Kenar uses its own bounded Swift wire reader. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
