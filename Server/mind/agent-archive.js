// The Dash and native app share the same per-member, reversible archive.
const archivePrefix = actor => "iterate:dash:agent-archive:v1:" + encodeURIComponent(actor) + ":";

export class AgentArchiveError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export async function archivedAgentPaths(itx, actor) {
  const prefix = archivePrefix(actor);
  const { keys } = await itx.kv.list(prefix);
  return keys.filter(key => key.startsWith(prefix)).map(key => key.slice(prefix.length));
}

export async function setAgentArchived(itx, actor, input, readCatalog) {
  const { path, archived } = input ?? {};
  if (typeof path !== "string" || !path.startsWith("/agents/") || path.length <= "/agents/".length || typeof archived !== "boolean") {
    throw new AgentArchiveError(400, "Choose an agent to archive or restore.");
  }
  const key = archivePrefix(actor) + path;
  const { state } = await readCatalog();
  if (!Object.hasOwn(state.agents, path)) {
    if (Object.hasOwn(state.deleted, path)) {
      if (!archived) await itx.kv.delete(key);
      throw new AgentArchiveError(410, "This agent has ended. Its history is available in Archived.");
    }
    throw new AgentArchiveError(404, "The agent could not be found.");
  }
  if (archived) await itx.kv.put(key, "1");
  else await itx.kv.delete(key);
  return { path, archived };
}
