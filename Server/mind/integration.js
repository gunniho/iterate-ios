import {
  MobileService, agentPath, hash, partsOfAgent, trackedEvents, MOBILE_RULE, MOBILE_TARGET, TICK,
} from "./mobile.js";
import { sendPush } from "./push.js";
import { deployment } from "./settings.js";

export { openAgentVoice } from "./agent-voice.js";
export { partsOfAgent };

// Approvals and Your move list what a mind holds for a member's decision, and what was decided
// lately. A mind that holds mail, agent actions or statements passes its reader as `approvalInbox`.
// It is called with the mind's root and whether the phone also reads signature requests. Without
// one both lists are empty.
export function createMobileService(storage, { approvalInbox = async () => ({ items: [], decided: [] }) } = {}) {
  return new MobileService(storage, sendPush, approvalInbox);
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

// What starts to wait for a member, as the phone's alert names it: an act the gate holds, by the
// platform's own record. A mind with requests of its own calls `itx.iterateMobile.waiting` for them.
function waitingNote(event) {
  const p = event.payload;
  if (event.ephemeral || event.source?.copiedFrom || !p) return;
  if (event.path === "/approvals" && event.type === "events.iterate.com/approval/act-held" && event.source?.platform === true) {
    if (typeof p.digest !== "string" || !/^[a-f0-9]{64}$/.test(p.digest) || typeof p.act !== "string") return;
    const kind = p.act === "email.send" ? "email" : p.act.startsWith("itx.") ? "action" : undefined;
    return kind && { key: p.digest, kind };
  }
}

export async function updateIterateMobile(itx, event) {
  const note = waitingNote(event);
  if (note) await itx.iterateMobile.waiting(note);
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
