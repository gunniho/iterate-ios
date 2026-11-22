import { FacetDurableObject } from "iterate/sdk";
import { voiceAgentFacetSpec } from "@iterate-com/voice/install";
import { createMobileService, openAgentVoice, partsOfAgent } from "./integration.js";

export { installIterateMobile, updateIterateMobile, mobileLink } from "./integration.js";

export class IterateMobile extends FacetDurableObject {
  static override publicMethods = ["request", "openAgentVoice", "reconcile", "tick", "waiting"];
  #service = createMobileService(this.ctx.storage);

  async request(command: unknown) {
    const member = this.onBehalfOf();
    using itx = this.getItx();
    return await this.#service.request(itx, member, command);
  }

  async openAgentVoice(command: unknown) {
    const member = this.onBehalfOf();
    using itx = this.getItx();
    return await openAgentVoice(itx, member, command, voiceAgentFacetSpec);
  }

  async reconcile(path: string) {
    const pair = partsOfAgent(path);
    if (!pair || this.onBehalfOf()) return;
    using itx = this.getItx();
    await this.#service.sync(itx, pair[0], pair[1]);
  }

  async waiting(note: { key: string; kind: string }) {
    using itx = this.getItx();
    // A member's own call sends nothing. Each send leaves a line on `/apps/iterate-ios/pushes`.
    const outcome = this.onBehalfOf() ? { skipped: "called on a member's behalf" } : await this.#service.waiting(itx, note);
    if (outcome) await itx.cd("/apps/iterate-ios/pushes").append({ type: "iterate.mobile/waiting-push", payload: { kind: note?.kind, ...outcome } });
  }

  async tick(owner: string, runID: string, actionID: string) {
    if (this.onBehalfOf()) return;
    using itx = this.getItx();
    await this.#service.tick(itx, owner, runID, actionID);
  }
}
