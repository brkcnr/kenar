# Validation

Version: **1.5.0**. Built on macOS using Swift 6.4, Xcode Command Line Tools and the macOS 26.5 SDK.

## Automated checks

The standalone runner passes **74 scenarios**. Coverage includes:

- Provider parsing, missing/invalid percentages, unlimited plans, new model labels and reset timestamps.
- Account, workspace, product and pool identity separation; explicit Cursor Models / Other Models parsing; unknown values remaining unknown.
- Independent Google product failures, stale data preservation and rejection of another account's previous quota.
- Source changes discarding in-flight responses only for the affected group.
- Transactional schema migration, online SQLite backup including WAL records, legacy accounts remaining unassigned, future schema protection and replay deduplication.
- Web usage excluded from local project token attribution.
- Threshold notification deduplication, quota periods, retention and reset separation.
- Existing Claude, Codex and Antigravity bridges, credential recovery, local project imports, privacy filtering, geometry, language and preferences.

The separate native application passed **75 scenarios with zero failures**, including the WebKit DOM fixture: quota cards must exclude conversation and marketing percentages. This check requires the normal desktop WebKit environment; the restricted shell cannot load its page. The native result was confirmed both in `.build/native-tests.log` and the application’s result window.

## Build and package

- A universal, ad-hoc signed macOS 13+ app is built for arm64 and x86_64. Signature and bundle verification pass. Physical Intel hardware has not been tested.
- The compressed DMG checksum passes verification; mounting through Finder has not been tested in this environment.
- The README animation uses the actual SwiftUI components and clearly labeled sample data. The README displays it at 360 pixels wide.
- Version 1.5 was installed and restarted. The existing Claude web session and optional Codex OAuth source returned measurements. The history migration retained legacy records and created its backup. Account identifiers and API bodies were excluded from diagnostics.

## Live coverage and remaining work

| Source | Evidence | Remaining verification |
| --- | --- | --- |
| Claude web account | Existing owned session returned three quota windows before upgrade; preserved session returned measurements after 1.5 restart | Compare with official usage screen, enterprise SSO |
| Codex OAuth alternative | Returned live agentic quota after restart | Ordinary ChatGPT Chat is deliberately separate |
| OpenAI owned web session | Defensive account/workspace and usage readers implemented | User sign-in, actual workspace response and independent web comparison not yet verified |
| Cursor owned web session | User completed official login after the subframe fix; owned-session API returned legacy Included usage / Auto / API meters. Official usage page showed activity consistent with the returned values. Restart retained the session and returned fresh web-account measurements. | Paid-plan named pools, non-zero usage changes and enterprise accounts not live-tested |
| Gemini web | Experimental official usage-card reader | No independent numeric quota source has been verified; sign-in alone does not establish coverage |
| Antigravity web | Experimental official usage-card reader | No independent numeric quota API or compatible web card has been verified |
| Antigravity CLI alternative | Live status-line publication verified in 1.3; local generation import verified in 1.4 | Requires an active CLI; independent account querying remains unverified |

The Google web reader is **experimental**, not a completed independent numeric integration. Missing percentages are displayed as unknown. Normal ChatGPT Chat must not inherit Codex / Work percentages. Different product pools are never added together.

Desktop access intermittently became locked during this run. OpenAI and Google account sign-ins and comparisons remain pending; inaccessible accounts are not marked live-verified. Other outstanding checks include notification banners, launch at login, physical monitor hot-plugging and multiple display scales. Apple notarization is not provided. Internal provider interfaces may change.

## Embedded sign-in compatibility

The initial navigation policy rejected `about:blank` and `about:srcdoc`, which Turnstile requires in WebViews. These URLs are now allowed **only as subframes**; HTTPS challenge frames are also permitted. They are never accepted as top-level quota sources. The standard WebKit user agent and persistent cookie store remain intact; no CAPTCHA is solved automatically or bypassed. See [Cloudflare's WebView requirements](https://developers.cloudflare.com/turnstile/get-started/mobile-implementation/). The user completed Cursor login after this change; the official dashboard, fresh account measurements and persistence after restart were confirmed.
