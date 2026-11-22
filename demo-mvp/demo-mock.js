// Standalone Interactive Demo MVP Mock Layer
// Intercepts /api/* requests in-browser using curated fictional personal-growth sample memories.
// Zero backend required — works directly via file:// or any static web host.
(function () {
  const realFetch = window.fetch.bind(window);

  const CATEGORIES = [
    { id: "00-核心自我", label: "核心自我" },
    { id: "01-人生章节", label: "人生章节" },
    { id: "02-经历与感受", label: "经历与感受" },
    { id: "03-重要关系", label: "重要关系" },
    { id: "04-决策实验室", label: "决策实验室" },
    { id: "05-认知演进与反思", label: "认知演进" },
    { id: "99-收件箱", label: "收件箱" },
  ];

  const demoDocs = new Map([
    [
      "00-核心自我/values.md",
      {
        path: "00-核心自我/values.md",
        title: "核心价值观与人生底线（示例）",
        category: "00-核心自我",
        category_label: "核心自我",
        privacy: "private",
        importance: 10,
        event_time: "2026-01-10",
        recorded_at: "2026-01-10",
        emotions: ["清醒", "笃定"],
        emotions_detail: [
          { name: "笃定", intensity: 8, valence: "positive", trigger: "完成年度复盘后明确不愿牺牲健康换头衔", body: "胸口放松、呼吸变深", thought: "长期主义比短期焦虑更重要" }
        ],
        people: [],
        wikilinks: ["02-经历与感受/2025/2025-09-12-放弃高压高薪岗位"],
        body: "# 核心价值观与人生底线\n\n1. **时间自主权与身心可持续**：拒绝长期剥夺睡眠与思考空间的组织。\n2. **真实创造与复利**：优先做能积累可迁移能力与长期作品的事。\n3. **真诚关系**：不靠讨好维持关系，保留说「不」的权利。\n\n## 关联记忆\n- [[02-经历与感受/2025/2025-09-12-放弃高压高薪岗位]]",
        updated_ts: Date.now() / 1000 - 3600,
      },
    ],
    [
      "01-人生章节/2024-2026-从追逐外部认可到建立内在坐标.md",
      {
        path: "01-人生章节/2024-2026-从追逐外部认可到建立内在坐标.md",
        title: "2024–2026：从追逐外部认可到建立内在坐标",
        category: "01-人生章节",
        category_label: "人生章节",
        privacy: "private",
        importance: 9,
        event_time: "2024-06-01",
        recorded_at: "2026-03-01",
        emotions: ["迷茫", "释然"],
        emotions_detail: [
          { name: "释然", intensity: 7, valence: "positive", trigger: "开始按自己的节奏评估机会", body: "肩颈不再长期紧绷", thought: "不需要向所有人证明自己很成功" }
        ],
        people: ["陈明"],
        wikilinks: ["00-核心自我/values", "03-重要关系/陈明"],
        body: "# 从追逐外部认可到建立内在坐标\n\n过去两年最大的变化，是发现很多焦虑并不来自「缺钱」，而是来自害怕在同龄人坐标系里掉队。\n\n- [转折] 2025 年秋天主动拒绝一份高薪高压 Offer 后，反而找回了持续创造的状态。\n- 关键对话参见 [[03-重要关系/陈明]]。",
        updated_ts: Date.now() / 1000 - 7200,
      },
    ],
    [
      "02-经历与感受/2025/2025-09-12-放弃高压高薪岗位.md",
      {
        path: "02-经历与感受/2025/2025-09-12-放弃高压高薪岗位.md",
        title: "放弃高压高薪岗位后的那个周末",
        category: "02-经历与感受",
        category_label: "经历与感受",
        privacy: "private",
        importance: 9,
        event_time: "2025-09-12",
        recorded_at: "2025-09-13",
        emotions: ["焦虑", "释然"],
        emotions_detail: [
          { name: "焦虑", intensity: 8, valence: "negative", trigger: "签字前一晚反复比较薪资涨幅", body: "胃部发紧、失眠到凌晨两点", thought: "错过这个机会以后会不会后悔" },
          { name: "释然", intensity: 9, valence: "positive", trigger: "发出婉拒邮件的十分钟后", body: "瞬间困意袭来，睡了十小时好觉", thought: "身体比大脑更诚实" }
        ],
        people: ["陈明"],
        wikilinks: ["00-核心自我/values", "03-重要关系/陈明"],
        body: "# 放弃高压高薪岗位后的那个周末\n\n## 发生了什么\n拿到一家高强度团队的 Offer，涨薪 40%，但明确要求每周六天且随时待命。\n\n## 我当时怎么想 & 什么感受\n签字前非常纠结，怕别人觉得我不上进；真正婉拒之后却感到极度轻松。\n\n## 关键观察 (Observations)\n- [感受] 身体出现失眠与胃部发紧，是触碰「自主权底线」的强信号。\n- [模式] 每次被「错过就可惜」驱动做决定，事后大概率消耗自己。\n\n## 关联记忆 (Relations)\n- [[00-核心自我/values]]\n- [[03-重要关系/陈明]]",
        updated_ts: Date.now() / 1000 - 10800,
      },
    ],
    [
      "03-重要关系/陈明.md",
      {
        path: "03-重要关系/陈明.md",
        title: "陈明（清醒的诤友）",
        category: "03-重要关系",
        category_label: "重要关系",
        privacy: "private",
        importance: 8,
        event_time: "2025-08-20",
        recorded_at: "2025-09-15",
        emotions: ["信任", "充能"],
        emotions_detail: [
          { name: "充能", intensity: 8, valence: "positive", trigger: "每次深度长谈后头脑变得非常清晰", body: "神清气爽", thought: "真正的朋友敢直接指出我的盲区" }
        ],
        people: ["陈明"],
        wikilinks: ["02-经历与感受/2025/2025-09-12-放弃高压高薪岗位"],
        body: "# 陈明\n\n大学认识十年的朋友，从不顺着我夸，总能一针见血提醒我别为了面子接下消耗自己的摊子。\n\n- 关联事件：[[02-经历与感受/2025/2025-09-12-放弃高压高薪岗位]]",
        updated_ts: Date.now() / 1000 - 14400,
      },
    ],
    [
      "04-决策实验室/进行中/2026-11-是否启动独立副业产品.md",
      {
        path: "04-决策实验室/进行中/2026-11-是否启动独立副业产品.md",
        title: "决策推演：是否用 3 个月业余时间做独立产品",
        category: "04-决策实验室",
        category_label: "决策实验室",
        privacy: "private",
        importance: 8,
        event_time: "2026-11-15",
        recorded_at: "2026-11-15",
        emotions: ["兴奋", "审慎"],
        emotions_detail: [
          { name: "兴奋", intensity: 7, valence: "positive", trigger: "构想出真实解决自己痛点的小工具", body: "精力充沛", thought: "先用最小原型验证，别一开始辞职梭哈" }
        ],
        people: [],
        wikilinks: ["00-核心自我/values", "05-认知演进与反思/观点演变日志"],
        body: "# 决策推演：是否启动独立副业产品\n\n## 候选选项\n1. **低成本小步试错（当前倾向）**：每周固定投入 8 小时，3 周内做出可演示 MVP 并找 10 位种子用户。\n2. **暂缓观察**：先记录需求痛点清单，下月再决定。\n3. **直接辞职全职开发**：违反现金流与身心安全底线，排除。\n\n## 1 周内最小验证动作\n本周六完成核心交互原型，并约 3 位目标用户访谈。",
        updated_ts: Date.now() / 1000 - 1800,
      },
    ],
    [
      "05-认知演进与反思/观点演变日志.md",
      {
        path: "05-认知演进与反思/观点演变日志.md",
        title: "观点演变日志",
        category: "05-认知演进与反思",
        category_label: "认知演进",
        privacy: "private",
        importance: 9,
        event_time: "2026-10-01",
        recorded_at: "2026-10-01",
        emotions: ["通透"],
        emotions_detail: [],
        people: [],
        wikilinks: ["00-核心自我/values"],
        body: "# 观点演变日志\n\n### 2026-10 · 关于「效率与休息」\n- **旧观点（2024）**：只要把日程排满，就是自律和成长。\n- **新认知（2026）**：高密度的无效忙碌只会毁掉判断力，留白本身是重要决策的生产力。",
        updated_ts: Date.now() / 1000 - 900,
      },
    ],
    [
      "99-收件箱/inbox.md",
      {
        path: "99-收件箱/inbox.md",
        title: "速记收件箱",
        category: "99-收件箱",
        category_label: "收件箱",
        privacy: "private",
        importance: 5,
        event_time: "2026-11-21",
        recorded_at: "2026-11-21",
        emotions: ["充能"],
        emotions_detail: [],
        people: [],
        wikilinks: [],
        body: "# 速记收件箱\n\n### 2026-11-21 21:30 `[情绪: 充能]`\n今晚关掉通知专注写了 90 分钟方案，完全没有刷手机，感觉内心很安静。",
        updated_ts: Date.now() / 1000 - 600,
      },
    ],
  ]);

  const demoSessions = [
    {
      id: "demo_sess_1",
      title: "是否接受跨城管理岗邀约（9步决策示例）",
      mode: "decision",
      provider_id: "demo-advisor",
      created_at: "2026-11-20T20:15:00+08:00",
      updated_at: "2026-11-20T20:22:00+08:00",
      messages: [
        {
          id: 1,
          role: "user",
          content: "最近收到一个跨城管理岗邀约，薪资高 30%，但我有点隐约的不安，想按 9 步反讨好决策流程帮我拆解一下。",
          reasoning: "",
          model: "",
          provider_name: "",
          references: [],
        },
        {
          id: 2,
          role: "assistant",
          content:
            "### 1. 问题重述与判断标准\n核心问题不是「要不要多赚 30%」，而是：**这份新岗位带来的经济收益，是否值得交换你对时间自主权、关系网络与身心节奏的控制？**\n\n### 2. 结合你的核心自我与历史证据\n- 依据 [[00-核心自我/values.md]]，你把「时间自主权与身心可持续」排在第一位。\n- 依据 [[02-经历与感受/2025/2025-09-12-放弃高压高薪岗位.md]]，你上一次面对高薪高压邀约时出现失眠和胃部发紧，婉拒后反而极其释然。\n\n### 3. 强制反方（Critic）提醒\n- **反方论点**：你可能正把「熟悉感」美化成「自主权」，如果这个管理岗能给你全新的杠杆能力，直接拒绝也许会错过一次阶梯成长。\n- **事实 vs 推断**：薪资高 30% 是事实；「一定会高压消耗」目前只是推断，尚未核实该团队的真实加班文化。\n\n### 4. 下一步 1 周内最小验证动作\n1. 约对方团队里一位非直属同事喝咖啡，了解真实工作节奏；\n2. 列出 3 条不可妥协的红线（如每周工时上限、远程弹性），在终面明确对齐；\n3. 聊完后点击下方 **✨ 提炼记忆提案**，把本次推演沉淀进 `04-决策实验室/`。",
          reasoning: "已检索核心自我 values.md 与 2025-09-12 高压岗位经历，检测到相似的「高薪 vs 自主权」张力，启用反讨好 Critic 视角区分事实与推断。",
          model: "demo-mvp-simulator",
          provider_name: "Demo MVP 演示引擎",
          references: [
            { path: "00-核心自我/values.md", title: "核心价值观与人生底线（示例）", category: "核心自我", importance: 10, source: "核心自我", reasons: ["常驻核心记忆"] },
            { path: "02-经历与感受/2025/2025-09-12-放弃高压高薪岗位.md", title: "放弃高压高薪岗位后的那个周末", category: "经历与感受", importance: 9, source: "4路混合召回", reasons: ["中文语义 0.89", "高显著 9/10"] },
          ],
        },
      ],
    },
  ];

  const demoSnapshots = [
    { hash: "a7c3f19", date: "2026-11-21 21:30:12 +0800", message: "inbox: 速记追加（Demo 示例）" },
    { hash: "8e21b04", date: "2026-11-15 19:05:44 +0800", message: "memory: 半自动确认写入 1 项 (2026-11-是否启动独立副业产品)" },
    { hash: "3d90c72", date: "2026-10-01 11:20:03 +0800", message: "edit: 更新观点演变日志" },
  ];

  function toSummary(d) {
    return {
      path: d.path,
      title: d.title,
      category: d.category,
      category_label: d.category_label,
      privacy: d.privacy,
      importance: d.importance,
      event_time: d.event_time,
      recorded_at: d.recorded_at,
      emotions: d.emotions || [],
      people: d.people || [],
      wikilinks: d.wikilinks || [],
      snippet: (d.body || "").replace(/[#>*`\n]+/g, " ").trim().slice(0, 140),
      updated_ts: d.updated_ts || Date.now() / 1000,
    };
  }

  function jsonResp(obj, status = 200) {
    return new Response(JSON.stringify(obj), {
      status,
      headers: { "Content-Type": "application/json; charset=utf-8" },
    });
  }

  function buildDemoReply(mode, userText) {
    const snippet = (userText || "").slice(0, 36);
    if (mode === "decision") {
      return {
        reasoning: "Demo MVP：已召回核心自我与 2025 年历史选择样本，按 9 步反讨好决策框架拆解。",
        text: `### 🧭 9 步反讨好决策拆解（Demo MVP 演示）\n\n围绕你提到的「**${snippet}**」，结合示例记忆库中的 [[00-核心自我/values.md]] 与 [[02-经历与感受/2025/2025-09-12-放弃高压高薪岗位.md]]：\n\n1. **真实标准**：优先检验它是否增强你的长期自主权与复利能力。\n2. **3 个选项**：\n   - 选项 A：**低成本小步试错**（先用 1 周最小成本验证核心假设）；\n   - 选项 B：**暂缓 72 小时**（避开当下情绪高峰再做拍板）；\n   - 选项 C：**果断推进并设好退出止损线**。\n3. **反方提醒（Critic）**：注意区分「真实渴望」与「怕错过带来的焦虑」。\n\n> 提示：你现在可以点击下方 **「✨ 提炼记忆提案」**，完整体验半自动确认写入流程！`,
      };
    }
    if (mode === "interview") {
      return {
        reasoning: "Demo MVP：冷启动温和访谈模式，每次只问 1-2 个有画面感的问题。",
        text: `谢谢你愿意先聊起「${snippet}」。我们先不着急填表，轻松聊两个具体的问题：\n\n1. 回想过去 2～3 年里，有没有哪一个瞬间让你突然觉得 **「原来我真正在乎的是这个」**？\n2. 当你感到特别充能或特别消耗时，通常是在和什么样的人、做什么样的事在一起？\n\n聊完这两句，就可以点下方 **✨ 提炼记忆提案** 看看系统如何把它沉淀成结构化 Markdown 记忆。`,
      };
    }
    return {
      reasoning: "Demo MVP：已结合示例核心自我与近期收件箱记录生成示范回复。",
      text: `听起来「${snippet}」对你当下很有触动。\n\n在示例记忆库里，你之前也在 [[05-认知演进与反思/观点演变日志.md]] 写过：**留白和觉察本身就是判断力的一部分**。可以先不用急着下结论，试着拆成两层看看：\n- **事实层**：客观上发生了什么？\n- **感受层**：身体和情绪最先冒出的信号是什么？\n\n*（当前为静态 Demo MVP 演示模式；真实私密使用请直接打开原生 macOS App 或连接你的 VPS 远程后端。）*`,
    };
  }

  function makeSSEStream(events) {
    const encoder = new TextEncoder();
    return new ReadableStream({
      async start(controller) {
        for (const ev of events) {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(ev)}\n\n`));
          await new Promise((r) => setTimeout(r, ev.type === "text" ? 28 : 40));
        }
        controller.close();
      },
    });
  }

  window.fetch = async function (input, init = {}) {
    const urlStr = typeof input === "string" ? input : input.url;
    if (!urlStr.startsWith("/api/")) {
      return realFetch(input, init);
    }

    const u = new URL(urlStr, "http://demo.local");
    const path = u.pathname;
    const method = (init.method || "GET").toUpperCase();
    let body = {};
    if (init.body && typeof init.body === "string") {
      try { body = JSON.parse(init.body); } catch (_) {}
    }

    if (path === "/api/auth/status") {
      return jsonResp({ auth_required: false, authenticated: true, deployment_mode: "demo_mvp", version: "0.12-demo" });
    }

    if (path === "/api/health") {
      return jsonResp({
        ok: true,
        version: "0.12-demo",
        deployment_mode: "demo_mvp",
        stats: { total: demoDocs.size, by_category: {}, high_importance_events: 5, sensitive_protected: 0, vault_path: "Demo MVP 示例记忆库（内存运行）" },
        index: { total_docs: demoDocs.size, embedded_docs: demoDocs.size, embedding_model: "Demo 离线模拟引擎", last_sync: "刚刚", graph_edges: 5 },
        active_provider_id: "demo-advisor",
      });
    }

    if (path === "/api/config") {
      return jsonResp({
        deployment_mode: "demo_mvp",
        vault_path: "Demo MVP 示例记忆库（纯前端演示，不落盘）",
        public_base_url: "https://decision.sakuramu.edu.kg",
        mcp_endpoint_url: "https://decision.sakuramu.edu.kg/mcp",
        has_access_token: false,
        active_provider_id: "demo-advisor",
        providers: [
          { id: "demo-advisor", name: "Demo MVP 演示引擎", kind: "openai_compatible", base_url: "demo://local", api_key: "", has_api_key: true, api_key_masked: "demo...mock", model: "demo-simulator", temperature: 0.7 },
        ],
        embedding: { mode: "local_bge_zh", local_model: "BAAI/bge-small-zh-v1.5 (Demo)", api_base_url: "", api_key: "", has_api_key: false, api_model: "" },
        network: { local_url: "demo://mvp", lan_url: "", tailscale_url: "" },
      });
    }

    if (path === "/api/config/test") {
      return jsonResp({ ok: true, provider: "Demo MVP 演示引擎", model: "demo-simulator", reply: "演示引擎连接成功" });
    }

    if (path === "/api/index/rebuild") {
      return jsonResp({ ok: true, total_docs: demoDocs.size, embedded_docs: demoDocs.size, graph_edges: 5 });
    }

    if (path === "/api/git/history") {
      return jsonResp({ items: demoSnapshots });
    }

    if (path === "/api/sessions" && method === "GET") {
      return jsonResp({
        items: demoSessions.map((s) => ({
          id: s.id, title: s.title, mode: s.mode, provider_id: s.provider_id,
          created_at: s.created_at, updated_at: s.updated_at, message_count: s.messages.length,
        })),
      });
    }

    if (path.startsWith("/api/sessions/")) {
      const sid = decodeURIComponent(path.slice("/api/sessions/".length));
      const idx = demoSessions.findIndex((s) => s.id === sid);
      if (idx === -1) return jsonResp({ detail: "对话不存在" }, 404);
      if (method === "DELETE") {
        demoSessions.splice(idx, 1);
        return jsonResp({ ok: true });
      }
      return jsonResp(demoSessions[idx]);
    }

    if (path === "/api/chat/stream" && method === "POST") {
      const msgs = body.messages || [];
      const lastUser = [...msgs].reverse().find((m) => m.role === "user")?.content || "";
      let sess = demoSessions.find((s) => s.id === body.session_id);
      if (!sess) {
        sess = {
          id: `demo_${Date.now().toString(36)}`,
          title: lastUser.slice(0, 22) || "演示对话",
          mode: body.mode || "chat",
          provider_id: "demo-advisor",
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
          messages: [],
        };
        demoSessions.unshift(sess);
      }
      sess.messages.push({ id: Date.now(), role: "user", content: lastUser, reasoning: "", model: "", provider_name: "", references: [] });
      const sim = buildDemoReply(body.mode || "chat", lastUser);
      const refs = [
        { path: "00-核心自我/values.md", title: "核心价值观与人生底线（示例）", category: "核心自我", importance: 10, source: "核心自我", reasons: ["常驻核心记忆"] },
        { path: "02-经历与感受/2025/2025-09-12-放弃高压高薪岗位.md", title: "放弃高压高薪岗位后的那个周末", category: "经历与感受", importance: 9, source: "4路混合召回", reasons: ["Demo 语义召回"] },
      ];
      sess.messages.push({
        id: Date.now() + 1,
        role: "assistant",
        content: sim.text,
        reasoning: sim.reasoning,
        model: "demo-simulator",
        provider_name: "Demo MVP 演示引擎",
        references: refs,
      });
      sess.updated_at = new Date().toISOString();

      const chunks = sim.text.match(/.{1,18}/gs) || [sim.text];
      const events = [
        { type: "meta", session_id: sess.id, provider_id: "demo-advisor", provider_name: "Demo MVP 演示引擎", model: "demo-simulator", references: refs },
        { type: "reasoning", delta: sim.reasoning },
        ...chunks.map((c) => ({ type: "text", delta: c })),
        { type: "done", session_id: sess.id },
      ];
      return new Response(makeSSEStream(events), {
        status: 200,
        headers: { "Content-Type": "text/event-stream; charset=utf-8" },
      });
    }

    if (path === "/api/proposals/extract" && method === "POST") {
      const today = new Date().toISOString().slice(0, 10);
      return jsonResp({
        provider_name: "Demo MVP 演示引擎",
        proposals: [
          {
            id: "demo_prop_1",
            action: "create",
            path: `02-经历与感受/${today.slice(0, 4)}/${today}-演示提炼记忆.md`,
            exists: false,
            level: 2,
            title: "对话洞察：明确自己的决策边界",
            summary: "从本次 Demo 对话中提炼的核心思考与感受，供你体验半自动确认落盘。",
            importance: 8,
            emotions: ["清醒", "释然"],
            relations: ["00-核心自我/values"],
            privacy: "private",
            evidence: "用户在演示对话中梳理了当前权衡与真实关注点。",
            content: `---\ntitle: 对话洞察：明确自己的决策边界\nevent_time: ${today}\nrecorded_at: ${today}\nimportance: 8\nprivacy: private\nemotions:\n  - name: 清醒\n    intensity: 8\n    valence: positive\n---\n\n# 对话洞察：明确自己的决策边界\n\n## 发生了什么\n通过 Demo MVP 完成了一次结构化思考演练。\n\n## 关联记忆 (Relations)\n- [[00-核心自我/values]]\n`,
            diff: "",
          },
        ],
      });
    }

    if (path === "/api/proposals/commit" && method === "POST") {
      const written = [];
      for (const item of body.items || []) {
        const cat = (item.path || "").split("/")[0] || "02-经历与感受";
        const catLabel = CATEGORIES.find((c) => c.id === cat)?.label || "经历与感受";
        demoDocs.set(item.path, {
          path: item.path,
          title: item.title || item.path,
          category: cat,
          category_label: catLabel,
          privacy: item.privacy || "private",
          importance: 8,
          event_time: new Date().toISOString().slice(0, 10),
          recorded_at: new Date().toISOString().slice(0, 10),
          emotions: ["清醒"],
          emotions_detail: [],
          people: [],
          wikilinks: ["00-核心自我/values"],
          body: item.content,
          updated_ts: Date.now() / 1000,
        });
        written.push(item.path);
      }
      demoSnapshots.unshift({
        hash: Math.random().toString(16).slice(2, 9),
        date: new Date().toISOString().replace("T", " ").slice(0, 19),
        message: `memory: Demo 确认写入 ${written.length} 项`,
      });
      return jsonResp({ ok: true, written });
    }

    if (path === "/api/memories" && method === "GET") {
      const cat = u.searchParams.get("category") || "all";
      const q = (u.searchParams.get("q") || "").trim().toLowerCase();
      const emo = (u.searchParams.get("emotion") || "").trim().toLowerCase();
      const minImp = Number(u.searchParams.get("min_importance") || "1");
      const allEmos = new Set();
      const items = [];
      for (const d of demoDocs.values()) {
        (d.emotions || []).forEach((e) => allEmos.add(e));
        if (cat !== "all" && d.category !== cat) continue;
        if (d.importance < minImp) continue;
        if (emo && !(d.emotions || []).some((e) => e.toLowerCase().includes(emo))) continue;
        if (q && !`${d.title} ${d.body} ${(d.people || []).join(" ")}`.toLowerCase().includes(q)) continue;
        items.push(toSummary(d));
      }
      return jsonResp({ categories: CATEGORIES, emotions: Array.from(allEmos), items, total: items.length });
    }

    if (path === "/api/memories/search" && method === "GET") {
      const q = (u.searchParams.get("q") || "").trim().toLowerCase();
      const items = Array.from(demoDocs.values())
        .map((d) => {
          const hit = `${d.title} ${d.body} ${(d.emotions || []).join(" ")}`.toLowerCase().includes(q);
          return { ...toSummary(d), score: hit ? 0.92 : 0.48, semantic: hit ? 0.87 : 0.44, reasons: [hit ? "Demo 语义命中" : "高显著关联"] };
        })
        .sort((a, b) => b.score - a.score);
      return jsonResp({ items, total: items.length, as_of: u.searchParams.get("as_of") || "" });
    }

    if (path === "/api/memories/timeline") {
      const items = Array.from(demoDocs.values())
        .filter((d) => ["01-人生章节", "02-经历与感受", "04-决策实验室", "05-认知演进与反思"].includes(d.category))
        .map((d) => ({ ...toSummary(d), valid_from: d.event_time, invalid_at: "", superseded_by: "" }))
        .sort((a, b) => (b.event_time || "").localeCompare(a.event_time || ""));
      return jsonResp({ items, total: items.length });
    }

    if (path === "/api/memories/graph") {
      const nodes = Array.from(demoDocs.values()).map((d) => ({
        id: d.path, title: d.title, category: d.category, category_label: d.category_label, importance: d.importance, emotions: d.emotions,
      }));
      const edges = [
        { source: "02-经历与感受/2025/2025-09-12-放弃高压高薪岗位.md", target: "00-核心自我/values.md", label: "values", relation_type: "wikilink", weight: 1.0 },
        { source: "02-经历与感受/2025/2025-09-12-放弃高压高薪岗位.md", target: "03-重要关系/陈明.md", label: "陈明", relation_type: "shared_person", weight: 0.7 },
        { source: "01-人生章节/2024-2026-从追逐外部认可到建立内在坐标.md", target: "03-重要关系/陈明.md", label: "陈明", relation_type: "wikilink", weight: 1.0 },
        { source: "04-决策实验室/进行中/2026-11-是否启动独立副业产品.md", target: "00-核心自我/values.md", label: "values", relation_type: "wikilink", weight: 1.0 },
        { source: "04-决策实验室/进行中/2026-11-是否启动独立副业产品.md", target: "05-认知演进与反思/观点演变日志.md", label: "观点演变日志", relation_type: "wikilink", weight: 1.0 },
      ];
      return jsonResp({ nodes, edges });
    }

    if (path === "/api/memories/file" && method === "GET") {
      const rel = u.searchParams.get("path") || "";
      const doc = demoDocs.get(rel);
      if (!doc) return jsonResp({ detail: "示例记忆不存在" }, 404);
      return jsonResp({ ...toSummary(doc), frontmatter: {}, body: doc.body, raw: doc.body, emotions_detail: doc.emotions_detail || [] });
    }

    if (path === "/api/memories/file" && method === "PUT") {
      const doc = demoDocs.get(body.path);
      if (doc) {
        doc.body = body.content || "";
        doc.updated_ts = Date.now() / 1000;
      }
      return jsonResp({ ok: true, path: body.path });
    }

    if (path === "/api/inbox" && method === "POST") {
      const inbox = demoDocs.get("99-收件箱/inbox.md");
      const now = new Date().toISOString().replace("T", " ").slice(0, 16);
      const moodTag = body.mood ? ` \`[情绪: ${body.mood}]\`` : "";
      inbox.body = `${inbox.body}\n\n### ${now}${moodTag}\n${body.text || ""}`;
      return jsonResp({ ok: true, path: "99-收件箱/inbox.md" });
    }

    return jsonResp({ ok: true });
  };
})();
