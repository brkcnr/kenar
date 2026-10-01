# Validation

Current version: **1.2.2**. Validation performed on macOS with Swift 6.3.3 and Xcode Command Line Tools.

## Automated checks

`bash test.sh` passes **40 scenarios**, covering:

- Provider quota parsing, missing fields, unknown models, unlimited plans, and reset timestamps.
- Provider-specific preview schemas: Codex session/weekly windows, Claude session/all-model/model-scoped windows, Cursor plan usage, and Gemini request quotas.
- Missing, expired, malformed, and blocked Claude credentials; immediate recovery after a failed read; source re-reading on manual retry; and provider-specific retry intent.
- Notification thresholds, deduplication across restarts, and quota-period changes.
- SQLite retention, failed-measurement exclusion, reset-period separation, streaming event deduplication, and transactional import rollback.
- Project/provider separation, model-scoped estimated attribution, baseline/reset exclusion, and unexplained usage.
- Claude, Codex, and Gemini transcript import with conversation content excluded from stored data.
- HTTPS redirect restrictions, chart downsampling, display geometry, legacy settings migration, connection freshness, hover behavior, and English formatting/persistence.

## Build and interface checks

- Release builds for Apple Silicon and Intel are combined into a universal macOS 13+ application. The Intel build has not been run on physical Intel hardware.
- The ad-hoc code signature, bundle metadata, and DMG checksums pass verification.
- The DMG uses an HFS-to-UDZO fallback when a writable disk device is unavailable. Finder mounting was not verified in that build environment.
- The compact island and expanded panel were rendered from the application's actual SwiftUI components. Sample data is explicitly labeled in preview mode.
- The installed 1.2.2 app was restarted and visually checked on the desktop. The compact island's top and bottom padding is 24 pt, with 6 pt additional clearance on each side compared with 1.2.1.
- Real Claude and Codex accounts returned successful quota measurements. Claude was also verified after restarting the installed app. No credentials or raw API bodies were included in diagnostic output.

## Remaining verification limits

- Cursor and Gemini live-account compatibility has not been verified; their parsers were exercised with representative fixtures.
- Claude's quota values were not independently compared with Claude Code's `/usage` display.
- Notification banner delivery, launch-at-login registration, physical monitor hot-plugging, and multiple physical display scales were not fully exercised.
- English settings controls were covered by automated checks and code-based rendering; a full desktop walkthrough of every language selector interaction was not performed.
- Apple notarization and App Store distribution are not provided. Internal provider endpoints may change.
