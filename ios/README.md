# 成长顾问 iOS

这个客户端采用原生 `UITextView` 悬浮双层聊天输入框（`AdvisorComposer`，兼容 iOS 26+ Liquid Glass 与中文 IME 多行输入），视觉配色与 macOS 端「白玻璃 · 温润薄荷绿」和品牌叶针罗盘保持一致，使用独立的 App 标识（`com.sakura.DecisionAdvisorMobile`）。用 Xcode 打开 `DecisionAdvisorMobile.xcodeproj`，选真机或模拟器运行。改了 `project.yml` 或增删源文件后，在本目录运行 `xcodegen generate` 重新生成工程。

首次打开时填写顾问 VPS 的 HTTPS 地址和访问密码，密码存在设备钥匙串里。手机和 Mac 远程模式读写同一个 VPS。

## 离线与同步

- 聊天、收件箱速记和「新建一条记忆」都先存在手机上（`Application Support/AdvisorCache/state.json`，受数据保护），再按顺序上传到 VPS。没网时照常写，联网、回到前台或手动「立即同步」时自动补传。
- 每条排队内容带固定的 `client_id`，VPS 用它去重：断网重传不会重复写入消息或速记，已经生成过的回复会直接返回，不会再调用模型。
- 新建记忆用 `create_only` 写入：同路径已有不同内容时 VPS 返回 409，「同步」页会列出失败项，由你重试或放弃。
- 历史会话、记忆列表在本机有缓存，离线可以看。编辑已有记忆、提炼记忆提案、删除会话需要联网。
- 「同步」页的「断开并清除本机数据」会删掉缓存和没上传的内容，VPS 上的数据不受影响。

**这版 App 依赖新的后端字段（`client_id`、`create_only`），先部署后端再装 App。** 旧后端会忽略这两个字段：重传可能出现重复，新建同名记忆会覆盖原文件。

Debug 版允许连接 `http://127.0.0.1` / `localhost` 上的本机测试后端，Release 版只接受 HTTPS。

## AI 访问（MCP）

支持 MCP 的 AI 客户端可以连接同一个 VPS 的 `/mcp`。授权时勾选「一并允许此 AI 读取已保存的聊天原文」，即可使用 `list_chat_sessions`、`search_chat_history` 和 `get_chat_messages`。只有记忆权限的旧授权保持不变。返回的聊天内容会隐藏 `<private>` 段落和模型推理字段。
