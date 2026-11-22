import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import {
  MobileService,
  agentTranscript,
  hash,
  partsOfAgent,
} from "../mind/mobile.js";

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
function fixture(readPendingApprovals) {
  const storage = new Store(),
    logs = new Map(),
    messages = new Map(),
    timers = new Map(),
    pushes = [];
  let failures = 0;
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
    return "accepted";
  }, readPendingApprovals);
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
  let approvalReads = 0;
  const f = fixture(async () => { approvalReads++; return pending; });
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
  assert.deepEqual(await f.call(actor, "GET", route), { status: 200, body: { approvals: [approval], questions: [
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
  assert.deepEqual(await f.call(actor, "GET", summary), { status: 200, body: { approvalCount: 1, questionCount: 2 } });
  f.storage.get = originalGet;
  f.storage.list = originalList;
  assert.deepEqual((await f.call("member-two", "GET", route, { actor })).body, { approvals: [approval], questions: [] });
  assert.deepEqual(await f.call(actor, "GET", "/approvals"), { status: 200, body: { items: pending } });
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
  assert.deepEqual((await f.call(actor, "GET", summary)).body, { approvalCount: 1, questionCount: 1 });
  const longQuestion = "a".repeat(767) + "🌍" + "b".repeat(23_000);
  f.append(path, "web-message-sent", { message: "[[ITERATE_NEEDS_INPUT]]\n" + longQuestion, llmRequestOffset: 9 });
  await f.service.sync(f.itx, owner, first);
  const latest = (await f.call(actor, "GET", route)).body.questions[0];
  assert.equal(latest.question, "a".repeat(767));
  assert.equal(latest.responseLength, longQuestion.length);
  assert.notEqual(latest.updatedAt, current.updatedAt);
  f.append(path, "paused", {});
  await f.service.sync(f.itx, owner, first);
  assert.deepEqual((await f.call(actor, "GET", summary)).body, { approvalCount: 1, questionCount: 1 });
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
