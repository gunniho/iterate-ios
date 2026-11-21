import { FacetDurableObject } from "iterate/sdk";
import { voiceAgentFacetSpec } from "@iterate-com/voice/install";
import { createMobileService, openAgentVoice, partsOfAgent } from "./integration.js";

export { installIterateMobile, updateIterateMobile, mobileLink } from "./integration.js";

export class IterateMobile extends FacetDurableObject {
  static override publicMethods = ["request", "openAgentVoice", "reconcile", "tick"];
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

  async tick(owner: string, runID: string, actionID: string) {
    if (this.onBehalfOf()) return;
    using itx = this.getItx();
    await this.#service.tick(itx, owner, runID, actionID);
  }
}
