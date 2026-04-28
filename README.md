# diregenta-ui

A macOS menu bar app for controlling your [IKEA Dirigera](https://www.ikea.com/us/en/p/dirigera-hub-for-smart-products-white-smart-50503409/) smart home hub.

Toggle lights, adjust brightness and colour, and glance at environment sensor readings — all without opening the Home app.

## Requirements

- macOS 26.2 or later
- An IKEA Dirigera hub on your local network
- A Dirigera access token (see below)

## Installation

1. Download the latest `diregenta-ui-vX.X.X.zip` from [Releases](../../releases)
2. Unzip and move `diregenta-ui.app` to `/Applications`
3. **First launch:** right-click the app → **Open** → click Open in the dialog  
   *(macOS blocks unsigned apps by default; this one-time step bypasses that)*

## Getting an access token

The Dirigera API uses a long-lived bearer token. To get one, press the action button on top of your hub for ~5 seconds until the light pulses, then run:

```sh
curl -X POST "https://<hub-ip>:8443/v1/oauth/authorize" \
  --insecure \
  -d '{"audience":"homesmart.local","grant_type":"authorization_code"}' \
  -H "Content-Type: application/json"
```

The response contains an `access_token`. Paste it into the app on first launch.

> The hub's IP address is shown in the menu while it's being discovered, or you can find it in your router's device list.

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
open diregenta-ui.xcodeproj
```

Select the `diregenta-ui` scheme and press **Run** (⌘R). Xcode will build and launch the app. No dependencies beyond the standard SDK.

To run tests:

```sh
xcodebuild test \
  -project diregenta-ui.xcodeproj \
  -scheme diregenta-ui \
  -destination 'platform=macOS' \
  -skip-testing:diregenta-uiTests/MDNSDiscoveryTests/testDiscoverHubOnLocalNetwork \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

## Releasing

Push a version tag and GitHub Actions builds and publishes the release automatically:

```sh
git tag v1.2.0 && git push --tags
```

## Privacy

Everything stays on your local network. The app communicates only with your Dirigera hub over HTTPS/WebSocket. No data leaves your home. The access token is stored in the macOS Keychain.
