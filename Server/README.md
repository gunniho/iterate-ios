# Connect the iOS app to your Iterate mind

The iPhone signs in to your control-plane hostname using Iterate’s device flow. Its agent list and conversations use the mind’s existing agents service over a WebSocket. The mobile facet adds Assistant requests, saved notes, capture, and voice for a particular chat. Text conversations use the model already configured for your mind.

## Install the mobile facet

1. Run the root setup command with `--mind-config /path/to/your/mind-config`. It copies the backend into `apps/iterate-ios/`, generates `settings.js` for your deployment, and adds the voice dependency and root `voice.ts` if missing. It preserves an existing voice package pin and shim. The tested pin is `@iterate-com/voice@0.1.0-main.20261119T232115Z-355995d`. If your mind tracks a package lock, refresh it with its usual package manager. [iOS setup](../README.md)
2. Open the config worker entrypoint named by `main` in your mind’s `package.json`, normally `worker.ts`. Add the imports below. Reuse the existing `installVoice` import if voice is already enabled.

   ```ts
   import { installVoice } from "@iterate-com/voice/install";
   import { installIterateMobile, mobileLink, updateIterateMobile } from "./apps/iterate-ios/backend.ts";
   ```

3. In `processEvent({ event, itx })`, add this before the existing event switch. The facet projects agent replies and processes its scheduled retries.

   ```ts
   await updateIterateMobile(itx, event);
   ```

4. In the existing `events.iterate.com/mind/worker-updated` case, add the mobile install after `installAgents(itx)`. Include the voice install once in this same case.

   ```ts
   await installIterateMobile(itx);
   await installVoice(itx);
   ```

   The voice package also expects this export in the root `voice.ts`. If your config already had that file, check it contains the service and relay class. Live voice uses your mind’s own OpenAI credential at `/secrets/openai`. Text chat, Assistant and capture work with your usual agent provider. [Iterate voice setup](https://github.com/iterate/packages/blob/main/packages/voice/README.md)

   ```ts
   export { default, VoiceAgentDurableObject } from "@iterate-com/voice";
   ```

5. In the worker’s `fetch(request)` method, add this before the catch-all website response. The handler serves Apple’s app association on your apex and redirects signed-in members to their own task in your Dash. If that domain already publishes an Apple association for other apps, keep its existing handler first and merge the iOS app’s ID and paths into its association. [Apple associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains)

   ```ts
   const mobileResponse = await mobileLink(request, this);
   if (mobileResponse) return mobileResponse;
   ```

6. Review the changes, then publish your config through its normal Iterate workflow. On a member account, check the installed rule with the Iterate CLI. Replace the example hostname with your control plane.

   ```sh
   iterate itx run --mind iterate.example.org \
     --eval 'return await itx.rewriteRules.get("itx.iterateMobile")'
   ```

   The target should name `IterateMobile` and `apps/iterate-ios/backend.ts`. Launch the phone app, approve **Connect**, and open an existing agent. To exercise the mobile facet, send a short request from **Assistant** and wait for the inline reply. You can check a signed build’s association at `https://<your-apex>/.well-known/apple-app-site-association`. Its application ID should match the signed app’s entitlements. For an older Apple app ID whose prefix differs from its team ID, set the configurator’s `--app-id-prefix` to the prefix in that entitlement.

## Member data

The mobile facet scopes runs, notes, attachments and device registrations to the actor in the authenticated member session. Requests and replies use stable UUIDs so delivery can resume after a disconnect. **Remember** saves the member’s original note. **Ask** retrieves relevant notes and **Briefing** can include recent work. When the mind’s AI enrichment is unavailable, the memory store can still match note text locally.

## Optional Apple push setup

The app in this repository displays replies inline. Its backend also supports APNs for clients that register task notifications or Live Activities. The following steps apply if you ship such a client.

1. Enable Push Notifications for your own app ID, add its push entitlement to that client, and create an APNs key for the intended app and environment. Save the downloaded `.p8` outside your source checkouts. Use your Apple Developer team ID and the mind ID from your iOS setup. [Apple key creation](https://developer.apple.com/help/account/keys/create-a-private-key/) · [APNs provider authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
2. Set `APNS_KEY_FILE`, `APPLE_TEAM_ID`, `ITERATE_CONTROL_HOST`, and `ITERATE_MIND_ID` in your shell. With Node.js 22 or later, run these commands from the iOS repository.

   ```sh
   cd Server/apns
   node configure.mjs check sandbox "$APNS_KEY_FILE" --team-id "$APPLE_TEAM_ID"
   npm ci --ignore-scripts
   node configure.mjs install sandbox "$APNS_KEY_FILE" --team-id "$APPLE_TEAM_ID" \
     --mind "$ITERATE_CONTROL_HOST" --mind-id "$ITERATE_MIND_ID"
   ```

   Use `production` for TestFlight or App Store builds. The installer reads the key ID from Apple’s `AuthKey_<ID>.p8` filename. For a renamed file supply `--key-id`. Repeating the command with the same key is safe. To rotate to a different key, supply `--replace`.

The installer checks the signed-in mind and sends the signing material directly to its vault. The provider uses `/secrets/iterate-apns-sandbox` or `/secrets/iterate-apns-production`, pinned to Apple’s corresponding host. The bundle ID in `settings.js` supplies the APNs topic. A client receiving a push on a signed device verifies delivery.

## Backend tests

From the iOS repository, run `node --test Server/tests/*.test.mjs`. The suite exercises a second deployment, member isolation, durable retries, notes, chat voice and APNs contracts with local fixtures.
