import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { cp, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { createMobileService, installIterateMobile, mobileLink, updateIterateMobile } from "../mind/integration.js";
import { agentPath, hash, MOBILE_RULE, MOBILE_TARGET, TICK } from "../mind/mobile.js";
import { ATTENTION_TICK } from "../mind/attention.js";
import { deployment } from "../mind/settings.js";

test("only mobile-agent and scheduled reconciliation events reach the installed facet", async () => {
  let rule, written = 0;
  const reconciled = [], ticks = [];
  const itx = {
    rewriteRules: { get: async match => match === MOBILE_RULE ? rule : undefined },
    append: async event => {
      assert.equal(event.type, "events.iterate.com/itx/rewrite-rule-configured");
      rule = event.payload;
      written++;
    },
    iterateMobile: {
      reconcile: async path => reconciled.push(path),
      tick: async (...args) => ticks.push(args),
    },
  };
  await installIterateMobile(itx);
  await installIterateMobile(itx);
  assert.equal(written, 1);
  assert.equal(rule.match, "itx.iterateMobile");
  assert.equal(rule.target, MOBILE_TARGET);
  assert.match(rule.target, /mainModule:'apps\/iterate-ios\/backend\.ts'/);
  const work = { owner: await hash("member-a"), runID: randomUUID(), actionID: randomUUID() };
  const path = agentPath(work.owner, work.runID);
  const reply = { path, type: "events.iterate.com/agent/web-message-sent" };
  await updateIterateMobile(itx, reply);
  await updateIterateMobile(itx, { ...reply, path: "/agents/shared" });
  await updateIterateMobile(itx, { ...reply, type: "events.iterate.com/agent/configured" });
  assert.deepEqual(reconciled, [path]);
  const tick = { path: "/", type: TICK, payload: work, source: { schedule: "mobile" } };
  await updateIterateMobile(itx, { ...tick, source: {} });
  await updateIterateMobile(itx, { ...tick, path });
  await updateIterateMobile(itx, tick);
  assert.deepEqual(ticks, [[work.owner, work.runID, work.actionID]]);
});

test("a copied backend serves only its configured apex and uses its own Dash and Apple topic", async t => {
  const dir = await mkdtemp(join(tmpdir(), "iterate-ios-mind-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(new URL("../mind/", import.meta.url), dir, { recursive: true });
  await writeFile(join(dir, "package.json"), JSON.stringify({ type: "module" }));
  const settings = {
    apexHost: "workspace.example.test",
    controlHost: "auth.example.test",
    dashHost: "console.example.test",
    bundleID: "test.example.workspace",
    teamID: "TESTTEAM01",
    appIDPrefix: "TESTAPP001",
  };
  await writeFile(join(dir, "settings.js"), "export const deployment = " + JSON.stringify(settings) + ";\n");
  const base = pathToFileURL(dir + "/");
  const { mobileLink: link } = await import(new URL("integration.js", base));
  const { sendPush } = await import(new URL("push.js", base));
  const { TICK: tick } = await import(new URL("mobile.js", base));
  assert.equal(tick, "events." + settings.apexHost + "/ios/reconcile");
  const request = path => new Request("https://" + settings.apexHost + path);
  const authenticated = { auth: {
    require: () => null,
    principal: () => ({ actor: "member-a" }),
  } };
  const runID = randomUUID();
  const run = request("/runs/" + runID.toUpperCase());
  const task = await link(run, authenticated);
  assert.equal(task.status, 302);
  assert.equal(task.headers.get("cache-control"), "no-store");
  assert.equal(task.headers.get("location"), "https://" + settings.dashHost + "/agents" + agentPath(await hash("member-a"), runID));
  const second = await link(run, { auth: { ...authenticated.auth, principal: () => ({ actor: "member-b" }) } });
  assert.notEqual(second.headers.get("location"), task.headers.get("location"));
  const signIn = new Response(null, { status: 401 });
  const guest = { auth: { require: () => signIn } };
  assert.equal(await link(run, guest), signIn);
  assert.equal((await link(run, { auth: { require: () => null, principal: () => null } })).status, 401);
  assert.equal(await link(new Request("https://" + settings.dashHost + "/talk"), authenticated), null);
  assert.equal(await link(new Request(run, { method: "POST" }), authenticated), null);
  assert.equal(await link(request("/unrelated"), authenticated), null);
  const associationPath = "/.well-known/apple-app-site-association";
  const aasa = request(associationPath);
  const response = await link(aasa);
  const association = await response.json();
  const applicationID = settings.appIDPrefix + "." + settings.bundleID;
  assert.deepEqual(association.activitycontinuation.apps, [applicationID]);
  assert.deepEqual(association.applinks.details[0].appIDs, [applicationID]);
  assert.ok(association.applinks.details[0].components.some(rule => rule["/"] === "/new-agent"));
  assert.equal(await (await link(new Request(aasa, { method: "HEAD" }))).text(), "");
  if (!deployment.appIDPrefix && !deployment.teamID) {
    assert.equal(await mobileLink(new Request("https://" + deployment.apexHost + associationPath)), null);
  }
  let topic;
  await sendPush({
    secrets: { describe: async () => ({ set: true }) },
    fetch: async req => {
      topic = req.headers.get("apns-topic");
      return new Response(null, { status: 200 });
    },
  }, {
    token: "ab".repeat(32), type: "alert", environment: "sandbox", collapseId: runID, payload: { aps: {} },
  });
  assert.equal(topic, settings.bundleID);
});

test("a held act alerts the phone from the platform's own record, and a mind supplies its inbox", async () => {
  const waited = [];
  let looked = 0;
  const itx = { iterateMobile: { waiting: async note => waited.push(note), attention: async () => { looked++; }, reconcile: async () => {}, tick: async () => {} } };
  const digest = "ab".repeat(32);
  const held = { path: "/approvals", type: "events.iterate.com/approval/act-held", source: { platform: true },
    payload: { digest, act: "email.send" } };
  await updateIterateMobile(itx, held);
  await updateIterateMobile(itx, { ...held, payload: { digest, act: "itx.calendar.send" } });
  // Anything but the gate's own record of a known act alerts nobody.
  await updateIterateMobile(itx, { ...held, source: {} });
  await updateIterateMobile(itx, { ...held, source: { platform: true, copiedFrom: "/elsewhere" } });
  await updateIterateMobile(itx, { ...held, ephemeral: true });
  await updateIterateMobile(itx, { ...held, path: "/agents/a" });
  await updateIterateMobile(itx, { ...held, type: "events.iterate.com/approval/act-approved" });
  await updateIterateMobile(itx, { ...held, payload: { digest, act: "other.verb" } });
  await updateIterateMobile(itx, { ...held, payload: { digest: "short", act: "email.send" } });
  assert.deepEqual(waited, [{ key: digest, kind: "email" }, { key: digest, kind: "action", text: "itx.calendar.send" }]);
  // With the gate's own line for a mail, the alert says who it goes to and its subject.
  await updateIterateMobile(itx, { ...held, payload: { digest, act: "email.send", summary: "Mail to ada@example.org: Friday" } });
  assert.deepEqual(waited.at(-1), { key: digest, kind: "email", text: "To ada@example.org: Friday" });
  // Every record of the gate may change what needs a member, as does a request's day running out.
  assert.equal(looked, 6);
  await updateIterateMobile(itx, { path: "/", type: ATTENTION_TICK, payload: {}, source: { schedule: "attention" } });
  await updateIterateMobile(itx, { path: "/", type: ATTENTION_TICK, payload: {}, source: {} });
  assert.equal(looked, 7);

  const member = { member: true, principal: { actor: "member-a" } };
  const read = { method: "GET", path: "/approvals?signatures=1" };
  assert.deepEqual(await createMobileService({}).request({}, member, read), { status: 200, body: { items: [], decided: [] } });
  const asked = [];
  const item = { id: 7, kind: "signature", title: "Sign", recipients: [], heldAt: "2026-01-01T00:00:00.000Z", reviewURL: "https://iterate.example.org/statements/sign?draft=abcdefgh" };
  const supplied = createMobileService({}, { approvalInbox: async (root, signatures) => {
    asked.push(signatures);
    return { items: signatures ? [item] : [], decided: [] };
  } });
  assert.deepEqual((await supplied.request({}, member, read)).body.items, [item]);
  assert.deepEqual((await supplied.request({}, member, { method: "GET", path: "/approvals" })).body.items, []);
  assert.deepEqual(asked, [true, false]);
  assert.equal((await supplied.request({}, member, { method: "POST", path: "/approvals" })).status, 405);
});

test("the lock screen counts what the inbox and the gate hold, or what a mind's own reader says", async () => {
  const storage = { get: async () => undefined, put: async () => {}, list: async () => new Map(), transaction: async run => run(storage) };
  const member = { member: true, principal: { actor: "member-a" } };
  const read = { method: "GET", path: "/attention" };
  const heldAt = "2026-01-01T00:00:00.000Z", at = Date.parse(heldAt);
  const inbox = async () => ({ decided: [], items: [
    { id: 2, kind: "signature", title: "Publish the notes", recipients: [], heldAt: "2026-01-02T00:00:00.000Z", reviewURL: "https://iterate.example.org/sign" },
    { id: 1, kind: "email", title: "Friday", recipients: ["ada@example.org"], heldAt, reviewURL: "https://iterate.example.org/review" },
  ] });
  // A platform from before `approvals.waiting` throws: the inbox alone is counted.
  const older = await createMobileService(storage, { approvalInbox: inbox }).request({}, member, read);
  assert.deepEqual(older.body, { approvals: 1, signatures: 1, questions: 0, urgent: 0, since: at / 1000,
    items: [{ kind: "approval", text: "Email to ada@example.org: Friday" }, { kind: "signature", text: "Publish the notes" }],
    until: at + 24 * 60 * 60 * 1000, urgentTodos: [] });
  const gate = { approvals: { waiting: async () => ({ acts: [], rules: [{ at: at - 1000, verb: "email.send" }],
    requests: [{ at: at + 1000, until: at + 5000, summary: "GET /orders", secret: "shop" }] }) } };
  const newer = await createMobileService(storage, { approvalInbox: inbox }).request(gate, member, read);
  assert.deepEqual(newer.body.items.map(item => item.text), ["New rule for email.send", "Email to ada@example.org: Friday", "Request with shop: GET /orders"]);
  assert.deepEqual([newer.body.approvals, newer.body.signatures, newer.body.until], [2, 2, at + 5000]);
  assert.equal((await createMobileService(storage).request({}, member, read)).body.approvals, 0);
  const own = { approvals: 0, signatures: 0, urgent: 1, since: at, until: 0, items: [{ kind: "urgent", text: "Renew the certificate" }],
    urgentTodos: [{ id: 4, text: "Renew the certificate", project: "Ops" }] };
  const supplied = await createMobileService(storage, { approvalInbox: inbox, attention: async () => own }).request({}, member, read);
  assert.deepEqual([supplied.body.urgent, supplied.body.approvals, supplied.body.urgentTodos], [1, 0, own.urgentTodos]);
});
