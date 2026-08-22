# iumrah Business — iOS

Native SwiftUI admin application for iumrah operations and the on-device Hotel Importer.

## Current v0.1 scope

- Uses the existing `https://iumrah.app` staff login/session.
- Reads existing D1 booking and chat APIs.
- Adds a Hotels module.
- On-device `WKWebView` importer checks Booking, Expedia and Agoda serially.
- Extracts structured metadata, hotel images, common amenities and room-name candidates.
- Human Review step selects photos / cover before publishing.
- Publishes hotel metadata and selected images to the companion Hotel API in `iumrah-web`.

## Generate Xcode project

```bash
brew install xcodegen
xcodegen generate
open iumrahBusiness.xcodeproj
```

## Bundle ID

`com.iumrah.business`

Change it in `project.yml` before creating the App Store Connect record if another identifier is required.

## GitHub Actions

Use `.github/workflows/testflight.yml` from the manual first-upload package. It validates the app on a GitHub macOS runner and can upload a signed archive to TestFlight when Apple secrets are configured.
