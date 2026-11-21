# Iterate for iOS

A native iPhone and iPad client for your Iterate mind. Open an agent, follow its replies as they arrive, dictate a message, or start a voice conversation. The app restores the paired member’s cached agent list on launch and refreshes it over the same foreground WebSocket used for chat.

## Open the app on a Mac

Use **Use this template** on GitHub to make your own copy, then clone it. Open `Iterate.xcodeproj` with Xcode and select the **Iterate** scheme and an iPhone simulator. Choose **Product → Run** to open the Agents screen. The checked-in project builds with sample settings. To sign in to your workspace, configure it below.

Development was tested with Xcode 27.1 and the iOS and watchOS SDKs. The shipping app targets iOS 17 and later. Setup uses Python 3.9 or later.

## Connect your Iterate mind

1. Have your workspace’s apex domain, a member account, and a local checkout of its Iterate config ready. From this iOS repository, run the command below. Replace `studio.example` with your domain and the final path with your config checkout.

   ```sh
   python3 scripts/configure.py --domain studio.example --mind-config ../my-mind-config
   ```

   Setup looks up the public mind ID at `https://iterate.<domain>/.well-known/iterate` and pins it in `Configuration/Local.xcconfig`. It uses `dash.<domain>` for links. Supply `--control-host` or `--dash-host` for another layout, or `--mind-id` if you already know the ID. The generated Xcode settings are gitignored. The identity lookup happens during setup, outside the app’s launch path.

2. In the mind config checkout, connect the generated mobile module to your worker’s event, publication, and fetch handlers. The backend guide has the copyable snippets. Review and publish the config through your usual Iterate workflow. If your mind already has this backend, omit `--mind-config` to configure only Xcode. [Worker integration and verification](Server/README.md#install-the-mobile-facet)

3. Build and run the **Iterate** scheme again. On **Agents**, tap **Connect** and approve the device in your workspace’s browser sign-in. Return to the app, open an agent, and send a message. To check the mobile backend, open **Assistant** from the top-right menu and ask a question. The reply appears inline.

Each member pairs their own device. The app keeps the OAuth session in the iOS Keychain and scopes its agent cache to the workspace and pairing. Text chat uses your mind’s existing agent provider. Live voice uses your mind’s voice service and its own provider credential. [Voice setup](Server/README.md#install-the-mobile-facet)

## Run on your iPhone

Add your Apple Developer account in Xcode. Choose a unique reverse-DNS bundle ID and your Apple team ID, and use those same values for the Xcode targets and the backend. For example, supply your own values for the shell variables below.

```sh
python3 scripts/configure.py --domain "$WORKSPACE_DOMAIN" \
  --bundle-id "$IOS_BUNDLE_ID" --team-id "$APPLE_TEAM_ID" \
  --mind-config ../my-mind-config
```

If you already installed the backend with simulator settings, review the files the command identifies and add `--replace-backend` to update them. Publish the updated settings so the website’s Apple association matches the signed app. Older Apple App IDs with a separate application identifier prefix can supply `--app-id-prefix`.

Use an enrolled team that supports the app’s capabilities. Xcode derives the extension and Watch identifiers from the base bundle ID. The targets share `group.<bundle-id>`; the main app also uses Associated Domains, HealthKit and HomeKit. Enable Developer Mode on the paired iPhone, select it in Xcode, and run the **Iterate** scheme. [Apple capability reference](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)

The shipping project includes the share extension, Safari extension, keyboard, widgets, capture controls, App Intents and Watch app. Screen sharing during a call uses Apple’s picker on a compatible iPhone. The **Iterate CarPlay** and **Iterate Japan Voice** schemes require their respective Apple entitlements. The separate **Iterate Siri Preview** project targets the matching preview SDK.

## Build and test

From the repository root, substitute an installed simulator’s ID in the test command. Backend tests use Node.js 22 or later. The opt-in microphone and live voice tests require microphone access or a paired account and voice service.

```sh
xcrun simctl list devices available
xcodebuild -project Iterate.xcodeproj -scheme Iterate \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" test
node --test Server/tests/*.test.mjs
python3 -m unittest discover -s scripts/tests
```

If you change target membership or build settings, update the XcodeGen specs and regenerate the projects with XcodeGen 2.45 or later.

```sh
xcodegen generate
xcodegen generate --spec project.siri-preview.yml
(cd VoiceClient && xcodegen generate)
```

This project uses the MIT license. [License](LICENSE)
