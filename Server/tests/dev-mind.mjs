// A local stand-in for a mind, for timing the native client and driving it in the simulator.
//
//   node Server/tests/dev-mind.mjs [--port 8787] [--rtt 80] [--mbps 8] [--cold 600] [--legacy]
//
// It speaks the mind's Cap'n Web socket, serves this checkout's MobileService and delays frames as
// a phone network would: --rtt is the round trip in ms, --mbps the downlink, --cold the wait for a
// context that has not been read lately. --legacy answers like a mind without the transcript route.
// A Debug build of the app uses it when launched with ITERATE_DEV_MIND=http://127.0.0.1:8787.
// The socket library is the Iterate SDK's own: run `npm ci --ignore-scripts` in Server/apns first.
import http from "node:http";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { createHash, randomUUID } from "node:crypto";
import { MobileService } from "../mind/mobile.js";

const sdk = createRequire(new URL("../apns/package.json", import.meta.url));
const { WebSocketServer } = sdk("ws");
const { RpcSession, RpcTarget } = sdk("capnweb");

const flag = (name, fallback) => {
  const index = process.argv.indexOf("--" + name);
  return index < 0 ? fallback : Number(process.argv[index + 1]);
};
const port = flag("port", 8787);
const net = { rtt: flag("rtt", 80), mbps: flag("mbps", 8), cold: flag("cold", 600), legacy: process.argv.includes("--legacy"), offline: false };
// Server-side time per call, from timings taken inside a real mind.
const cost = { whoami: 5, list: 30, read: 25, perEvent: 0.3, subscribe: 20, facet: 10, approvals: 120, voice: 700, accept: 150, reply: 1200 };

// The app only trusts a socket that names the workspace it was built for, so answer with the
// build's own settings: Deployment.xcconfig, then the Local.xcconfig that the setup script writes.
const settings = {};
for (const name of ["Deployment.xcconfig", "Local.xcconfig"]) {
  let text = "";
  try { text = readFileSync(new URL("../../Configuration/" + name, import.meta.url), "utf8"); } catch {}
  for (const [, key, value] of text.matchAll(/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/gm)) settings[key] = value;
}
const setting = (key) => (settings[key] ?? "").replace(/\$\((\w+)\)/g, (_, name) => setting(name)).toLowerCase();
const MIND_ID = setting("ITERATE_MIND_ID");
const MIND_HOST = setting("ITERATE_CONTROL_HOST");
const EMAIL = "dev@example.test";
const E = "events.iterate.com/agent/";
const V = "events.iterate.com/voice-agent/";
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

// --- A mind's worth of agents, the same on every start ------------------------------------------

function random(seed) {
  let state = seed >>> 0;
  return () => ((state = (Math.imul(state, 1664525) + 1013904223) >>> 0) / 2 ** 32);
}
const WORDS = "the calendar agenda review approve outgoing mail release worker feed estimate breakdown meeting notes travel reading briefing follow decision context summary update schedule draft".split(" ");
function prose(next, bytes) {
  let text = "";
  while (text.length < bytes) text += WORDS[Math.floor(next() * WORDS.length)] + (next() < 0.08 ? ".\n\n" : " ");
  return text.slice(0, bytes);
}
function replyText(next, turn) {
  return "**Update " + turn + "** — " + prose(next, 120 + Math.floor(next() * 500)) + "\n\n1. " + prose(next, 90) +
    "\n2. See [the agenda](https://example.test/agenda) and `feed-reader`.\n\n" + prose(next, Math.floor(next() * 1400));
}

const logs = new Map(); // path -> { events, head, subscribers:Set, warmUntil, waking }
function logOf(path) {
  if (!logs.has(path)) logs.set(path, { events: [], head: 0, subscribers: new Set(), warmUntil: 0, waking: null, sent: new Map() });
  return logs.get(path);
}
function store(path, type, payload, extra = {}) {
  const log = logOf(path);
  const event = { path, offset: (log.head += 1), type, payload, createdAt: new Date().toISOString(), ...extra };
  log.events.push(event);
  return event;
}
const member = { source: { onBehalfOf: { principal: { email: EMAIL, actor: "user:dev" } } } };

function turn(path, next, number) {
  const log = logOf(path);
  const gap = () => { log.head += next() < 0.55 ? 1 : next() < 0.5 ? 0 : 2; }; // ephemerals take offsets
  const said = store(path, E + "message-received", { message: "Question " + number + ": " + prose(next, 60 + Math.floor(next() * 120)), from: "/" },
    { idempotencyKey: "agent-message:seed-" + number, ...member });
  gap();
  store(path, E + "context-added", { role: "user", content: said.payload.message, messageOffset: said.offset });
  for (let step = 0; step < 6; step++) {
    gap();
    store(path, E + "llm-request-completed", { model: "gpt", input: prose(next, 1200 + Math.floor(next() * 2600)),
      output: [{ type: "text", text: prose(next, 800 + Math.floor(next() * 1800)) }], usage: { in: 4000, out: 600 } });
    if (step < 5) { gap(); store(path, E + "tool-called", { name: "run", input: prose(next, 400 + Math.floor(next() * 1500)), result: prose(next, 600 + Math.floor(next() * 2000)) }); }
  }
  gap();
  store(path, E + "context-added", { role: "assistant", content: prose(next, 2000 + Math.floor(next() * 5000)) });
  gap();
  store(path, E + "context-added", { role: "developer", content: prose(next, 2000 + Math.floor(next() * 6000)) });
  gap();
  store(path, E + "web-message-sent", { message: replyText(next, number), llmRequestOffset: log.head - 3 });
  gap();
}
function work(path, next, steps) {
  for (let step = 0; step < steps; step++) {
    logOf(path).head += 1;
    store(path, E + "tool-called", { name: "run", input: prose(next, 900), result: prose(next, 1800) });
  }
}

const TITLES = ["Daily briefing", "Calendar", "Reading notes", "Travel plans", "Release watch", "Mail triage",
  "Hosting costs", "Meeting notes", "Research: heat pumps", "School schedule", "Gift ideas", "Voice memos", "Weekly review",
  "House projects", "Golf bookings", "Family calendar", "Invoices", "Recipe box", "Running plan", "Book club", "Car service",
  "Garden", "Photo sorting", "Tax papers"];
const TURNS = [60, 40, 12, 24, 30, 8, 18, 5, 14, 22, 9, 6];
const catalog = [];
function seed() {
  logs.clear();
  catalog.length = 0;
  const started = Date.now();
  TITLES.forEach((title, index) => {
    const path = index % 3 === 2 ? "/agents/people/dev/web/" + randomSeeded(index) : "/agents/" + title.toLowerCase().replace(/[^a-z0-9]+/g, "-");
    const next = random(index + 1);
    const turns = TURNS[index % TURNS.length];
    for (let number = 1; number <= turns; number++) turn(path, next, number);
    if (index === 3) work(path, next, 170); // a long stretch of work with nothing said
    catalog.push({ path, title, createdAt: new Date(started - 30 * 864e5).toISOString(),
      lastActivityAt: new Date(started - index * 37 * 60e3).toISOString() });
  });
}
function randomSeeded(index) {
  const hex = createHash("sha256").update("agent-" + index).digest("hex");
  return [hex.slice(0, 8), hex.slice(8, 12), "4" + hex.slice(13, 16), "8" + hex.slice(17, 20), hex.slice(20, 32)].join("-");
}
seed();

// --- A context: its log, its subscriptions, and the wait for one that has gone cold -----------------

async function wake(path) {
  const log = logOf(path);
  const now = Date.now();
  if (log.warmUntil < now) {
    log.waking ??= sleep(net.cold).then(() => { log.waking = null; });
    await log.waking;
  }
  log.warmUntil = Date.now() + 60_000;
}
async function read(path, after = 0, limit = 100) {
  await wake(path);
  const log = logOf(path);
  const rows = [];
  let bytes = 0, more = false;
  for (const event of log.events) {
    if (event.offset <= after) continue;
    if (rows.length >= limit || bytes > 4 * 1024 * 1024) { more = true; break; }
    rows.push(event);
    bytes += JSON.stringify(event).length;
  }
  await sleep(cost.read + rows.length * cost.perEvent);
  return { events: rows, scannedThroughOffset: more ? rows.at(-1).offset : log.head, atHead: !more };
}
function publish(path, event) {
  for (const subscriber of logOf(path).subscribers) subscriber.deliver([event]);
}
function append(path, type, payload, extra) {
  const event = store(path, type, payload, extra);
  publish(path, event);
  return event;
}
function message(path, text, key) {
  const log = logOf(path);
  if (!log.sent.has(key)) {
    const event = append(path, E + "message-received", { message: text, from: "/" }, { idempotencyKey: "agent-message:" + key, ...member });
    log.sent.set(key, event);
    setTimeout(() => append(path, E + "web-message-sent", { message: "Understood: " + text.slice(0, 80) }), cost.reply);
    const row = catalog.find((agent) => agent.path === path);
    if (row) row.lastActivityAt = new Date().toISOString();
  }
  return log.sent.get(key);
}

class Subscription extends RpcTarget {
  constructor(path, options, session) {
    super();
    this.path = path;
    this.consumes = options.consumes ? new Set(options.consumes) : null;
    this.target = options.target.dup();
    this.session = session;
    logOf(path).subscribers.add(this);
    session.subscriptions.add(this);
    if (Number.isSafeInteger(options.afterOffset)) {
      const missed = logOf(path).events.filter((event) => event.offset > options.afterOffset);
      setImmediate(() => this.deliver(missed));
    }
  }
  deliver(events) {
    const batch = this.consumes ? events.filter((event) => this.consumes.has(event.type)) : events;
    if (batch.length && this.target) Promise.resolve(this.target(batch, {})).catch(() => {});
  }
  close() {
    logOf(this.path).subscribers.delete(this);
    this.session.subscriptions.delete(this);
    this.target?.[Symbol.dispose]?.();
    this.target = null;
  }
  [Symbol.dispose]() { this.close(); }
}

class Context extends RpcTarget {
  constructor(path, session) { super(); this.path = path; this.session = session; }
  async readEvents(after, limit) {
    this.session.stats.calls.push("readEvents");
    return read(this.path, after, limit);
  }
  async subscribe(options) {
    this.session.stats.calls.push("subscribe");
    await wake(this.path);
    await sleep(cost.subscribe);
    return new Subscription(this.path, options, this.session);
  }
  async append(event) {
    this.session.stats.calls.push("append");
    await wake(this.path);
    const stored = event.ephemeral ? { ...event, path: this.path, offset: (logOf(this.path).head += 1) } : append(this.path, event.type, event.payload);
    if (event.type === V + "call-started") {
      setTimeout(() => publish(this.path, { type: V + "conversation-accepted", payload: { activation: event.payload.activation }, offset: (logOf(this.path).head += 1) }), cost.accept);
    }
    return stored;
  }
  async appendOffsets(...events) {
    const log = logOf(this.path);
    return events.map(() => (log.head += 1));
  }
}

// --- What a member's socket reaches -------------------------------------------------------------------

class AgentHandle extends RpcTarget {
  constructor(path, session) { super(); this.path = path; this.session = session; }
  async message(text, options) {
    this.session.stats.calls.push("message");
    await wake(this.path);
    await sleep(cost.read);
    return message(this.path, text, options?.key ?? randomUUID());
  }
}
class Agents extends RpcTarget {
  constructor(session) { super(); this.session = session; }
  async list() {
    this.session.stats.calls.push("agents.list");
    await sleep(cost.list);
    return catalog.map((row) => ({ ...row }));
  }
  get(path) { return new AgentHandle(path, this.session); }
  async create(path) {
    this.session.stats.calls.push("agents.create");
    await sleep(cost.read);
    logOf(path).warmUntil = Date.now() + 60_000;
    if (!catalog.some((row) => row.path === path)) {
      const now = new Date().toISOString();
      catalog.unshift({ path, title: null, createdAt: now, lastActivityAt: now });
    }
    return { path };
  }
}

const kv = new Map();
class Storage {
  values = new Map();
  queue = Promise.resolve();
  async get(key) { return structuredClone(this.values.get(key)); }
  async put(key, value) { this.values.set(key, structuredClone(value)); }
  async delete(key) { this.values.delete(key); }
  async list({ prefix = "", startAfter, limit = 1000 }) {
    return new Map([...this.values].filter(([key]) => key.startsWith(prefix) && (!startAfter || key > startAfter))
      .sort(([a], [b]) => a.localeCompare(b)).slice(0, limit).map(([key, value]) => [key, structuredClone(value)]));
  }
  transaction(fn) {
    const tx = this.queue.then(() => fn(this));
    this.queue = tx.catch(() => {});
    return tx;
  }
}
const origin = "http://127.0.0.1:" + port;
const digest = (text) => createHash("sha256").update(text).digest("hex");
// The inbox as a mind's reader answers it: what waits, oldest first, and what was decided lately.
// A statement to sign is listed only for a phone that asks for signatures.
const service = new MobileService(new Storage(), async () => "accepted", async (_itx, signatures) => {
  await sleep(cost.approvals);
  const ago = (minutes) => new Date(Date.now() - minutes * 60e3).toISOString();
  const items = [
    { id: 41, kind: "email", title: "Re: Friday schedule", recipients: ["ada@example.test"],
      heldAt: ago(18), reviewURL: origin + "/secrets/approvals?digest=" + digest("one") },
    { id: 42, kind: "action", title: "Release the feed reader", recipients: [],
      heldAt: ago(4), reviewURL: origin + "/secrets/approvals?digest=" + digest("two") },
  ];
  if (signatures) items.push({ id: 43, kind: "signature", title: "Confirm the new page", recipients: [],
    heldAt: ago(1), reviewURL: origin + "/statements/sign?draft=" + digest("three").slice(0, 22) });
  const decided = [{ id: 40, kind: "email", title: "Re: Thursday", recipients: ["ada@example.test"],
    heldAt: ago(60), outcome: "approved", decidedAt: ago(50) }];
  return { items, decided };
});
const serviceItx = {
  cd: (path) => path === "/agents"
    ? { facets: { get: () => ({ snapshot: async () => ({ state: { agents: Object.fromEntries(catalog.map((row) => [row.path, {}])), deleted: {} } }) }) } }
    : { readEvents: (after, limit) => read(path, after, limit) },
  kv: {
    list: async (prefix) => ({ keys: [...kv.keys()].filter((key) => key.startsWith(prefix)) }),
    put: async (key, value) => { kv.set(key, value); return { ok: true }; },
    delete: async (key) => { kv.delete(key); return { ok: true }; },
  },
  agents: { create: async (path) => { logOf(path); }, get: (path) => ({ message: async (input, { key }) => message(path, input.message ?? String(input), key) }) },
  schedules: { set: async () => {}, cancel: async () => {} },
  ai: { run: async () => { throw new Error("Workers AI is offline"); } },
};
class Mobile extends RpcTarget {
  constructor(session) { super(); this.session = session; }
  async request(command) {
    this.session.stats.calls.push("request " + command?.method + " " + String(command?.path).split("?")[0]);
    await sleep(cost.facet);
    if (net.legacy && command?.path === "/agents/transcript") return { status: 404, body: { error: "Unknown Iterate action." } };
    return service.request(serviceItx, { member: true, principal: { actor: "user:dev", email: EMAIL } }, command);
  }
  async openAgentVoice(input) {
    this.session.stats.calls.push("openAgentVoice");
    await sleep(cost.voice);
    return { agentPath: input.agentPath, path: "/voice/ios-chat-" + digest(input.agentPath + input.client).slice(0, 40) };
  }
}
class Voice extends RpcTarget {
  constructor(session) { super(); this.session = session; }
  async ensureVoiceDevice(input) {
    this.session.stats.calls.push("ensureVoiceDevice");
    await sleep(cost.voice);
    return { path: "/voice/" + input.client, agentPath: "/agents/voice/" + input.client };
  }
}
class Mind extends RpcTarget {
  constructor(session) { super(); this.session = session; }
  async whoami() {
    this.session.stats.calls.push("whoami");
    await sleep(cost.whoami);
    return { mindId: MIND_ID, mindSlug: MIND_HOST, path: "/", principal: { email: EMAIL, actor: "user:dev" } };
  }
  get agents() { return new Agents(this.session); }
  get iterateMobile() { return new Mobile(this.session); }
  get voice() { return new Voice(this.session); }
  cd(path) { return new Context(path, this.session); }
}
class Root extends RpcTarget {
  constructor(session) { super(); this.session = session; }
  get mind() { return new Mind(this.session); }
}
class Api extends RpcTarget {
  constructor(session) { super(); this.session = session; }
  authenticate() { return new Root(this.session); }
}

// --- The network between the phone and the mind ---------------------------------------------------------

class Lane {
  tail = Promise.resolve();
  last = 0;
  push(due, run) {
    const at = (this.last = Math.max(due, this.last));
    this.tail = this.tail.then(() => sleep(Math.max(0, at - Date.now()))).then(run, run);
  }
}
class PhoneLink {
  inbox = [];
  waiting = [];
  error = null;
  free = 0;
  constructor(session) {
    const socket = (this.socket = session.socket);
    this.session = session;
    this.up = new Lane();
    this.down = new Lane();
    socket.on("message", (data) => {
      const text = data.toString();
      session.stats.framesIn += 1;
      this.up.push(Date.now() + net.rtt / 2, () => {
        const waiter = this.waiting.shift();
        if (waiter) waiter.resolve(text);
        else this.inbox.push(text);
      });
    });
    const end = (error) => {
      this.error = error;
      for (const waiter of this.waiting.splice(0)) waiter.reject(error);
    };
    socket.on("close", () => end(new Error("The phone closed the socket.")));
    socket.on("error", end);
  }
  receive() {
    if (this.inbox.length) return Promise.resolve(this.inbox.shift());
    if (this.error) return Promise.reject(this.error);
    return new Promise((resolve, reject) => this.waiting.push({ resolve, reject }));
  }
  send(text) {
    const bytes = Buffer.byteLength(text);
    this.session.stats.framesOut += 1;
    this.session.stats.bytesOut += bytes;
    const start = Math.max(Date.now(), this.free);
    this.free = start + (net.mbps > 0 ? (bytes * 8) / (net.mbps * 1000) : 0);
    this.down.push(this.free + net.rtt / 2, () => { if (this.socket.readyState === 1) this.socket.send(text); });
  }
  abort() { setTimeout(() => this.socket.close(), net.rtt); }
}

// --- HTTP: sign-in for the app's Connect button, and the test's controls -----------------------------------

const sessions = new Set();
let totals = { sockets: 0, framesIn: 0, framesOut: 0, bytesOut: 0, calls: [] };
function body(request) {
  return new Promise((resolve) => {
    let text = "";
    request.on("data", (chunk) => (text += chunk));
    request.on("end", () => resolve(text));
  });
}
const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, origin);
  const json = (status, value) => {
    response.writeHead(status, { "content-type": "application/json" });
    response.end(JSON.stringify(value));
  };
  const text = request.method === "POST" ? await body(request) : "";
  switch (url.pathname) {
    case "/oauth2/register": return json(201, { client_id: "dev-" + randomUUID() });
    case "/oauth2/device_authorization":
      return json(200, { device_code: randomUUID(), user_code: "DEVM-INDX", verification_uri: origin + "/oauth2/device", expires_in: 300, interval: 1 });
    case "/oauth2/token":
      return json(200, new URLSearchParams(text).has("token") ? {} :
        { token_type: "bearer", access_token: "dev-" + randomUUID(), refresh_token: "dev-refresh", expires_in: 86400, scope: "iterate" });
    case "/oauth2/device":
    case "/secrets/approvals":
    case "/statements/sign":
      response.writeHead(200, { "content-type": "text/html" });
      return response.end("<meta name=viewport content='width=device-width'><body style='font:17px system-ui;padding:2em'>Local dev mind. Nothing to approve here.");
    case "/dev/config": {
      if (text) Object.assign(net, JSON.parse(text));
      if (net.offline) for (const session of sessions) session.socket.terminate();
      return json(200, net);
    }
    case "/dev/reset": // every context cold, counters at zero, the seeded logs back
      seed();
      kv.clear();
      totals = { sockets: 0, framesIn: 0, framesOut: 0, bytesOut: 0, calls: [] };
      for (const session of sessions) session.stats = { framesIn: 0, framesOut: 0, bytesOut: 0, calls: [] };
      return json(200, { ok: true });
    case "/dev/cool":
      for (const log of logs.values()) log.warmUntil = 0;
      return json(200, { ok: true });
    case "/dev/say": {
      const { path, text: words } = JSON.parse(text);
      return json(200, append(path, E + "web-message-sent", { message: words }));
    }
    case "/dev/drop":
      for (const session of sessions) session.socket.terminate();
      return json(200, { ok: true });
    case "/dev/stats": {
      const live = [...sessions].reduce((sum, session) => ({
        framesIn: sum.framesIn + session.stats.framesIn, framesOut: sum.framesOut + session.stats.framesOut,
        bytesOut: sum.bytesOut + session.stats.bytesOut, calls: sum.calls.concat(session.stats.calls),
      }), { framesIn: totals.framesIn, framesOut: totals.framesOut, bytesOut: totals.bytesOut, calls: totals.calls });
      return json(200, { ...live, sockets: totals.sockets, open: sessions.size, agents: catalog.map((row) => row.path) });
    }
    default: return json(404, { error: "not_found" });
  }
});
const sockets = new WebSocketServer({ noServer: true });
server.on("upgrade", (request, socket, head) => {
  if (net.offline) return socket.destroy();
  if (new URL(request.url, origin).pathname !== "/api" || !/^Bearer \S+/.test(request.headers.authorization ?? "")) {
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    return socket.destroy();
  }
  sockets.handleUpgrade(request, socket, head, (accepted) => {
    const session = { socket: accepted, subscriptions: new Set(), stats: { framesIn: 0, framesOut: 0, bytesOut: 0, calls: [] } };
    sessions.add(session);
    totals.sockets += 1;
    new RpcSession(new PhoneLink(session), new Api(session));
    accepted.on("close", () => {
      for (const subscription of [...session.subscriptions]) subscription.close();
      sessions.delete(session);
      totals.framesIn += session.stats.framesIn;
      totals.framesOut += session.stats.framesOut;
      totals.bytesOut += session.stats.bytesOut;
      totals.calls = totals.calls.concat(session.stats.calls);
    });
  });
});
server.listen(port, "127.0.0.1", () => {
  console.log("dev mind on " + origin + " rtt=" + net.rtt + "ms mbps=" + net.mbps + " cold=" + net.cold + "ms" + (net.legacy ? " legacy" : ""));
});
