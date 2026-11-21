// The Iterate vault runs this module in its secret exchange worker. Only the short-lived
// provider token is substituted at egress, in a header going to the pinned Apple host.
export function isAppleID(value) {
  return (
    typeof value === "string" &&
    value.length === 10 &&
    /^[A-Z0-9]+$/.test(value)
  );
}

export async function exchange(material) {
  if (!isAppleID(material.teamID) || !isAppleID(material.keyID))
    throw Error("Invalid Apple signing identity.");
  if (
    !Array.isArray(material.keyBytes) ||
    material.keyBytes.length < 50 ||
    material.keyBytes.length > 1024 ||
    !material.keyBytes.every((n) => Number.isInteger(n) && n >= 0 && n <= 255)
  )
    throw Error("Invalid APNs private key.");
  const algorithm = { name: "ECDSA", namedCurve: "P-256" };
  const key = await crypto.subtle.importKey(
    "pkcs8",
    Uint8Array.from(material.keyBytes),
    algorithm,
    false,
    ["sign"],
  );
  const encode = (bytes) =>
    btoa(String.fromCharCode(...bytes))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
  const json = (value) =>
    encode(new TextEncoder().encode(JSON.stringify(value)));
  const now = Math.floor(Date.now() / 1000);
  const input =
    json({ alg: "ES256", kid: material.keyID }) +
    "." +
    json({ iss: material.teamID, iat: now });
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      new TextEncoder().encode(input),
    ),
  );
  if (signature.byteLength !== 64)
    throw Error("Invalid APNs signature format.");
  return {
    ...material,
    accessToken: input + "." + encode(signature),
    accessTokenExpiresAt: new Date((now + 46 * 60) * 1000).toISOString(),
  };
}
