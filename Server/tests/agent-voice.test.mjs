import test from "node:test";
import assert from "node:assert/strict";
import { openAgentVoice } from "../mind/agent-voice.js";
import { agentPath as taskPath, hash } from "../mind/mobile.js";

const member = { member: true, principal: { actor: "member-a", email: "Jo+Phone@example.test" } };
const draftId = "12345678-aaaa-4bbb-9ccc-111111111111";
const agentPath = "/agents/people/jo-phone/web/" + draftId;
const client = "ios-a00000000000";
const facet = { className: "VoiceAgentDurableObject" };

function fixture() {
  const created = new Set();
  const rows = new Map();
  const root = {
    agents: {
      create: async path => created.add(path),
      get: path => ({ recent: async () => {
        if (!created.has(path)) throw Error("Missing agent");
        return { path };
      } }),
    },
    cd: path => ({ append: async (...events) => {
      if (!rows.has(path)) rows.set(path, new Map());
      for (const event of events) rows.get(path).set(event.idempotencyKey, event);
    } }),
  };
  return { created, rows, root };
}

test("a call provisions the typed draft's agent and reopens the same isolated relay", async () => {
  const { created, rows, root } = fixture();
  const opened = await openAgentVoice(root, member, { agentPath, client, draftId }, facet);
  assert.deepEqual([...created], [agentPath]);
  assert.match(opened.path, /^\/voice\/ios-chat-[0-9a-f]{40}$/);
  const again = await openAgentVoice(root, member, { agentPath, client }, facet);
  assert.deepEqual(again, opened);
  const events = [...rows.get(opened.path).values()];
  assert.equal(events.find(e => e.type.endsWith("device-provisioned")).payload.agentPath, agentPath);
  for (const name of ["chat-user", "chat-agent"]) {
    assert.equal(events.find(e => e.payload.name === name).payload.target.path, agentPath);
  }
  assert.deepEqual(events.find(e => e.payload.name === "voice-agent").payload.target[2], ["get", "voice-agent", facet]);
  assert.equal([...rows.get(agentPath).values()][0].payload.target.path, opened.path);
  const otherPhone = await openAgentVoice(root, member, { agentPath, client: "ios-b00000000000" }, facet);
  const otherMember = await openAgentVoice(root, { ...member, principal: { actor: "member-b" } }, { agentPath, client }, facet);
  assert.equal(new Set([opened.path, otherPhone.path, otherMember.path]).size, 3);
});

test("voice refuses guests, missing agents and mismatched draft identities before attaching routes", async () => {
  const { created, rows, root } = fixture();
  await assert.rejects(openAgentVoice(root, {}, { agentPath, client, draftId }, facet), /Sign in/);
  await assert.rejects(openAgentVoice(root, member, { agentPath, client }, facet), /Missing agent/);
  await assert.rejects(openAgentVoice(root, member, { agentPath: "/agents/other", client, draftId }, facet), /different chat/);
  assert.equal(created.size, 0);
  assert.equal(rows.size, 0);
});

test("a private mobile task can attach voice only for its authenticated owner", async () => {
  const { created, rows, root } = fixture();
  const ownTask = taskPath(await hash(member.principal.actor), draftId);
  created.add(ownTask);
  const other = { ...member, principal: { actor: "member-b" } };
  await assert.rejects(openAgentVoice(root, other, { agentPath: ownTask, client }, facet), /unavailable/);
  assert.equal(rows.size, 0);
  const opened = await openAgentVoice(root, member, { agentPath: ownTask, client }, facet);
  assert.equal(opened.agentPath, ownTask);
});
