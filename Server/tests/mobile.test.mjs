import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import {
  MobileService,
  agentTranscript,
  hash,
  partsOfAgent,
} from "../mind/mobile.js";
import {
  ACTIVITY_LIFETIME,
  ATTENTION_SCHEDULE,
  ATTENTION_TICK,
  START_GRACE,
  attentionAlert,
  attentionLine,
  attentionPush,
  attentionState,
  attentionStep,
} from "../mind/attention.js";

import { appTopic } from "../mind/push.js";

class Store {
  values = new Map();
  queue = Promise.resolve();
  async get(k) {
    return structuredClone(this.values.get(k));
  }
  async put(k, v) {
    this.values.set(k, structuredClone(v));
  }
  async delete(k) {
    this.values.delete(k);
  }
  async list({ prefix = "", startAfter, limit = 1000 }) {
    return new Map(
      [...this.values]
        .filter(
          ([k]) => k.startsWith(prefix) && (!startAfter || k > startAfter),
        )
        .sort(([a], [b]) => a.localeCompare(b))
        .slice(0, limit)
        .map(([k, v]) => [k, structuredClone(v)]),
    );
  }
  transaction(fn) {
    const tx = this.queue.then(async () => {
      const prior = structuredClone(this.values);
      try {
        return await fn(this);
      } catch (e) {
        this.values = prior;
        throw e;
      }
    });
    this.queue = tx.catch(() => {});
    return tx;
  }
}
function fixture(readApprovalInbox, readAttention) {
  const storage = new Store(),
    logs = new Map(),
    messages = new Map(),
    timers = new Map(),
    pushes = [];
  let failures = 0;
  let apple = () => "accepted";
  const events = (path) => {
    if (!logs.has(path)) logs.set(path, []);
    return logs.get(path);
  };
  function append(path, type, payload) {
    const log = events(path);
    const seq = log.length + 1;
    const e = {
      path,
      offset: seq,
      type: "events.iterate.com/agent/" + type,
      payload,
      createdAt: new Date(Date.UTC(2026, 10, 20, 9, 0, seq)).toISOString(),
    };
    log.push(e);
    return e;
  }
  const itx = {
    ai: {
      run: async () => {
        throw new Error("Workers AI is offline");
      },
    },
    schedules: {
      set: async (item) => timers.set(item.key, item),
      cancel: async (key) => timers.delete(key),
    },
    agents: {
      create: async (path) => {
        events(path);
      },
      get: (path) => ({
        message: async (input, { key }) => {
          const k = path + ":" + key;
          if (!messages.has(k)) {
            const event = append(path, "message-received", {
              message: input.message,
            });
            messages.set(k, { input, event });
          }
          if (failures > 0) {
            failures--;
            throw Error("transport failed after accept");
          }
          return messages.get(k).event;
        },
      }),
    },
    cd: (path) => ({
      readEvents: async (after, limit) => {
        const log = events(path);
        const rows = log.slice(after, after + limit);
        const scanned = rows.at(-1)?.offset || after;
        return {
          events: rows,
          scannedThroughOffset: scanned,
          atHead: scanned === log.length,
        };
      },
    }),
  };
  const service = new MobileService(storage, async (_itx, j) => {
    pushes.push(j);
    return apple(j);
  }, readApprovalInbox, readAttention);
  const call = (actor, method, path, body) =>
    service.request(
      itx,
      actor ? { member: true, principal: { actor } } : undefined,
      { method, path, body },
    );
  return {
    storage,
    service,
    itx,
    timers,
    logs,
    messages,
    pushes,
    append,
    call,
    fail: () => {
      failures++;
    },
    // What Apple answers each push from now on: "accepted", "invalid", "retry" or "disabled".
    appleAnswers: (answer) => {
      apple = answer;
    },
  };
}
const testToken = "5b".repeat(32);
test("Your Move includes old open questions only for their owner and returns a private count-only summary", async () => {
  const approval = { id: 12, subject: "Shared mail", to: ["reader@example.org"], reviewURL: "https://example.org/review" };
  const heldAt = "2026-11-20T09:01:00.000Z";
  const pending = [
    { id: 12, kind: "email", title: approval.subject, recipients: approval.to, heldAt, reviewURL: approval.reviewURL },
    { id: 13, kind: "action", title: "itx.calendar.send", recipients: [], heldAt, reviewURL: "https://example.org/review-action" },
  ];
  const decided = [{ id: 9, kind: "email", title: "Earlier mail", recipients: [], heldAt, outcome: "approved", decidedAt: heldAt }];
  const signing = { id: 1_000_000_004, title: "Create example.org/banana", reviewURL: "https://example.org/sign" };
  const toSign = { id: signing.id, kind: "signature", title: signing.title, recipients: [], heldAt, reviewURL: signing.reviewURL };
  let approvalReads = 0;
  // A phone names signature requests to get them: an older build cannot read their kind.
  const f = fixture(async (_itx, signatures) => { approvalReads++; return { items: signatures ? [...pending, toSign] : pending, decided }; });
  const actor = "member-one";
  const owner = await hash(actor);
  const first = randomUUID();
  await f.call(actor, "POST", "/runs", { id: first, kind: "ask", prompt: "Plan a visit" });
  const path = "/agents/iterate-ios/" + owner + "/" + first;
  f.append(path, "web-message-sent", { message: "[[ITERATE_NEEDS_INPUT]]\nWhich day?", llmRequestOffset: 3 });
  await f.service.sync(f.itx, owner, first);
  const current = await f.storage.get("run:" + owner + ":" + first);
  for (let i = 0; i < 66; i++) {
    const id = randomUUID();
    await f.storage.put("run:" + owner + ":" + id, { id, status: i % 2 ? "completed" : "running", response: "A question?" });
  }
  const old = { id: randomUUID(), title: "Older question", updatedAt: "2020-01-01T09:00:00.000Z" };
  await f.storage.put("run:" + owner + ":" + old.id, { ...old, status: "needsInput", response: "Still available?" });
  const empty = randomUUID();
  await f.storage.put("run:" + owner + ":" + empty, { id: empty, status: "needsInput", response: "" });
  const route = "/your-move";
  const summary = route + "/summary";
  const list = f.storage.list.bind(f.storage);
  let interruptedCursor;
  f.storage.list = options => {
    if (options.prefix === "run:" + owner + ":" && options.startAfter) {
      interruptedCursor = options.startAfter;
      throw Error("temporarily offline");
    }
    return list(options);
  };
  await assert.rejects(() => f.call(actor, "GET", summary), /temporarily offline/);
  assert.ok(interruptedCursor);
  assert.equal(await f.storage.get("question-index-v1:" + owner), interruptedCursor);
  f.storage.list = list;
  assert.deepEqual(await f.call(actor, "GET", route), { status: 200, body: { approvals: [approval], signatures: [signing], questions: [
    { id: first, title: "Plan a visit", question: "Which day?", responseLength: 10, updatedAt: current.updatedAt },
    { ...old, question: "Still available?", responseLength: 16 },
  ] } });
  const originalGet = f.storage.get.bind(f.storage);
  const originalList = f.storage.list.bind(f.storage);
  f.storage.get = async key => {
    assert.ok(!key.startsWith("run:"), "widget refresh should only read the pending index");
    return originalGet(key);
  };
  f.storage.list = options => {
    assert.ok(!options.prefix.startsWith("run:"), "older runs have already been indexed");
    return originalList(options);
  };
  assert.deepEqual(await f.call(actor, "GET", summary), { status: 200, body: { approvalCount: 3, questionCount: 2 } });
  f.storage.get = originalGet;
  f.storage.list = originalList;
  assert.deepEqual((await f.call("member-two", "GET", route, { actor })).body, { approvals: [approval], signatures: [signing], questions: [] });
  assert.deepEqual(await f.call(actor, "GET", "/approvals"), { status: 200, body: { items: pending, decided } });
  assert.deepEqual(await f.call(actor, "GET", "/approvals?signatures=1"), { status: 200, body: { items: [...pending, toSign], decided } });
  const readsBeforeDenied = approvalReads;
  for (const path of [route, summary, "/approvals"]) {
    assert.equal((await f.call(undefined, "GET", path)).status, 401);
    assert.equal((await f.service.request(f.itx, { member: false, principal: { actor } }, { method: "GET", path })).status, 401);
    assert.equal((await f.call(actor, "POST", path)).status, 405);
  }
  assert.equal((await f.call(actor, "POST", "/approvals/12")).status, 404);
  assert.equal(approvalReads, readsBeforeDenied);
  assert.equal((await f.call(actor, "GET", route + "/bogus")).status, 404);
  assert.equal((await f.call(actor, "POST", "/runs/" + first + "/reply", {
    id: randomUUID(), text: "Tuesday", expectedUpdatedAt: current.updatedAt,
  })).status, 200);
  assert.deepEqual((await f.call(actor, "GET", summary)).body, { approvalCount: 3, questionCount: 1 });
  const longQuestion = "a".repeat(767) + "🌍" + "b".repeat(23_000);
  f.append(path, "web-message-sent", { message: "[[ITERATE_NEEDS_INPUT]]\n" + longQuestion, llmRequestOffset: 9 });
  await f.service.sync(f.itx, owner, first);
  const latest = (await f.call(actor, "GET", route)).body.questions[0];
  assert.equal(latest.question, "a".repeat(767));
  assert.equal(latest.responseLength, longQuestion.length);
  assert.notEqual(latest.updatedAt, current.updatedAt);
  f.append(path, "paused", {});
  await f.service.sync(f.itx, owner, first);
  assert.deepEqual((await f.call(actor, "GET", summary)).body, { approvalCount: 3, questionCount: 1 });
});

test("APNs registrations use the enrolled app's topic and leave previous topics dormant", async () => {
  const f = fixture(),
    member = "member with prior app",
    device = randomUUID(),
    run = randomUUID();
  const key = "device:" + (await hash(member)) + ":" + device;
  await f.storage.put(key, {
    generation: randomUUID(),
    environment: "sandbox",
    notificationToken: testToken,
    pushToStartToken: "ae".repeat(32),
  });
  await f.call(member, "POST", "/runs", {
    id: run,
    kind: "ask",
    prompt: "Fixture",
    deviceId: device,
    startActivityRemotely: true,
  });
  await f.call(member, "GET", "/runs/" + run);
  assert.equal(f.pushes.length, 0);
  assert.equal(
    (
      await f.call(member, "PUT", "/devices/" + device, {
        bundleID: appTopic + ".old",
        environment: "sandbox",
        notificationToken: testToken,
      })
    ).status,
    400,
  );
  const token = "ab".repeat(32);
  assert.equal(
    (
      await f.call(member, "PUT", "/devices/" + device, {
        bundleID: appTopic,
        environment: "sandbox",
        notificationToken: token,
      })
    ).status,
    200,
  );
  const current = await f.storage.get(key);
  assert.equal(current.bundleID, appTopic);
  assert.equal(current.pushToStartToken, undefined);
  f.append([...f.logs.keys()][0], "web-message-sent", {
    message: "New app result",
    llmRequestOffset: 5,
  });
  await f.call(member, "GET", "/runs/" + run);
  assert.deepEqual(
    f.pushes.map((job) => job.token),
    [token],
  );
});
test("Remember saves the member's words for relevant asks and their own briefings", async () => {
  const f = fixture();
  const owner = "one";
  const other = "two";
  const memory = randomUUID();
  const note = "My favorite fruit is peach.";
  const acknowledgement = "Saved. Apricots might also be worth trying.";
  const question = "What is my favorite fruit?";
  await f.call(owner, "POST", "/runs", {
    id: memory,
    kind: "remember",
    prompt: note,
  });
  const saved = await f.call(owner, "GET", "/memories");
  assert.equal(saved.status, 200);
  assert.deepEqual(saved.body.items.map(({ id, text }) => ({ id, text })), [
    { id: memory, text: note },
  ]);

  f.append([...f.logs.keys()][0], "web-message-sent", {
    message: acknowledgement,
    llmRequestOffset: 3,
  });
  const completed = await f.call(owner, "GET", "/runs/" + memory);
  assert.equal(completed.body.response, acknowledgement);

  await f.call(owner, "POST", "/runs", {
    id: randomUUID(),
    kind: "ask",
    prompt: question,
  });
  const ask = [...f.messages.values()].at(-1).input.message;
  assert.ok(ask.includes(question));
  assert.ok(ask.includes(note));
  assert.doesNotMatch(ask, /apricots/i);

  await f.call(owner, "POST", "/runs", {
    id: randomUUID(),
    kind: "ask",
    prompt: "When does the library open?",
  });
  assert.doesNotMatch(
    [...f.messages.values()].at(-1).input.message,
    /peach|apricots/i,
  );

  await f.call(owner, "POST", "/runs", {
    id: randomUUID(),
    kind: "briefing",
    prompt: "Prepare my briefing.",
  });
  const briefing = [...f.messages.values()].at(-1).input.message;
  assert.ok(briefing.includes(note));
  assert.ok(briefing.includes(question));
  assert.doesNotMatch(briefing, /apricots/i);

  assert.deepEqual((await f.call(other, "GET", "/memories")).body.items, []);
  await f.call(other, "POST", "/runs", {
    id: randomUUID(),
    kind: "briefing",
    prompt: "Prepare my briefing.",
  });
  assert.doesNotMatch(
    [...f.messages.values()].at(-1).input.message,
    /peach|apricots|favorite fruit|library/i,
  );
});
test("requests need a stamped member, scope by actor, and bind immutable UUIDs to content", async () => {
  const f = fixture(),
    id = randomUUID(),
    owner = "test member",
    other = "another member";
  assert.equal((await f.call(null, "GET", "/runs")).status, 401);
  assert.equal(
    (
      await f.service.request(
        f.itx,
        { member: false, principal: { actor: owner } },
        { method: "GET", path: "/runs" },
      )
    ).status,
    401,
  );
  const body = {
    id,
    kind: "remember",
    prompt: "Save this fixture",
    attachments: [
      { name: "sample.txt", contentType: "text/plain", dataBase64: "SGVsbG8=" },
    ],
  };
  f.fail();
  assert.equal(
    (await f.call(owner, "POST", "/runs", body)).body.status,
    "queued",
  );
  assert.equal(
    (await f.call(owner, "POST", "/runs", body)).body.status,
    "running",
  );
  assert.equal(f.messages.size, 1);
  assert.equal(
    Buffer.from([...f.messages.values()][0].input.files[0].data).toString(),
    "Hello",
  );
  const changed = await f.call(owner, "POST", "/runs", {
    ...body,
    prompt: "Different task",
  });
  assert.equal(changed.status, 409);
  assert.equal((await f.call(other, "GET", "/runs/" + id)).status, 404);
  assert.equal((await f.call(other, "GET", "/runs")).body.runs.length, 0);
  assert.equal((await f.call(owner, "GET", "/runs")).body.runs.length, 1);
});
test("a queued request survives retry through its durable clock with no duplicate agent message", async () => {
  const f = fixture(),
    owner = "phone",
    id = randomUUID(),
    h = await hash(owner);
  f.fail();
  const result = await f.call(owner, "POST", "/runs", {
    id,
    kind: "ask",
    prompt: "Check a sample",
  });
  assert.equal(result.body.status, "queued");
  await f.service.tick(f.itx, h, id, id);
  assert.equal(f.messages.size, 1);
  assert.equal(
    (await f.call(owner, "GET", "/runs/" + id)).body.status,
    "running",
  );
  const path = [...f.logs.keys()][0];
  assert.deepEqual(partsOfAgent(path), [h, id]);
  f.append(path, "web-message-sent", {
    message: "Still working",
    besideScript: true,
    llmRequestOffset: 5,
  });
  assert.equal(
    (await f.call(owner, "GET", "/runs/" + id)).body.status,
    "running",
  );
  f.append(path, "web-message-sent", {
    message: "Finished answer",
    llmRequestOffset: 9,
  });
  await f.service.tick(f.itx, h, id, id);
  assert.equal(f.timers.size, 0);
  assert.equal(
    (await f.call(owner, "GET", "/runs/" + id)).body.response,
    "Finished answer",
  );
});
test("decision replies use their exact revision, replays are safe, and pushes never contain private task text", async () => {
  const f = fixture(),
    o = "member",
    id = randomUUID(),
    device = randomUUID();
  await f.call(o, "PUT", "/devices/" + device, {
    environment: "sandbox",
    notificationToken: testToken,
    pushToStartToken: "aa".repeat(32),
  });
  await f.call(o, "POST", "/runs", {
    id,
    kind: "ask",
    prompt: "Private prompt",
    context: "work",
    deviceId: device,
    startActivityRemotely: false,
  });
  const path = [...f.logs.keys()][0];
  await f.call(o, "PUT", "/runs/" + id + "/activity", {
    deviceId: device,
    token: "bc".repeat(32),
  });
  f.append(path, "web-message-sent", {
    message: "[[ITERATE_NEEDS_INPUT]]\nPrivate question",
    llmRequestOffset: 7,
  });
  const result = (await f.call(o, "GET", "/runs/" + id)).body;
  assert.equal(result.status, "needsInput");
  assert.equal(result.response, "Private question");
  const alert = f.pushes.find((j) => j.type === "alert");
  assert.equal(alert.environment, "sandbox");
  assert.equal(alert.payload.aps.category, "ITERATE_DECISION");
  assert.equal(alert.payload.aps["filter-criteria"], "work");
  assert.equal(alert.payload.updatedAt, result.updatedAt);
  assert.equal(alert.payload.runID, id);
  assert.ok(!JSON.stringify(f.pushes).includes("Private"));
  assert.ok(!f.pushes.some((p) => p.payload.aps.event === "start"));
  const action = randomUUID(),
    words = {
      id: action,
      text: "Approved",
      expectedUpdatedAt: result.updatedAt,
    };
  assert.equal(
    (
      await f.call(o, "POST", "/runs/" + id + "/reply", {
        ...words,
        expectedUpdatedAt: "2025-01-02T12:00:00Z",
      })
    ).status,
    409,
  );
  assert.equal(
    (await f.call(o, "POST", "/runs/" + id + "/reply", words)).status,
    200,
  );
  assert.equal(
    (await f.call(o, "POST", "/runs/" + id + "/reply", words)).status,
    200,
  );
  assert.equal(f.messages.size, 2);
  assert.equal(
    (
      await f.call(o, "POST", "/runs/" + id + "/reply", {
        ...words,
        id: randomUUID(),
      })
    ).status,
    409,
  );
  const count = f.pushes.length;
  await f.call(o, "DELETE", "/devices/" + device);
  f.append(path, "web-message-sent", {
    message: "Private result",
    llmRequestOffset: 12,
  });
  assert.equal(
    (await f.call(o, "GET", "/runs/" + id)).body.status,
    "completed",
  );
  assert.equal(f.pushes.length, count);
});
test("invalid routes and attachment payloads never create agent messages", async () => {
  const f = fixture();
  const put = (attachments) =>
    f.call("member", "POST", "/runs", {
      id: randomUUID(),
      kind: "ask",
      prompt: "Hello",
      attachments,
    });
  assert.equal(
    (
      await put([
        {
          name: "a.bin",
          contentType: "application/octet-stream",
          dataBase64: Buffer.alloc(2 * 1024 * 1024 + 1).toString("base64"),
        },
      ])
    ).status,
    413,
  );
  assert.equal(
    (
      await put([
        { name: "../a", contentType: "text/plain", dataBase64: "YQ==" },
      ])
    ).status,
    400,
  );
  assert.equal(
    (await f.call("member", "GET", "//other.example/runs")).status,
    400,
  );
  // A backslash reads as a slash in a web address, so this path names another host too.
  assert.equal(
    (await f.call("member", "GET", "/\\other.example/runs")).status,
    400,
  );
  assert.equal(f.messages.size, 0);
});
test("a background submission starts an activity on its own phone and possession transfers Apple tokens at account switch", async () => {
  const f = fixture(),
    id = randomUUID(),
    device = randomUUID(),
    o = "member A",
    second = "member B";
  const fields = {
    environment: "sandbox",
    notificationToken: testToken,
    pushToStartToken: "cd".repeat(32),
  };
  await f.call(o, "PUT", "/devices/" + device, fields);
  const body = {
    id,
    kind: "ask",
    prompt: "Fixture task",
    deviceId: device,
    startActivityRemotely: true,
  };
  await f.call(o, "POST", "/runs", body);
  await f.call(o, "GET", "/runs/" + id);
  assert.equal(
    f.pushes.filter((j) => j.payload.aps.event === "start").length,
    1,
  );
  assert.equal(
    (
      await f.call(o, "POST", "/runs", {
        ...body,
        startActivityRemotely: false,
      })
    ).status,
    200,
  );
  await f.call(second, "PUT", "/devices/" + device, fields);
  await f.call(o, "DELETE", "/devices/" + device);
  f.append([...f.logs.keys()][0], "web-message-sent", {
    message: "Member A response",
    llmRequestOffset: 3,
  });
  await f.call(o, "GET", "/runs/" + id);
  assert.ok(!f.pushes.some((j) => j.type === "alert"));
  const idB = randomUUID();
  await f.call(second, "POST", "/runs", {
    id: idB,
    kind: "ask",
    prompt: "Second fixture",
    startActivityRemotely: true,
    deviceId: device,
  });
  await f.call(second, "PUT", "/devices/" + device, {
    environment: "sandbox",
    pushToStartToken: null,
  });
  await f.call(second, "GET", "/runs/" + idB);
  assert.equal(
    f.pushes.filter((j) => j.payload.aps.event === "start").length,
    1,
  );
  f.append([...f.logs.keys()][1], "web-message-sent", {
    message: "Member B response",
    llmRequestOffset: 3,
  });
  await f.call(second, "GET", "/runs/" + idB);
  assert.equal(f.pushes.filter((j) => j.type === "alert").length, 1);
});
test("superseded unseen questions in one timestamp refuse stale approvals and resend their revision", async () => {
  const f = fixture(),
    o = "test",
    id = randomUUID();
  await f.call(o, "PUT", "/devices/" + randomUUID(), {
    environment: "sandbox",
    notificationToken: testToken,
  });
  await f.call(o, "POST", "/runs", { id, kind: "ask", prompt: "Fixture" });
  const path = [...f.logs.keys()][0];
  const one = f.append(path, "web-message-sent", {
    message: "[[ITERATE_NEEDS_INPUT]]\nFirst?",
    llmRequestOffset: 6,
  });
  const first = (await f.call(o, "GET", "/runs/" + id)).body;
  const two = f.append(path, "web-message-sent", {
    message: "[[ITERATE_NEEDS_INPUT]]\nSecond?",
    llmRequestOffset: 8,
  });
  two.createdAt = one.createdAt;
  const reply = {
    id: randomUUID(),
    text: "Approved",
    expectedUpdatedAt: first.updatedAt,
  };
  assert.equal(
    (await f.call(o, "POST", "/runs/" + id + "/reply", reply)).status,
    409,
  );
  const updated = (await f.call(o, "GET", "/runs/" + id)).body;
  assert.ok(Date.parse(updated.updatedAt) > Date.parse(first.updatedAt));
  const sent = f.pushes
    .filter((j) => j.type === "alert")
    .map((j) => j.payload.updatedAt);
  assert.deepEqual(sent, [first.updatedAt, updated.updatedAt]);
  reply.expectedUpdatedAt = updated.updatedAt.replace("Z", "000Z");
  assert.equal(
    (await f.call(o, "POST", "/runs/" + id + "/reply", reply)).status,
    200,
  );
  reply.expectedUpdatedAt = updated.updatedAt;
  assert.equal(
    (await f.call(o, "POST", "/runs/" + id + "/reply", reply)).status,
    200,
  );
});
test("a large private reply is available in scalar-safe pages and the list fits the phone transport", async () => {
  const f = fixture(),
    o = "test",
    id = randomUUID();
  await f.call(o, "POST", "/runs", { id, kind: "ask", prompt: "Fixture" });
  const answer = "x".repeat(99999) + "😃" + "y".repeat(22000);
  f.append([...f.logs.keys()][0], "web-message-sent", {
    message: answer,
    llmRequestOffset: 4,
  });
  const first = (await f.call(o, "GET", "/runs/" + id)).body;
  assert.equal(first.response.length, 99999);
  assert.equal(first.responseLength, answer.length);
  const url =
    "/runs/" +
    id +
    "/response?at=" +
    encodeURIComponent(first.updatedAt) +
    "&from=";
  assert.equal((await f.call(o, "GET", url + "100000")).status, 400);
  assert.equal(
    first.response +
      (await f.call(o, "GET", url + first.response.length)).body.text,
    answer,
  );
  const path = "/runs/" + id + "/response?at=2025-01-01&from=90000";
  assert.equal((await f.call(o, "GET", path)).status, 409);
  for (let i = 0; i < 20; i++) {
    const other = randomUUID();
    await f.call(o, "POST", "/runs", {
      id: other,
      kind: "ask",
      prompt: "🤔".repeat(7000),
    });
    f.append([...f.logs.keys()].at(-1), "web-message-sent", {
      message: "😃".repeat(14000),
      llmRequestOffset: 4,
    });
    await f.call(o, "GET", "/runs/" + other);
  }
  let cursor = null,
    seen = new Set(),
    pages = 0;
  do {
    const result = (
      await f.call(o, "GET", "/runs" + (cursor ? "?cursor=" + cursor : ""))
    ).body;
    assert.ok(Buffer.byteLength(JSON.stringify(result)) < 400 * 1024);
    result.runs.forEach((r) => seen.add(r.id));
    cursor = result.nextCursor;
    pages++;
  } while (cursor);
  assert.equal(seen.size, 21);
  assert.ok(pages > 1);
});

test("native archive shares Dash state, checks catalog entries and isolates members", async () => {
  const f = fixture();
  const keys = new Map();
  f.itx.kv = {
    list: async (prefix) => ({ keys: [...keys.keys()].filter(key => key.startsWith(prefix)) }),
    put: async (key, value) => keys.set(key, value),
    delete: async (key) => keys.delete(key),
  };
  const originalContext = f.itx.cd;
  const agent = "/agents/people/chat%23one";
  const dashArchived = "/agents/dash-archived";
  const ended = "/agents/ended";
  f.itx.cd = (path) => path !== "/agents" ? originalContext(path) : {
    facets: { get: (name) => {
      assert.equal(name, "agents");
      return { snapshot: async () => ({ state: {
        agents: { [agent]: {}, [dashArchived]: {} }, deleted: { [ended]: {} },
      } }) };
    } },
  };
  const actor = "member:one";
  const prefix = "iterate:dash:agent-archive:v1:" + encodeURIComponent(actor) + ":";
  const route = "/agents/archive";
  keys.set(prefix + dashArchived, "1");
  assert.equal((await f.call(undefined, "GET", route)).status, 401);
  assert.equal((await f.service.request(f.itx, { member: false, principal: { actor } },
    { method: "PUT", path: route, body: { path: agent, archived: true } })).status, 401);
  assert.deepEqual(await f.call(actor, "GET", route), { status: 200, body: { paths: [dashArchived] } });
  assert.equal((await f.call(actor, "PUT", route, { path: "/secrets", archived: true })).status, 400);
  assert.equal((await f.call(actor, "PUT", route, { path: "/agents/missing", archived: true })).status, 404);
  assert.equal((await f.call(actor, "PUT", route, { path: ended, archived: true })).status, 410);
  assert.equal((await f.call(actor, "POST", route, { path: agent, archived: true })).status, 405);
  for (let i = 0; i < 2; i++) {
    assert.deepEqual(await f.call(actor, "PUT", route, { path: agent, archived: true, actor: "other" }),
      { status: 200, body: { path: agent, archived: true } });
  }
  assert.equal(keys.get(prefix + agent), "1");
  assert.deepEqual((await f.call("other", "GET", route)).body.paths, []);
  assert.deepEqual((await f.call(actor, "GET", route)).body.paths, [dashArchived, agent]);
  const put = f.itx.kv.put;
  f.itx.kv.put = async () => { throw new Error("offline"); };
  assert.equal((await f.call(actor, "PUT", route, { path: dashArchived, archived: true })).status, 503);
  f.itx.kv.put = put;
  assert.equal((await f.call(actor, "PUT", route, { path: agent, archived: false })).status, 200);
  assert.deepEqual((await f.call(actor, "GET", route)).body.paths, [dashArchived]);
});

// A log as the platform serves it: offsets have gaps, a page holds a number of events, and a
// read from past the end answers the head.
function agentLog(events, { head = events.at(-1)?.offset ?? 0, pageCap = Infinity } = {}) {
  const reads = [];
  const context = {
    readEvents: async (after = 0, limit = 100) => {
      reads.push([after, limit]);
      const take = Math.min(limit, pageCap);
      const rows = events.filter((e) => e.offset > after).slice(0, take);
      const more = events.some((e) => e.offset > (rows.at(-1)?.offset ?? after));
      return { events: structuredClone(rows), scannedThroughOffset: more ? rows.at(-1).offset : head, atHead: !more };
    },
  };
  return { reads, itx: { cd: (path) => (path === "/agents/chat" ? context : agentLog([]).itx.cd("/agents/chat")) } };
}
const chat = (offset, kind, payload) => ({ offset, type: "events.iterate.com/agent/" + kind, payload });
function conversation(turns, step = 1) {
  const events = [];
  let offset = 0;
  for (let turn = 1; turn <= turns; turn++) {
    events.push(chat((offset += step), "message-received", { message: "question " + turn }));
    events.push(chat((offset += step), "context-added", { role: "user", content: "question " + turn, messageOffset: offset - step }));
    events.push(chat((offset += step), "llm-request-started", { input: "x".repeat(400) }));
    events.push(chat((offset += step), "context-added", { role: "assistant", content: "draft " + turn }));
    events.push(chat((offset += step), "context-added", { role: "developer", content: "tool result " + turn }));
    events.push(chat((offset += step), "web-message-sent", { message: "answer " + turn }));
  }
  return events;
}

test("transcript returns the newest words of a conversation and pages back without gaps", async () => {
  const events = conversation(40, 3);
  const log = agentLog(events, { head: events.at(-1).offset + 2 });
  const service = new MobileService(new Store(), async () => "accepted", async () => []);
  const call = (method, body, stamp = { member: true, principal: { actor: "member:one" } }) =>
    service.request(log.itx, stamp, { method, path: "/agents/transcript", body });

  assert.equal((await call("POST", { path: "/agents/chat" }, null)).status, 401);
  assert.equal((await call("POST", { path: "/agents/chat" }, { member: false, principal: { actor: "guest" } })).status, 401);
  assert.equal((await call("GET", { path: "/agents/chat" })).status, 405);
  for (const body of [{}, { path: "/secrets" }, { path: "/agents/" }, { path: "/agents/" + "a".repeat(300) },
    { path: "/agents/chat", limit: 0 }, { path: "/agents/chat", limit: 101 }, { path: "/agents/chat", limit: 1.5 },
    { path: "/agents/chat", through: -1 }, { path: "/agents/chat", through: "9" }]) {
    assert.equal((await call("POST", body)).status, 400, JSON.stringify(body));
  }

  const shown = events.filter((e) => e.type.endsWith("message-received") || e.type.endsWith("web-message-sent") ||
    (e.type.endsWith("context-added") && e.payload.role === "user"));
  const first = await call("POST", { path: "/agents/chat", limit: 30 });
  assert.equal(first.status, 200);
  assert.equal(first.body.head, events.at(-1).offset + 2);
  assert.deepEqual(first.body.events, shown.slice(-30));
  assert.equal(first.body.floor, shown.at(-30).offset - 1);

  // Each earlier page continues exactly where the last one stopped, down to the start of the log.
  const pages = [first.body];
  while (pages.at(-1).floor > 0) {
    const next = await call("POST", { path: "/agents/chat", through: pages.at(-1).floor, limit: 30 });
    assert.equal(next.status, 200);
    assert.ok(next.body.floor < pages.at(-1).floor);
    pages.push(next.body);
  }
  assert.deepEqual(pages.reverse().flatMap((page) => page.events), shown);
  assert.deepEqual(await agentTranscript(agentLog([]).itx, { path: "/agents/chat" }), { head: 0, floor: 0, events: [] });
  assert.deepEqual((await call("POST", { path: "/agents/other" })).body, { head: 0, floor: 0, events: [] });
});

test("transcript widens over quiet stretches, follows short pages and bounds its answer", async () => {
  // One exchange, then a long run of work with nothing said.
  const quiet = [chat(5, "message-received", { message: "start" }), chat(9, "web-message-sent", { message: "on it" })];
  for (let offset = 20; offset <= 3000; offset += 4) quiet.push(chat(offset, "tool-called", { input: "y".repeat(200) }));
  const paged = agentLog(quiet, { pageCap: 90 });
  const found = await agentTranscript(paged.itx, { path: "/agents/chat" });
  assert.deepEqual(found.events.map((e) => e.offset), [5, 9]);
  assert.equal(found.floor, 0);
  assert.equal(found.head, 3000);
  assert.ok(paged.reads.every(([, limit]) => limit <= 500));

  // A very long silence ends the scan with nothing found, and the next page resumes below it.
  const silent = [chat(1, "message-received", { message: "start" })];
  for (let offset = 10; offset <= 40000; offset += 2) silent.push(chat(offset, "tool-called", {}));
  const far = await agentTranscript(agentLog(silent).itx, { path: "/agents/chat" });
  assert.deepEqual(far.events, []);
  assert.ok(far.floor > 30000 && far.floor < 40000 - 3000);
  let page = far;
  while (page.floor > 0) page = await agentTranscript(agentLog(silent).itx, { path: "/agents/chat", through: page.floor });
  assert.deepEqual(page.events.map((e) => e.offset), [1]);

  // Long replies stop the page at the byte budget. The remainder stays reachable.
  const long = [];
  for (let offset = 1; offset <= 30; offset++) long.push(chat(offset, "web-message-sent", { message: "z".repeat(100 * 1024) }));
  const heavy = await agentTranscript(agentLog(long).itx, { path: "/agents/chat" });
  assert.ok(heavy.events.length >= 1 && heavy.events.length < 30);
  assert.ok(JSON.stringify(heavy.events).length < 1100 * 1024);
  assert.equal(heavy.floor, heavy.events[0].offset - 1);
  assert.equal(heavy.events.at(-1).offset, 30);
  const rest = await agentTranscript(agentLog(long).itx, { path: "/agents/chat", through: heavy.floor });
  assert.equal(rest.events.at(-1).offset, heavy.floor);
});

test("a request that starts to wait alerts each registered phone once, in the words it was handed", async () => {
  const f = fixture(async () => ({ items: [], decided: [] }));
  const device = randomUUID(), other = randomUUID();
  await f.call("member-one", "PUT", "/devices/" + device, { environment: "sandbox", bundleID: appTopic, notificationToken: testToken });
  await f.call("member-two", "PUT", "/devices/" + other, { environment: "production", bundleID: appTopic, notificationToken: null });
  const digest = "ab".repeat(32);
  for (const bad of [undefined, { key: digest, kind: "other" }, { key: "short", kind: "email" }, { key: digest + "/x", kind: "email" }])
    await f.service.waiting(f.itx, bad);
  assert.equal(f.pushes.length, 0);
  await f.service.waiting(f.itx, { key: digest, kind: "confirm" });
  await f.service.waiting(f.itx, { key: digest, kind: "confirm" });
  assert.equal(f.pushes.length, 1);
  const [sent] = f.pushes;
  assert.deepEqual([sent.type, sent.token, sent.environment, sent.collapseId], ["alert", testToken, "sandbox", "iterate-waiting-" + digest.slice(0, 32)]);
  assert.deepEqual(sent.payload, { aps: { category: "ITERATE_WAITING", "thread-id": "your-move", sound: "default",
    alert: { title: "Iterate", body: "An agent is asking for your yes." } }, waiting: "confirm" });
  await f.service.waiting(f.itx, { key: "kiwi-2026-11-22", kind: "signature" });
  assert.equal(f.pushes.at(-1).payload.aps.alert.body, "A statement is waiting for your signature.");
  // with one line of what is asked, the alert is titled by its kind and says that line
  await f.service.waiting(f.itx, { key: "cd".repeat(32), kind: "email", text: "To ada@example.org:  Re: Friday\nschedule " });
  assert.deepEqual(f.pushes.at(-1).payload.aps.alert, { title: "Email to approve", body: "To ada@example.org: Re: Friday schedule" });
  await f.service.waiting(f.itx, { key: "ef".repeat(32), kind: "confirm", text: "Book the 9:40 train on Friday" });
  assert.deepEqual(f.pushes.at(-1).payload.aps.alert, { title: "An agent asks for your yes", body: "Book the 9:40 train on Friday" });
  // a line is cut to what an alert shows, and words that are no text leave the kind alone
  await f.service.waiting(f.itx, { key: "long-request-1", kind: "signature", text: "x".repeat(400) });
  assert.equal(f.pushes.at(-1).payload.aps.alert.body.length, 140);
  await f.service.waiting(f.itx, { key: "odd-request-1", kind: "action", text: { not: "text" } });
  assert.deepEqual(f.pushes.at(-1).payload.aps.alert, { title: "Iterate", body: "An agent action is waiting for your approval." });
});

test("the attention activity says the first things in their own words and counts the rest, and a start is sent once for one content", () => {
  const shared = {
    approvals: 2, signatures: 1, urgent: 1, since: 1_800_000_000_500, until: 1_800_000_900_000,
    items: [
      { kind: "urgent", text: "Pay the  electrician\ntoday" },
      { kind: "approval", text: "Email to ada@example.org: Re: Friday schedule" },
      { kind: "other", text: "A kind no phone knows" },
      { kind: "approval", text: "" },
      { kind: "signature", text: "Confirm the new page" },
      { kind: "approval", text: "Release the feed reader" },
    ],
    urgentTodos: [{ id: 4, text: "Pay the electrician today", project: "House" }],
  };
  const state = attentionState(shared, ["Which day suits you?", "Window or aisle?", "Shall I book it?"]);
  const items = [
    { kind: "urgent", text: "Pay the electrician today" },
    { kind: "approval", text: "Email to ada@example.org: Re: Friday schedule" },
    { kind: "signature", text: "Confirm the new page" },
  ];
  assert.deepEqual(state, { approvals: 2, signatures: 1, questions: 3, urgent: 1, since: 1_800_000_000, items });
  assert.equal(attentionLine(state), "2 to approve · 1 to sign · 3 questions · 1 urgent");
  assert.deepEqual(attentionAlert(state), { title: "Urgent", body: "Pay the electrician today · +6 more" });
  // a member's own questions come after what every member shares, and one thing is no "more"
  const asked = attentionState({ urgent: 0 }, ["Which day suits you?"]);
  assert.deepEqual(asked.items, [{ kind: "question", text: "Which day suits you?" }]);
  assert.deepEqual(attentionAlert(asked), { title: "Question", body: "Which day suits you?" });
  // a line is one line of ninety characters at most, and never more lines than things that wait
  assert.equal(attentionState({ urgent: 1, items: [{ kind: "urgent", text: "y".repeat(200) }] }).items[0].text, "y".repeat(89) + "…");
  assert.deepEqual(attentionState({ urgent: 1, items }).items, [items[0]]);
  // counts that are no counts say nothing, nothing waiting has waited since no time, and counts
  // with no words are told as counts
  assert.deepEqual(attentionState({ approvals: -1, signatures: "2", urgent: 1.5, since: 99, items }, null), { approvals: 0, signatures: 0, questions: 0, urgent: 0, since: 0, items: [] });
  assert.deepEqual(attentionAlert(attentionState({ approvals: 2 })), { title: "Iterate", body: "2 to approve" });

  const now = 1_800_000_100_000;
  const start = attentionPush("start", state, { now, until: shared.until });
  assert.deepEqual(start.aps, {
    timestamp: 1_800_000_100,
    event: "start",
    "content-state": state,
    "stale-date": 1_800_000_900,
    "relevance-score": 100,
    "attributes-type": "IterateAttentionAttributes",
    attributes: {},
    "input-push-token": 1,
    alert: { title: "Urgent", body: "Pay the electrician today · +6 more" },
  });
  const update = attentionPush("update", attentionState({}, ["Which day?"]), { now, until: now - 1 });
  assert.deepEqual(update.aps, { timestamp: 1_800_000_100, event: "update", "content-state": { approvals: 0, signatures: 0, questions: 1, urgent: 0, since: 0, items: [{ kind: "question", text: "Which day?" }] }, "relevance-score": 50 });
  assert.deepEqual(attentionPush("end", attentionState({}), { now }).aps["dismissal-date"], 1_800_000_100);

  const content = JSON.stringify(state);
  const step = (given) => attentionStep(state, { now, canStart: true, ...given });
  assert.deepEqual(step({}), { mode: "start", content });
  assert.equal(step({ canStart: false }), null);
  // the same counts were started, or swiped away: nothing until they change
  assert.equal(step({ sent: { content, mode: "start", at: now - START_GRACE } }), null);
  assert.equal(step({ sent: { content, mode: "dismissed", at: 0 } }), null);
  // a change soon after a start waits for the activity's own token, then starts anew
  assert.equal(step({ sent: { content: "{}", mode: "start", at: now - START_GRACE + 1 } }), null);
  assert.deepEqual(step({ sent: { content: "{}", mode: "start", at: now - START_GRACE } }), { mode: "start", content });
  // an activity that takes updates gets each change, and its end when nothing waits
  assert.deepEqual(step({ activity: { startedAt: now }, sent: { content: "{}", mode: "start", at: now } }), { mode: "update", content });
  assert.equal(step({ activity: { startedAt: now }, sent: { content, mode: "update", at: now } }), null);
  const none = attentionState({});
  assert.deepEqual(attentionStep(none, { now, canStart: true, activity: { startedAt: now }, sent: { content } }), { mode: "end", content: JSON.stringify(none) });
  assert.equal(attentionStep(none, { now, canStart: true }), null);
  // one as old as Apple lets an activity get is replaced by a start
  assert.deepEqual(step({ activity: { startedAt: now - ACTIVITY_LIFETIME }, sent: { content: "{}", mode: "update", at: 0 } }), { mode: "start", content });
});

test("the lock screen of each phone follows what needs its member, and says the first things in their words", async () => {
  const until = Date.now() + 60 * 60 * 1000;
  const mail = { kind: "approval", text: "Email to ada@example.org: Re: Friday schedule" };
  let shared = { approvals: 1, signatures: 0, urgent: 0, since: Date.now() - 5000, until, items: [mail], urgentTodos: [] };
  const f = fixture(undefined, async () => shared);
  const [a, b] = ["member A", "member B"], [phoneA, phoneB, plain] = [randomUUID(), randomUUID(), randomUUID()];
  const startA = "a1".repeat(32), startB = "b1".repeat(32), liveA = "a2".repeat(32);
  await f.call(a, "PUT", "/devices/" + phoneA, { environment: "sandbox", notificationToken: testToken });
  // the token that starts the activity is registered beside the alert's, and keeps it
  assert.equal((await f.call(a, "PUT", "/devices/" + phoneA, { environment: "sandbox", attentionStartToken: startA })).status, 200);
  await f.call(b, "PUT", "/devices/" + phoneB, { environment: "production", attentionStartToken: startB });
  // a phone with no Live Activity token is sent none
  await f.call(b, "PUT", "/devices/" + plain, { environment: "production", notificationToken: "c1".repeat(32) });
  const live = () => f.pushes.filter((job) => job.type === "liveactivity");
  // phones are visited in the order of their members' keys: the checks below go by token
  const byToken = (x, y) => x.token.localeCompare(y.token);
  const sent = async (options) => { const from = live().length; const outcome = await f.service.attention(f.itx, options); return [live().slice(from).sort(byToken), outcome]; };

  let [pushes, outcome] = await sent();
  assert.deepEqual(pushes.map((job) => [job.token, job.environment, job.payload.aps.event, job.collapseId]),
    [[startA, "sandbox", "start", "iterate-attention"], [startB, "production", "start", "iterate-attention"]]);
  assert.deepEqual(pushes[0].payload.aps["content-state"], { approvals: 1, signatures: 0, questions: 0, urgent: 0, since: Math.floor(shared.since / 1000), items: [mail] });
  assert.deepEqual(pushes[0].payload.aps.alert, { title: "To approve", body: mail.text });
  assert.equal(pushes[0].payload.aps["stale-date"], Math.floor(until / 1000));
  assert.deepEqual({ ...outcome, results: outcome.results.sort() }, { devices: 3, results: ["production:start:accepted", "sandbox:start:accepted"] });
  // the request's day running out is looked at again, once
  assert.equal(f.timers.get(ATTENTION_SCHEDULE).when.at, new Date(until + 1000).toISOString());
  assert.equal(f.timers.get(ATTENTION_SCHEDULE).events[0].type, ATTENTION_TICK);

  // the same event twice, or a second change before a phone reported its activity, starts no second one
  const action = { kind: "approval", text: "Release the feed reader" };
  shared = { ...shared, approvals: 2, items: [mail, action] };
  assert.deepEqual((await sent())[1].results, ["unchanged", "unchanged"]);

  // A's phone reports the activity it started: it is brought up to date at once, and B's is left alone
  const other = randomUUID();
  assert.equal((await f.call(a, "PUT", "/attention/activity", { deviceId: other, token: liveA })).status, 409);
  const before = live().length;
  assert.equal((await f.call(a, "PUT", "/attention/activity", { deviceId: phoneA, token: liveA })).status, 200);
  assert.deepEqual(live().slice(before).map((job) => [job.token, job.payload.aps.event, job.payload.aps["content-state"].approvals]), [[liveA, "update", 2]]);
  assert.equal(live().at(-1).payload.aps.alert, undefined);

  // a question an agent asked member A is counted on A's phone alone
  const run = randomUUID(), owner = await hash(a);
  await f.call(a, "POST", "/runs", { id: run, kind: "ask", prompt: "Plan a visit" });
  const from = live().length;
  f.append("/agents/iterate-ios/" + owner + "/" + run, "web-message-sent", { message: "[[ITERATE_NEEDS_INPUT]]\nWhich day?", llmRequestOffset: 3 });
  await f.service.sync(f.itx, owner, run);
  assert.deepEqual(live().slice(from).map((job) => [job.token, job.payload.aps.event, job.payload.aps["content-state"].questions]), [[liveA, "update", 1]]);
  // in the agent's own words, after what every member shares
  const asked = { kind: "question", text: "Which day?" };
  assert.deepEqual(live().at(-1).payload.aps["content-state"].items, [mail, action, asked]);
  const answer = await f.call(a, "GET", "/attention");
  assert.deepEqual(answer.body, { approvals: 2, signatures: 0, questions: 1, urgent: 0, since: Math.floor(shared.since / 1000), items: [mail, action, asked], until, urgentTodos: [] });
  const others = (await f.call(b, "GET", "/attention")).body;
  assert.deepEqual([others.questions, others.items], [0, [mail, action]]);
  assert.equal((await f.call(a, "POST", "/attention")).status, 404);

  // answering it, and everything else being decided, ends the activity where it was
  assert.equal((await f.call(a, "POST", "/runs/" + run + "/reply", { id: randomUUID(), text: "Friday" })).status, 200);
  assert.equal(live().at(-1).payload.aps["content-state"].questions, 0);
  shared = { approvals: 0, signatures: 0, urgent: 0, since: 0, until: 0, items: [], urgentTodos: [] };
  [pushes] = await sent();
  assert.deepEqual(pushes.map((job) => [job.token, job.payload.aps.event, job.payload.aps["dismissal-date"] === job.payload.aps.timestamp]), [[liveA, "end", true]]);
  assert.equal(f.timers.has(ATTENTION_SCHEDULE), false);
  assert.deepEqual((await sent())[0], []);

  // the next thing starts it again, and the alert says what it is
  shared = { approvals: 0, signatures: 1, urgent: 2, since: Date.now(), until: 0,
    items: [{ kind: "urgent", text: "Pay the electrician" }, { kind: "urgent", text: "Renew the passport" }, { kind: "signature", text: "Confirm the new page" }],
    urgentTodos: [{ id: 7, text: "Pay the electrician", project: "House" }] };
  [pushes] = await sent();
  // B's phone never said which activity it started, so it is not started a second time this soon
  assert.deepEqual(pushes.map((job) => [job.token, job.payload.aps.event, job.payload.aps.alert]),
    [[startA, "start", { title: "Urgent", body: "Pay the electrician · +2 more" }]]);
  assert.deepEqual((await f.call(a, "GET", "/attention")).body.urgentTodos, shared.urgentTodos);
  // a todo's project and its id stay with the member's own session
  for (const job of live()) assert.ok(!JSON.stringify(job.payload).includes("House"));
});

test("a refused or swiped-away attention activity is not pushed at again until something changes", async () => {
  let shared = { approvals: 1, signatures: 0, urgent: 0, since: Date.now(), until: 0, items: [{ kind: "approval", text: "Release the feed reader" }], urgentTodos: [] };
  const f = fixture(undefined, async () => shared);
  const member = "member A", phone = randomUUID(), start = "a1".repeat(32), activity = "a2".repeat(32);
  await f.call(member, "PUT", "/devices/" + phone, { environment: "sandbox", attentionStartToken: start });
  await f.call(member, "PUT", "/attention/activity", { deviceId: phone, token: activity });
  assert.deepEqual(f.pushes.map((job) => [job.token, job.payload.aps.event]), [[activity, "update"]]);

  // Apple says the activity is gone: its token is forgotten and the phone is started anew, once
  shared = { ...shared, approvals: 2 };
  f.appleAnswers((job) => (job.token === activity ? "invalid" : "accepted"));
  assert.deepEqual((await f.service.attention(f.itx)).results, ["sandbox:update:invalid", "sandbox:start:accepted"]);
  assert.equal(await f.storage.get("attention-activity:" + await hash(member) + ":" + phone), undefined);

  // the member swipes the new one away: the same counts do not bring it back, a change does
  f.pushes.length = 0;
  assert.equal((await f.call(member, "PUT", "/attention/activity", { deviceId: phone, token: null, dismissed: true })).status, 200);
  assert.deepEqual((await f.service.attention(f.itx)).results, ["unchanged"]);
  shared = { ...shared, approvals: 3 };
  assert.deepEqual((await f.service.attention(f.itx)).results, ["sandbox:start:accepted"]);

  // a start token Apple refuses is forgotten, a send that may work later is tried at the next change
  shared = { ...shared, approvals: 4 };
  await f.storage.delete("attention-sent:" + await hash(member) + ":" + phone);
  f.appleAnswers(() => "retry");
  assert.deepEqual((await f.service.attention(f.itx)).results, ["sandbox:start:retry"]);
  f.appleAnswers(() => "invalid");
  assert.deepEqual((await f.service.attention(f.itx)).results, ["sandbox:start:invalid"]);
  assert.equal((await f.storage.get("device:" + await hash(member) + ":" + phone)).attentionStartToken, null);
  f.pushes.length = 0;
  await f.service.attention(f.itx);
  assert.deepEqual(f.pushes, []);

  // a phone that signs out takes its activity's record with it
  await f.call(member, "PUT", "/attention/activity", { deviceId: phone, token: activity });
  await f.call(member, "DELETE", "/devices/" + phone);
  assert.deepEqual([...(await f.storage.list({ prefix: "attention-" })).keys()], []);
});

test("a todo flagged urgent alerts each phone once, by its words", async () => {
  const f = fixture();
  await f.call("member A", "PUT", "/devices/" + randomUUID(), { environment: "sandbox", notificationToken: testToken });
  await f.service.waiting(f.itx, { key: "todo-urgent-41", kind: "urgent", text: "Pay the electrician today" });
  await f.service.waiting(f.itx, { key: "todo-urgent-41", kind: "urgent", text: "Pay the electrician today" });
  assert.deepEqual(f.pushes.map((job) => [job.type, job.payload.aps.alert, job.payload.waiting]),
    [["alert", { title: "Urgent todo", body: "Pay the electrician today" }, "urgent"]]);
});
