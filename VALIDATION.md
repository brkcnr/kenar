# Validation

Current version: **1.3.0**. Validation performed on macOS with Swift 6.4 and the macOS 26.5 SDK and Xcode Command Line Tools.

## Automated checks

`bash test.sh` passes **52 scenarios**, covering:

- Antigravity official status line payloads, absolute/relative reset hints, missing/invalid fractions, stale sources, privacy filtering, repaint deduplication, history replay across refreshes and application restarts, settings preservation, and migration.
- Provider quota parsing, missing fields, unknown models, unlimited plans, and reset timestamps.
- Provider-specific preview schemas: Codex session/weekly windows, Claude session/all-model/model-scoped windows, Cursor plan usage, and Antigravity quota buckets.
- Suppressed background Keychain dialogs, silent provider-specific credential recovery, rejected-token exclusion, and recovery polling without API requests for blocked credentials.
- Missing, expired, malformed, and blocked Claude credentials; immediate recovery after a failed read; source re-reading on manual retry; and provider-specific retry intent.
- Notification thresholds, deduplication across restarts, and quota-period changes.
- SQLite retention, failed-measurement exclusion, reset-period separation, streaming event deduplication, and transactional import rollback.
- Project/provider separation, model-scoped estimated attribution, baseline/reset exclusion, and unexplained usage.
- Claude, Codex, and Gemini transcript import with conversation content excluded from stored data.
- HTTPS redirect restrictions, chart downsampling, display geometry, legacy settings migration, connection freshness, hover behavior, and English formatting/persistence.

## Build and interface checks

- Release builds for Apple Silicon and Intel are combined into a universal macOS 13+ application. The Intel build has not been run on physical Intel hardware.
- The ad-hoc code signature, bundle metadata, and DMG checksums pass verification.
- The packaged status line launcher was executed with a fixture in an isolated directory: it wrote validated quota metadata, omitted private fields, and produced no stdout or macOS UI.
- The DMG uses an HFS-to-UDZO fallback when a writable disk device is unavailable. Finder mounting was not verified in that build environment.
- The compact island and expanded panel were rendered from the application's actual SwiftUI components. Sample data is explicitly labeled in preview mode.
- The installed 1.2.2 app was restarted and visually checked on the desktop. The compact island's top and bottom padding is 24 pt, with 6 pt additional clearance on each side compared with 1.2.1.
- Real Claude and Codex accounts returned successful quota measurements. Claude was also verified after restarting the installed app. No credentials or raw API bodies were included in diagnostic output.
- Installed 1.2.3 was restarted: the compact island showed both Claude and Codex after automatic refresh, without a Keychain dialog during that launch. The shell-based account verifier reported offline in this restricted environment; the installed app's successful connection was checked on the desktop instead.

- Installed 1.3.0 received a live `agy` status line payload with `gemini-5h`, `gemini-weekly`, `3p-5h`, and `3p-weekly` quota buckets, including reset timestamps. The source was the existing authenticated CLI; no Google credential read or generated prompt was used.

## Remaining verification limits

- Cursor live-account compatibility has not been verified. Legacy Gemini parsers remain fixture-tested. Antigravity live publication was verified from the installed `agy` session; values have not been independently compared with its `/usage` panel.
- Antigravity project token consumption is unavailable; context counters are deliberately excluded.
- Persistent Keychain permission after choosing Always Allow and after Claude Code rotates a token still require an interactive desktop check.
- Claude's quota values were not independently compared with Claude Code's `/usage` display.
- Notification banner delivery, launch-at-login registration, physical monitor hot-plugging, and multiple physical display scales were not fully exercised.
- English settings controls were covered by automated checks and code-based rendering; a full desktop walkthrough of every language selector interaction was not performed.
- Apple notarization and App Store distribution are not provided. Internal provider endpoints may change.
