# README simulator screenshots

The README images are original PNG captures from the native SwiftUI apps running
headlessly in Apple's iOS 27 and watchOS 27 simulators. They are not mockups,
redrawn interfaces, physical-device captures or proof of real authentication.

The private simulator launch argument `--readme-demo` supplies the existing
purple/cyan app artwork as an explicitly labelled demo character. It skips account
loading, credential import, character-cache loading and WatchConnectivity setup;
view interaction is disabled. No voice starts. This flag is unavailable in
physical builds and public configurations. The demo character remains still for
stable screenshots. `--readme-setup` also opens the native
private Safari instructions sheet; it does not launch a browser.

After building the simulator apps using the README command, choose available
iPhone and Watch UDIDs from `xcrun simctl list devices available`:

```sh
xcrun simctl boot PHONE_SIMULATOR_UDID
xcrun simctl bootstatus PHONE_SIMULATOR_UDID -b
xcrun simctl install PHONE_SIMULATOR_UDID DerivedData/Build/Products/Private-iphonesimulator/DotPhone.app
xcrun simctl launch PHONE_SIMULATOR_UDID dev.dotwatch.app --readme-demo
xcrun simctl io PHONE_SIMULATOR_UDID screenshot docs/screenshots/iphone.png
xcrun simctl terminate PHONE_SIMULATOR_UDID dev.dotwatch.app
xcrun simctl launch PHONE_SIMULATOR_UDID dev.dotwatch.app --readme-demo --readme-setup
xcrun simctl io PHONE_SIMULATOR_UDID screenshot docs/screenshots/safari-setup.png

xcrun simctl boot WATCH_SIMULATOR_UDID
xcrun simctl bootstatus WATCH_SIMULATOR_UDID -b
xcrun simctl install WATCH_SIMULATOR_UDID DerivedData/Build/Products/Private-watchsimulator/DotWatch.app
xcrun simctl launch WATCH_SIMULATOR_UDID dev.dotwatch.app.watch --readme-demo
xcrun simctl io WATCH_SIMULATOR_UDID screenshot docs/screenshots/watch.png
```

Wait for the app/sheet to appear before each screenshot, and visually inspect the
captured PNG. A simulator already booted should not be booted again. Shut down
only simulators booted for the capture after finishing. Capture provenance is
recorded in `screenshots/capture.json`.

CarPlay's existing headless tests validate native framework objects and action
behavior, not its display. No substitute CarPlay drawing is presented as a
simulator screenshot. The actual head-unit display and vehicle tests remain open.
