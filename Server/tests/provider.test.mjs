import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { exchange } from "../apns/exchange.mjs";
import { validateKey, installKey } from "../apns/configure.mjs";
import { appTopic, sendPush } from "../mind/push.js";
const id = "00000000-0000-4000-8000-000000000000";
const job = {
  environment: "sandbox",
  type: "alert",
  token: "ab".repeat(32),
  collapseId: "iterate-" + id,
  payload: { aps: { category: "ITERATE_RESULT" }, runID: id },
};

test("locally validates the downloaded P-256 file and the vault mints an ES256 Apple provider JWT", async () => {
  const { publicKey, privateKey } = generateKeyPairSync("ec", {
    namedCurve: "P-256",
  });
  const folder = await mkdtemp(join(tmpdir(), "iterate-vault-test-"));
  try {
    const file = join(folder, "AuthKey_TEST123456.p8");
    await writeFile(file, privateKey.export({ format: "pem", type: "pkcs8" }), {
      mode: 0o600,
    });
    const team = "TESTTEAM01";
    await assert.rejects(validateKey(file, "TEST654321", team), /filename/);
    const material = await validateKey(file, "TEST123456", team);
    const minted = await exchange(material);
    const [header, claims, sig] = minted.accessToken.split(".");
    assert.deepEqual(JSON.parse(Buffer.from(header, "base64url")), {
      alg: "ES256",
      kid: "TEST123456",
    });
    const decoded = JSON.parse(Buffer.from(claims, "base64url"));
    assert.equal(decoded.iss, team);
    const enrolledTeam = "TEAM123456";
    const enrolled = await validateKey(file, "TEST123456", enrolledTeam);
    const enrolledClaims = (await exchange(enrolled)).accessToken.split(".")[1];
    assert.equal(
      JSON.parse(Buffer.from(enrolledClaims, "base64url")).iss,
      enrolledTeam,
    );
    for (const invalidTeam of [
      "SHORT",
      "team123456",
      "TEAM12345\n",
      1234567890,
      null,
    ]) {
      await assert.rejects(
        validateKey(file, "TEST123456", invalidTeam),
        /Team ID/,
      );
      await assert.rejects(
        exchange({ ...enrolled, teamID: invalidTeam }),
        /signing identity/,
      );
    }
    const run = promisify(execFile);
    const tool = fileURLToPath(
      new URL("../apns/configure.mjs", import.meta.url),
    );
    const check = [tool, "check", "sandbox", file];
    await assert.rejects(run(process.execPath, check), /enrolled Apple Developer team/);
    assert.match(
      (await run(process.execPath, [...check, "--team-id", enrolledTeam]))
        .stdout,
      /issuer TEAM123456/,
    );
    await assert.rejects(
      run(process.execPath, [tool, "install", "sandbox", file]),
      /enrolled Apple Developer team/,
    );
    assert.equal(
      Date.parse(minted.accessTokenExpiresAt) - decoded.iat * 1000,
      46 * 60 * 1000,
    );
    assert.ok(
      verify(
        "sha256",
        Buffer.from(header + "." + claims),
        { key: publicKey, dsaEncoding: "ieee-p1363" },
        Buffer.from(sig, "base64url"),
      ),
    );
    const target = { mind: "control.example.test", mindID: "1".repeat(64) };
    const calls = [],
      secrets = new Map();
    const itx = {
      whoami: async () => ({
        mindId: target.mindID,
        mindSlug: target.mind,
        path: "/",
        principal: { actor: "test member" },
      }),
      secrets: {
        describe: async (path) => secrets.get(path) || { set: false },
        set: async (path, raw, opts) => {
          assert.equal(typeof raw.keyBytes[0], "number");
          assert.equal(opts.placement, "header");
          assert.deepEqual(opts.operations, []);
          assert.deepEqual(opts.lendTo, []);
          assert.equal(opts.refresh.kind, "worker");
          assert.ok(!opts.refresh.source.includes(minted.accessToken));
          secrets.set(path, {
            set: true,
            urls: opts.urls,
            refresh: opts.refresh.kind,
            public: Object.fromEntries(opts.public.map((f) => [f, raw[f]])),
          });
          calls.push(path);
        },
      },
    };
    await assert.rejects(
      installKey(itx, "sandbox", material, { ...target, mindID: "2".repeat(64) }),
      /does not match/,
    );
    await assert.rejects(
      installKey(itx, "sandbox", material, { ...target, mind: "wrong.example.test" }),
      /does not match/,
    );
    await assert.rejects(
      installKey({ ...itx, whoami: async () => ({
        ...(await itx.whoami()), principal: { actor: "visitor", kind: "guest" },
      }) }, "sandbox", material, target),
      /does not match/,
    );
    assert.deepEqual(calls, []);
    assert.equal(await installKey(itx, "sandbox", material, target), "configured");
    assert.equal(
      await installKey(itx, "sandbox", material, target),
      "already configured",
    );
    assert.deepEqual(calls, ["/secrets/iterate-apns-sandbox"]);
    await assert.rejects(installKey(itx, "sandbox", enrolled, target), /--replace/);
    assert.equal(
      await installKey(itx, "sandbox", enrolled, { ...target, replace: true }),
      "configured",
    );
    assert.equal(
      await installKey(itx, "sandbox", enrolled, target),
      "already configured",
    );
    assert.equal(calls.length, 2);
    await assert.rejects(
      installKey(itx, "sandbox", { ...material, fingerprint: "changed" }, target),
      /--replace/,
    );
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});
test("delivery goes to the registered Apple environment and topic; only an expired device is removed", async () => {
  const requests = [];
  let response = new Response(null, { status: 200 });
  const itx = {
    secrets: { describe: async () => ({ set: true }) },
    fetch: async (req) => {
      requests.push(req);
      return response.clone();
    },
  };
  assert.equal(await sendPush(itx, job), "accepted");
  const sandbox = requests[0];
  assert.equal(
    sandbox.url,
    "https://api.sandbox.push.apple.com/3/device/" + job.token,
  );
  assert.equal(sandbox.headers.get("apns-topic"), appTopic);
  assert.equal(
    sandbox.headers.get("authorization"),
    'bearer getSecret("/secrets/iterate-apns-sandbox", { field: "accessToken" })',
  );
  response = Response.json({ reason: "ExpiredProviderToken" }, { status: 403 });
  const activity = {
    ...job,
    type: "liveactivity",
    environment: "production",
    payload: { aps: { event: "update" } },
  };
  assert.equal(await sendPush(itx, activity), "retry");
  assert.equal(
    requests[1].headers.get("apns-topic"),
    appTopic + ".push-type.liveactivity",
  );
  assert.match(requests[1].url, /^https:\/\/api\.push\.apple\.com\//);
  response = Response.json({ reason: "BadDeviceToken" }, { status: 400 });
  assert.equal(await sendPush(itx, job), "invalid");
  response = Response.json(
    { reason: "DeviceTokenNotForTopic" },
    { status: 400 },
  );
  assert.equal(await sendPush(itx, job), "invalid");
  itx.secrets.describe = async () => ({ set: false });
  assert.equal(await sendPush(itx, job), "disabled");
  await assert.rejects(
    sendPush(itx, { ...job, environment: "https://unknown.invalid" }),
  );
});
