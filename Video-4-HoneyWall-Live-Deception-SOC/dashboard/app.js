// filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/dashboard/app.js
// HoneyWall dashboard - vanilla JS, no external libraries, live data over Server-Sent Events.
(() => {
  "use strict";

  const $ = (s) => document.querySelector(s);
  const NS = "http://www.w3.org/2000/svg";
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const fmtTime = (iso) => { try { return new Date(iso).toLocaleTimeString([], { hour12: false }); } catch { return ""; } };

  // ------------------------------------------------------------------ preferences
  const store = {
    get(k, d) { try { const v = localStorage.getItem("hw_" + k); return v === null ? d : JSON.parse(v); } catch { return d; } },
    set(k, v) { try { localStorage.setItem("hw_" + k, JSON.stringify(v)); } catch { /* storage unavailable */ } },
  };
  const qs = new URLSearchParams(location.search);
  let token = qs.get("token") || store.get("token", "");
  if (qs.get("token")) store.set("token", token);
  // saved = what the viewer chose on this PC (wins); cur = what is applied right now
  const saved = { theme: store.get("theme", null), sound: store.get("sound", null), flash: store.get("flash", null), layout: store.get("layout", null) };
  const prefs = { theme: "hollywood", sound: true, flash: true, layout: "full" };

  // ------------------------------------------------------------------ state
  let CFG = {};
  const S = { attackers: {}, events: [], bans: [], reports: [], scoreboard: [], sessions: [], leaderboard: { passwords: [], usernames: [] }, fgt: {}, settings: {} };
  let focusIp = null;
  let sideTab = "reports";

  const api = async (path, opts = {}) => {
    const headers = { "Content-Type": "application/json", ...(token ? { "X-HoneyWall-Token": token } : {}) };
    const r = await fetch(path, { ...opts, headers });
    if (!r.ok) throw new Error((await r.text()).slice(0, 200) || r.statusText);
    return r.headers.get("content-type")?.includes("json") ? r.json() : r.text();
  };

  // ------------------------------------------------------------------ topology + honeycomb wall
  const topo = $("#topo");
  const T = {};
  const svg = (tag, attrs = {}, parent = topo) => {
    const el = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
    parent.appendChild(el);
    return el;
  };
  const hexPath = (cx, cy, r) => {
    const p = [];
    for (let i = 0; i < 6; i++) { const a = Math.PI / 180 * (60 * i - 30); p.push(`${(cx + r * Math.cos(a)).toFixed(1)},${(cy + r * Math.sin(a)).toFixed(1)}`); }
    return "M" + p.join("L") + "Z";
  };

  function node(id, x, y, cls, name, ip, role) {
    const g = svg("g", { class: "node " + cls, transform: `translate(${x - 95},${y - 55})` });
    svg("rect", { width: 190, height: 110 }, g);
    T[id + "Name"] = svg("text", { class: "name", x: 95, y: 36, "text-anchor": "middle" }, g);
    T[id + "Name"].textContent = name;
    T[id + "Ip"] = svg("text", { class: "ip", x: 95, y: 62, "text-anchor": "middle" }, g);
    T[id + "Ip"].textContent = ip;
    T[id + "Role"] = svg("text", { class: "role", x: 95, y: 86, "text-anchor": "middle" }, g);
    T[id + "Role"].textContent = role;
    return g;
  }

  function buildTopo() {
    topo.innerHTML = "";
    const y = 120;
    T.linkA = svg("path", { class: "link", d: `M215 ${y} L375 ${y}` });
    T.linkB = svg("path", { class: "link", d: `M565 ${y} L765 ${y}` });
    T.linkApi = svg("path", { class: "link api", d: "M770 256 C 640 285, 520 262, 478 176" });
    T.pathFull = svg("path", { d: `M215 ${y} L765 ${y}`, fill: "none", stroke: "none" });
    svg("text", { class: "label", x: 300, y: 24, "text-anchor": "middle" }).textContent = CFG.web_enabled ? `ssh :${CFG.decoy_vip_port || 22} · http :${CFG.web_vip_port || 80}` : `ssh :${CFG.decoy_vip_port || 22}`;
    svg("text", { class: "label", x: 665, y: y - 12, "text-anchor": "middle" }).textContent = CFG.web_enabled ? "DNAT → :2222 · :8088" : "DNAT → :2222";
    svg("text", { class: "label api", x: 610, y: 294, "text-anchor": "middle" }).textContent = "REST ban + read-back · https :443";

    T.kali = node("kali", 120, y, "attacker", "Attacker", CFG.kali_ip || "192.168.40.3", "Kali · VLAN 40");
    T.fgt = node("fgt", 470, y, "fgt", "FortiGate", `VIP ${CFG.decoy_vip_ip || "192.168.40.1"}:${CFG.decoy_vip_port || 22}`, "FortiOS");
    T.decoy = node("decoy", 860, y, "decoy", CFG.decoy_hostname || "srv-corp-ssh01", `${CFG.alpine_ip || "192.168.10.2"}:2222`, CFG.web_enabled ? "ssh + web · VLAN 10" : "Cowrie decoy · VLAN 10");
    const eg = svg("g", { class: "node", transform: "translate(770,230)" });
    svg("rect", { width: 190, height: 52 }, eg);
    const en = svg("text", { class: "name", x: 95, y: 22, "text-anchor": "middle" }, eg); en.textContent = "HoneyWall engine";
    const ei = svg("text", { class: "ip", x: 95, y: 41, "text-anchor": "middle" }, eg); ei.textContent = "reads every keystroke";

    // the wall: a 3-column honeycomb standing on the attacker link, right in front of the FortiGate
    T.hexes = [];
    const r = 13, dx = r * 1.732, dy = r * 1.5;
    for (let col = 0; col < 3; col++) {
      for (let row = 0; row < 8; row++) {
        const cx = 300 + col * dx + (row % 2 ? dx / 2 : 0);
        const cy = y - 3.5 * dy + row * dy;
        T.hexes.push(svg("path", { class: "hex", d: hexPath(cx, cy, r - 1.5) }));
      }
    }
    T.hexes.sort(() => Math.random() - 0.5);
    T.wallLabel = svg("text", { class: "wall-label", x: 328, y: y + 96, "text-anchor": "middle" });
    T.wallLabel.textContent = "HoneyWall open";
    T.packets = svg("g", {});
    applyWall(false, true);
  }

  function applyWall(sealed, instant = false) {
    if (!T.hexes) return;
    T.hexes.forEach((h, i) => {
      const go = () => h.classList.toggle("sealed", sealed);
      instant ? go() : setTimeout(go, (sealed ? i : T.hexes.length - i) * 22);
    });
    T.linkA.classList.toggle("cut", sealed);
    T.kali.classList.toggle("banned", sealed);
    T.wallLabel.classList.toggle("sealed", sealed);
    T.wallLabel.textContent = sealed ? `Sealed — ${focusIp || CFG.kali_ip || ""} banned` : "HoneyWall open";
  }

  const KIND_COLOR = { web_request: "var(--ctl)", web_login_failed: "var(--warn)", web_honeytoken: "var(--bad)", connect: "var(--ctl)", client: "var(--ctl)", recon: "var(--warn)", login_failed: "var(--warn)", login_success: "var(--bad)", command: "var(--ok)", download: "var(--bad)", closed: "var(--ink-dim)" };

  function packet(kind, blocked, hot) {
    if (!T.pathFull || document.hidden) return;
    const len = T.pathFull.getTotalLength();
    const stop = blocked ? 68 : len;
    const c = svg("circle", { class: "packet", r: 5, fill: hot ? "var(--bad)" : (KIND_COLOR[kind] || "var(--ok)") }, T.packets);
    const t0 = performance.now(), dur = blocked ? 380 : 900;
    const step = (now) => {
      const k = Math.min(1, (now - t0) / dur);
      const p = T.pathFull.getPointAtLength(stop * k);
      c.setAttribute("cx", p.x); c.setAttribute("cy", p.y);
      if (k < 1) return requestAnimationFrame(step);
      if (blocked) { c.setAttribute("r", 11); c.setAttribute("fill", "var(--bad)"); c.style.opacity = "0.4"; setTimeout(() => c.remove(), 220); }
      else c.remove();
    };
    requestAnimationFrame(step);
    if (blocked) T.hexes.slice(0, 4).forEach((h) => { h.classList.add("pulse"); setTimeout(() => h.classList.remove("pulse"), 300); });
  }

  // ------------------------------------------------------------------ clock + gauge + scoreboard
  const clock = $("#clock");
  let clockRaf = null, clockStart = 0;
  const showClock = (sec, cls) => {
    clock.className = "clock " + (cls || "");
    clock.innerHTML = `${sec.toFixed(3)}<span class="unit">s</span>`;
  };
  function startClock(reason) {
    cancelAnimationFrame(clockRaf);
    clockStart = performance.now();
    $("#clock-sub").textContent = reason;
    const tick = () => { showClock((performance.now() - clockStart) / 1000, "running"); clockRaf = requestAnimationFrame(tick); };
    tick();
  }
  function stopClock(ms, text) {
    cancelAnimationFrame(clockRaf);
    showClock(ms / 1000, "done");
    $("#clock-sub").textContent = text;
  }

  function gauge(score) {
    const L = Math.PI * 80;
    const f = $("#gauge-fill");
    f.setAttribute("stroke-dasharray", L.toFixed(1));
    f.setAttribute("stroke-dashoffset", (L * (1 - Math.min(100, score) / 100)).toFixed(1));
    f.setAttribute("stroke", score >= 100 ? "var(--bad)" : score >= 50 ? "var(--warn)" : "var(--ok)");
    $("#gauge-val").textContent = Math.round(score);
  }

  const RULE_NAME = { brute_force: "Brute force", honeytoken: "Honeytoken", web: "Web decoy", manual: "Manual", external: "External" };
  function renderScoreboard() {
    const rows = S.scoreboard.slice(-6).reverse();
    $("#scoreboard").innerHTML = rows.length
      ? `<table>${rows.map((r) => `<tr><td>${esc(RULE_NAME[r.rule] || r.rule)}</td><td>${esc(r.ip)}</td><td class="ms">${(r.ttq_ms / 1000).toFixed(3)} s</td></tr>`).join("")}</table>`
      : `<p class="empty">Each quarantine lands here with its time.</p>`;
  }

  // ------------------------------------------------------------------ terminal
  const term = $("#term");
  const termQ = [];
  let termBusy = false;
  const host = () => CFG.decoy_hostname || "srv-corp-ssh01";

  function termLineNow(html, cls = "") { return termLine(html, cls); }
  function termLine(html, cls = "") {
    const d = document.createElement("div");
    d.className = "ln " + cls;
    d.innerHTML = html;
    term.appendChild(d);
    while (term.children.length > 400) term.firstChild.remove();
    term.scrollTop = term.scrollHeight;
    return d;
  }
  function termType(prefixHtml, text, cls, after) {
    termQ.push({ prefixHtml, text, cls, after });
    if (!termBusy) drainTerm();
  }
  // plain lines wait their turn behind any command that is still being typed
  function termPush(html, cls = "") {
    if (!termBusy && !termQ.length) return termLine(html, cls);
    termQ.push({ plain: true, html, cls });
    if (!termBusy) drainTerm();
  }
  async function drainTerm() {
    termBusy = true;
    while (termQ.length) {
      const job = termQ.shift();
      if (job.plain) { termLine(job.html, job.cls); continue; }
      const { prefixHtml, text, cls, after } = job;
      const d = termLine(prefixHtml, cls);
      const span = document.createElement("span");
      const caret = document.createElement("span");
      caret.className = "caret"; caret.innerHTML = "&nbsp;";
      d.append(span, caret);
      const perChar = Math.max(6, Math.min(22, 500 / Math.max(1, text.length)));
      for (const ch of text) { span.textContent += ch; await new Promise((r) => setTimeout(r, perChar)); }
      caret.remove();
      if (after) after(d, span);
      term.scrollTop = term.scrollHeight;
    }
    termBusy = false;
  }

  // Hydra opens a new TCP connection per attempt; only show the first one of a burst
  const lastConnect = {};
  function quietConnect(e) {
    const t = Date.parse(e.ts) || Date.now();
    const prev = lastConnect[e.src_ip] || 0;
    lastConnect[e.src_ip] = t;
    return t - prev < 8000;
  }

  function termEvent(e, live = true) {
    const ip = esc(e.src_ip);
    const termLine = live ? termPush : termLineNow;
    switch (e.kind) {
      case "connect": if (!e._quiet) termLine(`── ${ip} opened a connection to ${esc(host())} ──`, "sys"); break;
      case "recon": termLine(`▲ ${esc(e.summary)}`, "fail"); break;
      case "login_failed":
        termLine(`<span class="sys">login as:</span> ${esc(e.detail.username)}   <span class="sys">password:</span> <span class="fail">${esc(e.detail.password)}</span>   <span class="fail">✗ access denied</span>`);
        break;
      case "login_success":
        termLine(`<span class="sys">login as:</span> ${esc(e.detail.username)}   <span class="sys">password:</span> ${esc(e.detail.password)}   <span class="succ">✓ authenticated</span>`);
        termLine(`Linux ${esc(host())} 6.1.0-28-amd64 #1 SMP PREEMPT_DYNAMIC Debian x86_64`, "sys");
        break;
      case "command": {
        const user = esc(e.detail.user || "user");
        const prefix = `<span class="prompt">${user}@${esc(host())}:~$</span> `;
        const tok = e.detail.honeytoken;
        const after = (d, span) => {
          if (tok) { span.innerHTML = esc(e.detail.input).replace(esc(tok.split("/").pop()), (m) => `<span class="tok">${m}</span>`); termLineNow(`▲ honeytoken touched: ${esc(tok)}`, "sev"); }
          else if (e.detail.risk?.length) span.classList.add("fail");
        };
        if (live) termType(prefix, e.detail.input, "", after);
        else { const d = termLineNow(prefix); const sp = document.createElement("span"); sp.textContent = e.detail.input; d.appendChild(sp); after(d, sp); }
        break;
      }
      case "download": termLine(`▲ ${esc(e.summary)}`, "sev"); break;
      case "web_request": {
        const st = e.detail.status;
        termLine(`<span class="sys">http ›</span> ${esc(e.detail.method)} ${esc(e.detail.path)} <span class="${st >= 400 ? "fail" : "sys"}">${esc(st)}</span>${e.detail.scanner ? ` <span class="fail">${esc(e.detail.scanner)}</span>` : ""}`);
        break;
      }
      case "web_login_failed":
        termLine(`<span class="sys">http › web login:</span> ${esc(e.detail.username)}   <span class="sys">password:</span> <span class="fail">${esc(e.detail.password)}</span>   <span class="fail">✗ invalid</span>`);
        break;
      case "web_honeytoken":
        termLine(`<span class="sys">http ›</span> GET <span class="tok">${esc(e.detail.path)}</span>`);
        termLine(`▲ honeytoken downloaded over HTTP: ${esc(e.detail.path)}`, "sev");
        break;
      default: break;
    }
  }

  // ------------------------------------------------------------------ credentials
  function credChip(c) {
    const el = document.createElement("span");
    el.className = "cred" + (c.ok ? " ok" : "") + (c.proto === "web" ? " web" : "");
    if (c.proto === "web") el.title = "Web decoy login";
    el.textContent = `${c.username}:${c.password}`;
    const wall = $("#wall");
    wall.prepend(el);
    while (wall.children.length > 140) wall.lastChild.remove();
  }
  function renderLeader() {
    const top = (S.leaderboard.passwords || []).slice(0, 5);
    const max = Math.max(1, ...top.map((x) => x[1]));
    $("#leader").innerHTML = top.length
      ? top.map(([p, n]) => `<div class="row"><span title="${esc(p)}">${esc(p)}</span><div class="bar" style="width:${(n / max) * 100}%"></div><span class="n">${n}</span></div>`).join("")
      : "";
    const total = (S.leaderboard.passwords_total ?? (S.leaderboard.passwords || []).reduce((n, x) => n + x[1], 0));
    $("#cred-hint").textContent = `${total} tried`;
  }

  // ------------------------------------------------------------------ bans
  function renderBans() {
    const el = $("#bans");
    $("#bans-hint").textContent = S.fgt.simulate ? "simulated FortiGate" : "live from FortiGate REST API";
    if (!S.bans.length) { el.innerHTML = `<p class="empty-state">No banned IPs. The wall is open.</p>`; return; }
    el.innerHTML = S.bans.map((b) => `
      <div class="ban">
        <span class="ip">${esc(b.ip)}</span>
        <button data-unban="${esc(b.ip)}">Unban</button>
        <span class="why">${esc(b.reason || "Banned on FortiGate")}</span>
        <span class="meta">${b.ttq_ms != null ? `quarantined in ${(b.ttq_ms / 1000).toFixed(3)} s · ` : ""}since ${b.created ? new Date(b.created * 1000).toLocaleTimeString([], { hour12: false }) : "—"} · ${b.expires ? "expires " + new Date(b.expires * 1000).toLocaleTimeString() : "until unbanned"}${b.source ? " · " + esc(b.source) : ""}</span>
      </div>`).join("");
  }

  // ------------------------------------------------------------------ timeline
  function evRow(e) {
    const d = document.createElement("div");
    d.className = `ev ${e.severity || ""} ${e.post_ban ? "post" : ""} ${e.sys ? "sys" : ""}`;
    const chips = (e.mitre || []).map((m) => `<span class="chip ${m.id === "T1552.001" || m.id === "T1110.001" ? "hot" : ""}" title="${esc(m.name)}">${esc(m.id)}</span>`).join("");
    d.innerHTML = `<span class="t">${fmtTime(e.ts)}</span><span class="s" title="${esc(e.summary)}">${esc(e.summary)}</span><span class="chips">${chips}</span>`;
    return d;
  }
  function addTimeline(e) {
    if (e._quiet) return;
    const tl = $("#timeline");
    tl.prepend(evRow(e));
    while (tl.children.length > 250) tl.lastChild.remove();
  }
  const sysEvent = (summary, severity = "") => addTimeline({ ts: new Date().toISOString(), summary, severity, sys: !severity, mitre: [] });

  // ------------------------------------------------------------------ reports + replay side panel
  function renderSide() {
    $("#tab-reports").setAttribute("aria-pressed", sideTab === "reports");
    $("#tab-replay").setAttribute("aria-pressed", sideTab === "replay");
    $("#side-title").textContent = sideTab === "reports" ? "Incident reports" : "Session replay";
    const el = $("#side");
    if (sideTab === "reports") {
      const list = S.reports.slice().reverse();
      el.innerHTML = list.length ? list.map((r) => `
        <div class="item">
          <span>${esc(r.ip)} <span class="badge ${r.status === "generating" ? "gen" : r.source === "llm" ? "ai" : ""}">${r.status === "generating" ? "AI writing…" : r.source === "llm" ? "AI" : "template"}</span></span>
          <button data-report="${esc(r.id)}" ${r.status === "generating" ? "disabled" : ""}>Read</button>
          <span class="sub">${esc(r.rule || "")} · ${fmtTime(r.created)}</span>
        </div>`).join("") : `<p class="empty-state">Reports appear here a few seconds after each quarantine.</p>`;
    } else {
      const list = S.sessions.filter((s) => s.logins > 0 || s.commands > 0).slice().reverse();
      el.innerHTML = list.length ? list.map((s) => `
        <div class="item">
          <span>${esc(s.user || "unknown")} from ${esc(s.ip)}</span>
          <button data-replay="${esc(s.session)}">Play</button>
          <span class="sub">${s.commands} command(s) · ${fmtTime(s.start)}</span>
        </div>`).join("") : `<p class="empty-state">Sessions with a login show up here for replay.</p>`;
    }
  }

  function md(src) {
    const lines = String(src).split(/\r?\n/);
    let html = "", inList = false;
    const inline = (t) => esc(t).replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>").replace(/(^|\s)_([^_]+)_(?=\s|$|[.,])/g, "$1<i>$2</i>");
    for (const raw of lines) {
      const l = raw.trimEnd();
      const li = l.match(/^\s*[-*]\s+(.*)/);
      if (li) { if (!inList) { html += "<ul>"; inList = true; } html += `<li>${inline(li[1])}</li>`; continue; }
      if (inList) { html += "</ul>"; inList = false; }
      const h = l.match(/^(#{1,3})\s+(.*)/);
      if (h) html += `<h${h[1].length}>${inline(h[2])}</h${h[1].length}>`;
      else if (l.trim()) html += `<p>${inline(l)}</p>`;
    }
    return html + (inList ? "</ul>" : "");
  }

  const modal = $("#modal");
  let replayTimer = null;
  function openModal(title, contentHtml, actionsHtml = "") {
    $("#modal-title").textContent = title;
    $("#modal-content").innerHTML = contentHtml;
    $("#modal-actions").innerHTML = actionsHtml;
    modal.classList.add("open");
    $("#modal-close").focus();
  }
  function closeModal() {
    modal.classList.remove("open");
    clearTimeout(replayTimer);
    if (location.hash.startsWith("#report-")) history.replaceState(null, "", location.pathname + location.search);
  }

  async function openReport(id) {
    try {
      const r = await api(`/api/reports/${encodeURIComponent(id)}`);
      const dl = `/api/reports/${encodeURIComponent(id)}.md${token ? "?token=" + encodeURIComponent(token) : ""}`;
      openModal(`Incident report · ${r.ip}`, `<div class="md">${md(r.markdown)}</div>`,
        `<span class="badge ${r.source === "llm" ? "ai" : ""}">${r.source === "llm" ? `AI · ${r.latency_ms} ms` : "template"}</span><a href="${dl}" download><button>Download .md</button></a>`);
      history.replaceState(null, "", "#report-" + id);
    } catch (e) { toast("warn", "Report not found", e.message); }
  }

  async function openReplay(sess) {
    let data;
    try { data = await api(`/api/replay/${encodeURIComponent(sess)}`); } catch (e) { return toast("warn", "Replay failed", e.message); }
    openModal(`Session replay · ${sess}`, `<div class="replay" id="replay"></div>`,
      `<span class="badge">${data.source === "tty" ? "TTY recording" : "command log"}</span><button id="rp-speed">Speed 1×</button><button id="rp-restart">Restart</button>`);
    const out = $("#replay");
    let speed = 1;
    const strip = (s) => s.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/\x1b[()][0-9A-Za-z]/g, "");
    const write = (s) => {
      for (const ch of strip(s)) {
        if (ch === "\b" || ch === "\x7f") out.textContent = out.textContent.slice(0, -1);
        else if (ch !== "\r") out.textContent += ch;
      }
      out.scrollTop = out.scrollHeight;
    };
    const play = () => {
      clearTimeout(replayTimer);
      out.textContent = "";
      let i = 0;
      const next = () => {
        if (i >= data.frames.length) { write("\n── end of recording ──\n"); return; }
        const f = data.frames[i++];
        write(f.d);
        const gap = i < data.frames.length ? Math.min(2.5, data.frames[i].t - f.t) : 0;
        replayTimer = setTimeout(next, (gap * 1000) / speed);
      };
      if (!data.frames.length) write("No keystrokes were recorded for this session yet.\n");
      else next();
    };
    $("#rp-speed").onclick = (ev) => { speed = speed === 1 ? 4 : speed === 4 ? 10 : 1; ev.target.textContent = `Speed ${speed}×`; };
    $("#rp-restart").onclick = play;
    play();
  }

  // ------------------------------------------------------------------ the quarantine moment
  let audio = null;
  function ensureAudio() {
    if (!audio) { try { audio = new (window.AudioContext || window.webkitAudioContext)(); } catch { audio = null; } }
    if (audio && audio.state === "suspended") audio.resume();
    $("#arm").hidden = !(prefs.sound && (!audio || audio.state !== "running"));
  }
  function siren() {
    if (!prefs.sound || !audio || audio.state !== "running") return;
    const now = audio.currentTime;
    const out = audio.createGain(); out.gain.value = 0.18; out.connect(audio.destination);
    const thunk = audio.createOscillator(); const tg = audio.createGain();
    thunk.type = "square"; thunk.frequency.setValueAtTime(110, now); thunk.frequency.exponentialRampToValueAtTime(40, now + 0.25);
    tg.gain.setValueAtTime(0.9, now); tg.gain.exponentialRampToValueAtTime(0.001, now + 0.3);
    thunk.connect(tg).connect(out); thunk.start(now); thunk.stop(now + 0.32);
    const o = audio.createOscillator(); const g = audio.createGain();
    o.type = "sawtooth";
    for (let i = 0; i < 3; i++) { o.frequency.setValueAtTime(620, now + 0.3 + i * 0.6); o.frequency.linearRampToValueAtTime(1150, now + 0.6 + i * 0.6); }
    g.gain.setValueAtTime(0.0001, now + 0.28); g.gain.exponentialRampToValueAtTime(0.6, now + 0.35); g.gain.setValueAtTime(0.6, now + 1.95); g.gain.exponentialRampToValueAtTime(0.001, now + 2.2);
    o.connect(g).connect(out); o.start(now + 0.28); o.stop(now + 2.25);
  }
  function flash(ip, ms) {
    if (!prefs.flash) return;
    $("#flash-what").textContent = `${ip} · banned on FortiGate in ${(ms / 1000).toFixed(3)} s`;
    const f = $("#flash");
    f.classList.remove("on"); void f.offsetWidth; f.classList.add("on");
    setTimeout(() => f.classList.remove("on"), 3000);
  }

  // ------------------------------------------------------------------ toasts + live indicator
  function toast(level, title, text = "") {
    const t = document.createElement("div");
    t.className = "toast " + level;
    t.innerHTML = `<b>${esc(title)}</b>${text ? `<span>${esc(text)}</span>` : ""}`;
    $("#toasts").appendChild(t);
    setTimeout(() => t.remove(), level === "crit" ? 9000 : 5500);
  }
  function renderLive(engineUp = true) {
    const el = $("#live"), txt = $("#live-text"), f = S.fgt || {};
    el.className = "live";
    if (!engineUp) { el.classList.add("off"); txt.textContent = "Engine offline — reconnecting…"; return; }
    if (f.simulate) { el.classList.add("sim"); txt.textContent = "Simulation mode — FortiGate is simulated"; }
    else if (f.online) { el.classList.add("on"); txt.textContent = `Live from FortiGate ${f.hostname || ""} · ${f.version || ""} · ${f.latency_ms ?? "?"} ms`; }
    else { el.classList.add("off"); txt.textContent = `FortiGate unreachable: ${f.error || "checking…"}`; }
    if (T.fgtRole) T.fgtRole.textContent = f.version ? `FortiOS ${String(f.version).replace(/^v/, "")}` : "FortiOS";
  }

  // ------------------------------------------------------------------ apply attacker focus
  function applyAttacker(a) {
    if (!a) return;
    S.attackers[a.ip] = a;
    focusIp = a.ip;
    gauge(a.score);
    if (T.kaliIp) T.kaliIp.textContent = a.ip;
    $("#term-hint").textContent = `${a.ip} · ${a.status}`;
  }

  // ------------------------------------------------------------------ full render from snapshot
  function fromSnapshot(snap) {
    CFG = snap.config || CFG;
    Object.assign(S, {
      attackers: Object.fromEntries((snap.attackers || []).map((a) => [a.ip, a])),
      events: snap.events || [], bans: snap.bans || [], reports: snap.reports || [],
      scoreboard: snap.scoreboard || [], sessions: snap.sessions || [], leaderboard: snap.leaderboard || S.leaderboard,
      fgt: snap.fgt || {}, settings: snap.settings || {},
    });
    $("#title").textContent = CFG.title || "HoneyWall";
    setTheme(saved.theme ?? CFG.theme ?? "hollywood", false);
    setSound(saved.sound ?? !!CFG.sound, false);
    setFlash(saved.flash ?? !!CFG.flash, false);
    setLayout(saved.layout ?? CFG.layout ?? "full", false);
    buildTopo();
    termQ.length = 0; term.innerHTML = ""; $("#wall").innerHTML = ""; $("#timeline").innerHTML = "";
    termLine(`HoneyWall is watching ${esc(CFG.decoy_hostname)} (ssh ${esc(CFG.decoy_vip_ip)}:${esc(CFG.decoy_vip_port)}${CFG.web_enabled ? `, web :${esc(CFG.web_vip_port)}` : ""}). Rules: ${esc(CFG.brute_threshold)} failed logins in ${esc(CFG.brute_window)} s, or any honeytoken.`, "sys");
    for (const k in lastConnect) delete lastConnect[k];
    for (const e of S.events) { if (e.kind === "connect") e._quiet = quietConnect(e); termEvent(e, false); addTimeline(e); if (e.kind === "login_failed" || e.kind === "login_success" || e.kind === "web_login_failed") credChip({ ...e.detail, ok: e.kind === "login_success" }); }
    const atk = Object.values(S.attackers).sort((x, y) => (x.last_seen < y.last_seen ? 1 : -1))[0];
    if (atk) applyAttacker(atk); else gauge(0);
    const banned = S.bans.some((b) => b.ip === (focusIp || CFG.kali_ip));
    applyWall(banned, true);
    const last = S.scoreboard[S.scoreboard.length - 1];
    if (last) stopClock(last.ttq_ms, `${RULE_NAME[last.rule] || last.rule} · ${last.ip}`);
    $("#btn-llm").setAttribute("aria-pressed", !!S.settings.llm_enabled);
    $("#btn-llm").title = CFG.llm_configured ? `AI incident reports via ${CFG.llm_mode} (${CFG.llm_model})` : "Set LLM_BASE_URL in .env to enable AI reports";
    renderScoreboard(); renderLeader(); renderBans(); renderSide(); renderLive(true);
  }

  // ------------------------------------------------------------------ live stream
  let es = null;
  function connect() {
    es = new EventSource("/api/stream" + (token ? "?token=" + encodeURIComponent(token) : ""));
    const on = (name, fn) => es.addEventListener(name, (m) => { try { fn(JSON.parse(m.data)); } catch (err) { console.error(name, err); } });
    on("snapshot", fromSnapshot);
    on("reset", (snap) => { fromSnapshot(snap); showClock(0, ""); $("#clock-sub").textContent = "Board cleared. Armed for the next take."; toast("ok", "Board cleared", "Bans and reports were kept"); });
    on("event", ({ event: e, attacker, session, leaderboard }) => {
      if (e.kind === "connect") e._quiet = quietConnect(e);
      S.events.push(e);
      applyAttacker(attacker);
      if (session) { const i = S.sessions.findIndex((s) => s.session === session.session); i >= 0 ? (S.sessions[i] = session) : S.sessions.push(session); }
      if (leaderboard) S.leaderboard = leaderboard;
      packet(e.kind, attacker.status === "quarantined", e.severity === "crit");
      termEvent(e, true);
      addTimeline(e);
      if (e.kind === "login_failed" || e.kind === "login_success" || e.kind === "web_login_failed") { credChip({ ...e.detail, ok: e.kind === "login_success" }); renderLeader(); }
      if (e.kind === "login_success" || e.kind === "command") renderSide();
    });
    on("trigger", ({ ip, reason, attacker }) => {
      applyAttacker(attacker);
      startClock(reason);
      sysEvent(`Rule fired for ${ip}: ${reason}. Asking the FortiGate to ban it…`, "warn");
    });
    on("quarantine", ({ ip, reason, ttq_ms, confirmed, attacker, bans, scoreboard }) => {
      applyAttacker(attacker);
      S.bans = bans; S.scoreboard = scoreboard;
      stopClock(ttq_ms, `${reason}${confirmed ? " · confirmed on FortiGate" : " · not confirmed"}`);
      applyWall(true);
      flash(ip, ttq_ms); siren();
      termPush(`■ FortiGate banned ${esc(ip)} in ${(ttq_ms / 1000).toFixed(3)} s — connection severed`, "sev");
      sysEvent(`Quarantined ${ip} on the FortiGate in ${ttq_ms} ms`, "crit");
      toast("crit", `Quarantined ${ip}`, `${(ttq_ms / 1000).toFixed(3)} s · ${reason}`);
      renderBans(); renderScoreboard();
    });
    on("release", ({ ip, bans, attacker, external }) => {
      S.bans = bans; if (attacker) applyAttacker(attacker);
      applyWall(S.bans.some((b) => b.ip === ip));
      termPush(`□ ${esc(ip)} was released from the FortiGate ban list${external ? " (outside HoneyWall)" : ""}`, "sys");
      sysEvent(`Released ${ip}${external ? " directly on the FortiGate" : ""}`);
      toast("ok", `Released ${ip}`, "Removed from the FortiGate ban list");
      $("#clock-sub").textContent = "Armed. Waiting for the next move.";
      renderBans();
    });
    on("bans", (b) => { S.bans = b; renderBans(); applyWall(S.bans.some((x) => x.ip === focusIp), true); });
    on("fgt", (f) => { S.fgt = f; renderLive(true); });
    on("report", (r) => {
      const i = S.reports.findIndex((x) => x.id === r.id);
      i >= 0 ? (S.reports[i] = r) : S.reports.push(r);
      if (r.status === "ready") toast("info", `Incident report ready · ${r.ip}`, r.source === "llm" ? `Written by the AI analyst in ${r.latency_ms} ms` : "Template report");
      renderSide();
    });
    on("settings", (s) => { S.settings = s; $("#btn-llm").setAttribute("aria-pressed", !!s.llm_enabled); });
    on("toast", (t) => toast(t.level, t.title, t.text));
    es.onerror = () => renderLive(false);
  }

  // ------------------------------------------------------------------ controls
  const remember = (k, v, save) => { prefs[k] = v; if (save) { saved[k] = v; store.set(k, v); } };
  function setTheme(t, save = true) { document.documentElement.dataset.theme = t; $("#btn-theme").textContent = `Theme: ${t}`; remember("theme", t, save); }
  function setSound(v, save = true) { $("#btn-sound").setAttribute("aria-pressed", v); remember("sound", v, save); if (v) ensureAudio(); else $("#arm").hidden = true; }
  function setFlash(v, save = true) { $("#btn-flash").setAttribute("aria-pressed", v); remember("flash", v, save); }
  function setLayout(l, save = true) { document.body.dataset.layout = l; $("#btn-layout").textContent = `Layout: ${l}`; remember("layout", l, save); }

  $("#btn-theme").onclick = () => setTheme(document.documentElement.dataset.theme === "hollywood" ? "enterprise" : "hollywood");
  $("#btn-sound").onclick = () => setSound(!prefs.sound);
  $("#btn-flash").onclick = () => setFlash(!prefs.flash);
  $("#btn-layout").onclick = () => setLayout(document.body.dataset.layout === "full" ? "split" : "full");
  $("#btn-llm").onclick = async () => {
    try { const s = await api("/api/settings", { method: "POST", body: JSON.stringify({ llm_enabled: !S.settings.llm_enabled }) }); S.settings = s; $("#btn-llm").setAttribute("aria-pressed", !!s.llm_enabled); toast("info", `AI reports ${s.llm_enabled ? "on" : "off"}`, s.llm_enabled && !CFG.llm_configured ? "LLM_BASE_URL is not set yet — template reports will be used" : ""); }
    catch (e) { toast("warn", "Could not change AI reports", e.message); }
  };
  $("#btn-test").onclick = async () => { try { await api("/api/test/alert", { method: "POST" }); } catch (e) { toast("warn", "Test alert failed", e.message); } };
  $("#btn-reset").onclick = async () => { if (confirm("Clear the board for the next take? FortiGate bans and reports are kept.")) { try { await api("/api/reset", { method: "POST" }); } catch (e) { toast("warn", "Reset failed", e.message); } } };
  $("#tab-reports").onclick = () => { sideTab = "reports"; renderSide(); };
  $("#tab-replay").onclick = () => { sideTab = "replay"; renderSide(); };
  $("#modal-close").onclick = closeModal;
  modal.addEventListener("click", (e) => { if (e.target === modal) closeModal(); });

  document.addEventListener("click", async (e) => {
    ensureAudio();
    const u = e.target.closest("[data-unban]");
    if (u) {
      u.disabled = true; u.textContent = "Unbanning…";
      try { await api("/api/unban", { method: "POST", body: JSON.stringify({ ip: u.dataset.unban }) }); }
      catch (err) { toast("crit", "Unban failed", err.message); u.disabled = false; u.textContent = "Unban"; }
      return;
    }
    const r = e.target.closest("[data-report]"); if (r) return openReport(r.dataset.report);
    const p = e.target.closest("[data-replay]"); if (p) return openReplay(p.dataset.replay);
  });
  document.addEventListener("keydown", (e) => {
    if (e.target.matches("input, textarea")) return;
    if (e.key === "Escape") closeModal();
    else if (e.key === "t" || e.key === "T") $("#btn-theme").click();
    else if (e.key === "s" || e.key === "S") $("#btn-sound").click();
    else if (e.key === "f" || e.key === "F") $("#btn-flash").click();
    else if (e.key === "l" || e.key === "L") $("#btn-layout").click();
  });
  window.addEventListener("hashchange", () => { const m = location.hash.match(/^#report-(.+)$/); if (m) openReport(decodeURIComponent(m[1])); });

  connect();
  const m = location.hash.match(/^#report-(.+)$/);
  if (m) setTimeout(() => openReport(decodeURIComponent(m[1])), 800);
})();
