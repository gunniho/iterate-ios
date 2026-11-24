# Iterate for iOS

A native iPhone, iPad and Apple Watch client for an [Iterate](https://iterate.com) mind. A mind is a workspace's Iterate deployment: its agents, its config worker and its vault. This app is how a member reaches it from a phone. Open an agent and follow its replies as they arrive, start a new one by typing, dictating or calling it, and decide what your agents are waiting on you for.

The repository is a template. It builds as checked in, with sample settings, and one setup command points it at your own mind. Nothing in it names a particular workspace.

## What the app does

| Where | What you can do |
| --- | --- |
| Agents | Your agents, ordered by recent activity. Open one to read and reply in a native conversation, with replies and typing shown live. Archive from the list. |
| New Agent | Type or dictate a first message, or call the agent. The plus adds a photo, a file or your current place, or shares your screen during a call. |
| Your move | The one screen for what waits for you: outgoing email and agent actions to approve, statements to sign, and questions an agent asked. You sign each decision with a passkey or a key kept on the iPhone. |
| Lock Screen | An alert when something starts to wait, in one line of what is asked. A Live Activity on the Lock Screen and in the Dynamic Island names the first three things and counts the rest. |
| Voice | A live voice call with an agent, and questions about a shared screen on a compatible iPhone. |
| Siri and Shortcuts | “Talk to Iterate”, “Ask Iterate”, “Brief me with Iterate”, “Remember this in Iterate”, and Shortcuts actions that take another action’s text or file. |
| Widgets and controls | Home Screen widgets for a new agent, Your move and recent agents. Talk, Capture and Camera controls for Control Center, the Lock Screen and the Action button. |
| Share, Safari and keyboard | A Share extension, a Safari extension for a page or selection, and a keyboard that drafts text for you to review. |
| Apple Watch | Ask a question, read the reply and answer a follow-up, from the app or a complication. |
| Phone actions | While the app is open, your agents can look up a contact, list and run Home scenes, search and play music, and read a day’s steps. iOS asks you once for each kind of access. |

Some surfaces need a recent system version or device. The app targets iOS 17 and watchOS 10 and adds what later versions allow.

## How it fits together

```
iPhone app ── OAuth device flow ──▶ control host (iterate.<your domain>)
     │
     ├── WebSocket /api ──▶ the mind’s agents service        agent list, conversations, new agents
     │
     └── WebSocket /api ──▶ mobile facet (Server/mind)       Your move, capture, Siri and Shortcuts
                                   │                         requests, notes, voice, push registrations
                                   └── HTTP/2 ──▶ Apple Push Notification service
```

The app signs in to your control host with Iterate’s device flow and keeps the session in the Keychain. Agents and conversations come from the mind’s existing agents service, so the app can list and chat as soon as it is paired. Everything else the phone needs lives in the **mobile facet**: a small backend in `Server/mind` that the setup command copies into your mind’s config. The facet scopes every request, note and device to the signed-in member.

A build knows its workspace from six settings in `Configuration/Deployment.xcconfig`: three hostnames, the mind’s ID, a bundle ID and an Apple team ID. The setup command writes your values to `Configuration/Local.xcconfig`, which is gitignored. The app pins the mind’s ID, so it talks only to the mind it was built for.

## What is in the repository

| Path | Contents |
| --- | --- |
| `Sources/` | App entry point, sign-in, the socket to the mind, and live voice. |
| `Native/` | The screens: Agents, conversations, New Agent, Your move, approvals, settings, phone actions. |
| `Shared/` | Code the app shares with its extensions: the facet client, links, widget snapshots. |
| `Capture/` | Photo, file and note capture, the camera, and screen sharing. |
| `Intents/` | App Intents for Siri, Shortcuts, controls, alarms and timers. |
| `Extensions/` | Widgets and Live Activity, Share, Safari, keyboard, camera capture, and the Watch app. |
| `Companions/` | The link between the iPhone and the Watch. |
| `Configuration/` | Deployment settings, Info.plist and entitlements. |
| `Server/mind/` | The mobile facet that runs in your mind. |
| `Server/apns/` | A tool that installs your Apple push key in the mind’s vault. |
| `Server/tests/` | Backend tests, and `dev-mind.mjs`, a local stand-in for a mind. |
| `Tests/` | The app’s unit tests. |
| `scripts/configure.py` | The setup command. |
| `project.yml` | The XcodeGen spec that `Iterate.xcodeproj` is generated from. |

## Open the app on a Mac

Use **Use this template** on GitHub to make your own copy, then clone it. Open `Iterate.xcodeproj` with Xcode and select the **Iterate** scheme and an iPhone simulator. Choose **Product → Run** to open the Agents screen. The checked-in project builds with sample settings.

Development was tested with Xcode 27.1 and the iOS and watchOS SDKs. Setup uses Python 3.9 or later.

### Try it without a mind

`Server/tests/dev-mind.mjs` is a local stand-in that speaks a mind’s socket and serves seeded agents. It needs Node.js 22 or later.

```sh
(cd Server/apns && npm ci --ignore-scripts)
node Server/tests/dev-mind.mjs
```

In Xcode, choose **Product → Scheme → Edit Scheme → Run → Arguments** and add the environment variable `ITERATE_DEV_MIND` with the value `http://127.0.0.1:8787`. Run the app in the simulator and tap **Connect**. A Debug build with that variable talks to the stand-in and keeps its sign-in apart from a real workspace’s. Release builds ignore it.

## Connect your Iterate mind

1. Have your workspace’s apex domain, a member account, and a local checkout of its Iterate config ready. From this iOS repository, run the command below. Replace `studio.example` with your domain and the final path with your config checkout.

   ```sh
   python3 scripts/configure.py --domain studio.example --mind-config ../my-mind-config
   ```

   Setup looks up the public mind ID at `https://iterate.<domain>/.well-known/iterate` and pins it in `Configuration/Local.xcconfig`. It uses `dash.<domain>` for links. Supply `--control-host` or `--dash-host` for another layout, or `--mind-id` if you already know the ID. The identity lookup happens during setup, outside the app’s launch path.

2. In the mind config checkout, connect the generated mobile module to your worker’s event, publication, and fetch handlers. The backend guide has the copyable snippets. Review and publish the config through your usual Iterate workflow. If your mind already has this backend, omit `--mind-config` to configure only Xcode. [Worker integration and verification](Server/README.md#install-the-mobile-facet)

3. Build and run the **Iterate** scheme again. On **Agents**, tap **Connect** and approve the device in your workspace’s browser sign-in. Return to the app, open an agent, and send a message. To check the mobile facet, tap the tray icon to open **Your move**. A list, even an empty one, means the facet answered.

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

Alerts and the Lock Screen activity need Push Notifications on your app ID and your Apple push key in the mind’s vault. [Apple push setup](Server/README.md#apple-push-setup)

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

## What stays out of the repository

Your workspace’s settings live in `Configuration/Local.xcconfig` and, for the backend, in the `settings.js` that setup writes into your mind’s config. Both stay out of this repository, as do signing keys, provisioning profiles and Xcode’s per-user files: `.gitignore` lists them. Keep your Apple push key outside any source checkout. The installer sends it to the mind’s vault, which does not give it back.

This project uses the MIT license. [License](LICENSE)
