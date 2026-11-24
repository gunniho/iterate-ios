import type { FacetSpec, IterateContextApi } from "iterate/api";
import type { IterateConfigEntrypoint, IterateConfigProcessEventArgs } from "iterate/sdk";

type WorkerEvent = IterateConfigProcessEventArgs["event"];

export function installIterateMobile(itx: IterateContextApi): Promise<void>;
export function updateIterateMobile(itx: IterateContextApi, event: WorkerEvent): Promise<void>;
export function mobileLink(request: Request, host: Pick<IterateConfigEntrypoint, "auth">): Promise<Response | null>;

/** One request held for a member's decision. `reviewURL` is the mind's own page for it. */
export type PendingApproval = {
  id: number;
  kind: "email" | "action" | "signature";
  title: string;
  recipients: string[];
  heldAt: string;
  reviewURL: string;
};
/** A request decided lately, so a phone that had it open can say how it ended. */
export type DecidedApproval = Omit<PendingApproval, "reviewURL"> & { outcome: "approved" | "rejected"; decidedAt: string };
/** What starts to wait for a member. `key` names it once, so each phone is alerted once. `text`
 *  is one line of what is asked: with it the alert says that line, without it the kind alone. */
export type WaitingNote = { key: string; kind: "email" | "action" | "confirm" | "signature" | "urgent"; text?: string };
/** One thing that needs a member, in one line. It passes through Apple and shows on a locked phone. */
export type AttentionItem = { kind: "urgent" | "approval" | "signature"; text: string };
/** What needs every member now. `since` and `until` are in milliseconds: when the oldest thing
 *  started to wait, and when the first of them can no longer be decided (0 for none). */
export type SharedAttention = {
  approvals: number;
  signatures: number;
  urgent: number;
  since: number;
  until: number;
  items: AttentionItem[];
  urgentTodos: { id: number; text: string; project: string }[];
  /** The HTTPS page that lists the todos, for the phone to open. */
  todoList?: string;
};

export function createMobileService(storage: DurableObjectStorage, options?: {
  approvalInbox?: (itx: IterateContextApi, signatures?: boolean) =>
    Promise<{ items: PendingApproval[]; decided: DecidedApproval[] }>;
  attention?: (itx: IterateContextApi) => Promise<SharedAttention>;
}): {
  request(itx: IterateContextApi, stamp: unknown, command: unknown): Promise<{ status: number; body: unknown }>;
  sync(itx: IterateContextApi, owner: string, runID: string): Promise<void>;
  tick(itx: IterateContextApi, owner: string, runID: string, actionID: string): Promise<void>;
  waiting(itx: IterateContextApi, note: WaitingNote): Promise<{ devices: number; results: string[] } | undefined>;
  attention(itx: IterateContextApi): Promise<{ devices: number; results: string[] }>;
};
export function partsOfAgent(path: string): [owner: string, runID: string] | undefined;
export function openAgentVoice(itx: IterateContextApi, stamp: unknown, command: unknown, facet: FacetSpec):
  Promise<{ path: string; agentPath: string }>;
