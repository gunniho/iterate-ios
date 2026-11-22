import { deployment } from "./settings.js";

export const appleEnvironments = {
  sandbox: {
    origin: "https://api.sandbox.push.apple.com",
    secret: "/secrets/iterate-apns-sandbox",
  },
  production: {
    origin: "https://api.push.apple.com",
    secret: "/secrets/iterate-apns-production",
  },
};
export const appTopic = deployment.bundleID;

export async function sendPush(itx, job) {
  const target = appleEnvironments[job.environment];
  if (
    !Object.hasOwn(appleEnvironments, job.environment) ||
    !["alert", "liveactivity"].includes(job.type) ||
    typeof job.token !== "string" ||
    !/^(?:[a-f0-9]{2}){16,512}$/.test(job.token)
  )
    throw Error("Invalid Iterate push registration.");
  if (!(await itx.secrets.describe(target.secret)).set) return "disabled";
  const live = job.type === "liveactivity";
  const response = await itx.fetch(
    new Request(target.origin + "/3/device/" + job.token, {
      method: "POST",
      // The runtime takes "follow" or "manual" alone. A redirect is then a refusal like any other status.
      redirect: "manual",
      headers: {
        authorization:
          'bearer getSecret("' + target.secret + '", { field: "accessToken" })',
        "apns-topic": live ? appTopic + ".push-type.liveactivity" : appTopic,
        "apns-push-type": job.type,
        "apns-priority":
          !live || job.payload.aps.event === "start" ? "10" : "5",
        "apns-collapse-id": job.collapseId,
        "apns-id": crypto.randomUUID(),
        "content-type": "application/json",
      },
      body: JSON.stringify(job.payload),
    }),
  );
  if (response.status === 200) return "accepted";
  const answer = await response.json().catch(() => ({}));
  // Apple's own word for a refusal, for whoever keeps a record of the send.
  job.refused?.(response.status + " " + (typeof answer.reason === "string" ? answer.reason.slice(0, 60) : ""));
  if (
    response.status === 410 ||
    (response.status === 400 &&
      ["BadDeviceToken", "DeviceTokenNotForTopic"].includes(answer.reason))
  )
    return "invalid";
  return "retry";
}
