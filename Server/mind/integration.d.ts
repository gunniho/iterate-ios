import type { FacetSpec, IterateContextApi } from "iterate/api";
import type { IterateConfigEntrypoint, IterateConfigProcessEventArgs } from "iterate/sdk";

type WorkerEvent = IterateConfigProcessEventArgs["event"];

export function installIterateMobile(itx: IterateContextApi): Promise<void>;
export function updateIterateMobile(itx: IterateContextApi, event: WorkerEvent): Promise<void>;
export function mobileLink(request: Request, host: Pick<IterateConfigEntrypoint, "auth">): Promise<Response | null>;

export function createMobileService(storage: DurableObjectStorage): {
  request(itx: IterateContextApi, stamp: unknown, command: unknown): Promise<{ status: number; body: unknown }>;
  sync(itx: IterateContextApi, owner: string, runID: string): Promise<void>;
  tick(itx: IterateContextApi, owner: string, runID: string, actionID: string): Promise<void>;
};
export function partsOfAgent(path: string): [owner: string, runID: string] | undefined;
export function openAgentVoice(itx: IterateContextApi, stamp: unknown, command: unknown, facet: FacetSpec):
  Promise<{ path: string; agentPath: string }>;
