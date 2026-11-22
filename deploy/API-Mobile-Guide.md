# 远程后端与手机端接入指南（Mobile-Ready API）

后端已部署在你的 VPS（`murmur-new-vps`）并由 Caddy 提供 24/7 公网 HTTPS 入口，供 **macOS 原生 App**、**未来手机 App（iOS / Android）** 及 **ChatGPT Remote MCP** 共同连接。

- **公网 Base URL**：`https://decision.sakuramu.edu.kg`
- **认证方式**：所有 `/api/*`（除 `/api/auth/status`）需携带 Header：
  - `X-Access-Token: <你的访问密码>` 或 `Authorization: Bearer <你的访问密码>`
- **Web 网页版状态**：生产后端已关闭网页版（`GET /` 仅返回服务状态 JSON）；原网页版已抽离为离线可打开的 `demo-mvp/` 交互演示原型。

---

## 核心端点清单（供后续手机端开发直接复用）

| 能力 | 方法 & 路径 | 说明 |
|---|---|---|
| 服务状态 | `GET /` | 无需认证，返回版本号与 `deployment_mode` |
| 鉴权状态 / 登录校验 | `GET /api/auth/status` / `POST /api/auth/verify` | 验证服务器地址与访问密码 |
| 健康与索引统计 | `GET /api/health` | 返回记忆数量、向量化进度、图谱边数与 `capabilities` |
| 流式对话 (SSE) | `POST /api/chat/stream` | 支持 4 种模式（`chat`/`decision`/`interview`/`reflect`）、`as_of` 历史回溯、`allow_sensitive` 敏感开关 |
| 对话历史 (SQLite) | `GET/POST /api/sessions`、`GET/PATCH/DELETE /api/sessions/{id}` | 多端实时同步历史对话 |
| 记忆列表与筛选 | `GET /api/memories?category=&q=&emotion=&min_importance=` | 分类、情绪与高显著筛选 |
| 4路中文语义检索 | `GET /api/memories/search?q=&top_k=12&as_of=` | 本地离线中文 BGE 向量 + 词法 + 图谱 + 双时间 |
| 人生时间轴 / 图谱 | `GET /api/memories/timeline` / `GET /api/memories/graph` | 直接渲染时间轴和关系图 |
| 单篇记忆读写删 | `GET/PUT/DELETE /api/memories/file` | 每次写/删自动生成外置 Git 快照并更新向量索引 |
| 10秒速记收件箱 | `POST /api/inbox` | 适合手机端快捷指令 / Widget 极速记录 |
| 半自动记忆提案 | `POST /api/proposals/extract` → `POST /api/proposals/commit` | 对话提炼提案 + 用户确认后落盘 |
| 记忆库整库导出 | `GET /api/vault/export` | 返回纯 Markdown `.zip` 压缩包，用于一键备份到本地 iCloud |
| 远程配置 & 测试 | `GET/PUT /api/config`、`POST /api/config/test` | 统一管理云端模型 API Key、访问密码与向量引擎 |
| ChatGPT 订阅授权登录 | `POST /api/chatgpt-oauth/start`、`GET /auth/callback`、`POST /api/chatgpt-oauth/complete-callback`、`POST /api/chatgpt-oauth/models/refresh`、`POST /api/chatgpt-oauth/logout` | OpenAI 官方 Sign in with ChatGPT（OAuth 2.0 PKCE + `chatgpt.tokens.use.direct`），直连调用用户 ChatGPT 套餐额度与模型 |
| ChatGPT 远程 MCP | `POST /mcp` + `/.well-known/oauth-*` | OAuth 2.1 PKCE，直接接入官方 ChatGPT 网页与 iPhone App |

---

## 日常运维命令（在 Mac 上执行）

- **更新后端代码到 VPS**（不动 VPS 上的记忆库与配置）：
  ```bash
  ./deploy/deploy-vps.sh
  ```
- **同步本地 iCloud 记忆库与配置到 VPS**：
  ```bash
  ./deploy/deploy-vps.sh --sync-vault
  ```
- **查看 VPS 实时日志**：
  ```bash
  ssh murmur-new-vps "journalctl -u decision-advisor -f"
  ```
