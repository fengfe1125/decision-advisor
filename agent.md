# Agent 开发者与维护指南 (`agent.md`)

> **项目名称**：成长决策顾问（Decision Advisor）  
> **当前版本**：`v0.17`  
> **核心定位**：Local-First 个人成长决策顾问与双时间轴长期记忆引擎（原生 macOS SwiftUI 客户端 + 内置/远程 VPS 双模 FastAPI 后端 + 4 路中文混合检索 + 官方 ChatGPT OAuth 订阅直连 & Remote MCP）

本文档面向参与本项目的 AI Coding Agent 与开发者，详细梳理**后端架构设计、核心模块职责、数据库与 API 规范**以及**目前程序的整体现状与运维工作流**。

---

## 〇、版本号规范（每次修改必做）

> **一句话：每次修改都要升级版本号；用户没有指定版本号时，默认在当前版本上 +0.01。macOS 客户端与 VPS 后端共用同一个版本号，同步升级。**

| 规则 | 说明 |
| :--- | :--- |
| 格式 | `X.YY`（两位小数），如 `0.12` → `0.13` → … → `0.99` → `1.00`；标签写作 `v0.13` |
| 默认步长 | 每个合入 `main` 的功能 / 修复 / 文档改动 PR **+0.01**；用户明确给出版本号（如“这次发 0.20”）时以用户为准 |
| 统一范围 | macOS 客户端（`CFBundleShortVersionString`）、VPS 后端（`GET /` 与 `/api/health` 返回的 `version`、MCP `serverInfo.version`）始终一致。只改了其中一端也一起升级 |
| 唯一真源 | `app/config.py` 中的 `APP_VERSION`。**不要手改各处**，统一执行 `./bump-version.sh`（默认 +0.01）或 `./bump-version.sh 0.20`，脚本会同步改写 `app/config.py`、`pyproject.toml`、`uv.lock`、`macos/build_app.sh` 与本文件顶部「当前版本」 |
| Build 号 | `CFBundleVersion` 由版本号自动推导（`0.13` → `13`，`1.00` → `100`），无需手改 |
| 一个 PR 一次 | 同一个功能分支只升级一次版本号；在分支内首次提交时执行 `./bump-version.sh`，PR 标题/描述中注明新版本号 |

发版与生效顺序（合并 PR 之后）：

1. **VPS**：在已合并的 `main` 上运行 `./deploy/deploy-vps.sh`，`/api/health` 应返回新版本号。
2. **本机 macOS**：`./macos/build_app.sh --install` 覆盖安装 `/Applications/成长决策顾问.app`。
3. **公开发布（供 App 内「检查更新」使用）**：`scripts/sync-mirror.sh decision-advisor --push` 同步镜像 → `./macos/build_app.sh --package` 生成 `macos/dist/DecisionAdvisor-v<X.YY>-macOS.zip` → 在 monorepo 打 `decision-advisor/v<X.YY>` 标签，在公开仓库打 `v<X.YY>` 标签并发布 Release，**附件名必须是 `DecisionAdvisor-v<X.YY>-macOS.zip`**（App 内更新器按此名称查找安装包，并用 GitHub 提供的 SHA-256 校验）。

---

## 一、目前程序的现状总览（v0.12）

当前项目已完成 **`v0.12` 全栈生产闭环**，整体架构由早期的单机 Web 应用演进为**「纯 API 后端 + 原生 macOS 客户端（内置离线引擎 / 24x7 远程 VPS 双模切换）+ 独立离线 Demo MVP」**：

| 子系统 | 目录 / 位置 | 当前状态 | 关键现状说明 |
| :--- | :--- | :--- | :--- |
| **1. 核心纯 API 后端** | `decision-advisor/app/` | ✅ **生产就绪** | 基于 FastAPI + SQLite (WAL) + FastEmbed (`BAAI/bge-small-zh-v1.5`)。**生产后端已下线内置 Web 页面**（`GET /` 仅返回服务状态 JSON），专注于提供 REST/SSE 接口、ChatGPT OAuth 2.0 登录与 Remote MCP 服务。 |
| **2. 原生 macOS 客户端** | `decision-advisor/macos/`<br/>`/Applications/成长决策顾问.app` | ✅ **生产就绪** | Swift 6.0 + SwiftUI + AppKit（macOS 14.0+，通过 `vtool` 注入 `LC_BUILD_VERSION` 适配 macOS 27 Liquid Glass）。内置四大工作区（顾问对话、记忆与图谱、10 秒收件箱、模型与设置），支持**内置本地引擎 (`127.0.0.1:18789`)** 与**远程 VPS (`https://decision.sakuramu.edu.kg`)** 一键无缝切换。 |
| **3. 24/7 远程 VPS 服务** | `decision-advisor/deploy/`<br/>主机 `murmur-new-vps` | ✅ **在线运行** | 部署于 VPS `/opt/decision-advisor`，由 `systemd` (`decision-advisor.service`) 守护在 `127.0.0.1:8789`，前端由 Caddy 提供自动 HTTPS 反代（`https://decision.sakuramu.edu.kg`），供 macOS 客户端、ChatGPT Remote MCP 与未来移动端 24/7 访问。 |
| **4. 记忆库唯一真源** | 本机 iCloud：`~/Library/Mobile Documents/com~apple~CloudDocs/决策`<br/>VPS：`/opt/decision-advisor/data/vault` | ✅ **双向可同步** | 100% 纯净 Markdown 文件，包含 8 大分类目录。Git 版本库（`.memory-git`）与状态库（`advisor_state.db`）物理外置，彻底杜绝 iCloud 同步冲突。支持通过 `./deploy/deploy-vps.sh --sync-vault` 推送至云端，或在 macOS App 内一键将云端记忆打包 `.zip` 下载解压回本机 iCloud。 |
| **5. 离线交互式 Demo** | `decision-advisor/demo-mvp/` | ✅ **独立归档** | 原 Web 前端已改造为零后端依赖、纯内存 Mock 数据的静态演示原型，直接打开 `demo-mvp/index.html` 即可体验完整交互。 |
| **6. 自动化测试套件** | `decision-advisor/tests/test_app.py` | ✅ **7/7 全绿通过** | 覆盖多模型请求构建与思考链解析、四级隐私防火墙、4 路混合检索与 `as_of` 双时间回溯、SQLite 会话与 SSE 流、OAuth 2.1 Remote MCP、整库 ZIP 导出、ChatGPT OAuth 2.0 PKCE + Responses API 全流程。 |

---

## 二、后端架构深度解析 (`app/`)

后端采用 **FastAPI + SQLite (WAL + FTS5) + 本地 ONNX 向量引擎 (FastEmbed) + 外置 Bare Git** 架构，共由 10 个核心模块组成：

```text
app/
├── main.py            # FastAPI 路由总入口、鉴权中间件、SSE 流式对话、提案提取与落盘、ChatGPT OAuth 路由
├── config.py          # 双模部署环境感知、5 类模型预设、Embedding 配置、敏感凭据掩码脱敏、网络地址探测
├── db.py              # SQLite (advisor_state.db) 连接管理、会话/消息持久化、向量/FTS5/图谱表、OAuth 2.1 表
├── memory_store.py    # Markdown 记忆库读写、路径防穿越、四级隐私防火墙、<private> 剥离、三级写权限与 Diff
├── search_index.py    # 4 路中文混合检索引擎（BGE 向量 + 词法 CJK + 图谱 1-Hop + 双时间 as_of 与显著性）
├── onboarding.py      # 核心自我 5 槽位完整度体检、3 分钟快速建档融合、槽位感知冷启动访谈引导
├── memory_importer.py # 跨 Agent 记忆导入解析引擎（提示词粘贴、ChatGPT/Claude 导出 JSON/ZIP、Mem0/PAM/Letta JSON）
├── prompts.py         # 4 大对话模式指令（含 9 步反讨好决策与槽位感知访谈）、对话/跨 Agent 导入提案 Prompt 与 JSON 解析
├── providers.py       # 多模型统一 HTTP/SSE 调用层（OpenAI Responses API / DeepSeek / OpenAI / Claude / Gemini）
├── chatgpt_oauth.py   # OpenAI 官方 Sign in with ChatGPT (OAuth 2.0 PKCE + 动态客户端注册 + 自动刷新 + 模型发现)
├── mcp_server.py      # 官方 ChatGPT Developer Mode 远程 MCP (Streamable HTTP POST /mcp + OAuth 2.1 PKCE)
└── git_backup.py      # 外置 .memory-git 自动快照与历史查询 + basic-memory 异步触发
```

### 1. 部署模式与配置管理 (`app/config.py`)

- **双部署模式 (`DeploymentMode`)**：
  - `embedded_local`（默认）：供本机调试（端口 `8789`）或 macOS App 内置引擎（端口 `18789`）使用，默认记忆库指向本机 iCloud `~/Library/Mobile Documents/com~apple~CloudDocs/决策`。
  - `remote_vps`：当环境变量 `ADVISOR_DEPLOYMENT_MODE=remote_vps` 时激活，默认记忆库指向 `$ADVISOR_DATA_DIR/vault`（在 VPS 上为 `/opt/decision-advisor/data/vault`）。
- **五大模型提供商类型 (`ProviderKind`)**：
  1. `chatgpt_oauth`：通过 OpenAI 官方 Sign in with ChatGPT 授权令牌直连 `https://api.openai.com/v1/responses`，默认模型 `gpt-5.4`。
  2. `deepseek`：DeepSeek 官方或兼容接口（默认 `deepseek-v4-pro`）。
  3. `openai_compatible`：OpenAI 官方或兼容中转站（默认 `gpt-6.2-sol`）。
  4. `claude`：Anthropic 原生 `/v1/messages` 接口（默认 `claude-sonnet-5-5`）。
  5. `gemini`：Google Gemini 原生 `/v1beta/models/{model}:streamGenerateContent` 接口（默认 `gemini-4-neon`）。
- **凭据安全原则**：
  - `config.local.json` 与 `chatgpt_oauth.local.json` 落盘时强制 `chmod 0600`。
  - `serialize_public_config()` 向前端/客户端返回配置时，所有 `api_key` 均清空为 `""`，仅返回 `has_api_key: bool` 与 `api_key_masked: "sk-xxxx...xxxx"`；更新配置时若前端未传新 key 且未传 `clear_api_key: true`，自动保留已有密钥。

### 2. SQLite 状态与索引数据库 (`app/db.py`)

数据库文件 `advisor_state.db` 开启 `PRAGMA journal_mode=WAL` 与 `PRAGMA foreign_keys=ON`，包含以下 7 张核心表：

1. **`sessions`**：对话会话列表（`id`, `title`, `mode`, `provider_id`, `created_at`, `updated_at`）。
2. **`messages`**：会话消息流（`id`, `session_id`, `role`, `content`, `reasoning`, `model`, `provider_name`, `references_json`, `created_at`）。支持跨设备恢复完整思考链与每轮引用的记忆胶囊。
3. **`proposals_log`**：半自动记忆提案审计日志（记录每次提取的 `proposals_json`、状态 `pending`/`committed` 及实际落盘的 `committed_paths_json`）。
4. **`doc_index`**：Markdown 记忆主索引表：
   - 基础元数据：`rel_path` (PK), `sha256`, `title`, `category`, `category_label`, `privacy`, `importance` (1~10), `mtime`, `indexed_at`
   - **双时间轴字段**：`event_time`（事件实际发生时间）、`recorded_at`（记录时间）、`valid_from`（认知生效时间）、`invalid_at`（认知失效时间）、`superseded_by`（被哪篇新认知迭代）
   - 结构化 JSON 字段：`emotions_json`、`people_json`、`chapters_json`、`observations_json`（提取正文中 `- [标签] 内容`）、`wikilinks_json`（提取正文中 `[[双链]]`）
   - 向量字段：`embedding_blob` (`float32` 归一化字节流)、`embedding_dim`、`embedding_model`
5. **`doc_fts`**：基于 SQLite `fts5` 的全文检索虚表（索引 `title`, `body_text`, `people_text`, `emotions_text`, `observations_text`）。
6. **`graph_edges`**：知识图谱关联边表（`src_path`, `dst_key`, `dst_path`, `relation_type`, `weight`），支持三类边：
   - `wikilink`（显式 `[[双链]]` 引用，权重 `1.0`）
   - `shared_person`（共同出现的人物，权重 `0.7`）
   - `shared_chapter`（共同归属的人生章节，权重 `0.6`）
7. **`oauth_clients` / `oauth_codes` / `oauth_tokens`**：内置 OAuth 2.1 授权服务器持久化表，供 ChatGPT Developer Mode 远程 MCP 动态注册客户端、校验 PKCE `code_challenge` 并签发有效期 30 天的 `da_mcp_*` 访问令牌（数据库仅存 SHA-256 哈希）。

### 3. Markdown 记忆真源与四级隐私防火墙 (`app/memory_store.py`)

- **8 大标准目录 (`CATEGORY_ORDER`)**：
  - `00-核心自我`（每次对话常驻全量加载：`identity.md`、`values.md`、`patterns.md`、`boundaries.md`、`goals.md`）
  - `01-人生章节`、`02-经历与感受`、`03-重要关系`、`04-决策实验室`（含 `进行中/` 与 `已复盘/`）、`05-认知演进与反思`（含 `观点演变日志.md`）、`99-收件箱`（`inbox.md`）、`_系统协议`（`顾问人格与工作协议.md`）。
- **四级隐私与 `<private>` 物理剥离**：
  - 文档 Frontmatter 支持 `privacy: public | normal | private | sensitive`（缺省为 `private`）。
  - 凡标记为 `privacy: sensitive` 的文档，在默认对话（`allow_sensitive=False`）及所有远程 MCP 调用中**物理排除**，绝不进入 Prompt。
  - 任何文档正文中被 `<private>...</private>` 包裹的段落，在调用 `sanitize_for_llm()` 时一律在本地被正则替换为 `[已根据本地隐私规则隐藏]`。
- **三级写入权限 (`infer_write_level`) 与 Diff 预览**：
  - **Level 1**：`99-收件箱/` 追加速记，低摩擦直接写入。
  - **Level 2**：常规经历、关系、决策实验室的新建或更新，需半自动提案确认。
  - **Level 3**：涉及 `00-核心自我`、`01-人生章节`、`05-认知演进与反思` 的修改或任何删除操作，提案弹窗强制生成并展示 `unified_diff` 前后对比与触发证据 (`evidence`)。

### 4. 4 路中文混合检索与双时间回溯 (`app/search_index.py`)

- **增量同步 (`sync_vault_index`)**：每次检索或写操作后自动扫描记忆库，比对文件 `sha256`；仅当文件新增、内容变化或 Embedding 模型变更时才调用 `EmbeddingEngine` 计算向量，随后重建 `graph_edges`。
- **4 路混合打分与 RRF 融合 (`hybrid_search`)**：
  1. **Way 1 · 中文语义向量**：默认使用 FastEmbed 本地离线 `BAAI/bge-small-zh-v1.5`（支持切换为 OpenAI 兼容 `/v1/embeddings` 或 `disabled`），将标题、分类、时间、人物、情绪、观察标签与正文拼接后向量化，按余弦相似度排序并计入 RRF（`1.6 / (30 + rank)`）。
  2. **Way 2 · 词法与结构化元数据**：采用零外部依赖的中文 CJK Bigram + 英文词元分词器 (`_tokenize`)，分别对标题（权重 `3.5`）、人物/情绪/观察（权重 `2.6`）、正文（权重 `0.75`）计算重合度并计入 RRF（`1.2 / (30 + rank)`）。
  3. **Way 3 · 知识图谱 1-Hop 扩散**：取前两路融合后的 Top-3 种子文档，沿 `graph_edges` 向一跳邻居（双链文档、共同人物文档、同一章节文档）扩散分数（`+0.018 * weight`），从而在用户只提到某个人或某个事件时，连带召回相关的深层背景。
  4. **Way 4 · 双时间回溯 (`as_of`) 与显著性加权**：
     - 支持从查询词中自动识别时间切片（如 `2024年以前` → `as_of=2024-12-31`）或接收显式 `as_of` 参数。
     - 当启用 `as_of` 时，严格过滤掉 `doc_start > as_of`（未来才发生的事件）以及 `invalid_at <= as_of`（当时已失效的认知），还原历史时间点的真实自我状态。
     - 常态检索（未指定 `as_of`）下，若某条旧认知已有 `superseded_by` 或 `invalid_at`，其得分自动乘以 `0.65` 降权并标注 `历史已演化认知`；高显著度事件（`importance >= 8`）与 `观点演变日志.md` 获得额外加权。

### 5. 多模型协议栈与官方 ChatGPT OAuth 订阅直连 (`app/providers.py` & `app/chatgpt_oauth.py`)

- **官方 Sign in with ChatGPT (`app/chatgpt_oauth.py`)**：
  - 完整实现 OpenAI 官方 OAuth 2.0 PKCE + 动态客户端注册协议：
    - 首次发起授权 (`POST /api/chatgpt-oauth/start`) 使用 `client_id=dynamic_agent_client`、`agent_name_hint=DecisionAdvisor`、安装级持久化 `ext_agent_host_id` (`urn:uuid:...`)，请求 `scope="openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"` 与 `resource="https://api.openai.com/v1"`。
    - 回调地址严格遵循 OpenAI Loopback 规范：`http://127.0.0.1:<port>/auth/callback`。
    - 换取 Token 成功后，自动解析 `id_token` / `access_token` JWT 声明（提取邮箱、套餐类型 `chatgpt_plan_type`、校验 `iss` 与 `nonce`），保存签发的专属 `client_id`（`oaiapp_...`）与 `refresh_token`，并立即请求 `GET https://api.openai.com/v1/models` 同步可用模型列表（过滤 `visibility == "list"`）。
    - 内置 `asyncio.Lock` 保护的 `get_valid_access_token()`：在 Token 过期前 120 秒或上游返回 HTTP 401 时自动使用 `refresh_token` 轮换续期。
- **多模型推理协议自适应 (`app/providers.py`)**：
  - `chatgpt_oauth`：使用 OpenAI Responses API (`POST /v1/responses`)，固定 `store: false, stream: true`，系统提示词放入 `instructions`，历史消息转换为 `input_text` / `output_text` 内容块；流式提取 `response.output_text.delta` 与 `response.reasoning_summary_text.delta`。
  - `deepseek` / `openai_compatible`：自动检测 `gpt-5+` / `gpt-6+` / `o1+` 切换 `max_completion_tokens`；自动检测推理模型（`gpt-5+`, `o1+`, `deepseek-reasoner`, `deepseek-v4`, `deepseek-flash`）省略不兼容的 `temperature` 字段。
  - `claude`：自动检测 Claude 4.7+（如 `claude-sonnet-5-5`）省略被弃用的 `temperature` 字段，支持 `thinking_delta` 流式解析。
  - `gemini`：自动检测 Gemini 4+（如 `gemini-4-neon`）省略 `temperature` 字段，支持 `thought: true` 思考块提取。

### 6. Remote MCP 服务端与 OAuth 2.1 PKCE (`app/mcp_server.py`)

- 遵循 MCP `2025-03-26` Streamable HTTP 规范（`POST /mcp`）及 RFC 9728 / RFC 8414 标准。
- 未认证访问 `/mcp` 时返回 `401 Unauthorized` 及 `WWW-Authenticate: Bearer resource_metadata="https://<base>/.well-known/oauth-protected-resource"`，引导 ChatGPT Web / iPhone App 自动发现 `/.well-known/oauth-authorization-server`、调用 `/oauth/register` 动态注册并弹出 `/oauth/authorize` 个人访问密码授权页。
- 提供 6 个标准工具：`get_core_self`、`search_memories`、`get_memory`、`get_timeline`、`add_inbox_note`、`save_memory`。

---

## 三、后端 API 端点全景速查表

除 `GET /`、`GET /api/auth/status`、`GET /auth/callback`、`/.well-known/*`、`/oauth/*` 外，其余 `/api/*` 端点均受 `require_auth` 保护（当 `config.local.json` 设置了 `access_token` 时，需在 Header 传入 `X-Access-Token: <token>` 或 `Authorization: Bearer <token>`）。

| 分类 | 方法 & 路径 | 功能描述 |
| :--- | :--- | :--- |
| **服务与鉴权** | `GET /` | 返回纯 API 服务状态、版本号（`app/config.py` 中的 `APP_VERSION`）、`deployment_mode` |
| | `GET /api/auth/status` | 检查是否需要密码及当前 Header 是否已通过认证 |
| | `POST /api/auth/verify` | 校验访问密码连通性（供客户端连接测试使用） |
| | `GET /api/health` | 返回服务健康状态、能力列表 (`capabilities`)、记忆分类统计、向量与图谱索引统计 |
| | `POST /api/index/rebuild` | 强制全量重建 SQLite 向量索引、FTS5 全文表与知识图谱边 |
| **会话与流式对话** | `GET /api/sessions` | 获取 SQLite 历史会话列表（按 `updated_at` 倒序，含 `message_count`） |
| | `POST /api/sessions` | 手动创建新会话 |
| | `GET /api/sessions/{session_id}` | 获取单次会话详情及完整历史消息（含 `reasoning` 与 `references`） |
| | `PATCH /api/sessions/{session_id}` | 更新会话标题、模式 (`mode`) 或关联模型 (`provider_id`) |
| | `DELETE /api/sessions/{session_id}` | 删除指定会话及级联消息 |
| | `POST /api/chat` | 非流式顾问对话（自动加载 `00-核心自我` + 4 路混合检索 + 写入 SQLite） |
| | `POST /api/chat/stream` | **核心 SSE 流式对话**，依次推送 `meta` → `reasoning` → `text` → `done` 事件 |
| **半自动记忆提案** | `POST /api/proposals/extract` | 从最近 16 条对话中提炼结构化 Markdown 变更提案，自动计算写入级别 (`level` 1~3) 与 `diff` |
| | `POST /api/proposals/commit` | 将用户勾选确认的提案落盘为 Markdown，自动生成外置 Git 快照并增量更新索引 |
| **初始化引导与导入** | `GET /api/onboarding/status` | 体检 `00-核心自我/` 5 个核心槽位完整度与引导状态 |
| | `POST /api/onboarding/state` | 更新引导状态（`completed` / `dismissed` / 重置）存入 SQLite `app_meta` |
| | `POST /api/onboarding/quick-profile` | 3 分钟快速画像建档（支持仅预览 Diff 或非破坏性融合写入 + Git 快照） |
| | `POST /api/onboarding/interview/start` | 顾问主动破冰开启槽位感知冷启动访谈（无 Key 时自动降级内置开场白） |
| | `GET /api/import/prompts` | 获取内置可复制的跨平台记忆提取提示词（ChatGPT / Claude / Gemini / DeepSeek 通用） |
| | `POST /api/import/preview` | 纯本地零额度解析粘贴文本、ChatGPT/Claude `.json`/`.zip`、Mem0/PAM/Letta JSON 并按个人相关性打分 |
| | `POST /api/import/extract` | 对筛选片段脱敏后由 LLM 去重提炼为标准记忆提案，复用半自动 Diff 确认流 |
| **记忆库、图谱与导出** | `GET /api/memories` | 按分类 (`category`)、关键词 (`q`)、情绪 (`emotion`)、最低显著度 (`min_importance`) 筛选记忆 |
| | `GET /api/memories/search` | 4 路中文混合检索接口（支持 `q`、`top_k`、`as_of` 历史时间切片、`allow_sensitive`） |
| | `GET /api/memories/timeline` | 获取按发生时间排序的人生章节、经历、决策与认知演进时间轴 |
| | `GET /api/memories/graph` | 获取知识图谱节点 (`nodes`) 与关联边 (`edges`: `wikilink`/`shared_person`/`shared_chapter`) |
| | `GET /api/memories/file` | 按相对路径读取单篇记忆的 Frontmatter、正文、原始 Markdown 与详细情绪结构 |
| | `PUT /api/memories/file` | 在线保存/更新单篇 Markdown 记忆（自动触发外置 Git 快照与索引刷新） |
| | `DELETE /api/memories/file` | 删除单篇 Markdown 记忆（自动触发外置 Git 快照与索引清理） |
| | `POST /api/inbox` | 10 秒速记追加至 `99-收件箱/inbox.md`（支持携带 `mood` 情绪标签） |
| | `GET /api/vault/export` | 将整个记忆库打包为 `decision-vault-backup.zip` 下载流 |
| **配置、Git 与 OAuth** | `GET /api/git/history` | 查询外置 `.memory-git` 最近提交快照历史 |
| | `GET /api/config` | 获取脱敏后的全局配置、网络地址信息与 ChatGPT OAuth 状态 |
| | `PUT /api/config` | 更新模型预设、激活模型、Embedding 配置、公网域名或访问密码 |
| | `POST /api/config/test` | 测试指定模型提供商连通性 |
| | `GET /api/chatgpt-oauth/status` | 查询 ChatGPT OAuth 授权状态、已发现模型列表与指定 `state` 的授权流进度 |
| | `POST /api/chatgpt-oauth/start` | 生成 OpenAI 官方 Sign in with ChatGPT 授权链接（支持传入客户端自定义 `redirect_port`） |
| | `GET /auth/callback` | 本机 Loopback 浏览器回调页（自动完成 Code 换 Token 并同步模型） |
| | `POST /api/chatgpt-oauth/complete-callback` | 供远程 VPS 模式下由客户端回传完整 `callback_url` 完成 Token 交换 |
| | `POST /api/chatgpt-oauth/models/refresh` | 使用已授权 OAuth 令牌重新拉取账号可用 GPT 模型目录 |
| | `POST /api/chatgpt-oauth/logout` | 调用 OpenAI RFC 7009 接口撤销令牌并清理本地会话 |
| **Remote MCP** | `POST /mcp` | 官方 ChatGPT Developer Mode 远程 MCP JSON-RPC 2.0 端点 |
| | `GET /.well-known/oauth-*` | OAuth 2.1 受保护资源与授权服务器元数据发现端点 |
| | `POST /oauth/register` | OAuth 2.1 动态客户端注册 |
| | `GET/POST /oauth/authorize` | OAuth 2.1 密码确认授权页与 Authorization Code 签发 |
| | `POST /oauth/token` | OAuth 2.1 PKCE 校验与 Bearer Token 换取 |

---

## 四、环境变量与目录映射规范

后端通过环境变量灵活切换本地开发、macOS App 内置引擎与远程 VPS 三种运行环境：

| 环境变量 | 默认值（本地开发） | macOS App 内置引擎 (`embedded_local`) | 远程 VPS (`remote_vps`) |
| :--- | :--- | :--- | :--- |
| `ADVISOR_DEPLOYMENT_MODE` | `embedded_local` | `embedded_local` | `remote_vps` |
| `ADVISOR_PORT` | `8789` | `18789` | `8789` |
| `ADVISOR_DATA_DIR` | 仓库根目录 | `~/Library/Application Support/DecisionAdvisor/local-data` | `/opt/decision-advisor/data` |
| `DECISION_VAULT_PATH` | `~/Library/Mobile Documents/com~apple~CloudDocs/决策` | 同左（读取本机 iCloud 记忆真源） | `/opt/decision-advisor/data/vault` |
| `ADVISOR_CONFIG_PATH` | `$ADVISOR_DATA_DIR/config.local.json` | `$ADVISOR_DATA_DIR/config.local.json` | `/opt/decision-advisor/data/config.local.json` |
| `ADVISOR_CHATGPT_OAUTH_PATH` | `$ADVISOR_DATA_DIR/chatgpt_oauth.local.json` | `$ADVISOR_DATA_DIR/chatgpt_oauth.local.json` | `/opt/decision-advisor/data/chatgpt_oauth.local.json` |
| `DECISION_DB_PATH` | `$ADVISOR_DATA_DIR/advisor_state.db` | `$ADVISOR_DATA_DIR/advisor_state.db` | `/opt/decision-advisor/data/advisor_state.db` |
| `DECISION_GIT_DIR` | `$ADVISOR_DATA_DIR/.memory-git` | `$ADVISOR_DATA_DIR/.memory-git` | `/opt/decision-advisor/data/.memory-git` |

---

## 五、原生 macOS 客户端与后端协同机制 (`macos/`)

macOS 客户端已精简为**纯远程客户端**（不再在 `.app` 内打包或拉起本地 Python 后端），与 iOS 端及 Remote MCP 共用 24/7 远程 VPS 后端（`https://decision.sakuramu.edu.kg`）：

1. **轻量原生打包 (`macos/build_app.sh`)**：
   - 执行 `./macos/build_app.sh --install` 时，使用完整 Xcode 工具链编译 Release 二进制，注入 `LC_BUILD_VERSION` 与 `AppIcon.icns`，签名并覆盖安装 `/Applications/成长决策顾问.app`；不再向 `Application Support` 同步 `.venv`。
   - App 图标源文件为 Icon Composer 格式 `macos/Assets/AppIcon.icon`（全出血画布，背景由 `icon.json` 的 `fill` 提供），由 `actool` 编译为 `Assets.car` + `AppIcon.icns` 并写入 `CFBundleIconName`，macOS 26+ 会套用系统圆角遮罩，图标占满 Dock / 访达中的位置（不再被缩小放进灰色底板）。无 Xcode `actool` 时回退到 `Assets/AppIcon.png` + `iconutil`。
   - 设置页保留「一键备份回本机 iCloud」（调用 `GET /api/vault/export` 解压至本机 iCloud 目录），也支持填写自定义服务器地址以便开发调试。
2. **远程 VPS 模式下的 ChatGPT OAuth 跨机回调 (`LocalOAuthCallbackCatcher.swift`)**：
   - OpenAI 官方 Sign in with ChatGPT 强制要求 `redirect_uri` 必须是 `http://127.0.0.1:<port>/auth/callback`。
   - `AppState.startChatGPTLogin()` 会在 Mac 本机通过 `NWListener` 随机绑定一个 `127.0.0.1` 临时端口，将该端口作为 `redirect_port` 传给远程 VPS 的 `/api/chatgpt-oauth/start`。
   - 用户在 Mac 浏览器完成 OpenAI 授权后，浏览器重定向回本机 `127.0.0.1:<port>/auth/callback`，由 `LocalOAuthCallbackCatcher` 捕获完整 URL 并自动 POST 给远程 VPS 的 `/api/chatgpt-oauth/complete-callback`，实现零手动复制的无感跨机授权（同时 UI 保留「手动粘贴回调链接」兜底）。
3. **应用内检查更新 (`UpdateChecker.swift`)**：
   - 请求公开仓库 `GET https://api.github.com/repos/fengfe1125/decision-advisor/releases/latest`，按点分数字比较 `tag_name`（去掉 `v`）与本机 `CFBundleShortVersionString`。
   - 入口：菜单「成长决策顾问 → 检查更新…」、设置页「关于与更新」；默认启动时自动检查（每 12 小时最多一次，可关闭，支持“跳过此版本”）。
   - 「下载并安装」会下载 `DecisionAdvisor-v<X.YY>-macOS.zip`，校验 SHA-256、Bundle ID 与版本号后，由独立 shell 进程在 App 退出后替换当前 `.app`（失败自动回滚）并重新打开。

---

## 六、常用开发、测试与部署命令（Agent 操作手册）

### 1. 运行自动化测试
```bash
cd apps/decision-advisor   # 在 monorepo 根目录执行；独立镜像仓库中直接在根目录执行

# 标准运行
uv run pytest -v

# 若在受限沙箱或无 Xcode GUI 会话下遇到 git / xcode-select 报错，请显式指定 DEVELOPER_DIR：
DEVELOPER_DIR=/Library/Developer/CommandLineTools ./.venv/bin/pytest tests/test_app.py -v
```

### 2. 启动本机纯 API 调试后端（仅本地开发调试用）
```bash
cd apps/decision-advisor   # 在 monorepo 根目录执行；独立镜像仓库中直接在根目录执行
./start.sh
# 默认监听 http://127.0.0.1:8789/api/health
```

### 3. 编译并安装原生 macOS 客户端
```bash
cd apps/decision-advisor   # 在 monorepo 根目录执行；独立镜像仓库中直接在根目录执行
./macos/build_app.sh --install
# 编译产物位于 macos/dist/成长决策顾问.app，并自动覆盖安装至 /Applications/成长决策顾问.app

# 生成供 GitHub Release / 应用内更新使用的安装包（不安装）
./macos/build_app.sh --package
# 产物：macos/dist/DecisionAdvisor-v<X.YY>-macOS.zip
```

### 3b. 升级版本号（每次修改必做，见「〇、版本号规范」）
```bash
./bump-version.sh          # 默认 +0.01
./bump-version.sh 0.20     # 用户指定版本
./bump-version.sh --show   # 查看当前版本
```

### 4. 部署或同步至远程 24/7 VPS (`murmur-new-vps`)
```bash
cd apps/decision-advisor   # 在 monorepo 根目录执行；独立镜像仓库中直接在根目录执行

# 仅更新 VPS 上的 Python 后端代码并重启 systemd 服务（保留云端现有数据与配置）
./deploy/deploy-vps.sh

# 将本机 iCloud 记忆库与 config.local.json 一并同步至 VPS
./deploy/deploy-vps.sh --sync-vault
```

---

## 七、Agent 代码修改守则（Guardrails）

1. **严禁破坏隐私防火墙**：任何新增的检索、对话、摘要或 MCP 工具，必须默认 `allow_sensitive=False`，且在发往外部 LLM 前必须经过 `store.sanitize_for_llm()` 剥离 `<private>...</private>` 块。
2. **严禁在记忆库目录内初始化 `.git` 或写入数据库**：所有状态文件（`advisor_state.db`、`.memory-git`、`config.local.json`、`chatgpt_oauth.local.json`）必须保持物理外置，确保 Markdown 记忆库 100% 纯净。
3. **每次记忆写删操作必须闭环**：任何对 Markdown 记忆的新增、修改、追加或删除，必须依次调用 `create_snapshot()`（外置 Git 快照）→ `sync_vault_index()`（增量更新 SQLite 向量/FTS/图谱）→ `trigger_basic_memory_reindex()`。
4. **保持多模型推理参数兼容**：新增或修改 LLM 调用时，务必通过 `app/providers.py` 的 `build_provider_request()` / `call_llm()` / `stream_llm()`，切勿硬编码 `temperature` 或 `max_tokens`（以免导致 GPT-5/6、o1/o3、DeepSeek-Reasoner/V4、Claude 4.7+、Gemini 4+ 或 ChatGPT Responses API 报错）。
