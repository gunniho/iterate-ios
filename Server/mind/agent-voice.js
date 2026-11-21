import { hash, partsOfAgent, principalOf } from "./mobile.js";

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const voice = "events.iterate.com/voice-agent/";
const agent = "events.iterate.com/agent/";
const itxEvent = "events.iterate.com/itx/";

function subscription(name, consumes, target) {
  return {
    type: itxEvent + "subscription-configured",
    idempotencyKey: "iterate-ios/chat-voice/v1/" + name,
    payload: { name, consumes, target },
  };
}

function transcript(path, speaker) {
  const user = speaker === "user";
  const label = user ? "Caller" : "Voice agent";
  const actor = user ? "member" : "voice-agent";
  return subscription("chat-" + speaker, [voice + (user ? "utterance-transcribed" : "answer-transcribed")], {
    path, type: agent + "context-added",
    payload: `{"role":"user","actor":{"type":"user"},"content":"[call] ${label} said: " & payload.text,"callNote":{"kind":"said","who":{"actor":"${actor}"},"text":payload.text},"llmRequestPolicy":{"behaviour":"dont-trigger-request"}}`,
  });
}

// The package's PCM relay delegates to the agent named by device-provisioned. Each phone
// gets its own relay for this chat, so calls on other phones cannot supersede its activation.
export async function openAgentVoice(itx, stamp, input, facet) {
  const actor = principalOf(stamp);
  const { agentPath, client, draftId } = input ?? {};
  if (typeof client !== "string" || !/^ios-[a-f0-9]{12}$/.test(client) ||
      typeof agentPath !== "string" || !agentPath.startsWith("/agents/") || agentPath.length > 800 ||
      agentPath.slice(1).split("/").some(p => !p || p === "." || p === "..")) {
    throw new Error("Invalid chat or iPhone installation.");
  }
  const task = partsOfAgent(agentPath);
  if (task && task[0] !== await hash(actor)) throw new Error("Agent unavailable.");
  if (draftId !== undefined) {
    const person = (stamp.principal.email ?? "").split("@")[0].toLowerCase()
      .replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40).replace(/-$/, "");
    const parent = person ? "/agents/people/" + person + "/web/" : "/agents/web/";
    if (typeof draftId !== "string" || !uuid.test(draftId) || agentPath !== parent + draftId)
      throw new Error("The draft belongs to a different chat.");
    await itx.agents.create(agentPath);
  } else {
    const existing = await itx.agents.get(agentPath).recent({ minutes: 1, limit: 1 });
    if (existing.path !== agentPath) throw new Error("Agent unavailable.");
  }
  const key = (await hash(JSON.stringify([actor, client, agentPath]))).slice(0, 40);
  const name = "ios-chat-" + key;
  const path = "/voice/" + name;
  await Promise.all([
    itx.cd(agentPath).append(subscription(name, ["summary-updated", "web-message-sent", "paused"].map(n => agent + n),
      { path, payload: "payload" })),
    itx.cd(path).append(
      { type: itxEvent + "rewrite-rule-configured", idempotencyKey: "iterate-ios/chat-voice/v1/parent",
        payload: { match: "itx", target: 'itx.cd("/")' } },
      subscription("voice-agent", ["*", voice + "mic-frame", voice + "keepalive"],
        ["itx", "facets", ["get", "voice-agent", facet], "processEventBatch"]),
      subscription("chat-warm-up", [voice + "call-started"], { path: agentPath, type: agent + "warm-up-requested" }),
      transcript(agentPath, "user"), transcript(agentPath, "agent"),
      { type: voice + "device-provisioned", idempotencyKey: "iterate-ios/chat-voice/v1/agent",
        payload: { agentPath } },
    ),
  ]);
  return { path, agentPath };
}
