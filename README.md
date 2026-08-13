# Reset Meter

[![CI](https://github.com/RZDESIGN/reset-meter/actions/workflows/ci.yml/badge.svg)](https://github.com/RZDESIGN/reset-meter/actions/workflows/ci.yml)

A lean, native macOS menu-bar meter for the remaining usage in Codex, Claude, and Cursor.

Reset Meter keeps each provider's logo, a compact capacity bar, and the remaining percentage visible in the menu bar. Open it for every available usage window and its reset countdown.

## Install

Reset Meter supports macOS 14 or later on Apple Silicon and Intel Macs.

1. Download the latest DMG from [Releases](https://github.com/RZDESIGN/reset-meter/releases/latest).
2. Open it and drag **Reset Meter** to **Applications**.
3. Launch Reset Meter. It runs only in the menu bar, so it does not appear in the Dock.

The current community build is not Apple-notarized. On first launch, Control-click the app, choose **Open**, then confirm. A Developer ID-signed and notarized build can replace it without changing the app or installer scripts.

## Provider support

| Provider | What Reset Meter reads | Requirement |
| --- | --- | --- |
| Codex | The CLI's read-only `account/rateLimits/read` response | Codex CLI installed and signed in |
| Claude | Claude Desktop's local `plan-usage-history.json` cache | Claude Desktop installed and used at least once |
| Cursor | Cursor's local sign-in token, used for its current-period usage request | Cursor installed and signed in |

Claude's local cache does not include reset timestamps. Reset Meter estimates the active rolling-window reset from the usage history and marks it with `≈`. Codex and Cursor currently expose live reset timestamps.

These integrations use local or provider-internal interfaces rather than stable public usage APIs. A provider update can require a corresponding Reset Meter update.

## Privacy

- Everything runs locally except the read-only Cursor usage request, which goes directly to Cursor.
- Cursor's access token is read only when refreshing, held in memory, sent only to `api2.cursor.sh`, and never logged or saved by Reset Meter.
- Codex is queried through the locally installed CLI process.
- Claude data is read from its local Desktop cache.
- Reset Meter does not read prompts, conversations, browser cookies, or repository contents.
- Reset Meter has no analytics, telemetry, crash reporter, or update tracker.

Do not attach real usage files, access tokens, or unredacted screenshots to public bug reports.

## Build from source

Requirements:

- macOS 14 or later
- Xcode command-line tools with Swift 6

```sh
git clone https://github.com/RZDESIGN/reset-meter.git
cd reset-meter
swift test
./scripts/build-app.sh
```

The build script creates a universal, ad-hoc-signed app at `dist/Reset Meter.app`.

Create a drag-to-Applications DMG:

```sh
./scripts/package-dmg.sh
```

## Signed releases

For Gatekeeper-trusted public distribution, export a Developer ID Application identity and a `notarytool` keychain profile:

```sh
export RESET_METER_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)"
export RESET_METER_NOTARY_PROFILE="reset-meter-notary"
./scripts/package-dmg.sh
```

The script signs the universal app with the hardened runtime, signs the DMG, submits it to Apple's notary service, and staples the returned ticket.

## Project notes

- Provider parsing and reset calculations live in `UsageMeterCore` and have unit tests.
- The menu-bar label is rendered as one native template image because macOS does not reliably preserve nested SwiftUI views inside a `MenuBarExtra` label.
- Provider marks are used only to identify their respective services. See [Third-party notices](THIRD_PARTY_NOTICES.md).

## License

The source code is available under the [MIT License](LICENSE). Third-party names, marks, and artwork are excluded from that license.

Reset Meter is an independent community project. It is not affiliated with, sponsored by, or endorsed by OpenAI, Anthropic, Cursor, or Apple.
