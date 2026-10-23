// Orchard web UI. Plain JS, no build step. Mirrors the native macOS app:
// a source-list sidebar (Chats, Tasks), a toolbar, and chat or task content.
const $ = (s) => document.querySelector(s);
const BUDGET = 3000;
const DEFAULT_SYSTEM = "You are a helpful assistant. Be concise.";
const est = (s) => Math.ceil([...s].length / 4); // same chars ÷ 4 rule as the server
const fmt = (n) => n.toLocaleString();
const narrow = matchMedia("(max-width: 720px)"); // sidebar becomes a drawer
const touch = matchMedia("(pointer: coarse)").matches; // on-screen keyboard
// Focusing a field on a phone pops the keyboard; only do it on desktop.
const focus = (el) => touch || el.focus();

// ---------- icons (Lucide, MIT licensed: https://lucide.dev) ----------

const ICONS = {
    compose:
        '<path d="M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.375 2.625a1 1 0 0 1 3 3l-9.013 9.014a2 2 0 0 1-.853.505l-2.873.84a.5.5 0 0 1-.62-.62l.84-2.873a2 2 0 0 1 .506-.852z"/>',
    panel: '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M9 3v18"/>',
    sliders:
        '<path d="M21 4h-7"/><path d="M10 4H3"/><path d="M21 12h-9"/><path d="M8 12H3"/><path d="M21 20h-5"/><path d="M12 20H3"/><path d="M14 2v4"/><path d="M8 10v4"/><path d="M16 18v4"/>',
    arrow: '<path d="m5 12 7-7 7 7"/><path d="M12 19V5"/>',
    stop: '<rect x="5" y="5" width="14" height="14" rx="2"/>',
    copy: '<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>',
    trash: '<path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/>',
    alert: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
    leaf: '<path d="M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.48 19 2c1 2 2 4.18 2 8 0 5.5-4.78 10-10 10Z"/><path d="M2 21c0-3 1.85-5.36 5.08-6C9.5 14.52 12 13 13 12"/>',
    chat: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
    list: '<path d="M3 12h.01"/><path d="M3 18h.01"/><path d="M3 6h.01"/><path d="M8 12h13"/><path d="M8 18h13"/><path d="M8 6h13"/>',
    braces: '<path d="M8 3H7a2 2 0 0 0-2 2v5a2 2 0 0 1-2 2 2 2 0 0 1 2 2v5c0 1.1.9 2 2 2h1"/><path d="M16 21h1a2 2 0 0 0 2-2v-5c0-1.1.9-2 2-2a2 2 0 0 1-2-2V5a2 2 0 0 0-2-2h-1"/>',
    commit: '<circle cx="12" cy="12" r="3"/><path d="M3 12h6"/><path d="M15 12h6"/>',
    tag: '<path d="M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z"/><circle cx="7.5" cy="7.5" r="1"/>',
    zap: '<path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>',
};
const icon = (name) => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name] || ICONS.zap}</svg>`;
const TASK_ICONS = { summarize: "list", extract: "braces", rewrite: "compose", commit: "commit", classify: "tag" };
const TASK_DESC = {
    summarize: "Summarize text in 3–5 short bullets.",
    extract: "Pull the fields you list out of the text as JSON.",
    rewrite: "Rewrite text in a different tone.",
    commit: "Write a one-line conventional commit message from a git diff.",
    classify: "Pick one label from your list for the text.",
};
document.querySelectorAll("[data-icon]").forEach((el) => (el.innerHTML = icon(el.dataset.icon)));

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

const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

function inline(s) {
    return s
        .split(/(`[^`\n]+`)/)
        .map((part) => {
            if (part.startsWith("`") && part.endsWith("`") && part.length > 1) return `<code>${esc(part.slice(1, -1))}</code>`;
            return esc(part)
                .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
                .replace(/(^|[^*\w])\*([^*\n]+)\*/g, "$1<em>$2</em>")
                .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
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
        if (list) out.push(`<${list.tag}>${list.items.map((x) => `<li>${inline(x)}</li>`).join("")}</${list.tag}>`);
        list = null;
    };
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line.trimStart().startsWith("```")) {
            flushPara();
            flushList();
            const code = [];
            while (++i < lines.length && !lines[i].trimStart().startsWith("```")) code.push(lines[i]);
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
    btn.style.color = "var(--green)";
    setTimeout(() => (btn.style.color = ""), 1000);
}

// ---------- layout: sidebar, selection, health ----------

const ui = { mode: "chat" }; // "chat" | "task"

function setMode(mode, title) {
    ui.mode = mode;
    $("#chat").hidden = mode !== "chat";
    $("#tasks").hidden = mode !== "task";
    $("#sys-btn").parentElement.hidden = mode !== "chat";
    $("#sys-pop").hidden = true;
    $("#title").textContent = title;
    document.title = `${title} – Orchard`;
    const hash = mode === "chat" ? `#chat=${chat.id}` : `#task=${tasks.current?.name}`;
    if (location.hash !== hash) history.replaceState(null, "", hash);
    markActive();
    if (narrow.matches) setSidebar(false);
}

function markActive() {
    document.querySelectorAll("#chat-list li").forEach((li) => li.classList.toggle("active", ui.mode === "chat" && +li.dataset.id === chat.id));
    document.querySelectorAll("#task-list li").forEach((li) => li.classList.toggle("active", ui.mode === "task" && li.dataset.name === tasks.current?.name));
}

// Desktop: the sidebar collapses. Narrow screens: it's a drawer over the
// content, closed by default, with the show button always in the toolbar.
function setSidebar(open) {
    const w = $("#window");
    if (narrow.matches) {
        w.classList.remove("collapsed");
        w.classList.toggle("drawer-open", open);
        $("#show-sidebar").hidden = false;
    } else {
        w.classList.remove("drawer-open");
        w.classList.toggle("collapsed", !open);
        $("#show-sidebar").hidden = open;
    }
}
$("#toggle-sidebar").onclick = () => setSidebar(false);
$("#show-sidebar").onclick = () => setSidebar(true);
$("#scrim").onclick = () => setSidebar(false);
narrow.addEventListener("change", () => setSidebar(!narrow.matches));
setSidebar(!narrow.matches);

async function checkHealth() {
    const el = $("#status");
    let ok = false,
        reachable = true;
    try {
        ok = (await fetch("/api/health")).ok;
    } catch {
        reachable = false;
    }
    el.className = "status " + (ok ? "ok" : "down");
    el.title = ok ? "fm serve is running" : "fm serve is not reachable";
    $("#banner").hidden = ok;
    $("#banner-text").textContent = !reachable
        ? "Can't reach Orchard. Is the app (or orchard serve) running?"
        : "fm serve isn't running yet. Orchard starts it automatically; if this persists, check Setup & Status in the Orchard app.";
}
checkHealth();
setInterval(checkHealth, 5000);

// ---------- chat ----------

const chat = { id: null, title: "", system: "", baseTokens: 0, controller: null };

async function loadChats() {
    const chats = await api("GET", "/api/chats");
    const ul = $("#chat-list");
    ul.innerHTML = "";
    for (const c of chats) {
        const li = document.createElement("li");
        li.dataset.id = c.id;
        li.innerHTML = `${icon("chat")}<span class="name">${esc(c.title || "New chat")}</span><button class="del" title="Delete">${icon("trash")}</button>`;
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
    markActive();
    return chats;
}

const EMPTY = `<div class="empty">${icon("leaf")}<h2>Orchard</h2><p>Chat with Apple's on-device model. Replies are drafts — check facts and code.</p></div>`;

function addMsg(role, content) {
    $("#messages .empty")?.remove();
    const div = document.createElement("div");
    div.className = "msg " + role;
    div.dataset.raw = content;
    div.innerHTML = `<div class="text"></div>`;
    const text = div.firstChild;
    if (role === "assistant") text.innerHTML = md(content);
    else text.textContent = content;
    const btn = document.createElement("button");
    btn.className = "tool small copy";
    btn.title = "Copy";
    btn.innerHTML = icon("copy");
    btn.onclick = () => copy(div.dataset.raw, btn);
    if (role === "user") div.prepend(btn);
    else div.appendChild(btn);
    $("#messages").appendChild(div);
    scrollDown();
    return div;
}

function setMsg(div, text) {
    div.dataset.raw = text;
    div.querySelector(".text").innerHTML = md(text);
}

const scrollDown = () => {
    const m = $("#messages");
    m.scrollTop = m.scrollHeight;
};

function updateMeter() {
    const draft = $("#input").value;
    const used = chat.baseTokens + (draft ? est(draft) + 4 : 0);
    $("#meter b").style.width = Math.min(100, (used / BUDGET) * 100) + "%";
    $("#meter").classList.toggle("high", used > BUDGET);
    $("#meter .meter-text").textContent = `${fmt(used)} / ${fmt(BUDGET)} tokens`;
    if (used > BUDGET) $("#trim-note").textContent = "· oldest turns will be left out";
    $("#send").classList.toggle("ready", !!draft.trim());
}

function autosize() {
    const t = $("#input");
    t.style.height = "auto";
    t.style.height = Math.min(t.scrollHeight + 1, 180) + "px";
}

async function openChat(id) {
    const { chat: c, messages, tokens } = await api("GET", `/api/chats/${id}`);
    Object.assign(chat, { id: c.id, title: c.title, system: c.system_prompt, baseTokens: tokens });
    $("#messages").innerHTML = messages.length ? "" : EMPTY;
    for (const m of messages) addMsg(m.role, m.content);
    $("#trim-note").textContent = "";
    setMode("chat", c.title || "New chat");
    updateMeter();
    focus($("#input"));
}

async function newChat() {
    // Reuse an empty chat instead of piling them up.
    if (chat.id && ui.mode === "chat" && !$("#messages .msg") && chat.title === "New chat") return narrow.matches ? setSidebar(false) : focus($("#input"));
    const c = await api("POST", "/api/chats", {});
    await loadChats();
    await openChat(c.id);
}

async function openFirstOrNew() {
    const chats = await loadChats();
    if (chats.length) await openChat(chats[0].id);
    else await newChat();
}

$("#new-chat").onclick = newChat;

// system prompt popover
$("#sys-btn").onclick = (e) => {
    e.stopPropagation();
    const pop = $("#sys-pop");
    pop.hidden = !pop.hidden;
    if (!pop.hidden) {
        $("#sys-prompt").value = chat.system;
        focus($("#sys-prompt"));
    }
};
$("#sys-pop").onclick = (e) => e.stopPropagation();
document.addEventListener("click", () => ($("#sys-pop").hidden = true));
$("#sys-reset").onclick = () => ($("#sys-prompt").value = DEFAULT_SYSTEM);
$("#sys-cancel").onclick = () => ($("#sys-pop").hidden = true);
$("#sys-save").onclick = async () => {
    await api("PATCH", `/api/chats/${chat.id}`, { system_prompt: $("#sys-prompt").value });
    chat.system = $("#sys-prompt").value;
    $("#sys-pop").hidden = true;
    const { tokens } = await api("GET", `/api/chats/${chat.id}`);
    chat.baseTokens = tokens;
    updateMeter();
};

$("#input").addEventListener("input", () => {
    autosize();
    updateMeter();
});
$("#input").addEventListener("keydown", (e) => {
    // On touch keyboards Return adds a line; the send button sends.
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing && !touch) {
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
    autosize();
    addMsg("user", text);
    const div = addMsg("assistant", "");
    div.classList.add("streaming");
    let reply = "";
    chat.controller = new AbortController();
    $("#send").hidden = true;
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
                    $("#trim-note").textContent = notes.length ? "· " + notes.join(" · ") : "";
                    if (m.title && m.title !== chat.title) {
                        chat.title = m.title;
                        $("#title").textContent = m.title;
                        loadChats();
                    }
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
        $("#send").hidden = false;
        $("#stop").hidden = true;
        const { tokens } = await api("GET", `/api/chats/${chat.id}`);
        chat.baseTokens = tokens;
        updateMeter();
        focus($("#input"));
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
    if (tasks.current?.name !== t.name) {
        $("#task-out-wrap").hidden = true;
        $("#task-out").textContent = "";
    }
    tasks.current = t;
    setMode("task", t.label);
    $("#task-desc").textContent = TASK_DESC[t.name] || "";
    $("#task-desc").hidden = !TASK_DESC[t.name];
    const wrap = $("#opt-wrap"),
        field = $("#opt-field");
    field.innerHTML = "";
    if (t.option) {
        wrap.hidden = false;
        $("#opt-label").textContent = t.option.label + ":";
        let el;
        if (t.option.choices?.length) {
            el = document.createElement("select");
            for (const c of t.option.choices) el.add(new Option(c[0].toUpperCase() + c.slice(1), c, false, c === t.option.default));
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
    focus($("#task-input"));
}

function updateTaskCount() {
    const t = tasks.current;
    if (!t) return;
    const text = $("#task-input").value;
    const n = [...text].length;
    const max = taskMaxChars(t);
    $("#task-count").textContent = n ? `${fmt(n)} characters · ~${fmt(est(text))} tokens` : "";
    const warn = $("#task-warn");
    warn.hidden = n <= max;
    warn.textContent = `Input is over budget: only the first ${fmt(max)} of ${fmt(n)} characters will be sent.`;
}

async function loadTasks() {
    tasks.list = await api("GET", "/api/tasks");
    const ul = $("#task-list");
    ul.innerHTML = "";
    for (const t of tasks.list) {
        const li = document.createElement("li");
        li.dataset.name = t.name;
        li.innerHTML = `${icon(TASK_ICONS[t.name] || "zap")}<span class="name">${esc(t.label)}</span>`;
        li.onclick = () => selectTask(t);
        ul.appendChild(li);
    }
    markActive();
}

$("#task-input").addEventListener("input", updateTaskCount);
$("#task-input").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        runTask();
    }
});
$("#task-run").onclick = () => (tasks.controller ? tasks.controller.abort() : runTask());
$("#task-copy").onclick = () => copy($("#task-out").textContent, $("#task-copy"));

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
                    if (m.truncated) note.textContent = `Input truncated to ${fmt(m.sent_chars)} of ${fmt(m.input_chars)} characters.`;
                },
                delta: (d) => {
                    if (first) {
                        first = false;
                        note.textContent += ` First token in ${Math.round(performance.now() - started)} ms.`;
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
        if (err.name !== "AbortError") out.textContent += (out.textContent ? "\n\n" : "") + "⚠️ " + err.message;
    } finally {
        tasks.controller = null;
        $("#task-run").textContent = "Run";
    }
}

// ---------- boot ----------

// Deep links: #chat=<id> or #task=<name>.
(async () => {
    const [kind, value] = location.hash.slice(1).split("=");
    await loadTasks();
    const t = kind === "task" && tasks.list.find((x) => x.name === value);
    if (t) {
        await loadChats();
        return selectTask(t);
    }
    if (kind === "chat" && value) {
        await loadChats();
        try {
            return await openChat(+value);
        } catch {}
    }
    await openFirstOrNew();
})();
