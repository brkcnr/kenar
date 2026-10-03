# Kenar

A native macOS usage monitor for **Claude Code, Codex, Cursor, and Gemini CLI**. Kenar lives in a small, Dynamic Island–style glass panel attached to the left or right edge of your display.

Built with SwiftUI and AppKit. Requires **macOS 13 or later** and supports both Apple Silicon and Intel Macs.

## Preview

<img src="assets/kenar-demo.gif" alt="Kenar expanding from an edge island, displaying Codex and Claude quota windows separately, and collapsing when the pointer leaves" width="360">

*Rendered from Kenar’s native SwiftUI interface with labeled sample data. Codex shows session and weekly limits; Claude shows session, all-model weekly, and model-specific limits when reported by the account.*

## Features

- **An unobtrusive edge island.** The collapsed island shows only providers with a successful, recent connection. Hover to expand it and inspect every enabled provider, including connection errors. Pin the panel to keep it open.
- **Quota details and reset countdowns.** See session, weekly, and model-specific limits when the provider exposes them. Unknown usage and reset times remain unknown.
- **Configurable alerts.** Default thresholds are 75%, 90%, and 100%, with separate settings for each provider. Alerts are deduplicated within each quota period, including across app restarts.
- **Local usage history.** Explore daily and weekly charts with provider and quota/model filters. History starts when Kenar runs and retains 90 days of successful measurements. Reset periods are drawn separately.
- **Project analytics.** Import token counters from local Claude Code, Codex, and Gemini CLI sessions. Group projects by Git root and filter by session, week, month, or all time. Estimated quota attribution is clearly labeled.
- **Display and appearance controls.** Choose a monitor, left or right edge, light/dark/system appearance, width, surface opacity, accent color, and text size. The panel falls back to the main display when its selected monitor disconnects.
- **English and Turkish.** Switch languages in Settings → Appearance → Language. The selection persists across restarts.
- **A background companion.** No Dock icon, optional launch at login, automatic quota refresh every two minutes, and manual refresh or connection retry.

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

Kenar reads existing CLI logins; it does not create accounts or change the tools' credentials. API-key usage, Gemini's web app, and the Gemini API are outside this version's scope.

| Provider | Required login | Project analytics |
| --- | --- | --- |
| Claude | Claude Code subscription OAuth login, stored in Keychain or `.claude/.credentials.json` | Local assistant token counters |
| Codex | Codex OAuth login in `.codex/auth.json` | Local `sessions` and `archived_sessions` records |
| Cursor | Cursor CLI login via `cursor-agent login` | Account totals; reliable project breakdown is unavailable from this source |
| Gemini | Gemini CLI login with a Google account | Local JSON and JSONL session records |

**Claude:** opening Claude Desktop alone does not establish a Claude Code login. Run `/login` in Claude Code when necessary. If Kenar needs Keychain access, expand Claude's details and select **Retry connection**, then choose **Always Allow** in the macOS dialog to grant ongoing access to Kenar. Choosing **Allow** grants only that read. Automatic reads explicitly disable Keychain permission dialogs.

When Claude's connection is blocked by unavailable or expired credentials, Kenar checks the local credential source silently every five seconds. Once Claude Code renews the login and macOS permits access, Kenar fetches Claude's quotas automatically without a manual retry. These probes do not launch Claude Code or send API requests until usable credentials are available. Rejected tokens are not repeatedly retried; normal API errors and rate limits retain their existing refresh/backoff behavior. Missing, expired, unreadable, and blocked credentials are reported separately.

Ad-hoc app signatures change when the app is rebuilt, so macOS may ask for access again after installing a new build. **Always Allow** applies to the app identity macOS approved; Kenar does not change the credential item's access controls.

**Gemini:** model names and quotas come from your account's response; no model generation is hardcoded. If Kenar cannot determine the Google Cloud project, enter the project ID used by Gemini CLI in Settings. When several quotas share a model and measurement type, Kenar shows the most constrained one and its reset time.

Expired tokens should be renewed in the corresponding CLI. Kenar does not use refresh tokens. A failed request preserves the last successful measurement and marks it stale; it never substitutes sample percentages. The collapsed island hides failed connections, while the expanded panel retains their details.

## Using the panel

Click a provider to inspect its quota windows and model details. Use the pin to keep the panel open and the edge-facing arrow to collapse it. The sliders button opens Settings; the clock and folder buttons open usage history and project analytics.

Right-click the island to refresh, retry a failed provider, open Settings, or quit. Opening and closing use the same pointer polling interval; closing has no extra cooldown. Only left and right edges are supported.

Enable notifications when prompted if you want threshold and reset reminders. A reset reminder reports the provider's scheduled time; Kenar fetches again rather than assuming that the quota has reset.

## Privacy and data

All analytics are local. Kenar has no telemetry, crash reporting service, or third-party backend.

- SQLite stores quota measurements, timestamps, provider/model identifiers, project paths, session/event identifiers, and token counters. Conversation text, tool output, and attachments are not stored.
- Data lives in `~/Library/Application Support/Kenar/`. Quota history retains 90 days; older local CLI token records can be imported for project analysis.
- Claude and Cursor may cache only a short-lived access token in Kenar's private data directory. Refresh tokens are neither used nor copied. CLI credential stores are read-only.
- Requests use HTTPS to the respective provider. HTTP disk caching is disabled, and credentials cannot follow redirects to a different origin or to HTTP.
- Token counts are not directly comparable across providers and do not represent billing. Cache reads are reported separately.
- Project quota attribution is an **estimate** based on quota increases between measurements and matching local token events. Initial measurements and resets are not counted as consumption. Unexplained usage is kept separate; activity on another device cannot be assigned reliably to a local project.

`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GEMINI_CLI_HOME`, `GOOGLE_CLOUD_PROJECT`, and `GOOGLE_CLOUD_PROJECT_ID` are honored when present in the app's process environment. An app launched from Finder does not automatically inherit your terminal's environment.

See [SECURITY.md](SECURITY.md) for credential handling and endpoint limitations.

## Development and verification

No external Swift package dependencies are required. The scripts preserve the native SwiftPM output layout. Set `KENAR_SDK` to an installed SDK path when your toolchain needs an SDK override (for example, an older SDK if Command Line Tools lacks the new SwiftUI macro plugin). Run:

```sh
bash test.sh
bash build.sh
```

`test.sh` uses XCTest with full Xcode, or a standalone assertion runner for the same scenarios when only Command Line Tools are installed. The current suite contains **44 scenarios**. `build.sh` compiles both architectures, combines them into a universal app, signs it ad hoc, and verifies the disk image.

Inspect a live provider connection without printing tokens or raw response bodies:

```sh
bash verify.sh codex
bash verify.sh claude cursor gemini
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
