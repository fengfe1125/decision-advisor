# 通过官方合规方式接入 ChatGPT Plus / Pro 订阅指南

> **重要合规与安全说明**：
> OpenAI 官方严禁将 ChatGPT 消费级订阅通过第三方逆向抓包、黑产代理池伪装成 API Key。
>
> 本项目**完全遵循 OpenAI 官方规范**，同时支持：
> 1. **首选 · 官方 Sign in with ChatGPT（OAuth 2.0 PKCE + `chatgpt.tokens.use.direct`）**：直接在「成长决策顾问」App 里点击授权登录 ChatGPT 账号，即可**直接调用你的 ChatGPT 订阅额度和可用模型**（支持 Go / Plus / Pro / Business，无需填写 API Key，随时可在 ChatGPT 设置中设置额度上限或撤销授权）。
> 2. **官方 ChatGPT Developer Mode 远程 MCP**：让 ChatGPT 网页版 + 官方 iPhone ChatGPT App 反向读写你的个人成长记忆库。

---

## 首选路径：官方 Sign in with ChatGPT 授权登录（程序内直接调用 GPT 额度与模型）

本项目已内置完整的 **OpenAI Sign in with ChatGPT（OAuth 2.0 + PKCE + 动态客户端注册 `dynamic_agent_client` + `chatgpt.tokens.use.direct`）**，并对接 OpenAI 官方公开 **Responses API（`POST https://api.openai.com/v1/responses`，`store=false`、`stream=true`）** 与 **账号可用模型列表（`GET https://api.openai.com/v1/models`）**。

### 使用步骤（macOS App 一键完成）
1. 打开 **「成长决策顾问」App** → 进入 **「⚙️ 模型与设置 → 大模型」**；
2. 点击顶部 **「使用 ChatGPT 授权登录」**（也可点击 **「复制授权链接」** 在任意浏览器手动打开）：
   - 首次授权使用 `client_id=dynamic_agent_client` + `agent_name_hint=DecisionAdvisor` + 本机持久化 `ext_agent_host_id`；
   - 授权完成后自动保存 OpenAI 签发的专属 `client_id`（`oaiapp_...`）与可自动续期的 Refresh Token（权限 `0600`，仅存于本机/VPS `chatgpt_oauth.local.json`，绝不上传 iCloud）。
3. 在浏览器中登录你的 ChatGPT 账号，**确认勾选允许使用你的 ChatGPT 套餐额度**并点击同意；
4. 浏览器自动跳转回本机回调地址 `http://127.0.0.1:<port>/auth/callback`：
   - **本地内置模式**：由内置 FastAPI 直接接收并完成换取 Token；
   - **远程 VPS 模式**：由 macOS App 临时本机 loopback 监听自动接收回调并安全回传给 VPS（也可展开「手动粘贴回调链接」在远程设备上完成）。
5. 授权成功后会自动拉取你账号当前可调用的所有 GPT 模型列表，并自动配置/启用 **「ChatGPT 订阅授权」** 预设，直接点 **「设为默认并测试」** 即可开始对话！

### 额度管理与安全控制
- 查看或限制本程序的每周套餐额度上限：**ChatGPT 设置 → Usage**；
- 随时撤销授权：在程序内点击 **「退出登录」**（会调用 OpenAI RFC 7009 `revocation_endpoint` 撤销令牌），或在 **ChatGPT 设置 → Security and login → Login connections → Sign in with ChatGPT** 中手动断开。

---

## 推荐路径二：VPS HTTPS + ChatGPT Developer Mode 远程 MCP（网页 + 手机官方 App 均可用！）

本项目已内置完整的 **MCP Streamable HTTP（`POST /mcp`）+ OAuth 2.1 PKCE（动态客户端注册 + 个人访问密码授权页）**，完全符合 OpenAI 官方 Developer Mode 远程 MCP 规范。

### 为什么推荐「Mac 跑本地真源 + VPS 做公网 HTTPS 入口」？
- 你的 iCloud `决策` 目录和 SQLite 历史/中文向量索引 **100% 留在你自己的 Mac**，无需把私密日记同步到云服务器硬盘；
- VPS 只负责提供公网 HTTPS 入口（Caddy 自动证书）和把流量通过加密 SSH 隧道安全转发回你的 Mac；
- 手机出门在外打开 `https://decision.yourdomain.com` 也能直接用我们的 Web 顾问，同时官方 ChatGPT App 也能连 `https://decision.yourdomain.com/mcp`！

### 4 步完成对接（已按你的 VPS `murmur-new-vps` 与域名 `decision.sakuramu.edu.kg` 配好）

#### 第 1 步：在本地网页「设置」先做好安全密码
1. 打开本地 `http://127.0.0.1:8789` → **「⚙️ 模型与设置」**；
2. 设置一个强 **访问密码（Access Token）** 并保存（OAuth 授权页和网页端都会用它保护你的记忆库）；
3. 公网域名已预填为：`https://decision.sakuramu.edu.kg`。

#### 第 2 步：在你的 DNS 服务商添加解析记录
- 在 DNS 解析面板新增一条 **A 记录**：
  - 主机记录：`decision`
  - 记录值：`<你的 VPS 公网 IP>`
- VPS 上的 Caddy 已配置好 `decision.sakuramu.edu.kg` 自动申请并续期 Let's Encrypt HTTPS 证书。

#### 第 3 步：在 Mac 启动反向 SSH 隧道
确保本机 `./start.sh` 已在运行，然后新开终端执行：
```bash
cd /Volumes/Developer/个人汇总/decision-advisor
./deploy/vps-tunnel-mac.sh
```
*(脚本已默认指向 `murmur-new-vps`，可配合 `autossh` 断线自动重连；所有记忆与 SQLite 物理留在你的 Mac，不落云服务器硬盘。)*

#### 第 4 步：在 ChatGPT Plus / Pro 网页端添加 MCP App
1. 打开 `https://chatgpt.com` → 左下角头像 → **设置（Settings）→ Security and login（或 Advanced）→ 开启 Developer Mode**；
2. 进入 **Apps / Plugins → Add → Create MCP App**；
3. 填入：
   - **Name**：`我的个人成长记忆库`
   - **Server URL**：`https://decision.sakuramu.edu.kg/mcp`
   - **Authentication**：`OAuth`
4. 点击连接后会自动跳到你自己的授权页，输入你在第 1 步设置的访问密码即可完成 OAuth 2.1 PKCE 授权；
5. 授权成功后，**ChatGPT 网页版 + iPhone 官方 ChatGPT App** 即可直接消耗你的 ChatGPT 订阅额度，调用以下 6 个工具：
   - `get_core_self`：读取你的 `00-核心自我` 和顾问协议（自动屏蔽 `sensitive`）
   - `search_memories`：调用 4 路中文语义向量 + FTS + 图谱 + 双时间（`as_of`）检索
   - `get_memory`：查看单篇记忆详情
   - `get_timeline`：查看人生时间轴
   - `add_inbox_note`：随手记进收件箱
   - `save_memory`：经 ChatGPT 官方人工确认弹窗批准后写入记忆库 + 自动 Git 快照！

---

## 路径二：如果你是 ChatGPT Pro / Business 订阅（官方 API Credits 福利）
OpenAI 官方为符合条件的 **ChatGPT Pro（100/200/500）及 Business** 订阅提供等额免费月度 API Credits：
- 在 ChatGPT 账单设置中关联你名下的 OpenAI API Organization 领取官方额度；
- 把生成的正规 `OPENAI_API_KEY` 直接填进我们 Web 顾问的 **OpenAI 兼容中转站 / 官方 API** 预设即可！

---

## 路径三：电脑端 OpenAI Codex CLI（Plus / Pro 订阅官方自带）
无需 VPS，适合在 Mac 终端直接用 ChatGPT 订阅额度：
```bash
npm install -g @openai/codex
```
在 `~/.codex/config.toml` 中加入：
```toml
[mcp_servers.decision-memory]
command = "/Users/sakura/.local/bin/basic-memory"
args = ["mcp", "--project", "decision-kb"]
```
进入 `/Users/sakura/Library/Mobile Documents/com~apple~CloudDocs/决策` 运行 `codex` 并选择 **Sign in with ChatGPT** 即可开聊。
