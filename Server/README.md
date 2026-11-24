# Connect the iOS app to your Iterate mind

The iPhone signs in to your control-plane hostname using Iterate’s device flow. Its agent list and conversations use the mind’s existing agents service over a WebSocket. The mobile facet adds Your move, capture, Siri and Shortcuts requests, saved notes, push registrations, and voice for a particular chat. Text conversations use the model already configured for your mind.

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

   The voice package also expects this export in the root `voice.ts`. If your config already had that file, check it contains the service and relay class. Live voice uses your mind’s own OpenAI credential at `/secrets/openai`. Text chat and capture work with your usual agent provider. [Iterate voice setup](https://github.com/iterate/packages/blob/main/packages/voice/README.md)

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

   The target should name `IterateMobile` and `apps/iterate-ios/backend.ts`. Launch the phone app, approve **Connect**, and open an existing agent. To exercise the mobile facet, tap the tray icon to open **Your move**: a list, even an empty one, means the facet answered. For a full round trip, run the **Ask Iterate** shortcut and wait for its reply. You can check a signed build’s association at `https://<your-apex>/.well-known/apple-app-site-association`. Its application ID should match the signed app’s entitlements. For an older Apple app ID whose prefix differs from its team ID, set the configurator’s `--app-id-prefix` to the prefix in that entitlement.

## Member data

The mobile facet scopes runs, notes, attachments and device registrations to the actor in the authenticated member session. Requests and replies use stable UUIDs so delivery can resume after a disconnect. **Remember** saves the member’s original note. **Ask** retrieves relevant notes and **Briefing** can include recent work. When the mind’s AI enrichment is unavailable, the memory store can still match note text locally.

## Your move: approvals and signatures

**Your move** lists what your mind is holding for a member's decision: outgoing email, agent actions and statements to sign. The template has no source of these of its own, so the list starts empty. To fill it, pass a reader when `backend.ts` creates the service.

```ts
#service = createMobileService(this.ctx.storage, { approvalInbox });
```

`approvalInbox(itx, signatures)` returns `{ items, decided }`. Each item is `{ id, kind, title, recipients, heldAt, reviewURL }`. `kind` is `"email"`, `"action"` or `"signature"`, and `heldAt` is an ISO 8601 time. `signatures` is true when the phone can show signature requests, so leave them out otherwise. `decided` lists what was settled lately, as the same fields without `reviewURL` plus `outcome` (`"approved"` or `"rejected"`) and `decidedAt`. A phone that had a request open uses it to say how the request ended.

The app opens an item only if its `reviewURL` is your mind's own page for it: `https://<control-host>/secrets/approvals?digest=<64 lowercase hex characters>` for a held act, or `https://<control-host>/statements/sign?draft=<id>` for a statement. The member signs each decision, with a passkey or with a key kept on the iPhone, and the facet's approvals route is read-only.

A statement opens natively, with the passkey prompt shown by iOS, only when the Apple association file on your control host names the signed app under `webcredentials`. The platform serves that file once your mind's deploy lists the app ID (`apple.appIds` in its stack config, as `<team-id>.<bundle-id>`). Until then a statement opens on the platform's signing page.

## The lock screen activity

While something waits for a member, a Live Activity names the first three things in one line each and counts the rest. It leaves when nothing waits, and one the member swipes away stays away until something changes. The mind starts, updates and ends it over Apple’s push service (`attention.js`), so it stays true while the app is closed. The phone registers the token that starts it (`attentionStartToken` on `PUT /devices/<id>`) and the token of the activity it shows (`PUT /attention/activity`), and reads the same content from `GET /attention` on the member’s session.

Those lines pass through Apple and show on a locked phone, as an alert’s words do. Each is cut to 90 characters. The whole request is read in the app.

Out of the box the activity counts the questions an agent asked the member, what your `approvalInbox` lists, and, where the platform has `itx.approvals.waiting()`, the proposed rules and the requests a secret holds. `updateIterateMobile` calls the facet’s `attention` when the platform’s gate records something or a request’s day runs out. To count more, such as todos flagged urgent, pass your own reader and say when its answer may have changed.

```ts
#service = createMobileService(this.ctx.storage, { approvalInbox, attention });
// where your own counts change:
await itx.iterateMobile.attention();
```

`attention(itx)` returns `{ approvals, signatures, urgent, since, until, items, urgentTodos, todoList? }`. The three counts are numbers. `since` is when the oldest thing started to wait and `until` when the first of them can no longer be decided, both in milliseconds, or 0. `items` lists what waits in the order the phone should name it, each `{ kind, text }` with `kind` set to `"urgent"`, `"approval"` or `"signature"`. `urgentTodos` lists each urgent todo as `{ id, text, project }` for Your move, and `todoList` is the HTTPS page that lists them. Each send leaves a line on `/apps/iterate-ios/pushes` with how it went, and no token or member.

## Phone actions

While the app is open on the screen it lends the iPhone to the mind as `itx.<person>.iphone`, where the person is the start of the member’s address in lower-case letters and digits: `ada.lovelace@example.com` lends `itx.adalovelace.iphone`. The lend ends when the app leaves the screen or the phone loses its network. This needs nothing from the mobile facet.

```ts
const phone = itx.adalovelace.iphone;
const { contacts } = await phone.contacts.find({ name: "Grace Hopper" });
const { steps } = await phone.health.steps({ day: "2026-11-24" });
```

Every action takes one object and answers one object. `await phone.describe()` answers the list below from the phone itself, with its time zone and its clock. iOS asks the member once for each kind of access, the first time an agent needs it.

| Call | Input | Answer |
| --- | --- | --- |
| `contacts.find` | `{ name }` | `{ contacts: [{ name, organization?, phones, emails }] }`, 20 at most |
| `home.scenes` | `{}` | `{ scenes: [{ home, scene }] }` |
| `home.run` | `{ scene, home? }` | `{ ran: { home, scene } }` |
| `music.search` | `{ term, in? }`: `"library"` (the default) or `"catalog"` for Apple Music | `{ songs: [{ id, title, artist, album? }] }` |
| `music.play` | `{ term, in?, id? }` | `{ playing: { id, title, artist, album? } }` |
| `music.pause` | `{}` | `{ paused: true }` |
| `health.steps` | `{ day? }`: a day like `2026-11-24` on the phone’s clock, today when absent | `{ day, steps }` |

Calendar and Reminders are Shortcuts actions alone. No agent reaches them through the phone.

## Apple push setup

The app registers for one alert: something started to wait for the member. `updateIterateMobile` sends it when the platform records a held email or agent action, once to each registered phone. The alert is titled by its kind and says what is asked in one line: who a mail goes to and its subject, or the action’s name. For requests of your own, call `await itx.iterateMobile.waiting({ key, kind, text })` with `kind` set to `"confirm"`, `"signature"` or `"urgent"`, a `key` that names the request once, and `text` as one line of what is asked. Without `text` the alert names the kind alone.

The app also keeps one Live Activity, on the Lock Screen and in the Dynamic Island, that counts what needs the member: requests to approve, statements to sign, questions an agent asked them, and todos flagged urgent ([what it counts](#the-lock-screen-activity)). The steps below install the key that the alert and the activity need.

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
