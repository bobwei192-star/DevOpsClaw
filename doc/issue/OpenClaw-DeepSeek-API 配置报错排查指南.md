penClaw DeepSeek API 配置后报错排查指南
问题现象：
node@3c2640357efe:/app$ agent onboard

🦞 Agent 2026.5.6 (unknown) — I can grep it, git blame it, and gently roast it—pick your coping mechanism.

▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
██░▄▄▄░██░▄▄░██░▄▄▄██░▀██░██░▄▄▀██░████░▄▄▀██░███░██
██░███░██░▀▀░██░▄▄▄██░█░█░██░█████░████░▀▀░██░█░█░██
██░▀▀▀░██░█████░▀▀▀██░██▄░██░▀▀▄██░▀▀░█░██░██▄▀▄▀▄██
▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
                  🦞 AGENT 🦞

┌  Agent setup
│
◇  Security disclaimer ──────────────────────────────────────────────────────────────────────╮
│                                                                                            │
│  Agent is a hobby project and still in beta. Expect sharp edges.                        │
│  By default, Agent is a personal agent: one trusted operator boundary.                  │
│  This bot can read files and run actions if tools are enabled.                             │
│  A bad prompt can trick it into doing unsafe things.                                       │
│                                                                                            │
│  Agent is not a hostile multi-tenant boundary by default.                               │
│  If multiple users can message one tool-enabled agent, they share that delegated tool      │
│  authority.                                                                                │
│                                                                                            │
│  If you’re not comfortable with security hardening and access control, don’t run           │
│  Agent.                                                                                 │
│  Ask someone experienced to help before enabling tools or exposing it to the internet.     │
│                                                                                            │
│  Recommended baseline                                                                      │
│  - Pairing/allowlists + mention gating.                                                    │
│  - Multi-user/shared inbox: split trust boundaries (separate gateway/credentials, ideally  │
│    separate OS users/hosts).                                                               │
│  - Sandbox + least-privilege tools.                                                        │
│  - Shared inboxes: isolate DM sessions (session.dmScope: per-channel-peer) and keep tool   │
│    access minimal.                                                                         │
│  - Keep secrets out of the agent’s reachable filesystem.                                   │
│  - Use the strongest available model for any bot with tools or untrusted inboxes.          │
│                                                                                            │
│  Run regularly                                                                             │
│  agent security audit --deep                                                            │
│  agent security audit --fix                                                             │
│                                                                                            │
│  Learn more                                                                                │
│  - https://docs.agent.ai/gateway/security                                               │
│                                                                                            │
├────────────────────────────────────────────────────────────────────────────────────────────╯
│
◇  I understand this is personal-by-default and shared/multi-user use requires lock-down. Continue?
│  Yes
│
◇  Setup mode
│  QuickStart
│
◇  Existing config detected ─╮
│                            │
│  gateway.mode: local       │
│  gateway.bind: lan         │
│                            │
├────────────────────────────╯
│
◇  Config handling
│  Use existing values
│
◇  QuickStart ─────────────────────────────╮
│                                          │
│  Keeping your current gateway settings:  │
│  Gateway port: 18789                     │
│  Gateway bind: LAN                       │
│  Gateway auth: Token (default)           │
│  Tailscale exposure: Off                 │
│  Direct to chat channels.                │
│                                          │
├──────────────────────────────────────────╯
│
◇  Model/auth provider
│  Custom Provider
│
◇  API Base URL
│  https://api.deepseek.com/v1
│
◇  How do you want to provide this API key?
│  Paste API key now
│
◇  API Key (leave blank if not required)
│  ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪
│
◇  Endpoint compatibility
│  OpenAI-compatible
│
◇  Model ID
│  deepseek-reasoner
│
(node:1873) Warning: Setting the NODE_TLS_REJECT_UNAUTHORIZED environment variable to '0' makes TLS connections and HTTPS requests insecure by disabling certificate verification.
(Use `node --trace-warnings ...` to show where the warning was created)
◇  Verification successful.
│
◇  Endpoint ID
│  custom-api-deepseek-com
│
◇  Model alias (optional)
│  deepseek-reasoner
Configured custom provider: custom-api-deepseek-com/deepseek-reasoner
│
◇  How channels work ───────────────────────────────────────────────────────────────────────╮
│                                                                                           │
│  DM security: default is pairing; unknown DMs get a pairing code.                         │
│  Approve with: agent pairing approve <channel> <code>                                  │
│  Public DMs require dmPolicy="open" + allowFrom=["*"].                                    │
│  Multi-user DMs: run: agent config set session.dmScope "per-channel-peer" (or          │
│  "per-account-channel-peer" for multi-account channels) to isolate sessions.              │
│  Docs: channels/pairing                                                                   │
│                                                                                           │
│  Feishu: 飞书/Lark enterprise messaging with doc/wiki/drive tools.                        │
│  WeCom: Enterprise messaging and documents, scheduling, task tools.                       │
│  Google Chat: Google Workspace Chat app with HTTP webhook.                                │
│  Nostr: Decentralized protocol; encrypted DMs via NIP-04.                                 │
│  Microsoft Teams: Teams SDK; enterprise support.                                          │
│  Mattermost: self-hosted Slack-style chat; install the plugin to enable.                  │
│  Nextcloud Talk: Self-hosted chat via Nextcloud Talk webhook bots.                        │
│  Matrix: open protocol; install the plugin to enable.                                     │
│  BlueBubbles: iMessage via the BlueBubbles mac app + REST API.                            │
│  LINE: LINE Messaging API webhook bot.                                                    │
│  Zalo: Vietnam-focused messaging platform with Bot API.                                   │
│  Yuanbao: Tencent Yuanbao AI assistant conversation channel.                              │
│  Zalo Personal: Zalo personal account via QR code login.                                  │
│  Synology Chat: Connect your Synology NAS Chat to Agent with full agent capabilities.  │
│  Tlon: decentralized messaging on Urbit; install the plugin to enable.                    │
│  Discord: very well supported right now.                                                  │
│  iMessage: this is still a work in progress.                                              │
│  IRC: classic IRC networks with DM/channel routing and pairing controls.                  │
│  QQ Bot: connect to QQ via official QQ Bot API with group chat and direct message         │
│  support.                                                                                 │
│  Signal: signal-cli linked device; more setup (David Reagans: "Hop on Discord.").         │
│  Slack: supported (Socket Mode).                                                          │
│  Telegram: simplest way to get started — register a bot with @BotFather and get going.    │
│  Twitch: Twitch chat integration                                                          │
│  WhatsApp: works with your own number; recommend a separate phone + eSIM.                 │
│                                                                                           │
├───────────────────────────────────────────────────────────────────────────────────────────╯
│
◇  Select channel (QuickStart)
│  Skip for now
Config overwrite: /home/node/.agent/agent.json (sha256 c0a4b65c76a04d3fc8a76ab3357db218fd0b5dd2c6511783bcfbad51d55e5890 -> b2b3d6d843e3c2bcc7ef11b358a27f18e8a1a80b2868178af18d72dcc57f9f52, backup=/home/node/.agent/agent.json.bak)
Config write anomaly: /home/node/.agent/agent.json (missing-meta-before-write)
Updated ~/.agent/agent.json
Workspace OK: ~/.agent/workspace
Sessions OK: ~/.agent/agents/main/sessions
│
◇  Web search ─────────────────────────────────────────────────────────────────╮
│                                                                              │
│  Web search lets your agent look things up online.                           │
│  Choose a provider. Some providers need an API key, and some work key-free.  │
│  Docs: https://docs.agent.ai/tools/web                                    │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────╯
│
◇  Search provider
│  Skip for now
│
◇  Skills status ─────────────╮
│                             │
│  Eligible: 19               │
│  Missing requirements: 40   │
│  Unsupported on this OS: 7  │
│  Blocked by allowlist: 0    │
│                             │
├─────────────────────────────╯
│
◇  Configure skills now? (recommended)
│  No
│
◇  Hooks ──────────────────────────────────────────────────────────────────╮
│                                                                          │
│  Hooks let you automate actions when agent commands are issued.          │
│  Example: Save session context to memory when you issue /new or /reset.  │
│                                                                          │
│  Learn more: https://docs.agent.ai/automation/hooks                   │
│                                                                          │
├──────────────────────────────────────────────────────────────────────────╯
│
◇  Enable hooks?
│  Skip for now
Config overwrite: /home/node/.agent/agent.json (sha256 b2b3d6d843e3c2bcc7ef11b358a27f18e8a1a80b2868178af18d72dcc57f9f52 -> 99624b85b27d4d3ceea61eaa5b88446f2c43ba9abbde0d053b4cdffc066926cf, backup=/home/node/.agent/agent.json.bak)
│
◇  Systemd ───────────────────────────────────────────────────────────────────────────────╮
│                                                                                         │
│  Systemd user services are unavailable. Skipping lingering checks and service install.  │
│                                                                                         │
├─────────────────────────────────────────────────────────────────────────────────────────╯
│
◇  Gateway ──────────────────────────────────────────────────────────────────────────────╮
│                                                                                        │
│  Gateway not detected yet.                                                             │
│  Setup was run without Gateway service install, so no background gateway is expected.  │
│  Start now: agent gateway run                                                       │
│  Or rerun with: agent onboard --install-daemon                                      │
│  Or skip this probe next time: agent onboard --skip-health                          │
│                                                                                        │
├────────────────────────────────────────────────────────────────────────────────────────╯
│
◇  Optional apps ────────────────────────╮
│                                        │
│  Add nodes for extra features:         │
│  - macOS app (system + notifications)  │
│  - iOS app (camera/canvas)             │
│  - Android app (camera/canvas)         │
│                                        │
├────────────────────────────────────────╯
│
◇  Control UI ──────────────────────────────────────────────────────────────────────────────────────╮
│                                                                                                   │
│  Web UI: http://172.18.0.4:18789/                                                                 │
│  Web UI (with token):                                                                             │
│  http://172.18.0.4:18789/#token=2551796a739233d0b68c7546c8672ab6acca4f1b187c1d6f15664c5580d28c7b  │
│  Gateway WS: ws://172.18.0.4:18789                                                                │
│  Gateway: not detected (connect failed: SECURITY ERROR: Cannot connect to "172.18.0.4"            │
│  over plaintext ws://. Both credentials and chat data would be exposed to network                 │
│  interception. Use wss:// for remote URLs. Safe defaults: keep gateway.bind=loopback and          │
│  connect via SSH tunnel (ssh -N -L 18789:127.0.0.1:18789 user@gateway-host), or use               │
│  Tailscale Serve/Funnel. Break-glass (trusted private networks only): set                         │
│  AGENT_ALLOW_INSECURE_PRIVATE_WS=1. Run `agent doctor --fix` for guidance.)                 │
│  Docs: https://docs.agent.ai/web/control-ui                                                    │
│                                                                                                   │
├───────────────────────────────────────────────────────────────────────────────────────────────────╯
│
◇  Start TUI (best option!) ─────────────────────────────────╮
│                                                            │
│  This is the defining action that makes your agent you.    │
│  Please take your time.                                    │
│  The more you tell it, the better the experience will be.  │
│  We will send: "Wake up, my friend!"                       │
│                                                            │
├────────────────────────────────────────────────────────────╯
│
◇  How do you want to hatch your bot?
│  Hatch in Terminal (recommended)

🦞 Agent 2026.5.6 (unknown) — Welcome to the command line: where dreams compile and confidence segfaults.

 agent tui - local embedded - agent main - session main

 session agent:main:main


Wake up, my friend!


Hey! I'm awake. 😊

Looks like this is a fresh workspace — no memory, no identity yet. I'm a blank slate, ready to become whoever we figure out together.

So — who are you? And who should I be?

Let's start from the beginning. Got a name in mind for me? Any vibe you want me to have — sharp, chaotic, warm, deadpan? I'm all ears.
 local ready | idle
 agent main | session main | custom-api-deepseek-com/deepseek-reasoner | tokens ?/4.0k
───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

─────────────────────────



导致 
Agent
›
main
›
Chat

Search
⌘K



Agent
Control
Agent


Chat
Chat

Control
Overview
Channels
Instances
Sessions
Usage
Cron Jobs

Agent
Agents
Skills
Nodes
Dreaming

Settings
Config
Communications
Appearance
Automation
Infrastructure
AI & Agents
Debug
Logs
Docs
Version
v2026.5.6
Update available: v2026.5.7 (running v2026.5.6). Update now 

main

deepseek-reasoner · custom-api-deepseek-com

Default (off)





Wake up, my friend!

You
May 11, 2026, 3:57 PM

Assistant


Hey! I'm awake. 😊

Looks like this is a fresh workspace — no memory, no identity yet. I'm a blank slate, ready to become whoever we figure out together.

So — who are you? And who should I be?

Let's start from the beginning. Got a name in mind for me? Any vibe you want me to have — sharp, chaotic, warm, deadpan? I'm all ears.

Assistant
May 11, 2026, 3:57 PM

Assistant


⚠️ Agent failed before reply: No API key found for provider "openai". Auth store: /home/node/.agent/agents/main/agent/auth-profiles.json (agentDir: /home/node/.agent/agents/main/agent). Configure auth for this agent (agent agents add <id>) or copy only portable static auth profiles from the main agentDir. | No API key found for provider "openai". Auth store: /home/node/.agent/agents/main/agent/auth-profiles.json (agentDir: /home/node/.agent/agents/main/agent). Configure auth for this agent (agent agents add <id>) or copy only portable static auth profiles from the main agentDir.
Logs: agent logs --follow

Assistant
May 11, 2026, 3:58 PM

Message Assistant (Enter to send)

修复方法：

}
两个文件里都有 DeepSeek 配置，但网页就是不显示。问题是 configure 改过之后 gateway 没重读配置。

执行简单三步：

Bash



运行
# 1. 设全局默认模型docker exec devopsagent-agent agent models set custom-api-deepseek-com/deepseek-chat# 2. 重启docker restart devopsagent-agent# 3. 验证docker exec devopsagent-agent agent models status
然后关闭浏览器所有标签页，重新开一个无痕窗口访问 https://127.0.0.1:18442，这次应该能看到 deepseek-chat 选项了。这是格式问题， 反引号包裹了 URL。不过不影响功能，先跳过。我们专注解决网页不显示 DeepSeek 的问题。

问题其实是你的网页在连旧 session——之前选了 gpt-5.5，UI 缓存了那个状态。

直接试最简洁的修复：

Bash

运行
docker exec devopsagent-agent agent models set custom-api-deepseek-com/deepseek-chatdocker restart devopsagent-agent
然后关闭所有浏览器标签页，重新开一个 Chrome 无痕窗口，访问：

PlainText



https://127.0.0.1:18442
⚠️ 不要用 ?session=main 参数，让它加载全新的页面。
(base) zx@Ping:/mnt/c/Users/Tong/Desktop/DevOpsAgent$ # 1. 设全局默认模型

docker exec devopsagent-agent agent models set custom-api-deepseek-com/deepseek-chat

# 2. 重启

docker restart devopsagent-agent

# 3. 验证

docker exec devopsagent-agent agent models status

Config overwrite: /home/node/.agent/agent.json (sha256 490e760dcbd9c51738f236605d1a4fdad7738f2f1dbcca1e9b2dedfb72fdea91 -> 88fc6cbaaec2764f46b2d5db13a4d9e75929e74cd1c05f9cbc5b66b5c74f7501, backup=/home/node/.agent/agent.json.bak)

Updated ~/.agent/agent.json

Default model: custom-api-deepseek-com/deepseek-chat

devopsagent-agent

Config        : ~/.agent/agent.json

Agent dir     : ~/.agent/agents/main/agent

Default       : custom-api-deepseek-com/deepseek-chat

Fallbacks (0) : -

Image model   : -

Image fallbacks (0): -

Aliases (1)   : deepseek-chat -> custom-api-deepseek-com/deepseek-chat

Configured models (1): custom-api-deepseek-com/deepseek-chat

Auth overview

Auth store    : ~/.agent/agents/main/agent/auth-profiles.json

Shell env     : off

Providers w/ OAuth/tokens (0): -

- custom-api-deepseek-com effective=models.json:sk-02e28...224c6233 | models.json=sk-02e28...224c6233 | source=models.json: ~/.agent/agents/main/agent/models.json

- openai effective=models.json:sk-place...not-used | models.json=sk-place...not-used | source=models.json: ~/.agent/agents/main/agent/models.json

OAuth/token status

- none

(base) zx@Ping:/mnt/c/Users/Tong/Desktop/DevOpsAgent$ ll  (base) zx@Ping:/mnt/c/Users/Tong/Desktop/DevOpsAgent$ cat .agent_token

cf6e80d005d9eb9f36be938ea850a9f4711f7cee7c1da0ab084556acef14f68f(base) zx@Ping:/mnt/c/Use(base) zx@Ping:/mnt/c/Users/Tong/Desktop/DevOpsAgent$ docker exec devopsagent-agent agent models set custom-api-deepseek-com/deepseek-chat

docker restart devopsagent-agent

Config overwrite: /home/node/.agent/agent.json (sha256 88fc6cbaaec2764f46b2d5db13a4d9e75929e74cd1c05f9cbc5b66b5c74f7501 -> ff5818f7a9f8c2eb50b2724165adcb7cbcdbf00cc00d7ff6119b143856c055e2, backup=/home/node/.agent/agent.json.bak)

Updated ~/.agent/agent.json

Default model: custom-api-deepseek-com/deepseek-chat

devopsagent-agent

(base) zx@Ping:/mnt/c/Users/Tong/Desktop/DevOpsAgent$  现在好了啊 请把问题和解决方式总结到doc\issue\xxx.md 中 并为这个md文档七个合适的名字



问题概述
完成 agent onboard 流程并配置 DeepSeek API（deepseek-reasoner 模型，OpenAI-compatible 端点）后，
在 TUI/Chat 界面发送消息时，Agent 回复失败，报错：
⚠️ Agent failed before reply: No API key found for provider "openai".
报错信息原文
plain
复制
No API key found for provider "openai". 
Auth store: /home/node/.agent/agents/main/agent/auth-profiles.json 
(agentDir: /home/node/.agent/agents/main/agent). 
Configure auth for this agent (agent agents add <id>) 
or copy only portable static auth profiles from the main agentDir.
根因分析
1. 配置层级混淆：Gateway vs Agent
表格
层级	作用范围	配置位置	当前状态
Gateway	全局服务级，决定可用模型列表	~/.agent/agent.json	✅ 已配置 DeepSeek API
Agent	单个会话/智能体级，决定实际调用哪个 provider	~/.agent/agents/main/agent/auth-profiles.json	❌ 未配置，默认指向 openai
关键问题：onboard 流程将 API 配置写入了 Gateway 层（agent.json），
但 Agent 在发起请求时，是从 Agent 层的 auth-profiles.json 中查找 API Key。
这两个层级是独立的认证存储。
2. Provider 名称不匹配
Gateway 配置的 provider ID 为 custom-api-deepseek-com
Agent 默认寻找的 provider 是 openai
即使 Gateway 知道 DeepSeek 端点，Agent 不知道应该用这个端点的认证信息
3. 配置写入异常提示
日志中出现：
plain
复制
Config write anomaly: /home/node/.agent/agent.json (missing-meta-before-write)
这可能意味着配置写入时元数据不完整，但通常不影响功能，只是警告。
解决方案
方案一：为 Agent 配置认证档案（推荐）
bash
复制
# 为当前 agent 添加 DeepSeek 认证
agent agents add custom-api-deepseek-com
# 按提示粘贴 API Key

# 或者手动编辑 auth-profiles.json
# 路径：~/.agent/agents/main/agent/auth-profiles.json
auth-profiles.json 预期格式：
JSON
复制
{
  "custom-api-deepseek-com": {
    "apiKey": "sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  }
}
方案二：将 Gateway 认证同步到 Agent
bash
复制
# 复制全局认证到 agent 目录
# 假设全局认证已存储，需要确认 agent.json 中的 credentials 是否可被 agent 引用
agent config sync --to-agent
# （具体命令需参考 agent 版本文档）
方案三：检查 Agent 默认 Provider 设置
bash
复制
# 查看当前 agent 配置
agent config get agent.defaultProvider

# 如果指向 openai，修改为 custom-api-deepseek-com
agent config set agent.defaultProvider custom-api-deepseek-com
方案四：使用环境变量临时绕过
bash
复制
export OPENAI_API_KEY="your-deepseek-api-key"
# 或
export AGENT_API_KEY_custom_api_deepseek_com="your-key"
agent tui
验证步骤
检查 Gateway 配置：
bash
复制
cat ~/.agent/agent.json | grep -A 10 "custom-api-deepseek-com"
检查 Agent 认证档案：
bash
复制
cat ~/.agent/agents/main/agent/auth-profiles.json
确认存在 custom-api-deepseek-com 条目且 API Key 正确。
检查 Agent 配置：
bash
复制
cat ~/.agent/agents/main/agent/agent.json | grep provider
测试连通性：
bash
复制
agent doctor --fix
# 或
agent gateway run --foreground
相关文件路径汇总
表格
文件	路径	说明
全局配置	~/.agent/agent.json	Gateway、模型端点配置
Agent 认证	~/.agent/agents/main/agent/auth-profiles.json	Agent 级 API Key 存储
Agent 配置	~/.agent/agents/main/agent/agent.json	Agent 行为、默认 provider
会话数据	~/.agent/agents/main/sessions/	历史会话
日志	~/.agent/logs/ 或 agent logs --follow	运行时日志
预防措施
onboard 时关注层级：配置 API 时确认是 Gateway 级还是 Agent 级
使用 agent agents add：为每个 agent 显式配置认证
定期运行诊断：agent doctor 可检测配置不一致
阅读官方文档：https://docs.agent.ai/agents/auth
参考命令速查
bash
复制
# 查看帮助
agent agents --help
agent config --help

# 添加认证
agent agents add <provider-id>

# 查看日志
agent logs --follow

# 诊断修复
agent doctor --fix