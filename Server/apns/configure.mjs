import {
  createHash,
  createPrivateKey,
  createPublicKey,
  verify,
} from "node:crypto";
import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import { pathToFileURL } from "node:url";
import { appleEnvironments } from "../mind/push.js";
import { exchange, isAppleID } from "./exchange.mjs";

function checkTarget(mind, mindID) {
  const hostname = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
  if (typeof mind !== "string" || mind.length > 253 || !hostname.test(mind))
    throw Error("Pass --mind with your Iterate control-plane hostname.");
  if (typeof mindID !== "string" || mindID.length !== 64 || !/^[0-9a-f]+$/.test(mindID))
    throw Error("Pass --mind-id with your trusted 64-character Iterate mind ID.");
}

export async function validateKey(file, keyID, teamID) {
  if (!isAppleID(teamID))
    throw Error("Apple Team ID must be 10 uppercase letters or digits.");
  if (!isAppleID(keyID))
    throw Error("Apple Key ID must be 10 uppercase letters or digits.");
  const pem = await readFile(file, "utf8");
  if (
    pem.length > 4096 ||
    !/^-----BEGIN PRIVATE KEY-----[\s\S]*-----END PRIVATE KEY-----\s*$/.test(
      pem,
    )
  )
    throw Error("Choose the PKCS#8 .p8 file downloaded from Apple Developer.");
  const filenameID = /^AuthKey_([A-Z0-9]{10})\.p8$/i
    .exec(basename(file))?.[1]
    ?.toUpperCase();
  if (filenameID && filenameID !== keyID)
    throw Error("Apple Key ID does not match the .p8 filename.");
  let key;
  try {
    key = createPrivateKey(pem);
  } catch {
    throw Error("Unable to read the APNs private key.");
  }
  if (
    key.asymmetricKeyType !== "ec" ||
    key.asymmetricKeyDetails?.namedCurve !== "prime256v1"
  )
    throw Error("APNs requires a P-256 key.");
  const pub = createPublicKey(key);
  const fingerprint = createHash("sha256")
    .update(pub.export({ format: "der", type: "spki" }))
    .digest("hex");
  const material = {
    teamID,
    keyID,
    fingerprint,
    keyBytes: Array.from(key.export({ type: "pkcs8", format: "der" })),
  };
  const token = (await exchange(material)).accessToken;
  const [header, claims, signature] = token.split(".");
  if (
    !verify(
      "sha256",
      Buffer.from(header + "." + claims),
      { key: pub, dsaEncoding: "ieee-p1363" },
      Buffer.from(signature, "base64url"),
    )
  )
    throw Error("Unable to verify the APNs provider signature.");
  return material;
}

function matchesKey(description, material, origin) {
  return (
    description.set &&
    description.public?.fingerprint === material.fingerprint &&
    description.public?.keyID === material.keyID &&
    description.public?.teamID === material.teamID &&
    description.urls?.length === 1 &&
    description.urls[0] === origin &&
    description.refresh === "worker"
  );
}

export async function installKey(itx, environment, material, { mind, mindID, replace = false }) {
  checkTarget(mind, mindID);
  const target = appleEnvironments[environment];
  if (!target || !Object.hasOwn(appleEnvironments, environment))
    throw Error("Choose sandbox or production.");
  if (!isAppleID(material.teamID) || !isAppleID(material.keyID))
    throw Error("Supply the 10-character Apple Team ID and Key ID.");
  const who = await itx.whoami();
  if (
    who.mindId !== mindID ||
    who.mindSlug !== mind ||
    who.path !== "/" ||
    typeof who.principal?.actor !== "string" || !who.principal.actor || who.principal.kind
  )
    throw Error("The authenticated session does not match the requested mind and member account.");
  const existing = await itx.secrets.describe(target.secret);
  if (matchesKey(existing, material, target.origin))
    return "already configured";
  if (existing.set && !replace)
    throw Error(
      "The selected environment already has an APNs key. Pass --replace to rotate it.",
    );
  const source = await readFile(
    new URL("./exchange.mjs", import.meta.url),
    "utf8",
  );
  // This is a direct authenticated RPC. Script runs record their source and must never carry key bytes.
  await itx.secrets.set(target.secret, material, {
    urls: [target.origin],
    placement: "header",
    operations: [],
    lendTo: [],
    public: ["keyID", "teamID", "fingerprint"],
    refresh: { kind: "worker", source },
  });
  const saved = await itx.secrets.describe(target.secret);
  if (!matchesKey(saved, material, target.origin))
    throw Error("Could not verify the Apple vault configuration.");
  return "configured";
}

async function main(args) {
  const [operation, environment, file, ...rest] = args;
  if (
    !["check", "install"].includes(operation) ||
    !Object.hasOwn(appleEnvironments, environment) ||
    !file
  )
    throw Error(
      "Usage: node configure.mjs check|install sandbox|production /path/to/AuthKey_ID.p8 --team-id TEAMID [--key-id KEYID] [--mind HOST --mind-id ID] [--replace]",
    );
  let keyID = /^AuthKey_([A-Z0-9]{10})\.p8$/i
    .exec(basename(file))?.[1]
    ?.toUpperCase();
  let teamID;
  let mind, mindID;
  let replace = false;
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === "--key-id" && rest[i + 1]) {
      keyID = rest[++i];
      continue;
    }
    if (rest[i] === "--team-id" && rest[i + 1] && !teamID) {
      teamID = rest[++i];
      continue;
    }
    if (rest[i] === "--mind" && operation === "install" && rest[i + 1] && !mind) {
      mind = rest[++i].toLowerCase();
      continue;
    }
    if (rest[i] === "--mind-id" && operation === "install" && rest[i + 1] && !mindID) {
      mindID = rest[++i].toLowerCase();
      continue;
    }
    if (rest[i] === "--replace" && operation === "install") {
      replace = true;
      continue;
    }
    throw Error("Unrecognized setup option.");
  }
  if (!teamID)
    throw Error(
      "Pass --team-id with the enrolled Apple Developer team that issued the APNs key.",
    );
  if (operation === "install") checkTarget(mind, mindID);
  const material = await validateKey(file, keyID, teamID);
  if (operation === "check") {
    console.log(
      "Validated the local P-256 signature for Apple key " +
        material.keyID +
        " with issuer " +
        material.teamID +
        ".",
    );
    return;
  }
  const { connectMind } = await import("iterate/node").catch(() => {
    throw Error(
      "Install the pinned Iterate client with npm ci --ignore-scripts in Server/apns.",
    );
  });
  const connection = await connectMind({ address: mind });
  try {
    const result = await installKey(
      connection.itx,
      environment,
      material,
      { mind, mindID, replace },
    );
    console.log(
      "Iterate " +
        environment +
        " key " +
        material.keyID +
        " for team " +
        material.teamID +
        " " +
        result +
        ".",
    );
  } finally {
    connection[Symbol.dispose]();
  }
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
