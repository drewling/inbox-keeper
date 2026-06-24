/* inbox-keeper panel logic. Vanilla, no dependencies. Reads the cached state
   artifact, renders four views, and drives keeper/undo jobs via the local API. */
"use strict";

// Running inside the native app window? Fill edge-to-edge (the window rounds it).
if (new URLSearchParams(location.search).get("app")) {
  document.documentElement.classList.add("in-app");
}

const $ = (sel, root = document) => root.querySelector(sel);
const viewEl = $("#view");
const navEl = $("#nav");
const stripEl = $("#accounts-strip");
const actionEl = $("#actionbar");
const panelEl = $(".panel");

let STATE = null;
const _VIEWS = ["loops", "accounts", "undo", "policy"];
let VIEW = _VIEWS.includes(location.hash.slice(1)) ? location.hash.slice(1) : "loops";
let JOB_POLL = null;
let KEEPING = false;     // a keeper run is in progress (show the tidying state)
let AUTO_RAN = false;    // auto-run-when-stale fires at most once per panel open

/* ---------- helpers ---------- */
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function relTime(epoch) {
  if (!epoch) return "";
  const s = Math.max(0, Math.floor(Date.now() / 1000) - epoch);
  if (s < 90) return "now";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60);
  if (h < 24) return h + "h";
  const d = Math.floor(h / 24);
  if (d < 7) return d + "d";
  const w = Math.floor(d / 7);
  if (w < 5) return w + "w";
  return Math.floor(d / 30) + "mo";
}

const acctBySlug = (slug) => (STATE?.accounts || []).find((a) => a.slug === slug);

function gmailUrl(acct, threadId) {
  const who = encodeURIComponent(acct?.email || "");
  return `https://mail.google.com/mail/?authuser=${who}#all/${threadId}`;
}

async function api(path, opts, timeoutMs = 20000) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const r = await fetch(path, { ...(opts || {}), signal: ctrl.signal });
    const ct = r.headers.get("content-type") || "";
    const data = ct.includes("json") ? await r.json() : await r.text();
    return { ok: r.ok, status: r.status, data };
  } catch (e) {
    // Timed out or server unreachable.
    return { ok: false, status: 0, data: null, aborted: e && e.name === "AbortError" };
  } finally {
    clearTimeout(timer);
  }
}
// Pull a human error out of an api() result.
const apiErr = (data) => (data && data.error) ? String(data.error) : "";

let toastTimer = null;
function _toastEl() {
  let t = $(".toast", panelEl);
  if (!t) { t = document.createElement("div"); t.className = "toast"; panelEl.appendChild(t); }
  return t;
}
function toast(msg) {
  const t = _toastEl();
  t.innerHTML = `<span>${esc(msg)}</span>`;
  requestAnimationFrame(() => t.classList.add("show"));
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show"), 2600);
}
function toastUndo(msg, onUndo) {
  const t = _toastEl();
  t.innerHTML = `<span>${esc(msg)}</span><button class="toast-undo">Undo</button>`;
  t.querySelector(".toast-undo").onclick = () => {
    t.classList.remove("show");
    onUndo();
  };
  requestAnimationFrame(() => t.classList.add("show"));
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show"), 4500);
}

/* ---------- data ---------- */
async function loadState() {
  const { data } = await api("/api/state");
  if (!data) {                       // server unreachable: keep last good state
    toast("Can’t reach the keeper server");
    return;
  }
  STATE = data;
  renderStrip();
  render();
  maybeAutoRun();
}

// Self-maintaining: if the data is stale when the panel opens, quietly run the
// keeper once (it shows the tidying state) so you never open to stale noise.
function maybeAutoRun() {
  if (AUTO_RAN || KEEPING || JOB_POLL || !STATE) return;
  const ageSec = Date.now() / 1000 - (STATE.generated_at || 0);
  if (ageSec > 1800 && (STATE.accounts || []).some((a) => a.ok)) {
    AUTO_RAN = true;
    runKeeper();
  }
}

/* ---------- top strip ---------- */
function renderStrip() {
  const accts = STATE?.accounts || [];
  stripEl.innerHTML = accts.map((a) => {
    const badge = a.inbox_threads > 0
      ? `<span class="badge">${a.inbox_threads > 99 ? "99+" : a.inbox_threads}</span>` : "";
    return `<span class="acct-dot${a.ok ? "" : " err"}" style="background:${esc(a.color)}"
                  title="${esc(a.email)}${a.ok ? "" : " — needs attention"}">${esc(a.short)}${badge}</span>`;
  }).join("");
}

/* ---------- views ---------- */
function loopRows() {
  const rows = [];
  for (const a of STATE.accounts || []) {
    for (const l of a.loops || []) rows.push({ ...l, _acct: a });
  }
  rows.sort((x, y) => (y.epoch || 0) - (x.epoch || 0));
  return rows;
}

function failureBanner() {
  const failed = (STATE.accounts || []).filter((a) => !a.ok);
  const partial = (STATE.accounts || []).filter((a) => a.ok && a.partial > 0);
  if (failed.length) {
    const names = failed.map((a) => a.short).join(", ");
    return `<div class="banner banner-err" role="alert">
      Couldn’t read ${failed.length === 1 ? "an account" : failed.length + " accounts"}
      (${esc(names)}). Counts below may be incomplete.</div>`;
  }
  if (partial.length) {
    const n = partial.reduce((s, a) => s + a.partial, 0);
    return `<div class="banner" role="status">${n} ${n === 1 ? "thread" : "threads"} couldn’t be loaded; the list may be short.</div>`;
  }
  return "";
}

function renderLoops() {
  if (!STATE || STATE.needs_build) return skeleton();
  if (KEEPING) {
    return `<div class="empty tidying">
      <div class="mark"><span class="spinner dark"></span></div>
      <h2>Tidying your inboxes</h2>
      <p data-keeper-status>Starting…</p>
    </div>`;
  }
  const rows = loopRows();
  const total = STATE.total_loops ?? rows.length;
  const anyFailed = (STATE.accounts || []).some((a) => !a.ok);

  // Never show the calm "all clear" state while an account is unreachable —
  // a transient Gmail/auth failure must not read as "you're caught up".
  if (total === 0 && anyFailed) {
    const failed = (STATE.accounts || []).filter((a) => !a.ok);
    return `<div class="empty">
      <div class="mark warn">${alertSvg()}</div>
      <h2>Couldn’t check your inboxes</h2>
      <p>${failed.length === 1 ? "An account" : failed.length + " accounts"} didn’t
         respond, so this isn’t a real "all clear". ${esc(failed[0].error || "")}</p>
    </div>`;
  }

  if (total === 0) {
    return `<div class="empty">
      <div class="mark">${checkSvg()}</div>
      <h2>Your inboxes are clear</h2>
      <p>Nothing is waiting on you across ${(STATE.accounts || []).length} accounts.
         Everything else was set aside, reversibly.</p>
    </div>`;
  }

  const word = total === 1 ? "thing" : "things";
  const hero = `<div class="hero">
      <div class="count">${total}</div>
      <div class="lede">${total === 1 ? "thing still needs you" : word + " still need you"}</div>
      <div class="sub">Across ${(STATE.accounts || []).length} accounts. Tap any to open it in Gmail.</div>
    </div>`;

  const list = rows.map((r) => {
    const a = r._acct;
    return `<li class="row" role="button" tabindex="0" data-thread="${esc(r.thread_id)}"
        data-slug="${esc(a.slug)}" data-sender="${esc(r.sender)}"
        data-email="${esc(r.sender_email || "")}" data-subject="${esc(r.subject)}"
        data-snippet="${esc(r.snippet || "")}" data-epoch="${r.epoch || 0}">
      <span class="mono" style="background:${esc(a.color)}">${esc(a.short)}</span>
      <span class="body">
        <span class="sender">${esc(r.sender)}</span>
        <span class="ask">${esc(r.subject)}</span>
      </span>
      <span class="meta"><span class="when">${esc(relTime(r.epoch))}</span></span>
      <span class="row-actions">
        <button class="row-act" data-reply aria-label="Reply to: ${esc(r.subject)}" title="Draft a reply">${replySvg()}</button>
        <button class="row-act" data-dismiss aria-label="Set aside: ${esc(r.subject)}" title="Set aside (reversible)">${archiveSvg()}</button>
      </span>
    </li>`;
  }).join("");

  return failureBanner() + hero +
    `<div class="section-label">Waiting on you</div><ul class="rows">${list}</ul>`;
}

function renderAccounts() {
  if (!STATE) return skeleton();
  if (!(STATE.accounts || []).length) {
    return `<div class="empty">
      <div class="mark">${archiveSvg()}</div>
      <h2>Connect your first inbox</h2>
      <p>Add a Gmail account and the keeper starts watching for what needs you.</p>
      <button class="add-account" data-add-account style="margin-top:18px;max-width:260px">
        <span class="plus">+</span> Add a Gmail account</button>
    </div>`;
  }
  const cards = (STATE.accounts || []).map((a) => {
    const undoN = (a.undo_points || []).reduce((n, u) => n + (u.count || 0), 0);
    const bits = [`${a.unread} unread`];
    if (undoN) bits.push(`${undoN} archived`);
    const stat = a.ok ? bits.join(" · ") : "Couldn’t reach this account";
    return `<li class="acct-card">
      <span class="avatar" style="background:${esc(a.color)}">${esc(a.short)}</span>
      <span class="acct-meta">
        <span class="email">${esc(a.email)}</span>
        <span class="stat${a.ok ? "" : " err"}"${a.ok ? "" : ` title="${esc(a.error || "")}"`}>${esc(stat)}</span>
      </span>
      <span class="num"><b>${a.ok ? a.inbox_threads : "—"}</b><span>open</span></span>
    </li>`;
  }).join("");
  return `<ul class="acct-list">${cards}</ul>
    <button class="add-account" data-add-account>
      <span class="plus">+</span> Add a Gmail account
    </button>`;
}

function renderUndo() {
  if (!STATE) return skeleton();
  const items = [];
  for (const a of STATE.accounts || []) {
    for (const u of a.undo_points || []) items.push({ ...u, _acct: a });
  }
  items.sort((x, y) => (y.date || "").localeCompare(x.date || ""));

  if (!items.length) {
    return `<div class="empty">
      <div class="mark">${checkSvg()}</div>
      <h2>Nothing to undo</h2>
      <p>Archived mail is grouped by the day it was set aside. Restore points appear here.</p>
    </div>`;
  }

  const intro = `<p class="undo-intro">Nothing is ever deleted. Each point restores a day’s
    set-aside threads back to the inbox in one tap.</p>`;
  const list = items.map((u, i) => `<li class="undo-item">
      <span>
        <span class="what">${u.count} ${u.count === 1 ? "thread" : "threads"} set aside</span>
        <span class="who">${esc(u._acct.email)} · ${esc(u.date)}</span>
      </span>
      <button class="btn btn-restore" data-restore="${i}"
              data-slug="${esc(u._acct.slug)}" data-label="${esc(u.label)}">Restore</button>
    </li>`).join("");
  return intro + `<ul class="undo-list">${list}</ul>`;
}

function renderPolicy() {
  const text = STATE?.policy || "";
  const learned = (STATE?.learned || "").trim();
  const learnedBody = learned.replace(/^#[^\n]*\n+/, "");  // panel adds its own heading
  const learnedBlock = learned
    ? `<div class="learned">
         <div class="section-label">Learned from your actions</div>
         <div class="learned-body">${mdLite(learnedBody)}</div>
       </div>`
    : `<p class="policy-note dim">As you set loops aside and edit drafts, the keeper
        learns your preferences and shows them here.</p>`;
  return `<div class="policy-wrap">
    <p class="policy-note">The <b>only</b> thing you configure. Describe what counts as
      “still needs me” in plain English. The agent reads each thread and enforces it.</p>
    <textarea class="policy-edit" id="policy-edit" spellcheck="false"
              aria-label="Keep policy">${esc(text)}</textarea>
    ${learnedBlock}
  </div>`;
}

// Minimal, safe markdown: headings, bullets, bold. Escapes first, then formats.
function mdLite(src) {
  const lines = esc(src).split("\n");
  let html = "", inList = false;
  const closeList = () => { if (inList) { html += "</ul>"; inList = false; } };
  for (let raw of lines) {
    const line = raw.replace(/\*\*(.+?)\*\*/g, "<b>$1</b>");
    if (/^#+\s/.test(line)) { closeList(); html += `<h4>${line.replace(/^#+\s/, "")}</h4>`; }
    else if (/^[-*]\s/.test(line)) {
      if (!inList) { html += "<ul>"; inList = true; }
      html += `<li>${line.replace(/^[-*]\s/, "")}</li>`;
    } else if (line.startsWith("&gt;")) { /* skip blockquote chrome */ }
    else if (line.trim()) { closeList(); html += `<p>${line}</p>`; }
  }
  closeList();
  return html;
}

function skeleton() {
  const r = `<div class="sk-row"><div class="sk" style="width:26px;height:26px;border-radius:7px"></div>
    <div style="flex:1"><div class="sk sk-line" style="width:42%"></div>
    <div class="sk sk-line" style="width:74%;margin-top:7px"></div></div></div>`;
  return `<div style="padding-top:18px">${r.repeat(6)}</div>`;
}

const VIEWS = { loops: renderLoops, accounts: renderAccounts, undo: renderUndo, policy: renderPolicy };

function checkSvg() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>`;
}
function alertSvg() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><path d="M12 9v4"/><path d="M12 17h.01"/><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/></svg>`;
}
function archiveSvg() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="4" rx="1"/><path d="M5 8v11a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8"/><path d="M10 12h4"/></svg>`;
}
function replySvg() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 17l-5-5 5-5"/><path d="M4 12h11a5 5 0 0 1 5 5v1"/></svg>`;
}
function runSvg() {
  return `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4v5h-5"/></svg>`;
}

/* ---------- action bar (per view) ---------- */
function renderAction() {
  const running = JOB_POLL !== null;
  if (VIEW === "policy") {
    actionEl.innerHTML = `<span class="status" id="status"></span>
      <button class="btn btn-ghost" id="policy-save">Save policy</button>`;
    $("#policy-save").onclick = savePolicy;
    return;
  }
  const label = running ? "Keeping…" : "Run keeper now";
  actionEl.innerHTML = `<span class="status${running ? " run" : ""}" id="status" data-keeper-status>${running ? "" : "Tidies every inbox to only what needs you."}</span>
    <button class="btn btn-primary" id="run" ${running ? "disabled" : ""}>
      ${running ? `<span class="spinner"></span>` : runSvg()}<span>${label}</span></button>`;
  $("#run").onclick = runKeeper;
}

function setStatus(msg, run) {
  // Update the footer status and the tidying-state line together.
  document.querySelectorAll("[data-keeper-status]").forEach((s) => {
    s.textContent = msg;
    s.classList.toggle("run", !!run);
  });
}

/* ---------- render ---------- */
function render() {
  viewEl.innerHTML = (VIEWS[VIEW] || renderLoops)();
  viewEl.classList.remove("view-enter");
  void viewEl.offsetWidth;
  viewEl.classList.add("view-enter");
  renderAction();
  navEl.querySelectorAll(".seg").forEach((b) =>
    b.setAttribute("aria-selected", String(b.dataset.view === VIEW)));
  wireView();
}

function wireView() {
  viewEl.querySelectorAll(".row").forEach((row) => {
    const open = () => {
      const a = acctBySlug(row.dataset.slug);
      window.open(gmailUrl(a, row.dataset.thread), "_blank");
    };
    row.onclick = (e) => { if (!e.target.closest("[data-dismiss]")) open(); };
    row.onkeydown = (e) => {
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); open(); }
    };
  });
  viewEl.querySelectorAll("[data-dismiss]").forEach((btn) => {
    btn.onclick = (e) => { e.stopPropagation(); doDismiss(btn.closest(".row")); };
  });
  viewEl.querySelectorAll("[data-reply]").forEach((btn) => {
    btn.onclick = (e) => { e.stopPropagation(); openComposer(btn.closest(".row").dataset); };
  });
  viewEl.querySelectorAll("[data-restore]").forEach((btn) => {
    btn.onclick = () => doUndo(btn.dataset.slug, btn.dataset.label, btn);
  });
  const addBtn = $("[data-add-account]", viewEl);
  if (addBtn) addBtn.onclick = () => addAccount(addBtn);
}

async function addAccount(btn) {
  btn.disabled = true;
  btn.innerHTML = `<span class="spinner dark"></span> Opening your browser…`;
  const ok = await startJob("/api/add-account", {});
  if (!ok) { btn.disabled = false; btn.innerHTML = `<span class="plus">+</span> Add a Gmail account`; }
}

// Remove / re-insert a loop from the in-memory STATE so the count AND the list
// stay consistent across tab switches without waiting for a full rebuild.
function dropLoop(slug, threadId) {
  for (const a of STATE?.accounts || []) {
    if (a.slug !== slug) continue;
    const before = (a.loops || []).length;
    a.loops = (a.loops || []).filter((l) => l.thread_id !== threadId);
    if (a.loops.length < before) a.inbox_threads = Math.max(0, (a.inbox_threads || 1) - 1);
  }
  recomputeTotal();
}
function readdLoop(slug, loop) {
  for (const a of STATE?.accounts || []) {
    if (a.slug !== slug) continue;
    if (!(a.loops || []).some((l) => l.thread_id === loop.thread_id)) {
      a.loops = [loop, ...(a.loops || [])];
      a.inbox_threads = (a.inbox_threads || 0) + 1;
    }
  }
  recomputeTotal();
}
function recomputeTotal() {
  if (!STATE) return;
  STATE.total_loops = (STATE.accounts || [])
    .filter((a) => a.ok).reduce((s, a) => s + (a.inbox_threads || 0), 0);
}

async function doDismiss(row) {
  if (!row) return;
  const d = row.dataset;
  const loop = { thread_id: d.thread, sender: d.sender, sender_email: d.email,
                 subject: d.subject, snippet: d.snippet, epoch: Number(d.epoch || 0),
                 account_slug: d.slug };
  row.classList.add("removing");
  setTimeout(() => row.remove(), 180);
  dropLoop(d.slug, d.thread);                 // keep data + count in sync
  renderStrip();
  const c = $(".hero .count"); if (c) c.textContent = STATE.total_loops;
  const { ok, data } = await api("/api/dismiss", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ slug: d.slug, thread_id: d.thread, sender: d.sender,
      sender_email: d.email, subject: d.subject, snippet: d.snippet, epoch: loop.epoch }),
  });
  if (!ok) { toast("Couldn’t set aside"); loadState(); return; }
  toastUndo("Set aside", () => doRestoreThread(d, loop, data && data.label));
}

async function doRestoreThread(d, loop, label) {
  readdLoop(d.slug, loop);
  if (VIEW === "loops") render();
  renderStrip();
  await api("/api/dismiss", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ undo: true, slug: d.slug, thread_id: d.thread, label,
      sender: d.sender, sender_email: d.email, subject: d.subject,
      snippet: d.snippet, epoch: loop.epoch }),
  });
}

/* ---------- jobs ---------- */
async function startJob(path, body) {
  const { ok, status } = await api(path, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body || {}),
  });
  if (status === 409) { toast("A keeper run is already going"); return false; }
  if (!ok) { toast("Couldn’t start — check the server"); return false; }
  pollJob();
  return true;
}

function pollJob() {
  if (JOB_POLL) return;
  renderAction();
  JOB_POLL = setInterval(async () => {
    const { data } = await api("/api/job");
    if (!data) return;               // transient unreachable; keep polling
    if (data.message) setStatus(data.message, true);
    if (data.state === "done") {
      KEEPING = false;
      stopPoll();
      await loadState();
      // For a keeper run, show the real summary it produced ("Set aside N, M still need you").
      const msg = data.kind === "run" ? (data.message || "Inbox updated")
        : ({ add_account: "Account added", undo: "Restored", refresh: "Updated" }[data.kind] || "Done");
      toast(msg);
    } else if (data.state === "error") {
      KEEPING = false;
      stopPoll();
      const what = data.kind === "add_account" ? "Couldn’t add account" : "Run failed";
      toast(what + ": " + (data.error || "unknown"));
      await loadState();
    }
  }, 900);
}
function stopPoll() { clearInterval(JOB_POLL); JOB_POLL = null; renderAction(); }

async function runKeeper() {
  KEEPING = true;
  if (VIEW === "loops") render();   // show the tidying state immediately
  setStatus("Starting…", true);
  const ok = await startJob("/api/run", {});   // server default grace 0
  if (!ok) { KEEPING = false; if (VIEW === "loops") render(); }
}

async function doUndo(slug, label, btn) {
  btn.disabled = true; btn.textContent = "Restoring…";
  await startJob("/api/undo", { slug, label });
}

/* ---------- reply composer ---------- */
let COMPOSER = null;

function openComposer(d) {
  if (COMPOSER) return;  // one reply at a time; close the open one first
  COMPOSER = { slug: d.slug, thread: d.thread, sender: d.sender,
               subject: d.subject, to_email: d.email, original: "" };
  let el = $(".composer", panelEl);
  if (!el) { el = document.createElement("div"); el.className = "composer"; panelEl.appendChild(el); }
  el.innerHTML = `
    <div class="composer-head">
      <div>
        <div class="composer-to">Reply to ${esc(d.sender)}</div>
        <div class="composer-subj">${esc(d.subject)}</div>
      </div>
      <button class="composer-x" aria-label="Close">${xSvg()}</button>
    </div>
    <div class="composer-body">
      <div class="composer-loading"><span class="spinner dark"></span> Drafting in your voice…</div>
      <div class="composer-editor" hidden>
        <div class="composer-toolbar" role="toolbar" aria-label="Formatting">
          <button class="fmt" data-cmd="bold" title="Bold (⌘B)" aria-label="Bold"><b>B</b></button>
          <button class="fmt" data-cmd="italic" title="Italic (⌘I)" aria-label="Italic"><i>I</i></button>
          <span class="fmt-sep"></span>
          <button class="fmt" data-cmd="insertUnorderedList" title="Bulleted list" aria-label="Bulleted list">${listSvg()}</button>
          <button class="fmt" data-cmd="createLink" title="Add link" aria-label="Add link">${linkSvg()}</button>
        </div>
        <div class="composer-text" contenteditable="true" role="textbox" aria-multiline="true" aria-label="Reply" spellcheck="true"></div>
      </div>
    </div>
    <div class="composer-foot">
      <button class="btn btn-ghost" data-c-regen disabled>${runSvg()}<span>Regenerate</span></button>
      <button class="btn btn-primary" data-c-send disabled>Send reply</button>
    </div>`;
  requestAnimationFrame(() => el.classList.add("show"));
  $(".composer-x", el).onclick = closeComposer;
  $("[data-c-regen]", el).onclick = () => generateDraft(true);
  $("[data-c-send]", el).onclick = sendDraft;
  el.querySelectorAll(".fmt").forEach((b) => {
    // mousedown (not click) so the editor keeps its selection while we format.
    b.onmousedown = (e) => {
      e.preventDefault();
      const cmd = b.dataset.cmd;
      if (cmd === "createLink") {
        let url = (prompt("Link URL:") || "").trim();
        if (!url) return;
        if (!/^(https?:|mailto:)/i.test(url)) url = "https://" + url;
        if (!document.execCommand("createLink", false, url)) toast("Select the text to link first");
      } else if (!document.execCommand(cmd, false, null)) {
        toast("Couldn’t apply that here");
      }
      syncFmtState(el);
    };
  });
  generateDraft(false);
}

function syncFmtState(el) {
  el.querySelectorAll(".fmt[data-cmd]").forEach((b) => {
    try { b.classList.toggle("on", document.queryCommandState(b.dataset.cmd)); }
    catch (e) { /* createLink has no state */ }
  });
}

// Plain draft text -> simple HTML (paragraphs + line breaks) for the editor.
function textToHtml(t) {
  return esc(t).split(/\n\n+/).map((p) => `<p>${p.replace(/\n/g, "<br>")}</p>`).join("");
}

// Structure-aware plain-text from the rich editor (keeps link URLs + list markers,
// unlike innerText which drops hrefs and is layout-dependent).
function editorText(el) {
  const walk = (node) => {
    let out = "";
    node.childNodes.forEach((n) => {
      if (n.nodeType === 3) { out += n.nodeValue; return; }
      if (n.nodeType !== 1) return;
      const tag = n.tagName.toLowerCase();
      if (tag === "br") out += "\n";
      else if (tag === "a") {
        const t = n.textContent, h = n.getAttribute("href") || "";
        out += (h && h !== t) ? `${t} (${h})` : t;
      } else if (tag === "li") out += "- " + walk(n) + "\n";
      else if (["p", "div", "ul", "ol"].includes(tag)) out += walk(n) + "\n";
      else out += walk(n);
    });
    return out;
  };
  return walk(el).replace(/\n{3,}/g, "\n\n").trim();
}

function closeComposer() {
  const el = $(".composer", panelEl);
  if (el) { el.classList.remove("show"); setTimeout(() => el.remove(), 200); }
  COMPOSER = null;
}

async function generateDraft(isRegen) {
  const el = $(".composer", panelEl);
  if (!el || !COMPOSER) return;
  const editor = $(".composer-editor", el), ta = $(".composer-text", el);
  const load = $(".composer-loading", el);
  const send = $("[data-c-send]", el), regen = $("[data-c-regen]", el);
  editor.hidden = true; load.hidden = false; send.disabled = true; regen.disabled = true;
  const steer = isRegen ? (prompt("Adjust the draft (e.g. ‘shorter’, ‘warmer’, ‘decline politely’):") || "") : "";
  const { ok, data, aborted } = await api("/api/draft", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ slug: COMPOSER.slug, thread_id: COMPOSER.thread, steer }),
  }, 135000);
  load.hidden = true;
  if (!ok || !data || !data.body) {
    toast(aborted ? "Drafting took too long, try Regenerate"
          : (apiErr(data) ? "Couldn’t draft: " + apiErr(data) : "Couldn’t draft a reply"));
    // Leave the composer open and usable: write or Regenerate.
    if (!ta.innerHTML) ta.innerHTML = "";
    editor.hidden = false; send.disabled = false; regen.disabled = false;
    return;
  }
  COMPOSER.original = data.body;
  COMPOSER.to_email = data.to_email || COMPOSER.to_email;
  COMPOSER.subject = data.subject || COMPOSER.subject;
  ta.innerHTML = textToHtml(data.body);
  editor.hidden = false; ta.focus();
  send.disabled = false; regen.disabled = false;
}

async function sendDraft() {
  const el = $(".composer", panelEl);
  if (!el || !COMPOSER) return;
  const ta = $(".composer-text", el), send = $("[data-c-send]", el);
  if (send.disabled) return;                 // guard against double-fire
  const text = editorText(ta);
  const html = ta.innerHTML;
  if (!text) { toast("Write a reply first"); return; }
  send.disabled = true; send.textContent = "Sending…";
  const { ok, data, aborted } = await api("/api/draft/send", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ slug: COMPOSER.slug, thread_id: COMPOSER.thread,
      to_email: COMPOSER.to_email, subject: COMPOSER.subject,
      body: text, html, original: COMPOSER.original }),
  }, 60000);
  if (!ok) {
    toast(aborted ? "Send timed out, check Gmail before retrying"
          : (apiErr(data) ? "Couldn’t send: " + apiErr(data) : "Couldn’t send"));
    send.disabled = false; send.textContent = "Send reply"; return;
  }
  dropLoop(COMPOSER.slug, COMPOSER.thread);
  closeComposer();
  if (VIEW === "loops") render();
  renderStrip();
  toast("Reply sent");
}

function xSvg() {
  return `<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>`;
}
function listSvg() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 6h13M8 12h13M8 18h13"/><circle cx="3.5" cy="6" r="1"/><circle cx="3.5" cy="12" r="1"/><circle cx="3.5" cy="18" r="1"/></svg>`;
}
function linkSvg() {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1"/><path d="M14 11a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1"/></svg>`;
}

async function savePolicy() {
  const text = $("#policy-edit").value;
  const btn = $("#policy-save");
  btn.disabled = true; btn.textContent = "Saving…";
  const { ok } = await api("/api/policy", {
    method: "PUT", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ policy: text }),
  });
  btn.disabled = false; btn.textContent = "Save policy";
  toast(ok ? "Policy saved" : "Couldn’t save policy");
  if (ok && STATE) STATE.policy = text;
}

/* ---------- nav ---------- */
navEl.addEventListener("click", (e) => {
  const seg = e.target.closest(".seg");
  if (!seg) return;
  VIEW = seg.dataset.view;
  history.replaceState(null, "", "#" + VIEW);
  render();
  viewEl.scrollTop = 0;
});

/* ---------- boot ---------- */
loadState();
// If state was missing on boot, the server builds it; refetch shortly after.
setTimeout(() => { if (!STATE || STATE.needs_build) loadState(); }, 2500);
