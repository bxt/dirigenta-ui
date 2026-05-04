# dirigenta-ui

A macOS menu bar app for controlling your [IKEA Dirigera](https://www.ikea.com/de/de/p/dirigera-hub-fuer-smarte-produkte-weiss-smart-10503406/) smart home hub.

Toggle lights, adjust brightness and color, and glance at environment sensor readings — all without opening the Home app.

This is perfect if you just want to toggle a single IKEA light with one click on your Macbook. Or if you have an IKEA hub and no Apple hub (e.g. HomePod, Apple TV) but you still want to control your smart home from macOS.

It also takes all your room configs and settings from the IKEA smart home instead of having to set up another Matter hub.

## Requirements

- macOS 26.2 or later
- An IKEA Dirigera hub on your local network

## Installation

1. Download the latest `dirigenta-ui-vX.X.X.zip` from [Releases](../../releases)
2. Unzip and move `dirigenta-ui.app` to `/Applications`
3. Run `xattr -r -d com.apple.quarantine /Applications/dirigenta-ui.app` *(macOS blocks unsigned apps by default; this one-time step bypasses that)*
4. You can optionally verify the integrity of the download by running `gh attestation verify dirigenta-ui-vX.X.X.zip --repo bxt/dirigenta-ui`

## Features

- **Toggle lights** on and off from the menu bar, control brightness and color
- **Pin a light** to the status bar icon for one-click toggling
- **Environment sensors** — temperature, humidity, CO₂, and PM2.5 readings with out-of-range highlights
- **Open/close sensors** — see if and how long e.g. windows have been open
- **Window notifications** – notifications when windows have been open a while or should be opened, factoring in CO₂, temperature, and humidity from nearby sensors
- **Terminal notifications** — flash lights red at the end of a CLI command (see below)
- **Room pinning** – you can now pin a room to a persistent third tab
- Disco mode to make lights switch colors in a groovy fashion
- Automatic hub discovery via mDNS (no manual IP entry needed)
- Real-time updates over WebSocket
- Devices other than lights and sensors listed as well

## Light notifications from the terminal

dirigenta-ui can flash your lights as a visual notification at the end of a long-running terminal command — handy for builds, tests, or deploys that run in the background.

### How it works

Pass `--notify` to the app binary. It posts an IPC message to the already-running instance and exits immediately (< 100 ms). The running app then:

1. Flashes the **pinned light** if one is set, otherwise flashes **all lights that are currently on**
2. Lights that were off are turned on for the flash and switched back off afterwards
3. Color lights turn **red** at full brightness for 1 second, then restore their previous color, temperature, and brightness
4. White-spectrum and dimmable lights flash at **full brightness** for 1 second, then restore their previous level

The app must be running and connected to the hub for the notification to have any effect. You have to turn on the feature in the app's settings first.

### Usage

```bash
# Run after any command
your-long-running-command && \
  /Applications/dirigenta-ui.app/Contents/MacOS/dirigenta-ui --notify
```

```bash
# Notify whether the command succeeded or failed
your-long-running-command; \
  /Applications/dirigenta-ui.app/Contents/MacOS/dirigenta-ui --notify
```

### Shell alias

Add this to your `~/.bashrc` or `~/.zshrc` for a short alias:

```bash
alias notify-lights='/Applications/dirigenta-ui.app/Contents/MacOS/dirigenta-ui --notify'
```

Then use it like:

```bash
./long-running-build.sh && notify-lights
```

## Building from source

```sh
git clone <repo-url>
open dirigenta-ui.xcodeproj
```

Select the `dirigenta-ui` scheme and press **Run** (⌘R). Xcode will build and launch the app. No dependencies beyond the standard SDK.

To run tests:

```sh
xcodebuild test \
  -project dirigenta-ui.xcodeproj \
  -scheme dirigenta-ui \
  -destination 'platform=macOS' \
  -skip-testing:dirigenta-uiTests/MDNSDiscoveryTests/testDiscoverHubOnLocalNetwork \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

## Releasing

Push a version tag and GitHub Actions builds and publishes the release automatically:

```sh
git tag v1.2.0 && git push --tags
```

## Privacy

Everything stays on your local network. The app communicates only with your Dirigera hub over HTTPS/WebSocket. No data leaves your home. The access token is stored in the macOS Keychain.

## Acknowledgements

This was made possible by [Leggin's Python dirigera lib which has e.g. some auth code](https://github.com/Leggin/dirigera/blob/main/src/dirigera/hub/auth.py) and [lpgera's TypeScript dirigera lib where I e.g. found the public key](https://github.com/lpgera/dirigera/blob/main/src/certificate.ts) and other efforts made by the community.

## Disclaimer

This application is an independent, unofficial project and is in no way affiliated with, endorsed by, sponsored by, or associated with IKEA Systems B.V., Inter IKEA Systems B.V., or any of their subsidiaries or affiliates. All IKEA trademarks, product names, and brand identifiers are the property of their respective owners.

This app was built entirely through vibe coding — an AI-assisted, intuition-driven development process — and makes no guarantees regarding functionality, accuracy, or fitness for any particular purpose. Use at your own risk.