import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { cp, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { installIterateMobile, mobileLink, updateIterateMobile } from "../mind/integration.js";
import { agentPath, hash, MOBILE_RULE, MOBILE_TARGET, TICK } from "../mind/mobile.js";
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
