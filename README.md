# Agent Meter

[日本語](README.ja.md)

Agent Meter is a macOS menu bar app that shows your Codex and Claude Code usage limits at a glance. It is built with SwiftUI.

## Features

- Uses the same login as the Codex CLI / supported IDE extensions
- Shows Codex rate-limit usage and reset times from the Codex app-server
- Shows Claude Code 5-hour and 7-day limits
- Turn each menu bar item (Codex · Week, Claude Code · 5 hours, Claude Code · Week) on or off independently; a service's bars sit side by side after its icon
- For each item, choose whether to show the period label and the bar, and whether the value is used, remaining (as a number or percentage), time until reset, or hidden
- Live preview in Settings (sample values fill in for services without data)
- Token counts are not shown: the services report usage only as a percentage and a reset time
- Refreshes automatically every 60 seconds

## Supported services

| Service | Source | Periods |
| --- | --- | --- |
| Codex | Codex CLI app-server | Whatever the account returns (currently 7 days) |
| Claude Code | Anthropic usage API, using Claude Code's login token from the Keychain | 5 hours, 7 days |

## Installation

With Homebrew:

```sh
brew install --cask scolor-dev/tap/agent-meter
```

Or download `AgentMeter-<version>.zip` from [GitHub Releases](https://github.com/scolor-dev/agent-meter/releases/latest), unzip it and move `AgentMeter.app` to `/Applications`.

## Updates

Agent Meter updates itself with [Sparkle](https://sparkle-project.org), however it was installed. In **Settings → Updates** you can turn automatic checks and automatic installation on or off, or use **Check for Updates…** in the menu.

You can also update by hand:

- Homebrew: `brew upgrade --cask --greedy agent-meter` (the cask is marked `auto_updates`, so a plain `brew upgrade` skips it)
- GitHub: download the latest ZIP from Releases and replace the app

## Requirements

- macOS 14 or later
- Codex CLI or a Codex-enabled IDE extension (for Codex)
- Claude Code CLI or a Claude Code-enabled IDE extension (for Claude Code)

You only need the services you want to show.
- Xcode, to build from source

The app runs external CLIs, so the App Sandbox is disabled. It is distributed through GitHub Releases and Homebrew, not the Mac App Store.

## Development

Open the project in Xcode:

```sh
open AgentMeter.xcodeproj
```

Debug build from the command line:

```sh
xcodebuild \
  -project AgentMeter.xcodeproj \
  -scheme AgentMeter \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO \
  build
```

If `xcode-select` points to the Command Line Tools, prefix the command with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

Run the unit tests:

```sh
xcodebuild -project AgentMeter.xcodeproj -scheme AgentMeter \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  test -only-testing:AgentMeterTests
```

## Claude Code integration and privacy

Agent Meter has no login of its own for Claude. It reuses the Claude Code login, whether it was made in a terminal or from a supported IDE extension.

In **Settings → Accounts**, choose **Add** (or **Manage**) for Claude Code:

- If you are already logged in (`claude auth login`), press **Recheck**.
- If not, **Log in** starts the official `claude auth login` browser (OAuth) flow.

To read usage, Agent Meter reads the access token Claude Code keeps in the macOS Keychain (`Claude Code-credentials`) and calls Anthropic's usage endpoint. The token is read through macOS's `security` tool, the same tool Claude Code uses to write it, which is meant to avoid macOS asking for permission on every read. If a permission prompt still appears, choose **Always Allow**. Token renewal is left to Claude Code: when the token has expired, Agent Meter runs `claude auth status` so Claude Code can refresh its own credentials, then reads them again. Agent Meter never refreshes, writes, or stores the token.

Usage values are kept in memory only. The only things saved to disk are which services you added and your menu bar display settings. Prompts, responses and working directories are never stored.

## Releasing

`scripts/release.sh` archives the app, exports it with Developer ID, notarizes it, signs the ZIP for Sparkle, publishes a GitHub release with `AgentMeter-<version>.zip` and `appcast.xml`, and leaves the Homebrew cask to [scolor-dev/homebrew-tap](https://github.com/scolor-dev/homebrew-tap), whose CI picks up each new stable release within the hour (it checks the app's signature and notarization first; run its `Update cask` workflow by hand for an immediate update).

One-time setup:

1. A Developer ID Application certificate in the login keychain.
2. Notarization credentials: `xcrun notarytool store-credentials agent-meter-notary`.
3. A Sparkle EdDSA key: run Sparkle's `generate_keys` (in `SourcePackages/artifacts/sparkle/Sparkle/bin` after resolving packages) and set the printed public key as `SPARKLE_PUBLIC_ED_KEY` in the app target's build settings. Back up the private key with `generate_keys -x <file>`; without it, existing installs can no longer be updated.
4. `gh auth login`.

Then bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (Sparkle only offers a build whose number is higher than the installed one), commit, and run:

```sh
scripts/release.sh
```

The working tree must be clean. Notarization can take anywhere from minutes to a few hours for a new account, and the script waits for it. `--no-publish` builds the ZIP and `appcast.xml` without creating a release; `--skip-notarize` skips notarization (local testing only) and cannot be combined with publishing.

## License

Agent Meter is released under the [MIT License](LICENSE).

It bundles [Sparkle](https://sparkle-project.org), which has its own license; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The Codex and Claude Code icons are trademarks of OpenAI and Anthropic and are not covered by this license. Agent Meter is not affiliated with OpenAI or Anthropic.
