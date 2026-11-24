import {
  MobileService, agentPath, hash, partsOfAgent, trackedEvents, MOBILE_RULE, MOBILE_TARGET, TICK,
} from "./mobile.js";
import { sendPush } from "./push.js";
import { ATTENTION_TICK } from "./attention.js";
import { deployment } from "./settings.js";

export { openAgentVoice } from "./agent-voice.js";
export { partsOfAgent };

// Approvals and Your move list what a mind holds for a member's decision, and what was decided
// lately. A mind that holds mail, agent actions or statements passes its reader as `approvalInbox`.
// It is called with the mind's root and whether the phone also reads signature requests. Without
// one both lists are empty.
//
// The Live Activity on the lock screen says what needs a member now. `attention(itx)` answers
// that for everything every member shares, in the shape of `NOTHING` in attention.js. Without one
// it is read from `approvalInbox` and the platform's gate. A mind with more that can need a
// member, such as urgent todos, passes a reader that counts those too. The questions an agent
// asked a member are always counted, by the service itself.
export function createMobileService(storage, { approvalInbox = async () => ({ items: [], decided: [] }), attention } = {}) {
  return new MobileService(storage, sendPush, approvalInbox, attention ?? (itx => heldAttention(itx, approvalInbox)));
}

const DAY = 24 * 60 * 60 * 1000;

// A held act or a statement in one line, as the lock screen says it: who a mail goes to and its
// subject, the verb of any other call.
function waitingLine(item) {
  if (item.kind === "email") return (item.recipients?.length ? "Email to " + item.recipients.join(", ") : "Email") + ": " + item.title;
  return /^itx\.[^\s]+$/.test(item.title) ? "Agent action: " + item.title : item.title;
}

// What is held for a member's decision, as counts and one line for each thing, the longest wait
// first. The lines are what the phone's list already titles them, so they pass through Apple and
// show on a locked phone. Where the platform says what waits with no text (`itx.approvals.waiting`),
// the proposed rules and the requests a secret holds are counted and named too.
async function heldAttention(itx, approvalInbox) {
  // A platform from before the call throws, in the call or in its answer.
  const platform = async () => { try { return await itx.approvals.waiting(); } catch { return undefined; } };
  const [waiting, inbox] = await Promise.all([platform(), approvalInbox(itx, true)]);
  const listed = inbox.items.map(item => {
    const at = Date.parse(item.heldAt);
    return { kind: item.kind === "signature" ? "signature" : "approval", text: waitingLine(item), at, until: at + DAY };
  });
  const elsewhere = [
    ...(waiting?.requests ?? []).map(row => ({ kind: "approval", text: "Request with " + row.secret + ": " + row.summary, at: row.at, until: row.until })),
    ...(waiting?.rules ?? []).map(row => ({ kind: "signature", text: "New rule for " + (row.verb ?? "requests with " + row.secret), at: row.at, until: 0 })),
  ];
  const waits = [...listed, ...elsewhere].filter(row => Number.isFinite(row.at)).sort((a, b) => a.at - b.at);
  const ends = waits.map(row => row.until).filter(until => until > 0);
  return {
    approvals: waits.filter(row => row.kind === "approval").length,
    signatures: waits.filter(row => row.kind === "signature").length,
    urgent: 0,
    since: waits.length ? waits[0].at : 0,
    until: ends.length ? Math.min(...ends) : 0,
    items: waits.map(({ kind, text }) => ({ kind, text })).slice(0, 12),
    urgentTodos: [],
  };
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

// What starts to wait for a member, as the phone's alert says it: an act the gate holds, by the
// platform's own record. `text` is one line of what is asked, as Your move titles it. A mind with
// requests of its own calls `itx.iterateMobile.waiting` for them.
function waitingNote(event) {
  const p = event.payload;
  if (event.ephemeral || event.source?.copiedFrom || !p) return;
  if (event.path === "/approvals" && event.type === "events.iterate.com/approval/act-held" && event.source?.platform === true) {
    if (typeof p.digest !== "string" || !/^[a-f0-9]{64}$/.test(p.digest) || typeof p.act !== "string") return;
    const kind = p.act === "email.send" ? "email" : p.act.startsWith("itx.") ? "action" : undefined;
    // The gate's own line for a mail: "Mail to <recipients>: <subject>".
    const mail = kind === "email" && typeof p.summary === "string" ? /^Mail to (.+?): ([^\r\n]*)$/u.exec(p.summary) : null;
    const text = mail ? "To " + mail[1] + ": " + mail[2] : kind === "action" ? p.act : undefined;
    return kind && { key: p.digest, kind, ...(text && { text }) };
  }
}

// Whether `event` may change what needs a member: a decision or a proposal at the gate, or the
// day of a request running out. A question's opening and closing is the service's own (mobile.js
// `settle`). A mind whose own reader counts more calls `itx.iterateMobile.attention` when that changes.
function changesAttention(event) {
  if (event.ephemeral || event.source?.copiedFrom) return false;
  if (event.path === "/approvals") return event.source?.platform === true && event.type.startsWith("events.iterate.com/approval/");
  return event.type === ATTENTION_TICK && event.path === "/" && Boolean(event.source?.schedule);
}

export async function updateIterateMobile(itx, event) {
  const note = waitingNote(event);
  if (note) await itx.iterateMobile.waiting(note);
  if (changesAttention(event)) await itx.iterateMobile.attention();
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
