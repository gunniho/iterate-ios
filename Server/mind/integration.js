import {
  MobileService, agentPath, hash, partsOfAgent, trackedEvents, MOBILE_RULE, MOBILE_TARGET, TICK,
} from "./mobile.js";
import { sendPush } from "./push.js";
import { deployment } from "./settings.js";

export { openAgentVoice } from "./agent-voice.js";
export { partsOfAgent };

export function createMobileService(storage) {
  return new MobileService(storage, sendPush);
}

export async function installIterateMobile(itx) {
  if ((await itx.rewriteRules.get(MOBILE_RULE))?.target === MOBILE_TARGET) return;
  await itx.append({
    type: "events.iterate.com/itx/rewrite-rule-configured",
    payload: {
      match: MOBILE_RULE,
      target: MOBILE_TARGET,
      description: "Member-authenticated iOS tasks, replies, voice sessions and Apple push registrations.",
    },
  });
}

export async function updateIterateMobile(itx, event) {
  if (partsOfAgent(event.path) && trackedEvents.has(event.type))
    await itx.iterateMobile.reconcile(event.path);
  if (event.type === TICK && event.path === "/" && event.source?.schedule) {
    const { owner, runID, actionID } = event.payload;
    await itx.iterateMobile.tick(owner, runID, actionID);
  }
}

const nativePaths = ["/runs", "/inbox", "/new-agent", "/talk", "/camera", "/capture", "/briefing"];
const associations = new Set(["/.well-known/apple-app-site-association", "/apple-app-site-association"]);
const runRoute = /^\/(?:runs|read)\/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\/?$/i;

export async function mobileLink(request, host) {
  const url = new URL(request.url);
  if (url.origin !== "https://" + deployment.apexHost || !["GET", "HEAD"].includes(request.method))
    return null;

  if (associations.has(url.pathname)) {
    const prefix = deployment.appIDPrefix || deployment.teamID;
    if (!prefix) return null;
    const appID = prefix + "." + deployment.bundleID;
    const association = {
      activitycontinuation: { apps: [appID] },
      applinks: { details: [{
        appIDs: [appID],
        components: ["/runs/*", "/read/*", ...nativePaths].map(path => ({ "/": path })),
      }] },
    };
    return new Response(request.method === "HEAD" ? null : JSON.stringify(association), {
      headers: { "content-type": "application/json", "cache-control": "public,max-age=3600" },
    });
  }

  const match = runRoute.exec(url.pathname);
  if (!match && !nativePaths.includes(url.pathname)) return null;
  const denied = host.auth.require(request);
  if (denied) return denied;
  const actor = host.auth.principal(request)?.actor;
  if (!actor) return new Response(null, { status: 401 });
  const path = match ? "/agents" + agentPath(await hash(actor), match[1].toLowerCase()) : "/";
  return new Response(null, {
    status: 302,
    headers: { location: "https://" + deployment.dashHost + path, "cache-control": "no-store" },
  });
}
