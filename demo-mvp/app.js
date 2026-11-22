const state = {
  tab: "chat",
  mode: "chat",
  sessions: [],
  currentSessionId: null,
  messages: [],
  config: null,
  memories: [],
  memoryView: "list",
  currentMemory: null,
  currentCategory: "all",
  proposals: [],
  token: localStorage.getItem("advisor_access_token") || "",
  sending: false,
};

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

const WELCOME_HTML = `
  <div class="welcome-card">
    <h3>你好，我是你的个人成长决策顾问（v0.12）</h3>
    <p>所有记忆以纯 Markdown 保存在 iCloud <code>决策</code> 目录；所有对话自动沉淀到本地 SQLite 历史表，支持 <strong>4 路中文语义向量 + 双时间图谱召回</strong> 与 <strong>半自动确认落盘</strong>。</p>
    <div class="quick-starters">
      <button class="starter-btn" data-mode="interview" data-text="我想开始第一次冷启动访谈，请先用1-2个轻松的问题帮我建立「核心自我」和最早的重要经历。">🎙️ 开始冷启动访谈（零压力建库）</button>
      <button class="starter-btn" data-mode="decision" data-text="我最近面临一个重要选择，想请你按 9 步反讨好决策流程帮我分析：">🧭 做一个重要选择分析</button>
      <button class="starter-btn" data-mode="chat" data-text="今天发生了一件让我感触很深的事，想先和你聊聊当时的感受：">💬 聊聊今天的经历与感受</button>
      <button class="starter-btn" data-mode="reflect" data-text="请帮我读取收件箱和近期记忆，做一次阶段反思，看看有哪些情绪模式和值得整理入库的内容。">🔍 整理收件箱与周期反思</button>
    </div>
  </div>
`;

function showToast(msg, duration = 2600) {
  const el = $("#toast");
  el.textContent = msg;
  el.classList.remove("hidden");
  clearTimeout(el._timer);
  el._timer = setTimeout(() => el.classList.add("hidden"), duration);
}

function escapeHtml(str) {
  return String(str ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderMarkdown(md) {
  let text = escapeHtml(md || "");
  text = text.replace(/^---\n[\s\S]*?\n---\n?/, "");
  const codeBlocks = [];
  text = text.replace(/```[\w-]*\n([\s\S]*?)```/g, (_, code) => {
    const idx = codeBlocks.length;
    codeBlocks.push(`<pre><code>${code}</code></pre>`);
    return `@@CODEBLOCK_${idx}@@`;
  });

  text = text
    .replace(/^### (.*)$/gm, "<h3>$1</h3>")
    .replace(/^## (.*)$/gm, "<h2>$1</h2>")
    .replace(/^# (.*)$/gm, "<h1>$1</h1>")
    .replace(/^&gt; (.*)$/gm, "<blockquote>$1</blockquote>")
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/`([^`\n]+)`/g, "<code>$1</code>")
    .replace(/\[\[([^\]]+)\]\]/g, (_, link) => `<button class="wikilink-btn" data-wikilink="${link}">[[${link}]]</button>`);

  const lines = text.split("\n");
  const out = [];
  let inList = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (/^[-*] /.test(trimmed)) {
      if (!inList) { out.push("<ul>"); inList = true; }
      out.push(`<li>${trimmed.slice(2)}</li>`);
    } else {
      if (inList) { out.push("</ul>"); inList = false; }
      if (!trimmed) continue;
      if (/^<(h[1-3]|blockquote|pre)/.test(trimmed) || trimmed.startsWith("@@CODEBLOCK_")) {
        out.push(trimmed);
      } else {
        out.push(`<p>${trimmed}</p>`);
      }
    }
  }
  if (inList) out.push("</ul>");

  let html = out.join("\n");
  codeBlocks.forEach((blk, idx) => {
    html = html.replace(`@@CODEBLOCK_${idx}@@`, blk);
  });
  return html;
}

function authHeaders(extra = {}) {
  const h = { "Content-Type": "application/json", ...extra };
  if (state.token) h["X-Access-Token"] = state.token;
  return h;
}

async function apiFetch(url, options = {}) {
  const resp = await fetch(url, { ...options, headers: authHeaders(options.headers || {}) });
  if (resp.status === 401) {
    $("#authOverlay").classList.remove("hidden");
    throw new Error("需要访问密码");
  }
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error(data.detail || `请求失败 (${resp.status})`);
  return data;
}

/* ---------- Theme & Navigation ---------- */

function initTheme() {
  const saved = localStorage.getItem("advisor_theme");
  const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  document.documentElement.setAttribute("data-theme", saved || (prefersDark ? "dark" : "light"));
}

function toggleTheme() {
  const next = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
  document.documentElement.setAttribute("data-theme", next);
  localStorage.setItem("advisor_theme", next);
}

function switchTab(tab) {
  state.tab = tab;
  $$(".tab-panel").forEach((el) => el.classList.toggle("active", el.id === `tab-${tab}`));
  $$(".nav-item, .mobile-nav-item").forEach((el) => el.classList.toggle("active", el.dataset.tab === tab));
  if (tab === "memories") refreshCurrentMemoryView();
  if (tab === "inbox") loadInboxPreview();
  if (tab === "settings") { loadConfig(); loadStats(); loadGitHistory(); }
}

/* ---------- Auth ---------- */

async function checkAuth() {
  const res = await fetch("/api/auth/status", {
    headers: state.token ? { "X-Access-Token": state.token } : {},
  }).then((r) => r.json());
  if (res.auth_required && !res.authenticated) {
    $("#authOverlay").classList.remove("hidden");
    return false;
  }
  $("#authOverlay").classList.add("hidden");
  return true;
}

async function handleAuthSubmit() {
  const val = $("#authInput").value.trim();
  if (!val) return;
  state.token = val;
  const ok = await checkAuth();
  if (ok) {
    localStorage.setItem("advisor_access_token", val);
    $("#authError").classList.add("hidden");
    await bootstrap();
  } else {
    $("#authError").textContent = "密码不正确，请重试";
    $("#authError").classList.remove("hidden");
  }
}

/* ---------- Stats & Config ---------- */

async function loadStats() {
  try {
    const data = await apiFetch("/api/health");
    const total = data.stats?.total ?? 0;
    const idx = data.index || {};
    const text = `${total} 篇记忆 · ${idx.embedded_docs ?? 0} 向量`;
    $("#vaultStatBadge").textContent = text;
    $("#mobileStatBadge").textContent = `· ${total} 篇`;
    if ($("#indexStatusText")) {
      $("#indexStatusText").textContent = `已索引 ${idx.total_docs ?? 0} 篇 · 已向量化 ${idx.embedded_docs ?? 0} 篇 · 图谱关联 ${idx.graph_edges ?? 0} 条 · 模型：${idx.embedding_model || "未建"}`;
    }
  } catch (err) {
    console.error(err);
  }
}

async function loadConfig() {
  try {
    const cfg = await apiFetch("/api/config");
    state.config = cfg;
    renderProviderSelect();
    renderSettings();
  } catch (err) {
    showToast(err.message);
  }
}

function renderProviderSelect() {
  const sel = $("#providerSelect");
  if (!state.config) return;
  sel.innerHTML = state.config.providers
    .map((p) => {
      const mark = p.has_api_key ? "" : " (未填Key)";
      return `<option value="${escapeHtml(p.id)}" ${p.id === state.config.active_provider_id ? "selected" : ""}>${escapeHtml(p.name)} · ${escapeHtml(p.model)}${mark}</option>`;
    })
    .join("");
}

/* ---------- SQLite Sessions ---------- */

async function loadSessions() {
  try {
    const data = await apiFetch("/api/sessions");
    state.sessions = data.items || [];
    renderSessionList();
  } catch (err) {
    console.error(err);
  }
}

function renderSessionList() {
  const el = $("#sessionList");
  if (state.sessions.length === 0) {
    el.innerHTML = `<div class="muted small-text" style="padding:14px;text-align:center;">暂无历史对话，发送消息后自动保存在 SQLite。</div>`;
    return;
  }
  const modeMap = { chat: "💬", decision: "🧭", interview: "🎙️", reflect: "🔍" };
  el.innerHTML = state.sessions
    .map((s) => {
      const active = s.id === state.currentSessionId ? "active" : "";
      const icon = modeMap[s.mode] || "💬";
      return `
        <div class="session-item ${active}" data-sid="${escapeHtml(s.id)}">
          <div style="min-width:0;flex:1;">
            <div class="session-title">${icon} ${escapeHtml(s.title)}</div>
            <div class="session-meta">${s.message_count || 0} 条 · ${escapeHtml((s.updated_at || "").slice(5, 16).replace("T", " "))}</div>
          </div>
          <button class="session-del-btn" data-del-sid="${escapeHtml(s.id)}" title="删除对话">✕</button>
        </div>
      `;
    })
    .join("");
}

async function openSession(sid) {
  try {
    const sess = await apiFetch(`/api/sessions/${encodeURIComponent(sid)}`);
    state.currentSessionId = sess.id;
    setMode(sess.mode || "chat");
    if (sess.provider_id && $("#providerSelect").querySelector(`option[value="${sess.provider_id}"]`)) {
      $("#providerSelect").value = sess.provider_id;
    }
    state.messages = (sess.messages || []).map((m) => ({
      role: m.role,
      content: m.content,
      reasoning: m.reasoning || "",
      model: m.model || "",
      provider_name: m.provider_name || "",
      references: m.references || [],
    }));
    renderChatMessages();
    renderSessionList();
    $("#sessionsPane").classList.remove("mobile-open");
  } catch (err) {
    showToast(err.message);
  }
}

function startNewChat() {
  state.currentSessionId = null;
  state.messages = [];
  renderChatMessages();
  renderSessionList();
  $("#sessionsPane").classList.remove("mobile-open");
  $("#chatInput").focus();
}

async function deleteSessionById(sid) {
  if (!confirm("确定删除这条历史对话吗？（不会删除已写入 iCloud 的正式记忆）")) return;
  try {
    await apiFetch(`/api/sessions/${encodeURIComponent(sid)}`, { method: "DELETE" });
    if (state.currentSessionId === sid) startNewChat();
    await loadSessions();
    showToast("已删除历史对话");
  } catch (err) {
    showToast(err.message);
  }
}

/* ---------- Chat with SSE Streaming ---------- */

function setMode(mode) {
  state.mode = mode;
  $$("#modePills .pill").forEach((b) => b.classList.toggle("active", b.dataset.mode === mode));
}

function renderChatMessages() {
  const container = $("#chatMessages");
  if (state.messages.length === 0) {
    $("#extractProposalBtn").disabled = true;
    container.innerHTML = WELCOME_HTML;
    return;
  }
  $("#extractProposalBtn").disabled = false;
  container.innerHTML = state.messages
    .map((m) => {
      if (m.role === "user") {
        return `<div class="msg-row user"><div class="msg-bubble">${escapeHtml(m.content)}</div></div>`;
      }
      const reasoningHtml = m.reasoning
        ? `<details class="reasoning-box" ${m._streaming ? "open" : ""}><summary>🧠 思考过程</summary><div style="margin-top:6px;white-space:pre-wrap;">${escapeHtml(m.reasoning)}</div></details>`
        : "";
      const refsHtml = m.references && m.references.length
        ? `<details class="ref-details"><summary>📎 本次参考了 ${m.references.length} 篇本地记忆（点击可查看原文）</summary><div class="ref-chip-list">${m.references
            .map((r) => {
              const reasonTag = r.reasons && r.reasons.length ? ` · ${r.reasons[0]}` : "";
              return `<button class="ref-chip" data-open-path="${escapeHtml(r.path)}">${escapeHtml(r.title)}${escapeHtml(reasonTag)}</button>`;
            })
            .join("")}</div></details>`
        : "";
      const bodyHtml = m.content ? renderMarkdown(m.content) : (m._streaming ? `<span class="muted">正在思考中...</span>` : "");
      return `
        <div class="msg-row assistant">
          <div class="msg-bubble">
            ${reasoningHtml}
            <div class="markdown-body">${bodyHtml}</div>
            ${refsHtml}
          </div>
          <div class="msg-meta"><span>${escapeHtml(m.provider_name || "")} ${escapeHtml(m.model || "")}</span></div>
        </div>
      `;
    })
    .join("");
  container.scrollTop = container.scrollHeight;
}

async function sendChat(overrideText = null) {
  if (state.sending) return;
  const input = $("#chatInput");
  const text = (overrideText ?? input.value).trim();
  if (!text) return;

  input.value = "";
  state.messages.push({ role: "user", content: text });
  const assistantMsg = {
    role: "assistant",
    content: "",
    reasoning: "",
    model: "",
    provider_name: "",
    references: [],
    _streaming: true,
  };
  state.messages.push(assistantMsg);
  renderChatMessages();

  state.sending = true;
  $("#sendBtn").disabled = true;
  $("#chatStatusHint").textContent = "正在 4 路检索记忆并流式生成回答...";

  try {
    const payload = {
      session_id: state.currentSessionId,
      messages: state.messages.slice(0, -1).map((m) => ({ role: m.role, content: m.content })),
      mode: state.mode,
      provider_id: $("#providerSelect").value || null,
      allow_sensitive: $("#allowSensitiveCheck").checked,
      as_of: $("#chatAsOfInput").value || null,
    };

    const resp = await fetch("/api/chat/stream", {
      method: "POST",
      headers: authHeaders(),
      body: JSON.stringify(payload),
    });
    if (resp.status === 401) {
      $("#authOverlay").classList.remove("hidden");
      throw new Error("需要访问密码");
    }
    if (!resp.ok) {
      const errJson = await resp.json().catch(() => ({}));
      throw new Error(errJson.detail || `请求失败 (${resp.status})`);
    }

    const reader = resp.body.getReader();
    const decoder = new TextDecoder("utf-8");
    let buffer = "";

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const parts = buffer.split("\n\n");
      buffer = parts.pop() || "";

      for (const block of parts) {
        for (const line of block.split("\n")) {
          const trimmed = line.trim();
          if (!trimmed.startsWith("data:")) continue;
          const jsonStr = trimmed.slice(5).trim();
          if (!jsonStr) continue;
          let ev;
          try { ev = JSON.parse(jsonStr); } catch { continue; }

          if (ev.type === "meta") {
            state.currentSessionId = ev.session_id;
            assistantMsg.provider_name = ev.provider_name || "";
            assistantMsg.model = ev.model || "";
            assistantMsg.references = ev.references || [];
            renderChatMessages();
          } else if (ev.type === "reasoning") {
            assistantMsg.reasoning += ev.delta || "";
            renderChatMessages();
          } else if (ev.type === "text") {
            assistantMsg.content += ev.delta || "";
            renderChatMessages();
          } else if (ev.type === "error") {
            assistantMsg.content = `⚠️ **调用失败**：${ev.detail}\n\n请检查「⚙️ 模型与设置」中是否已填写对应 API Key 和正确的 Base URL。`;
            renderChatMessages();
          } else if (ev.type === "done") {
            state.currentSessionId = ev.session_id || state.currentSessionId;
          }
        }
      }
    }

    assistantMsg._streaming = false;
    renderChatMessages();
    await loadSessions();
    $("#chatStatusHint").textContent = "已存入 SQLite 历史表 · 聊完可点左侧按钮半自动沉淀进记忆库";
  } catch (err) {
    assistantMsg._streaming = false;
    assistantMsg.content = `⚠️ **调用失败**：${err.message}`;
    renderChatMessages();
    $("#chatStatusHint").textContent = "";
  } finally {
    state.sending = false;
    $("#sendBtn").disabled = false;
  }
}

/* ---------- Semi-Auto Proposals ---------- */

async function extractProposals() {
  if (state.messages.length === 0) return;
  const btn = $("#extractProposalBtn");
  btn.disabled = true;
  const orig = btn.textContent;
  btn.textContent = "⏳ 正在提炼记忆提案...";
  try {
    const data = await apiFetch("/api/proposals/extract", {
      method: "POST",
      body: JSON.stringify({
        session_id: state.currentSessionId,
        messages: state.messages.map((m) => ({ role: m.role, content: m.content })),
        provider_id: $("#providerSelect").value || null,
        allow_sensitive: $("#allowSensitiveCheck").checked,
      }),
    });
    state.proposals = data.proposals || [];
    if (state.proposals.length === 0) {
      showToast("本轮对话暂无需要新沉淀的正式记忆");
      return;
    }
    renderProposalModal();
    $("#proposalModal").classList.remove("hidden");
  } catch (err) {
    showToast(`提炼失败: ${err.message}`, 4000);
  } finally {
    btn.disabled = false;
    btn.textContent = orig;
  }
}

function renderProposalModal() {
  const list = $("#proposalList");
  list.innerHTML = state.proposals
    .map((p, idx) => {
      const levelBadge =
        p.level === 3
          ? `<span class="badge badge-danger">Level 3 核心自我强确认</span>`
          : p.level === 1
          ? `<span class="badge">Level 1 收件箱</span>`
          : `<span class="badge badge-accent">Level 2 常规记忆</span>`;
      const actionLabel = p.action === "append" ? "追加" : p.exists ? "更新已有文件" : "新建文件";
      const emoHtml = (p.emotions || []).map((e) => `<span class="badge">${escapeHtml(e)}</span>`).join("");
      const diffHtml = p.diff
        ? `<details open><summary class="small-text muted">🔍 查看变更 Diff（修改前 → 修改后）</summary><pre class="diff-pre">${escapeHtml(p.diff)}</pre></details>`
        : "";
      return `
        <div class="proposal-card" data-prop-idx="${idx}">
          <div class="proposal-top">
            <label class="proposal-check-wrap">
              <input type="checkbox" class="prop-check" checked />
              <div>
                <strong>${escapeHtml(p.title)}</strong>
                <div class="small-text muted">${actionLabel} · <code>${escapeHtml(p.path)}</code></div>
              </div>
            </label>
            <div class="badge-row">
              ${levelBadge}
              <span class="badge">显著性 ${escapeHtml(p.importance)}/10</span>
            </div>
          </div>
          <div style="font-size:13.5px;line-height:1.55;">${escapeHtml(p.summary)}</div>
          <div class="badge-row">
            ${emoHtml}
            <select class="select-compact prop-privacy">
              <option value="normal" ${p.privacy === "normal" ? "selected" : ""}>privacy: normal</option>
              <option value="private" ${p.privacy === "private" ? "selected" : ""}>privacy: private（默认）</option>
              <option value="sensitive" ${p.privacy === "sensitive" ? "selected" : ""}>🔒 privacy: sensitive（不发云端）</option>
            </select>
          </div>
          ${p.evidence ? `<div class="small-text muted">证据要点：${escapeHtml(p.evidence)}</div>` : ""}
          ${diffHtml}
          <details>
            <summary class="small-text muted">✏️ 查看或微调即将写入的完整 Markdown</summary>
            <textarea class="prop-content" rows="10" style="margin-top:8px;font-family:ui-monospace,monospace;font-size:12.5px;">${escapeHtml(p.content)}</textarea>
          </details>
        </div>
      `;
    })
    .join("");
}

async function commitSelectedProposals() {
  const cards = $$("#proposalList .proposal-card");
  const items = [];
  cards.forEach((card) => {
    if (!card.querySelector(".prop-check").checked) return;
    const idx = Number(card.dataset.propIdx);
    const p = state.proposals[idx];
    items.push({
      action: p.action,
      path: p.path,
      title: p.title,
      privacy: card.querySelector(".prop-privacy").value,
      content: card.querySelector(".prop-content").value,
    });
  });

  if (items.length === 0) {
    showToast("请至少勾选 1 条要写入的记忆");
    return;
  }

  const btn = $("#commitProposalBtn");
  btn.disabled = true;
  try {
    const res = await apiFetch("/api/proposals/commit", {
      method: "POST",
      body: JSON.stringify({ session_id: state.currentSessionId, items }),
    });
    $("#proposalModal").classList.add("hidden");
    showToast(`✅ 已写入 ${res.written.length} 篇记忆、更新向量图谱并生成 Git 快照！`, 3500);
    loadStats();
  } catch (err) {
    showToast(`写入失败: ${err.message}`, 4000);
  } finally {
    btn.disabled = false;
  }
}

/* ---------- Memories: List / 4-Way Semantic / Timeline / Graph ---------- */

function setMemoryView(view) {
  state.memoryView = view;
  $$("#memoryViewPills .pill").forEach((b) => b.classList.toggle("active", b.dataset.view === view));
  $("#listFiltersRow").classList.toggle("hidden", view !== "list");
  $("#categoryPills").classList.toggle("hidden", view !== "list");
  $("#semanticFiltersRow").classList.toggle("hidden", view !== "semantic");
  $("#runSemanticBtn").classList.toggle("hidden", view !== "semantic");
  refreshCurrentMemoryView();
}

async function refreshCurrentMemoryView() {
  if (state.memoryView === "list") return loadMemories();
  if (state.memoryView === "semantic") return runSemanticSearch();
  if (state.memoryView === "timeline") return loadTimelineView();
  if (state.memoryView === "graph") return loadGraphView();
}

async function loadMemories() {
  const q = $("#memorySearchInput").value.trim();
  const emotion = $("#emotionFilter").value;
  const minImp = $("#highImportanceOnly").checked ? 7 : 1;
  const params = new URLSearchParams({
    category: state.currentCategory,
    q,
    emotion,
    min_importance: String(minImp),
  });
  try {
    const data = await apiFetch(`/api/memories?${params.toString()}`);
    state.memories = data.items || [];

    const cats = [{ id: "all", label: "全部" }, ...(data.categories || [])];
    $("#categoryPills").innerHTML = cats
      .map((c) => `<button class="pill ${c.id === state.currentCategory ? "active" : ""}" data-cat="${escapeHtml(c.id)}">${escapeHtml(c.label)}</button>`)
      .join("");

    const emoSel = $("#emotionFilter");
    const prevEmo = emoSel.value;
    emoSel.innerHTML = `<option value="">全部情绪</option>` + (data.emotions || [])
      .map((e) => `<option value="${escapeHtml(e)}" ${e === prevEmo ? "selected" : ""}>${escapeHtml(e)}</option>`)
      .join("");

    renderMemoryCards(state.memories);
  } catch (err) {
    showToast(err.message);
  }
}

async function runSemanticSearch() {
  const q = $("#memorySearchInput").value.trim();
  const cardsEl = $("#memoryCards");
  if (!q) {
    cardsEl.innerHTML = `<div class="muted small-text" style="padding:20px;text-align:center;">输入自然语言意图（如“被否定后的焦虑”、“2024年以前关于自由的选择”），按回车或点「检索」体验 4 路中文语义 + 图谱 + 双时间召回。</div>`;
    return;
  }
  cardsEl.innerHTML = `<div class="muted small-text" style="padding:20px;text-align:center;">🧠 正在执行 4 路中文语义向量 + 图谱检索...</div>`;
  try {
    const params = new URLSearchParams({ q, as_of: $("#searchAsOfInput").value || "" });
    const data = await apiFetch(`/api/memories/search?${params.toString()}`);
    renderMemoryCards(data.items || [], true);
  } catch (err) {
    showToast(err.message);
  }
}

function renderMemoryCards(items, showReasons = false) {
  const cardsEl = $("#memoryCards");
  if (!items.length) {
    cardsEl.innerHTML = `<div class="muted" style="padding:24px;text-align:center;">暂无匹配的记忆条目</div>`;
    return;
  }
  cardsEl.innerHTML = items
    .map((m) => {
      const active = state.currentMemory && state.currentMemory.path === m.path ? "active" : "";
      const priv = m.privacy === "sensitive" ? `<span class="badge badge-danger">🔒 sensitive</span>` : "";
      const emos = (m.emotions || []).slice(0, 3).map((e) => `<span class="badge">${escapeHtml(e)}</span>`).join("");
      const reasonBadges = showReasons && m.reasons
        ? m.reasons.map((r) => `<span class="badge badge-warn">${escapeHtml(r)}</span>`).join("")
        : "";
      return `
        <div class="mem-card ${active}" data-path="${escapeHtml(m.path)}">
          <div class="mem-card-top">
            <div class="mem-card-title">${escapeHtml(m.title)}</div>
            <span class="badge badge-accent">${escapeHtml(m.category_label)}</span>
          </div>
          <div class="mem-card-snippet">${escapeHtml(m.snippet)}</div>
          <div class="badge-row">
            ${m.event_time ? `<span class="badge">📅 ${escapeHtml(m.event_time)}</span>` : ""}
            <span class="badge">⭐ ${m.importance}/10</span>
            ${priv}
            ${reasonBadges}
            ${emos}
          </div>
        </div>
      `;
    })
    .join("");
}

async function loadTimelineView() {
  const cardsEl = $("#memoryCards");
  try {
    const data = await apiFetch("/api/memories/timeline");
    const items = data.items || [];
    if (!items.length) {
      cardsEl.innerHTML = `<div class="muted small-text" style="padding:24px;text-align:center;">时间轴暂无事件/人生章节/决策记录，先聊一次「冷启动访谈」沉淀你的过去吧！</div>`;
      return;
    }
    cardsEl.innerHTML = items
      .map(
        (it) => `
        <div class="timeline-item" data-path="${escapeHtml(it.path)}">
          <div class="timeline-date">📅 ${escapeHtml(it.event_time || it.recorded_at || "未标日期")} · ${escapeHtml(it.category_label)} · ⭐${it.importance}/10</div>
          <div class="mem-card-title">${escapeHtml(it.title)}</div>
          <div class="mem-card-snippet">${escapeHtml(it.snippet)}</div>
          <div class="badge-row">
            ${(it.emotions || []).map((e) => `<span class="badge">${escapeHtml(e)}</span>`).join("")}
            ${it.superseded_by ? `<span class="badge badge-warn">已被新认知替代</span>` : ""}
          </div>
        </div>`
      )
      .join("");
  } catch (err) {
    showToast(err.message);
  }
}

async function loadGraphView() {
  const cardsEl = $("#memoryCards");
  try {
    const g = await apiFetch("/api/memories/graph");
    const nodesById = Object.fromEntries((g.nodes || []).map((n) => [n.id, n]));
    const edges = g.edges || [];
    const relName = { wikilink: "🔗 双链关联", shared_person: "👤 共同人物", shared_chapter: "📖 同一章节" };
    if (!edges.length) {
      cardsEl.innerHTML = `<div class="muted small-text" style="padding:24px;text-align:center;">图谱已有 ${g.nodes?.length || 0} 个节点，随着添加 [[双链]] 与共同人物，关联关系会自动呈现。</div>`;
      return;
    }
    cardsEl.innerHTML =
      `<div class="small-text muted" style="padding:4px 6px;">共 ${g.nodes.length} 个记忆节点 · ${edges.length} 条图谱关系（点击节点直达原文）</div>` +
      edges
        .map((e) => {
          const s = nodesById[e.source];
          const t = nodesById[e.target];
          return `
            <div class="graph-edge-card">
              <div class="badge-row"><span class="badge badge-accent">${relName[e.relation_type] || e.relation_type}</span></div>
              <div>
                <button class="wikilink-btn" data-open-path="${escapeHtml(e.source)}">${escapeHtml(s?.title || e.source)}</button>
                <span class="muted"> ⇄ </span>
                <button class="wikilink-btn" data-open-path="${escapeHtml(e.target)}">${escapeHtml(t?.title || e.target)}</button>
              </div>
            </div>`;
        })
        .join("");
  } catch (err) {
    showToast(err.message);
  }
}

async function openMemory(path) {
  try {
    const doc = await apiFetch(`/api/memories/file?path=${encodeURIComponent(path)}`);
    state.currentMemory = doc;
    $("#emptyReader").classList.add("hidden");
    $("#readerContentWrap").classList.remove("hidden");
    $(".memories-layout").classList.add("reading-mobile");

    $("#readerTitle").textContent = doc.title;
    const badges = [
      `<span class="badge badge-accent">${escapeHtml(doc.category_label)}</span>`,
      `<span class="badge">⭐ 显著性 ${doc.importance}/10</span>`,
      doc.event_time ? `<span class="badge">📅 ${escapeHtml(doc.event_time)}</span>` : "",
      `<span class="badge ${doc.privacy === "sensitive" ? "badge-danger" : ""}">${doc.privacy === "sensitive" ? "🔒 " : ""}${escapeHtml(doc.privacy)}</span>`,
      `<span class="badge">${escapeHtml(doc.path)}</span>`,
    ].filter(Boolean);
    $("#readerBadges").innerHTML = badges.join("");

    const emoGrid = $("#readerEmotions");
    const details = (doc.emotions_detail || []).filter((e) => e && typeof e === "object" && e.name);
    if (details.length > 0) {
      emoGrid.classList.remove("hidden");
      emoGrid.innerHTML = details
        .map(
          (e) => `
          <div class="emotion-card">
            <strong>💭 ${escapeHtml(e.name)}</strong>
            ${e.intensity ? `<span class="badge">强度 ${escapeHtml(e.intensity)}/10</span>` : ""}
            ${e.trigger ? `<div><span class="muted">触发：</span>${escapeHtml(e.trigger)}</div>` : ""}
            ${e.body ? `<div><span class="muted">身体：</span>${escapeHtml(e.body)}</div>` : ""}
            ${e.thought ? `<div><span class="muted">念头：</span>${escapeHtml(e.thought)}</div>` : ""}
          </div>`
        )
        .join("");
    } else {
      emoGrid.classList.add("hidden");
    }

    $("#readerRendered").innerHTML = renderMarkdown(doc.raw);
    $("#readerEditor").value = doc.raw;
    setReaderEditMode(false);
    $$(".mem-card").forEach((c) => c.classList.toggle("active", c.dataset.path === doc.path));
  } catch (err) {
    showToast(err.message);
  }
}

function setReaderEditMode(editing) {
  $("#readerRendered").classList.toggle("hidden", editing);
  $("#readerEditor").classList.toggle("hidden", !editing);
  $("#toggleEditBtn").classList.toggle("hidden", editing);
  $("#saveEditBtn").classList.toggle("hidden", !editing);
  $("#cancelEditBtn").classList.toggle("hidden", !editing);
}

async function saveCurrentMemory() {
  if (!state.currentMemory) return;
  try {
    await apiFetch("/api/memories/file", {
      method: "PUT",
      body: JSON.stringify({ path: state.currentMemory.path, content: $("#readerEditor").value }),
    });
    showToast("💾 已保存到 iCloud、刷新向量索引并生成 Git 快照");
    await openMemory(state.currentMemory.path);
    refreshCurrentMemoryView();
    loadStats();
  } catch (err) {
    showToast(`保存失败: ${err.message}`, 3500);
  }
}

async function openByWikilink(linkText) {
  const cleaned = linkText.replace(/\.md$/i, "").trim();
  switchTab("memories");
  state.memoryView = "list";
  await loadMemories();
  const hit = state.memories.find(
    (m) => m.path === `${cleaned}.md` || m.path.endsWith(`/${cleaned}.md`) || m.title === cleaned
  );
  if (hit) openMemory(hit.path);
  else {
    $("#memorySearchInput").value = cleaned;
    loadMemories();
    showToast(`已为你搜索关联记忆：${cleaned}`);
  }
}

/* ---------- Inbox ---------- */

async function loadInboxPreview() {
  try {
    const doc = await apiFetch(`/api/memories/file?path=${encodeURIComponent("99-收件箱/inbox.md")}`);
    $("#inboxPreview").innerHTML = renderMarkdown(doc.raw);
  } catch {
    $("#inboxPreview").innerHTML = `<p class="muted">收件箱暂无内容</p>`;
  }
}

async function saveInbox() {
  const text = $("#inboxText").value.trim();
  const mood = $("#inboxMoodInput").value.trim();
  if (!text) return showToast("先写点当下的感受或想法吧");
  try {
    await apiFetch("/api/inbox", { method: "POST", body: JSON.stringify({ text, mood }) });
    $("#inboxText").value = "";
    $("#inboxMoodInput").value = "";
    $$("#moodChips .chip").forEach((c) => c.classList.remove("active"));
    showToast("⚡ 已存入收件箱并同步 iCloud");
    loadInboxPreview();
    loadStats();
  } catch (err) {
    showToast(err.message);
  }
}

/* ---------- Settings & Git ---------- */

const RECOMMENDED_MODELS = {
  deepseek: ["deepseek-v4-pro", "deepseek-flash"],
  openai_compatible: ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6-luna"],
  claude: ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2", "claude-haiku-5-5"],
  gemini: ["gemini-4-neon", "gemini-4-carbon", "gemini-4-hydrogen", "gemini-4-argon", "gemini-3.5-flash-lite"],
};

function renderModelPresetChips(kind, currentModel) {
  const list = RECOMMENDED_MODELS[kind] || RECOMMENDED_MODELS.openai_compatible;
  return list
    .map(
      (m) =>
        `<button type="button" class="chip model-preset-chip ${m === currentModel ? "active" : ""}" data-model="${escapeHtml(m)}" style="font-size:11.5px;padding:3px 9px;font-family:ui-monospace,monospace;">${escapeHtml(m)}</button>`
    )
    .join("");
}

function renderSettings() {
  if (!state.config) return;
  const list = $("#providersList");
  list.innerHTML = state.config.providers
    .map(
      (p, idx) => `
      <div class="provider-card" data-idx="${idx}" data-id="${escapeHtml(p.id)}">
        <div class="card-header-row">
          <label class="proposal-check-wrap">
            <input type="radio" name="activeProvider" value="${escapeHtml(p.id)}" ${p.id === state.config.active_provider_id ? "checked" : ""} />
            <strong>${escapeHtml(p.name)}</strong>
            ${p.has_api_key ? `<span class="badge badge-accent">已配Key ${escapeHtml(p.api_key_masked)}</span>` : `<span class="badge badge-warn">未填Key</span>`}
          </label>
          <div class="row-actions">
            <button class="btn btn-ghost btn-sm test-provider-btn" data-pid="${escapeHtml(p.id)}">测试连通</button>
            <button class="btn btn-danger btn-sm del-provider-btn" data-idx="${idx}">删除</button>
          </div>
        </div>
        <div class="provider-grid">
          <div class="form-row"><label>名称</label><input type="text" class="p-name" value="${escapeHtml(p.name)}" /></div>
          <div class="form-row">
            <label>协议类型</label>
            <select class="p-kind">
              <option value="deepseek" ${p.kind === "deepseek" ? "selected" : ""}>DeepSeek 官方</option>
              <option value="openai_compatible" ${p.kind === "openai_compatible" ? "selected" : ""}>OpenAI 兼容中转站</option>
              <option value="claude" ${p.kind === "claude" ? "selected" : ""}>Claude 原生 API</option>
              <option value="gemini" ${p.kind === "gemini" ? "selected" : ""}>Gemini 原生 API</option>
            </select>
          </div>
          <div class="form-row"><label>Base URL</label><input type="url" class="p-url" value="${escapeHtml(p.base_url)}" /></div>
          <div class="form-row">
            <label>模型名称</label>
            <input type="text" class="p-model" value="${escapeHtml(p.model)}" />
            <div class="mood-chips p-model-chips" style="margin-top:6px;">${renderModelPresetChips(p.kind, p.model)}</div>
          </div>
          <div class="form-row"><label>API Key（留空保留已保存 Key）</label><input type="password" class="p-key" placeholder="${p.has_api_key ? "已保存，留空不修改" : "粘贴你的 API Key"}" /></div>
        </div>
      </div>`
    )
    .join("");

  const emb = state.config.embedding || {};
  $("#embModeSelect").value = emb.mode || "local_bge_zh";
  $("#embLocalModel").value = emb.local_model || "BAAI/bge-small-zh-v1.5";
  $("#embApiUrl").value = emb.api_base_url || "https://api.openai.com/v1";
  $("#embApiModel").value = emb.api_model || "text-embedding-3-small";
  $("#embApiKey").placeholder = emb.has_api_key ? `已保存 (${emb.api_key_masked})，留空不修改` : "选 API 模式时填写";

  $("#publicBaseUrlInput").value = state.config.public_base_url || "";
  const mcpUrl = state.config.mcp_endpoint_url;
  $("#mcpEndpointBox").innerHTML = mcpUrl
    ? `
      <div>🔗 <strong>ChatGPT Developer Mode MCP URL</strong>：<code>${escapeHtml(mcpUrl)}</code></div>
      <div>🔐 <strong>OAuth 2.1 状态</strong>：${state.config.has_access_token ? "✅ 已设访问密码（就绪）" : "⚠️ 请先在下方设置访问密码后再暴露到公网"}</div>
      <div class="small-text muted">在 chatgpt.com 开启 Developer Mode → Create MCP App → 粘贴上方 URL 并选 OAuth 授权，网页和 iPhone ChatGPT App 即可共用本记忆库！</div>
    `
    : `<div class="muted">填入你的 VPS 公网 HTTPS 域名并保存后，这里会生成供 ChatGPT Developer Mode 填写的官方 MCP URL。</div>`;

  const net = state.config.network || {};
  $("#networkInfo").innerHTML = `
    <div>💻 <strong>本机访问</strong>：<code>${escapeHtml(net.local_url || "http://127.0.0.1:8789")}</code></div>
    <div>📶 <strong>同 Wi-Fi 手机访问</strong>：${net.lan_url ? `<code>${escapeHtml(net.lan_url)}</code>` : `<span class="muted">未检测到局域网 IP</span>`}</div>
    <div>🌐 <strong>Tailscale 远程直连</strong>：${net.tailscale_url ? `<code>${escapeHtml(net.tailscale_url)}</code>` : `<span class="muted">登录 Tailscale 后自动显示</span>`}</div>
    <div class="small-text muted" style="margin-top:4px;">📂 唯一数据真源：<code>${escapeHtml(state.config.vault_path)}</code></div>
  `;
  $("#accessTokenState").textContent = state.config.has_access_token
    ? "🔒 当前已开启访问密码保护"
    : "⚠️ 当前未设置访问密码（仅限本地/信任网络使用）";
}

function collectSettingsFromDom() {
  const cards = $$("#providersList .provider-card");
  const providers = cards.map((card, i) => ({
    id: card.dataset.id || `custom-${Date.now()}-${i}`,
    name: card.querySelector(".p-name").value.trim() || "自定义模型",
    kind: card.querySelector(".p-kind").value,
    base_url: card.querySelector(".p-url").value.trim(),
    model: card.querySelector(".p-model").value.trim(),
    api_key: card.querySelector(".p-key").value.trim(),
  }));
  const checkedRadio = document.querySelector('input[name="activeProvider"]:checked');
  return {
    active_provider_id: checkedRadio ? checkedRadio.value : (providers[0]?.id || ""),
    providers,
    public_base_url: $("#publicBaseUrlInput").value.trim(),
    access_token: $("#accessTokenInput").value.trim(),
    embedding: {
      mode: $("#embModeSelect").value,
      local_model: $("#embLocalModel").value.trim(),
      api_base_url: $("#embApiUrl").value.trim(),
      api_model: $("#embApiModel").value.trim(),
      api_key: $("#embApiKey").value.trim(),
    },
  };
}

async function saveSettings(extra = {}) {
  const payload = { ...collectSettingsFromDom(), ...extra };
  try {
    const updated = await apiFetch("/api/config", { method: "PUT", body: JSON.stringify(payload) });
    if (payload.access_token) {
      state.token = payload.access_token;
      localStorage.setItem("advisor_access_token", payload.access_token);
    }
    if (payload.clear_access_token) {
      state.token = "";
      localStorage.removeItem("advisor_access_token");
    }
    $("#accessTokenInput").value = "";
    $("#embApiKey").value = "";
    state.config = updated;
    renderProviderSelect();
    renderSettings();
    showToast("✅ 全部配置已保存");
  } catch (err) {
    showToast(`保存失败: ${err.message}`, 3500);
  }
}

async function rebuildVectorIndex() {
  const btn = $("#rebuildIndexBtn");
  btn.disabled = true;
  btn.textContent = "⏳ 重建中（首次会下载约90MB中文BGE模型）...";
  try {
    const res = await apiFetch("/api/index/rebuild", { method: "POST" });
    showToast(`✅ 索引完成：${res.embedded_docs}/${res.total_docs} 篇已向量化，${res.graph_edges} 条图谱关系！`, 4000);
    loadStats();
  } catch (err) {
    showToast(`重建失败: ${err.message}`, 4000);
  } finally {
    btn.disabled = false;
    btn.textContent = "🔄 立即重建索引";
  }
}

async function loadGitHistory() {
  try {
    const data = await apiFetch("/api/git/history");
    const items = data.items || [];
    const el = $("#gitHistoryList");
    if (!items.length) {
      el.innerHTML = `<div class="muted small-text">暂无快照记录。</div>`;
      return;
    }
    el.innerHTML = items
      .map((it) => `<div class="git-item"><div><span class="git-hash">${escapeHtml(it.hash)}</span> ${escapeHtml(it.message)}</div><span class="muted small-text">${escapeHtml(it.date.slice(0, 16))}</span></div>`)
      .join("");
  } catch (err) {
    console.error(err);
  }
}

/* ---------- Events ---------- */

function bindEvents() {
  $("#themeToggleDesktop").addEventListener("click", toggleTheme);
  $("#themeToggleMobile").addEventListener("click", toggleTheme);
  $("#authSubmitBtn").addEventListener("click", handleAuthSubmit);
  $("#authInput").addEventListener("keydown", (e) => { if (e.key === "Enter") handleAuthSubmit(); });

  $$(".nav-item, .mobile-nav-item").forEach((btn) =>
    btn.addEventListener("click", () => switchTab(btn.dataset.tab))
  );

  $("#newChatBtn").addEventListener("click", startNewChat);
  $("#openSessionsMobileBtn").addEventListener("click", () => $("#sessionsPane").classList.add("mobile-open"));
  $("#closeSessionsMobileBtn").addEventListener("click", () => $("#sessionsPane").classList.remove("mobile-open"));

  $("#sessionList").addEventListener("click", (e) => {
    const delBtn = e.target.closest("[data-del-sid]");
    if (delBtn) { e.stopPropagation(); deleteSessionById(delBtn.dataset.delSid); return; }
    const item = e.target.closest("[data-sid]");
    if (item) openSession(item.dataset.sid);
  });

  $("#modePills").addEventListener("click", (e) => {
    const pill = e.target.closest(".pill");
    if (pill) setMode(pill.dataset.mode);
  });

  $("#sendBtn").addEventListener("click", () => sendChat());
  $("#chatInput").addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); sendChat(); }
  });

  $("#chatMessages").addEventListener("click", (e) => {
    const starter = e.target.closest(".starter-btn");
    if (starter) { setMode(starter.dataset.mode); $("#chatInput").value = starter.dataset.text; $("#chatInput").focus(); return; }
    const refBtn = e.target.closest("[data-open-path]");
    if (refBtn) { switchTab("memories"); openMemory(refBtn.dataset.openPath); return; }
    const wikiBtn = e.target.closest("[data-wikilink]");
    if (wikiBtn) openByWikilink(wikiBtn.dataset.wikilink);
  });

  $("#extractProposalBtn").addEventListener("click", extractProposals);
  $("#closeProposalBtn").addEventListener("click", () => $("#proposalModal").classList.add("hidden"));
  $("#cancelProposalBtn").addEventListener("click", () => $("#proposalModal").classList.add("hidden"));
  $("#commitProposalBtn").addEventListener("click", commitSelectedProposals);

  // Memories events
  $("#memoryViewPills").addEventListener("click", (e) => {
    const pill = e.target.closest(".pill");
    if (pill) setMemoryView(pill.dataset.view);
  });
  let searchTimer = null;
  $("#memorySearchInput").addEventListener("input", () => {
    if (state.memoryView === "list") {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(loadMemories, 220);
    }
  });
  $("#memorySearchInput").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && state.memoryView === "semantic") runSemanticSearch();
  });
  $("#runSemanticBtn").addEventListener("click", runSemanticSearch);
  $("#clearAsOfBtn").addEventListener("click", () => { $("#searchAsOfInput").value = ""; runSemanticSearch(); });
  $("#emotionFilter").addEventListener("change", loadMemories);
  $("#highImportanceOnly").addEventListener("change", loadMemories);
  $("#refreshMemoriesBtn").addEventListener("click", refreshCurrentMemoryView);

  $("#categoryPills").addEventListener("click", (e) => {
    const pill = e.target.closest(".pill");
    if (!pill) return;
    state.currentCategory = pill.dataset.cat;
    loadMemories();
  });

  $("#memoryCards").addEventListener("click", (e) => {
    const openBtn = e.target.closest("[data-open-path]");
    if (openBtn) { openMemory(openBtn.dataset.openPath); return; }
    const card = e.target.closest("[data-path]");
    if (card) openMemory(card.dataset.path);
  });

  $("#backToListBtn").addEventListener("click", () => $(".memories-layout").classList.remove("reading-mobile"));
  $("#toggleEditBtn").addEventListener("click", () => setReaderEditMode(true));
  $("#cancelEditBtn").addEventListener("click", () => setReaderEditMode(false));
  $("#saveEditBtn").addEventListener("click", saveCurrentMemory);
  $("#readerRendered").addEventListener("click", (e) => {
    const wikiBtn = e.target.closest("[data-wikilink]");
    if (wikiBtn) openByWikilink(wikiBtn.dataset.wikilink);
  });

  // Inbox events
  $("#moodChips").addEventListener("click", (e) => {
    const chip = e.target.closest(".chip");
    if (!chip) return;
    $$("#moodChips .chip").forEach((c) => c.classList.remove("active"));
    chip.classList.add("active");
    $("#inboxMoodInput").value = chip.dataset.mood;
  });
  $("#saveInboxBtn").addEventListener("click", saveInbox);
  $("#reloadInboxBtn").addEventListener("click", loadInboxPreview);
  $("#organizeInboxBtn").addEventListener("click", () => {
    switchTab("chat");
    startNewChat();
    setMode("reflect");
    sendChat("请帮我读取 99-收件箱/inbox.md 和近期经历，整理出值得归档的经历、情绪洞察与待更新事项。");
  });

  // Settings events
  $("#addProviderBtn").addEventListener("click", () => {
    if (!state.config) return;
    state.config.providers.push({
      id: `custom-${Date.now()}`,
      name: "新中转站 / 模型",
      kind: "openai_compatible",
      base_url: "https://api.openai.com/v1",
      model: "gpt-6.2-sol",
      has_api_key: false,
      api_key_masked: "",
    });
    renderSettings();
  });

  $("#providersList").addEventListener("change", (e) => {
    const kindSel = e.target.closest(".p-kind");
    if (!kindSel) return;
    const card = kindSel.closest(".provider-card");
    if (!card) return;
    const modelInput = card.querySelector(".p-model");
    const chipsBox = card.querySelector(".p-model-chips");
    if (chipsBox) {
      chipsBox.innerHTML = renderModelPresetChips(kindSel.value, modelInput ? modelInput.value.trim() : "");
    }
  });

  $("#providersList").addEventListener("click", async (e) => {
    const modelChip = e.target.closest(".model-preset-chip");
    if (modelChip) {
      const card = modelChip.closest(".provider-card");
      if (card) {
        const modelInput = card.querySelector(".p-model");
        if (modelInput) modelInput.value = modelChip.dataset.model || "";
        card.querySelectorAll(".model-preset-chip").forEach((c) => c.classList.toggle("active", c === modelChip));
      }
      return;
    }
    const delBtn = e.target.closest(".del-provider-btn");
    if (delBtn) {
      if (state.config.providers.length <= 1) return showToast("至少保留 1 个模型配置");
      state.config.providers.splice(Number(delBtn.dataset.idx), 1);
      renderSettings();
      return;
    }
    const testBtn = e.target.closest(".test-provider-btn");
    if (testBtn) {
      await saveSettings();
      testBtn.disabled = true;
      testBtn.textContent = "测试中...";
      try {
        const res = await apiFetch("/api/config/test", { method: "POST", body: JSON.stringify({ provider_id: testBtn.dataset.pid }) });
        showToast(`✅ ${res.provider} 连通成功：${res.reply}`, 3200);
      } catch (err) {
        showToast(`❌ 连通失败: ${err.message}`, 4500);
      } finally {
        testBtn.disabled = false;
        testBtn.textContent = "测试连通";
      }
    }
  });

  $("#saveConfigBtn").addEventListener("click", () => saveSettings());
  $("#clearAccessTokenBtn").addEventListener("click", () => saveSettings({ clear_access_token: true }));
  $("#rebuildIndexBtn").addEventListener("click", rebuildVectorIndex);
  $("#reloadGitBtn").addEventListener("click", loadGitHistory);
}

async function bootstrap() {
  renderChatMessages();
  await Promise.all([loadStats(), loadConfig(), loadSessions()]);
}

initTheme();
bindEvents();
checkAuth().then((ok) => {
  if (ok) bootstrap();
});
