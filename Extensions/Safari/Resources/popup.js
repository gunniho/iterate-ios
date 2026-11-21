const element = id => document.getElementById(id);
const ask = element("ask");
const remember = element("remember");
const check = element("check");
const question = element("question");
const continuation = element("continue");
let page = null;
let submitting = false;
let pending = null;
let lastSubmission = null;

function updateButtons() {
  ask.disabled = !page || submitting || !question.value.trim();
  remember.disabled = !page || submitting;
  check.disabled = submitting;
  check.hidden = !pending;
}

async function readSelection() {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  if (tab?.id === undefined) throw new Error("Open a webpage in Safari to use Iterate.");
  const [frame] = await browser.scripting.executeScript({
    target: { tabId: tab.id },
    func: () => ({
      title: document.title.slice(0, 240),
      url: location.href,
      selection: String(window.getSelection() || "").trim().slice(0, 8000)
    })
  });
  const captured = frame?.result;
  if (!captured) throw new Error("Safari couldn't read this page.");
  const url = new URL(captured.url);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
    throw new Error("Iterate supports web pages with an HTTP or HTTPS address.");
  }
  element("title").textContent = captured.title || url.hostname;
  element("url").textContent = url.href;
  element("selection").textContent = captured.selection;
  element("selection").hidden = !captured.selection;
  page = { title: captured.title, url: url.href, selection: captured.selection };
  updateButtons();
}

async function submit(mode) {
  if (submitting || !page) return;
  submitting = true;
  updateButtons();
  continuation.hidden = true;
  element("result").textContent = "Sending…";
  try {
    let request;
    if (mode === "check") {
      request = { mode, id: pending };
    } else {
      const instruction = question.value.trim();
      if (!lastSubmission || lastSubmission.mode !== mode || lastSubmission.question !== instruction) {
        lastSubmission = { mode, question: instruction, id: crypto.randomUUID() };
      }
      request = { ...lastSubmission, page };
    }
    // Safari routes this call to the containing extension regardless of the application ID.
    const reply = await browser.runtime.sendNativeMessage("application.id", request);
    if (!reply?.ok) throw new Error(reply?.message || "Iterate couldn't accept this request.");
    pending = ["queued", "running"].includes(reply.status) ? reply.id : null;
    if (reply.status === "needsInput" && reply.url?.startsWith("https://")) {
      continuation.href = reply.url;
      continuation.hidden = false;
    }
    element("result").textContent = reply.message;
  } catch (error) {
    element("result").textContent = error.message || "Open the Iterate app and check your connection.";
  } finally {
    submitting = false;
    updateButtons();
  }
}

question.addEventListener("input", updateButtons);
ask.addEventListener("click", () => submit("ask"));
remember.addEventListener("click", () => submit("remember"));
check.addEventListener("click", () => submit("check"));
readSelection().catch(error => {
  element("result").textContent = error.message || "Allow this extension to access the current page.";
});
