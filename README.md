# dirigenta-ui

A macOS menu bar app for controlling your [IKEA Dirigera](https://www.ikea.com/de/de/p/dirigera-hub-fuer-smarte-produkte-weiss-smart-10503406/) smart home hub.

Toggle lights, adjust brightness and colour, and glance at environment sensor readings — all without opening the Home app.

## Requirements

- macOS 26.2 or later
- An IKEA Dirigera hub on your local network

## Installation

1. Download the latest `dirigenta-ui-vX.X.X.zip` from [Releases](../../releases)
2. Unzip and move `dirigenta-ui.app` to `/Applications`
3. **First launch:** right-click the app → **Open** → click Open in the dialog  
   *(macOS blocks unsigned apps by default; this one-time step bypasses that)*
   You can verify the integrity of the download by running `gh attestation verify dirigenta-ui-v1.2.0.zip --repo bxt/dirigenta-ui`

## Features

- **Toggle lights** on and off from the menu bar
- **Brightness slider** for dimmable lights
- **Colour temperature** control for white-spectrum lights
- **Full RGB colour** picker for colour lights
- **Environment sensors** — temperature, humidity, CO₂, and PM2.5 readings with out-of-range highlights
- **Pin a light** to the status bar icon for one-click toggling
- Automatic hub discovery via mDNS (no manual IP entry needed)
- Real-time updates over WebSocket

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

## Disclaimer

This application is an independent, unofficial project and is in no way affiliated with, endorsed by, sponsored by, or associated with IKEA Systems B.V., Inter IKEA Systems B.V., or any of their subsidiaries or affiliates. All IKEA trademarks, product names, and brand identifiers are the property of their respective owners.

This app was built entirely through vibe coding — an AI-assisted, intuition-driven development process — and makes no guarantees regarding functionality, accuracy, or fitness for any particular purpose. Use at your own risk.