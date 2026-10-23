// Orchard UI. Plain JS, no build step.
const $ = (s) => document.querySelector(s);
const BUDGET = 3000;
const est = (s) => Math.ceil([...s].length / 4); // same chars ÷ 4 rule as the server

// ---------- helpers ----------

async function api(method, url, body) {
  const res = await fetch(url, {
    method,
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (res.status === 204) return null;
  const j = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(j.error || res.statusText);
  return j;
}

// POST and dispatch server-sent events to handlers[eventName](data).
async function stream(url, body, handlers, signal) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
    signal,
  });
  if (!res.ok) {
    const j = await res.json().catch(() => ({}));
    throw new Error(j.error || res.statusText);
  }
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const block = buf.slice(0, i);
      buf = buf.slice(i + 2);
      let ev = "message",
        data = "";
      for (const line of block.split("\n")) {
        if (line.startsWith("event: ")) ev = line.slice(7);
        else if (line.startsWith("data: ")) data += line.slice(6);
      }
      handlers[ev]?.(data ? JSON.parse(data) : {});
    }
  }
}

const esc = (s) =>
  s.replace(
    /[&<>"]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c],
  );

function inline(s) {
  return s
    .split(/(`[^`\n]+`)/)
    .map((part) => {
      if (part.startsWith("`") && part.endsWith("`") && part.length > 1)
        return `<code>${esc(part.slice(1, -1))}</code>`;
      return esc(part)
        .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
        .replace(/(^|[^*\w])\*([^*\n]+)\*/g, "$1<em>$2</em>")
        .replace(
          /\[([^\]]+)\]\((https?:[^)\s]+)\)/g,
          '<a href="$2" target="_blank" rel="noopener">$1</a>',
        );
    })
    .join("");
}

// Minimal markdown: fences, headings, lists, paragraphs, inline code/bold/italic/links.
function md(src) {
  const out = [];
  const lines = src.split("\n");
  let para = [],
    list = null;
  const flushPara = () => {
    if (para.length) out.push(`<p>${para.map(inline).join("<br>")}</p>`);
    para = [];
  };
  const flushList = () => {
    if (list)
      out.push(
        `<${list.tag}>${list.items.map((x) => `<li>${inline(x)}</li>`).join("")}</${list.tag}>`,
      );
    list = null;
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.trimStart().startsWith("```")) {
      flushPara();
      flushList();
      const code = [];
      while (++i < lines.length && !lines[i].trimStart().startsWith("```"))
        code.push(lines[i]);
      out.push(`<pre><code>${esc(code.join("\n"))}</code></pre>`);
      continue;
    }
    let m;
    if ((m = line.match(/^(#{1,6})\s+(.*)/))) {
      flushPara();
      flushList();
      const n = Math.min(m[1].length + 1, 3);
      out.push(`<h${n}>${inline(m[2])}</h${n}>`);
    } else if ((m = line.match(/^\s*(?:[-*+•]|(\d+)[.)])\s+(.*)/))) {
      flushPara();
      const tag = m[1] ? "ol" : "ul";
      if (list && list.tag !== tag) flushList();
      list ??= { tag, items: [] };
      list.items.push(m[2]);
    } else if (!line.trim()) {
      flushPara();
      flushList();
    } else {
      flushList();
      para.push(line);
    }
  }
  flushPara();
  flushList();
  return out.join("");
}

async function copy(text, btn) {
  await navigator.clipboard.writeText(text);
  const old = btn.textContent;
  btn.textContent = "Copied";
  setTimeout(() => (btn.textContent = old), 1200);
}

// ---------- tabs + health ----------

document.querySelectorAll(".tab").forEach((b) =>
  b.addEventListener("click", () => {
    document
      .querySelectorAll(".tab")
      .forEach((t) => t.classList.toggle("active", t === b));
    document
      .querySelectorAll(".view")
      .forEach((v) => (v.hidden = v.id !== b.dataset.view));
    (b.dataset.view === "chat" ? $("#input") : $("#task-input")).focus();
  }),
);

async function checkHealth() {
  const el = $("#status");
  try {
    const r = await fetch("/api/health");
    const ok = r.ok;
    el.className = "status " + (ok ? "ok" : "down");
    el.title = ok
      ? "fm serve is running"
      : "fm serve is not reachable — run `fm serve`";
  } catch {
    el.className = "status down";
    el.title = "Orchard server is not reachable";
  }
}
checkHealth();
setInterval(checkHealth, 5000);

// ---------- chat ----------

const chat = { id: null, baseTokens: 0, controller: null };

async function loadChats() {
  const chats = await api("GET", "/api/chats");
  const ul = $("#chat-list");
  ul.innerHTML = "";
  for (const c of chats) {
    const li = document.createElement("li");
    li.classList.toggle("active", c.id === chat.id);
    li.innerHTML = `<span>${esc(c.title || "New chat")}</span><button class="del" title="Delete">×</button>`;
    li.onclick = () => openChat(c.id);
    li.querySelector(".del").onclick = async (e) => {
      e.stopPropagation();
      if (!confirm(`Delete "${c.title}"?`)) return;
      await api("DELETE", `/api/chats/${c.id}`);
      if (c.id === chat.id) chat.id = null;
      await loadChats();
      if (!chat.id) await openFirstOrNew();
    };
    ul.appendChild(li);
  }
  return chats;
}

function addMsg(role, content) {
  $("#messages .empty")?.remove();
  const div = document.createElement("div");
  div.className = "msg " + role;
  div.dataset.raw = content;
  if (role === "assistant") div.innerHTML = md(content);
  else div.textContent = content;
  const btn = document.createElement("button");
  btn.className = "copy";
  btn.textContent = "Copy";
  btn.onclick = () => copy(div.dataset.raw, btn);
  div.appendChild(btn);
  $("#messages").appendChild(div);
  scrollDown();
  return div;
}

function setMsg(div, text) {
  div.dataset.raw = text;
  const btn = div.querySelector(".copy");
  div.innerHTML = md(text);
  div.appendChild(btn);
}

const scrollDown = () => {
  const m = $("#messages");
  m.scrollTop = m.scrollHeight;
};

function updateMeter() {
  const draft = $("#input").value;
  const used = chat.baseTokens + (draft ? est(draft) + 4 : 0);
  const pct = Math.min(100, (used / BUDGET) * 100);
  $("#meter b").style.width = pct + "%";
  $("#meter").classList.toggle("high", used > BUDGET);
  $("#meter > span:last-child").textContent = `${used} / ${BUDGET}`;
  $("#trim-note").textContent =
    used > BUDGET ? "oldest turns will be left out" : "";
}

async function openChat(id) {
  const { chat: c, messages, tokens } = await api("GET", `/api/chats/${id}`);
  chat.id = c.id;
  chat.baseTokens = tokens;
  $("#sys-prompt").value = c.system_prompt;
  $("#sys-note").textContent = "";
  const box = $("#messages");
  box.innerHTML = "";
  if (!messages.length)
    box.innerHTML = `<p class="empty">Ask anything. Replies are drafts from a small on-device model — check facts and code.</p>`;
  for (const m of messages) addMsg(m.role, m.content);
  document
    .querySelectorAll("#chat-list li")
    .forEach((li, i) => li.classList.remove("active"));
  await loadChats();
  updateMeter();
  $("#input").focus();
}

async function newChat() {
  const c = await api("POST", "/api/chats", {});
  await openChat(c.id);
}

async function openFirstOrNew() {
  const chats = await loadChats();
  if (chats.length) await openChat(chats[0].id);
  else await newChat();
}

$("#new-chat").onclick = newChat;

$("#sys-save").onclick = async () => {
  await api("PATCH", `/api/chats/${chat.id}`, {
    system_prompt: $("#sys-prompt").value,
  });
  $("#sys-note").textContent = "Saved";
  const { tokens } = await api("GET", `/api/chats/${chat.id}`);
  chat.baseTokens = tokens;
  updateMeter();
};

$("#input").addEventListener("input", updateMeter);
$("#input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
    e.preventDefault();
    $("#composer").requestSubmit();
  }
});

$("#stop").onclick = () => chat.controller?.abort();

$("#composer").addEventListener("submit", async (e) => {
  e.preventDefault();
  const text = $("#input").value.trim();
  if (!text || chat.controller) return;
  $("#input").value = "";
  addMsg("user", text);
  const div = addMsg("assistant", "");
  div.classList.add("streaming");
  let reply = "";
  chat.controller = new AbortController();
  $("#send").disabled = true;
  $("#stop").hidden = false;
  try {
    await stream(
      `/api/chats/${chat.id}/messages`,
      { content: text },
      {
        meta: (m) => {
          const notes = [];
          if (m.dropped) notes.push(`${m.dropped} oldest message${m.dropped > 1 ? "s" : ""} left out to fit`);
          if (m.truncated) notes.push("your message was truncated to fit");
          $("#trim-note").textContent = notes.join("; ");
          loadChats();
        },
        delta: (d) => {
          reply += d.text;
          setMsg(div, reply);
          scrollDown();
        },
        error: (e) => {
          throw new Error(e.error);
        },
      },
      chat.controller.signal,
    );
  } catch (err) {
    if (err.name !== "AbortError") {
      if (!reply) div.remove();
      addMsg("assistant", "⚠️ " + err.message).classList.add("error");
    }
  } finally {
    div.classList.remove("streaming");
    chat.controller = null;
    $("#send").disabled = false;
    $("#stop").hidden = true;
    const { tokens } = await api("GET", `/api/chats/${chat.id}`);
    chat.baseTokens = tokens;
    updateMeter();
    $("#input").focus();
  }
});

// ---------- tasks ----------

const tasks = { list: [], current: null, controller: null };

function taskMaxChars(t) {
  // Mirrors Task.Prepare on the server, for the live warning only.
  let max = (BUDGET - est(t.system) - 8) * 4;
  if (t.max_input_chars && t.max_input_chars < max) max = t.max_input_chars;
  return max;
}

function selectTask(t) {
  tasks.current = t;
  document
    .querySelectorAll("#task-list li")
    .forEach((li) => li.classList.toggle("active", li.dataset.name === t.name));
  $("#task-title").textContent = t.label;
  const wrap = $("#opt-wrap"),
    field = $("#opt-field");
  field.innerHTML = "";
  if (t.option) {
    wrap.hidden = false;
    $("#opt-label").textContent = t.option.label;
    let el;
    if (t.option.choices?.length) {
      el = document.createElement("select");
      for (const c of t.option.choices)
        el.add(new Option(c, c, false, c === t.option.default));
    } else {
      el = document.createElement("input");
      el.value = t.option.default || "";
    }
    el.id = "opt-value";
    field.appendChild(el);
  } else {
    wrap.hidden = true;
  }
  updateTaskCount();
  $("#task-input").focus();
}

function updateTaskCount() {
  const t = tasks.current;
  if (!t) return;
  const n = [...$("#task-input").value].length;
  const max = taskMaxChars(t);
  $("#task-count").textContent = n
    ? `${n.toLocaleString()} chars · ~${est($("#task-input").value)} tokens`
    : "";
  const warn = $("#task-warn");
  warn.hidden = n <= max;
  warn.textContent = `Input is over budget: only the first ${max.toLocaleString()} of ${n.toLocaleString()} characters will be sent.`;
}

async function loadTasks() {
  tasks.list = await api("GET", "/api/tasks");
  const ul = $("#task-list");
  ul.innerHTML = "";
  for (const t of tasks.list) {
    const li = document.createElement("li");
    li.dataset.name = t.name;
    li.innerHTML = `<span>${esc(t.label)}</span>`;
    li.onclick = () => selectTask(t);
    ul.appendChild(li);
  }
  if (tasks.list.length) selectTask(tasks.list[0]);
}

$("#task-input").addEventListener("input", updateTaskCount);
$("#task-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
    e.preventDefault();
    runTask();
  }
});
$("#task-run").onclick = () =>
  tasks.controller ? tasks.controller.abort() : runTask();
$("#task-copy").onclick = () =>
  copy($("#task-out").textContent, $("#task-copy"));

async function runTask() {
  const t = tasks.current;
  const input = $("#task-input").value;
  if (!t || !input.trim() || tasks.controller) return;
  const out = $("#task-out"),
    note = $("#task-note");
  $("#task-out-wrap").hidden = false;
  out.textContent = "";
  note.textContent = "";
  tasks.controller = new AbortController();
  $("#task-run").textContent = "Stop";
  const started = performance.now();
  let first = true;
  try {
    await stream(
      `/api/tasks/${t.name}`,
      { input, option: $("#opt-value")?.value ?? "" },
      {
        meta: (m) => {
          if (m.truncated)
            note.textContent = `Input truncated to ${m.sent_chars.toLocaleString()} of ${m.input_chars.toLocaleString()} chars.`;
        },
        delta: (d) => {
          if (first) {
            first = false;
            note.textContent += ` First token ${Math.round(performance.now() - started)} ms.`;
          }
          out.textContent += d.text;
        },
        retry: () => {
          out.textContent = "";
          note.textContent += " Not valid JSON; retrying once…";
        },
        done: (d) => {
          out.textContent = d.text;
        },
        error: (e) => {
          throw new Error(e.error);
        },
      },
      tasks.controller.signal,
    );
  } catch (err) {
    if (err.name !== "AbortError")
      out.textContent += (out.textContent ? "\n\n" : "") + "⚠️ " + err.message;
  } finally {
    tasks.controller = null;
    $("#task-run").textContent = "Run";
  }
}

// ---------- boot ----------

openFirstOrNew();
loadTasks();
