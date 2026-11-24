// attention.js — WHAT NEEDS THE MEMBER NOW, as the phone's lock screen says it: one Live Activity
// that says what waits for them (requests to approve, statements to sign, questions an agent
// asked, todos flagged urgent). The mind starts, updates and ends it over Apple's push service
// (mobile.js `attention`), so it is true while the app is closed.
//
// A push says what is asked, in one line for each of the first MOST_ITEMS things: a member reads
// on the Lock Screen what they are wanted for, without opening the app. So those lines pass
// through Apple and show on a locked phone, as the waiting alert's words do. Each is one line of
// ITEM_TEXT characters at most: the whole request is read in the app, over the member's session.
import { deployment } from "./settings.js";

export const ATTENTION_ATTRIBUTES = "IterateAttentionAttributes";
export const ATTENTION_TICK = "events." + deployment.apexHost + "/ios/attention";
export const ATTENTION_SCHEDULE = "iterate-ios:attention";
/** Apple ends a Live Activity after eight hours. One that is older is started again. */
export const ACTIVITY_LIFETIME = 8 * 60 * 60 * 1000;
/** How long a started activity may take to report the token its updates go to. */
export const START_GRACE = 30 * 60 * 1000;

const KINDS = ["approvals", "signatures", "questions", "urgent"];
/** How many things the activity names in words. The rest are counted. */
export const MOST_ITEMS = 3;
const ITEM_TEXT = 90;
/** An item's kind, and how an alert that leads with it is titled. */
const ITEM_TITLES = { urgent: "Urgent", approval: "To approve", signature: "To sign", question: "Question" };
const count = (value) => (Number.isSafeInteger(value) && value > 0 ? Math.min(value, 999) : 0);
const seconds = (ms) => (Number.isFinite(ms) && ms > 0 ? Math.floor(ms / 1000) : 0);

/** `value` as one line of `max` characters at most, or "" for what is no text. */
export function oneLine(value, max = ITEM_TEXT) {
  if (typeof value !== "string") return "";
  const line = value.replace(/[\s\u0000-\u001f\u007f]+/g, " ").trim();
  return line.length > max ? line.slice(0, max - 1).trimEnd() + "…" : line;
}

/** Nothing waits. Also what a mind with no reader of its own answers. `items`: what waits, in the
 *  order the phone lists it, each `{ kind, text }` with a kind of ITEM_TITLES. A reader may add
 *  `todoList`, the address of the page that lists the todos, for the phone to open. */
export const NOTHING = Object.freeze({ approvals: 0, signatures: 0, urgent: 0, since: 0, until: 0, items: [], urgentTodos: [] });

/** The activity's content, as `IterateAttentionAttributes.ContentState` decodes it: four counts,
 *  `since`, when the oldest of them started to wait, in seconds (0 for none), and `items`, the
 *  first MOST_ITEMS things in words. `questions`: what an agent asked this member, each as its
 *  words, after everything every member shares. */
export function attentionState(shared, questions = []) {
  const asked = Array.isArray(questions) ? questions : [];
  const state = {
    approvals: count(shared?.approvals),
    signatures: count(shared?.signatures),
    questions: count(asked.length),
    urgent: count(shared?.urgent),
  };
  const total = totalOf(state);
  const items = [...(Array.isArray(shared?.items) ? shared.items : []), ...asked.map((text) => ({ kind: "question", text }))]
    .map((item) => ({ kind: item?.kind, text: oneLine(item?.text) }))
    .filter((item) => Object.hasOwn(ITEM_TITLES, item.kind) && item.text)
    .slice(0, Math.min(MOST_ITEMS, total));
  return { ...state, since: total ? seconds(shared?.since) : 0, items };
}

export const totalOf = (state) => KINDS.reduce((sum, kind) => sum + (state[kind] || 0), 0);

/** The counts in words: "2 to approve · 1 urgent". */
export function attentionLine(state) {
  const words = {
    approvals: (n) => n + " to approve",
    signatures: (n) => n + " to sign",
    questions: (n) => (n === 1 ? "1 question" : n + " questions"),
    urgent: (n) => n + " urgent",
  };
  const parts = KINDS.filter((kind) => state[kind] > 0).map((kind) => words[kind](state[kind]));
  return parts.length ? parts.join(" · ") : "Nothing needs you.";
}

/** The alert that starts the activity: the first thing that waits, in its own words, and how many
 *  more there are. A content with no words is told by its counts. */
export function attentionAlert(state) {
  const [first] = state.items || [];
  if (!first) return { title: "Iterate", body: attentionLine(state) };
  const more = totalOf(state) - 1;
  return { title: ITEM_TITLES[first.kind], body: first.text + (more > 0 ? " · +" + more + " more" : "") };
}

/** One Live Activity push. `start` makes the activity on a phone that shows none, `update` changes
 *  the one it shows, `end` takes it away at once. `until`: when the first of what waits can no
 *  longer be decided, after which the phone marks the counts as out of date until it hears again. */
export function attentionPush(mode, state, { now = Date.now(), until = 0 } = {}) {
  const stamp = seconds(now);
  const stale = until > now ? seconds(until) : 0;
  const aps = { timestamp: stamp, event: mode, "content-state": state };
  if (mode === "end") return { aps: { ...aps, "dismissal-date": stamp } };
  if (stale) aps["stale-date"] = stale;
  // Urgent work and requests outrank a question when the phone has room for one activity.
  aps["relevance-score"] = state.urgent || state.approvals || state.signatures ? 100 : 50;
  if (mode === "start")
    Object.assign(aps, {
      "attributes-type": ATTENTION_ATTRIBUTES,
      attributes: {},
      "input-push-token": 1,
      // Apple takes no start without an alert. It has no sound: the waiting alert made one.
      alert: attentionAlert(state),
    });
  return { aps };
}

/** What to send a phone, or null for nothing. `sent` is what it was last sent, `alive` whether it
 *  the activity it reported (it takes updates), `canStart` whether it gave a token that starts one.
 *
 *  A start is sent once for one content: a member who swiped the activity away is shown it again
 *  when something changes, and not before. After a start, the phone has START_GRACE to report the
 *  new activity's token, so a second change in that time does not start a second activity. */
export function attentionStep(state, { sent, activity, canStart, now = Date.now() }) {
  const content = JSON.stringify(state);
  const total = totalOf(state);
  // An activity as old as Apple lets one get shows nothing any more: the next start replaces it.
  if (activity && now - (activity.startedAt || now) < ACTIVITY_LIFETIME)
    return sent?.content === content ? null : { mode: total ? "update" : "end", content };
  if (!total || !canStart || sent?.content === content) return null;
  if (sent?.mode === "start" && now - sent.at < START_GRACE) return null;
  return { mode: "start", content };
}
