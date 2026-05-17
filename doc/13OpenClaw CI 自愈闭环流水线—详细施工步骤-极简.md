# Agent CI 自愈闭环流水线 — 一步一步部署指南

> **版本**: v4.0  
> **日期**: 2026-05-12  
> **目标**: 从零开始，在 Agent 容器内部署 `ci-selfheal` Skill，实现 Jenkins 失败 → 自动抓日志 → AI 诊断 → 创建 fix 分支 → 触发重建 → 自动提 MR，最多重试 5 轮，全程零人工干预。

---

## 0. 前置知识：这个系统怎么工作的？

在动手之前，先用 30 秒理解整体流程：

```
Jenkins Job 构建失败
      │
      ▼
Jenkins 发 Webhook ──▶ ci-selfheal 收到通知
      │
      ▼
① G0 白名单校验（仓库 + 分支是否允许自愈）
      │ ✅ 通过
      ▼
② 拉取 Jenkins 构建日志（脱敏掉 token/IP）
      │
      ▼
③ 调用 agent agent（底层用 DeepSeek）做 AI 诊断
      │ 返回: { root_cause, fix_diff, confidence }
      │
      ▼
④ 通过 gitlab-skill 创建 fix 分支 → 提交修复代码 → push
      │
      ▼
⑤ 通过 jenkins skill 触发重建 → 每 5 秒轮询一次结果
      │
      ├── ✅ 成功 ──▶ ⑥ 创建 GitLab MR（标签 auto-fix）
      │
      └── ❌ 失败 ──▶ 拿新日志回到 ③，重试（最多 5 轮）
                        │
                        └── 5 轮全挂 ──▶ 熔断 + 通知人工
```

**核心原则**：Jenkins 只当工具（负责构建），Agent 做决策（诊断 + 调度），人工仅在熔断后介入。

---

## 1. 环境确认（必须逐项检查）

### 1.1 进容器

```bash
docker exec -it devopsagent-agent bash
```

之后所有命令都在容器内执行。

### 1.2 确认 Agent CLI 可用

```bash
agent --version
```

预期输出：版本号，无报错。

### 1.3 理解容器网络拓扑

所有容器都在同一个 Docker 网络 `devopsagent-network` 上：

| 容器 | 内网 IP | 端口 | 说明 |
|------|---------|------|------|
| `devopsagent-nginx` | DNS 名 `devopsagent-nginx` | `8440`→Jenkins、`8441`→GitLab、`8442`→Agent | **容器间通信的统一入口** |
| `devopsagent-jenkins` | 容器名 `devopsagent-jenkins` | `8080` | Jenkins 内部 HTTP |
| `devopsagent-gitlab` | 容器名 `devopsagent-gitlab` | `80` | GitLab 内部 HTTP |
| `devopsagent-agent` | `172.19.0.3`（可能漂移） | `18789` | Agent API |

> ⚠️ **重要**：容器间通信走 nginx HTTPS（`devopsagent-nginx:844x`），**用 Docker DNS 名而非 IP**（容器重建后 IP 会变，DNS 名不变）。**不要用** `172.19.0.1:184xx`（那是宿主机网关，WSL 重启后偶发不通）。

### 1.4 确认 Jenkins 连通性（通过 nginx HTTPS）

```bash
baseDir="/home/node/.agent/workspace/skills/jenkins"
export JENKINS_URL="https://devopsagent-nginx:8440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec81c11241d5a3897ab45608c6851"
export NODE_TLS_REJECT_UNAUTHORIZED=0

node ${baseDir}/scripts/jenkins.mjs jobs
```

**预期输出**：返回 Jenkins Job 列表（JSON），含 `name`、`color`、`lastBuild` 等字段。

### 1.5 确认 GitLab 连通性（通过 nginx HTTPS）

```bash
export GITLAB_TOKEN="glpat-86x2pYV78K_2MMCZXc9RE286MQp1OjEH.01.0w1fpvejn"

curl -k -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://devopsagent-nginx:8441/api/v4/user"
```

**预期输出**：返回用户信息 JSON（含 `id`、`username`、`name` 等）。

> ⚠️ **注意**：Token 包含完整的三段式格式（`glpat-...01....`）。如果 `401 Unauthorized`，说明 Token 过期（GitLab 容器重建会重置 Token），需去 GitLab Web UI → Settings → Access Tokens 重新生成。

### 1.5 确认已安装的 Skill

```bash
ls /home/node/.agent/workspace/skills/
```

预期至少有以下 Skill（这是我们依赖的）：

| Skill | 用途 | 状态 |
|-------|------|------|
| `jenkins` | 拉日志、触发构建、查状态 | ✅ 必须 |
| `ci-cd-watchdog` | 解析日志、定位根因 | ✅ 必须 |
| `cicd-pipeline` | CI/CD 流程管理 | ✅ 必须 |
| `gitlab-skill` | Git 操作（分支/提交/MR） | ⚠️ 需安装 |
| `n8n` | 通知推送 | ✅ 推荐 |

### 1.6 推荐安装：agentic-devops（互补 Skill）

`agentic-devops` 是 ClawHub 上的通用运维诊断工具箱（纯 Python 标准库，零外部依赖），与 `ci-selfheal` 互补：

| 功能 | 用途 | ci-selfheal 覆盖? |
|------|------|-----------------|
| Docker 容器管理 | 查看容器状态、重启、日志 | 部分 |
| 进程检查 | 找 CPU/内存最高的进程 | ❌ |
| 日志分析 | 扫描错误模式、统计频率 | 部分（Jenkins 日志 + AI） |
| HTTP 健康检查 | 验证端点响应 | ✅ /health |
| 系统快照 | CPU、内存、磁盘、端口一次性快照 | ❌ |

```bash
docker exec -it devopsagent-agent bash
agent skills install tkuehnl/agentic-devops
```

> **组合建议**：`ci-selfheal` 处理 Jenkins Pipeline 层面的失败（编译错误、Shell 语法），`agentic-devops` 处理基础设施层面的诊断（容器挂了、CPU 爆了）。两者配合覆盖从基础设施到 CI Pipeline 的全栈自愈。

### 1.7 安装 gitlab-skill + 凭据配置（实测有效方案）

> ⚠️ **注意**：以下命令都在**容器内**执行。所有 `agent` 命令如果在宿主机跑会连到另一套环境（宿主机没有安装这些 Skill）。

```bash
docker exec -it devopsagent-agent bash
agent skills install gitlab-skill
```

**Step 1：创建 `~/.claude/gitlab_config.json`（这是 gitlab-skill 真正读取的凭据文件）**：

> 实测发现当前版本 gitlab-skill **不读环境变量**，必须写 `~/.claude/gitlab_config.json`。

```bash
mkdir -p ~/.claude
cat > ~/.claude/gitlab_config.json << 'EOF'
{
  "host": "https://devopsagent-nginx:8441",
  "access_token": "glpat-86x2pYV78K_2MMCZXc9RE286MQp1OjEH.01.0w1fpvejn"
}
EOF
chmod 600 ~/.claude/gitlab_config.json
```

> **不同环境对应不同的 `host` 值**：
> - 本地 Docker 环境：`"host": "https://devopsagent-nginx:8441"`
> - 跨主机直连 GitLab：`"host": "http://10.67.167.53:8088"`

**Step 2：验证分支创建能力（gitlab-skill CLI）**：

```bash
python3 /home/node/.agent/workspace/skills/gitlab-skill/scripts/gitlab_api.py projects --search test
python3 /home/node/.agent/workspace/skills/gitlab-skill/scripts/gitlab_api.py create-branch \
  --project "root/model_test" \
  --branch "test-branch-cli" \
  --branch-ref "main"
```

**预期输出**：返回分支 URL。

**Step 3：验证 MR 创建能力（直接 GitLab REST API——因 gitlab-skill 的 MR 功能在当前环境下不稳定）**：

先获取项目 ID：

```bash
GITLAB_TOKEN="glpat-imZiYsNETLhKnLsIsOkEwG86MQp1OnoH.01.0w0rr1066"
curl -s -k --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://devopsagent-nginx:8441/api/v4/projects?search=model_test" \
  | python3 -m json.tool | grep -B 2 '"path_with_namespace"' | head -5
```

然后创建 MR：

```bash
PROJECT_ID="<上一步获取的 ID>"
curl -s -k -X POST "https://devopsagent-nginx:8441/api/v4/projects/${PROJECT_ID}/merge_requests" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --data-urlencode "source_branch=test-branch-cli" \
  --data-urlencode "target_branch=main" \
  --data-urlencode "title=测试MR-通过API" \
  --data-urlencode "description=验证 GitLab API 创建 MR"
```

**预期输出**：MR JSON 含 `web_url` 和 `reference`（如 `!5`）。

> 📚 详细实测过程见 [gitlab-skill 凭据配置与 MR 能力实测](../doc/issue/gitlab-skill%20凭据配置与%20MR%20能力实测.md)。

### 1.8 确认 AI 模型可用

```bash
agent agent --agent main --message "Hello, 1+1=?" --json
```

预期：返回 JSON 格式的回复，内容包含 "2"。如果超时或报错，检查 DeepSeek API Key 是否配置正确。

**常见问题**：
- 报 `401 Unauthorized` → API Key 过期或余额不足
- 报 `timeout` → 网络不通，检查容器能否访问 `api.deepseek.com`

> ✅ **1.1 ~ 1.8 全部通过后，进入第 2 章。**

---

## 2. 安装 Python 依赖（容器内没有 pip 怎么办？）

你的 Agent 容器是一个**重度裁剪的 Debian 环境**：没有 pip、没有 venv、`/app` 只读、`~/.local` 只读。唯一可写的位置是 `/tmp`。

### 2.1 确认当前环境

```bash
python3 --version          # 预期 Python 3.11.x
python3 -m pip --version   # 预期报错（没有 pip）
touch /tmp/test-write && rm /tmp/test-write && echo "/tmp 可写 ✅"
```

### 2.2 一键安装依赖

`ci-selfheal` 只需要两个第三方库：`PyYAML`（读配置文件）和 `requests`（发 HTTP 通知）。

我们已经把安装逻辑写进了 `install.sh`，直接执行：

```bash
cd /home/node/.agent/workspace/skills/ci-selfheal
bash install.sh
```

这个脚本会：
1. 用 Python 标准库（`urllib` + `zipfile`）从 PyPI 下载 wheel 包
2. 解压到 `/tmp/selfheal-deps/`
3. 不碰系统 Python、不需要 root、不需要 pip

**预期输出**：

```
Downloading PyYAML-6.0.3-cp311-cp311-manylinux_2_28_x86_64.whl...
✅ PyYAML -> /tmp/selfheal-deps
Downloading requests-2.32.3-py3-none-any.whl...
✅ requests -> /tmp/selfheal-deps
...
🎉 全部安装完成
启动命令：
  PYTHONPATH=/tmp/selfheal-deps:$(pwd) python3 -m scripts.webhook_listener --host 0.0.0.0 --port 8080
```

### 2.3 验证依赖安装成功

```bash
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 -c "import yaml; import requests; print('✅ 依赖就绪')"
```

> ✅ **看到 "依赖就绪" 后，进入第 3 章。**

---

## 3. 部署 ci-selfheal Skill 文件

### 3.1 确认文件结构

`ci-selfheal` 的全部文件已经在你 Windows 宿主机上准备好了，路径是：

```
C:\Users\Tong\Desktop\DevOpsAgent\agent-skill-ci-selfheal\
```

容器内需要的路径是：

```
/home/node/.agent/workspace/skills/ci-selfheal/
```

### 3.2 将文件拷贝进容器

**方式 A：用 docker cp（推荐）**

在 **宿主机 PowerShell** 中执行：

```powershell
docker cp C:\Users\Tong\Desktop\DevOpsAgent\agent-skill-ci-selfheal\. devopsagent-agent:/home/node/.agent/workspace/skills/ci-selfheal/
```

**方式 B：在容器内手动创建，然后粘贴文件内容**

如果 docker cp 不可用，则逐个文件手动写入：

```bash
docker exec -it devopsagent-agent bash
mkdir -p /home/node/.agent/workspace/skills/ci-selfheal/scripts
```

然后用 `cat > file << 'EOF' ... EOF` 的方式写入每个文件。

### 3.3 验证文件完整性

```bash
cd /home/node/.agent/workspace/skills/ci-selfheal
ls -la
```

预期输出：

```
├── SKILL.md
├── skill.toml
├── config.yaml
├── install.sh
├── run.sh
├── README.md
├── LICENSE
├── requirements.txt
├── bin/
│   └── ci-selfheal
└── scripts/
    ├── __init__.py
    ├── agent_wrapper.py
    ├── orchestrator.py
    └── webhook_listener.py
```

### 3.4 赋予执行权限

```bash
chmod +x bin/ci-selfheal install.sh run.sh
```

### 3.5 验证 Python 语法

```bash
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 -m py_compile scripts/agent_wrapper.py && echo "✅ agent_wrapper"
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 -m py_compile scripts/orchestrator.py && echo "✅ orchestrator"
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 -m py_compile scripts/webhook_listener.py && echo "✅ webhook_listener"
```

> ✅ **全部通过后，进入第 4 章。**

---

## 4. 配置 config.yaml

### 4.1 理解配置项

打开 `config.yaml`，逐一核对：

```yaml
# ===== Jenkins 连接 =====
jenkins:
  url_env: "JENKINS_URL"               # ← 从环境变量 JENKINS_URL 读取
  user_env: "JENKINS_USER"              # ← 从环境变量 JENKINS_USER 读取
  token_env: "JENKINS_API_TOKEN"        # ← 从环境变量 JENKINS_API_TOKEN 读取

# ===== GitLab 连接 =====
gitlab:
  url: "https://devopsagent-nginx:8441"        # ← nginx → GitLab（容器 DNS 名，重建不变）
  token_env: "GITLAB_TOKEN"             # ← 环境变量名
  host_env: "GITLAB_HOST"               # ← GitLab 地址环境变量名

# ===== 自愈参数 =====
repair:
  max_retries: 5                          # 最多重试 5 次
  poll_interval_sec: 5                    # 每 5 秒轮询一次构建结果
  build_timeout_min: 30                   # 单次构建最长等 30 分钟

# ===== 白名单（G0 门控） =====
whitelist:
  repos:                                  # 允许自愈的仓库路径
    - "root/model_test"
    - "group/backend-api"
    - "ci/gitlab_repo_example"
  branch_pattern: "^(feat|fix|dev|feature|main)(/.*)?$"  # 允许的分支名正则（/.* 可选）
  protected_branches:                     # 禁止自愈的分支
      - "master"
      - "release/*"

# ===== 通知 =====
notify:
  dingtalk_webhook_env: "DINGTALK_WEBHOOK"  # 钉钉通知 webhook 环境变量名
```

### 4.2 配置说明

- **Jenkins 三要素全部从环境变量读取**：`JENKINS_URL`、`JENKINS_USER`、`JENKINS_API_TOKEN` 统一在 `.env` 中管理，`config.yaml` 只声明 `url_env`/`user_env`/`token_env` 指向哪个环境变量名。这样切换 Jenkins 实例只需改 `.env`，无需动 `config.yaml`。
- **Token 不写死**：所有敏感信息通过环境变量注入，防止泄露到代码仓库。

### 4.3 设置环境变量

创建 `.env` 文件（在 `ci-selfheal/` 目录下）：

```bash
cat > /home/node/.agent/workspace/skills/ci-selfheal/.env << 'EOF'
# ===== Jenkins 连接（全部从环境变量读取） =====
export JENKINS_URL="https://devopsagent-nginx:8440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec81c11241d5a3897ab45608c6851"

# ===== GitLab 连接 =====
export GITLAB_HOST="https://devopsagent-nginx:8441"
export GITLAB_TOKEN="glpat-imZiYsNETLhKnLsIsOkEwG86MQp1OnoH.01.0w0rr1066"

# ===== 可选：钉钉通知 =====
# export DINGTALK_WEBHOOK="https://oapi.dingtalk.com/robot/send?access_token=xxx"
EOF
```

> ⚠️ **安全提醒**：`.env` 包含明文 token，不要提交到 Git！已在 `.gitignore` 中忽略。

---

## 5. 逐步验证每个模块

在启动完整服务之前，先分步验证每个模块都能正常工作。

### 5.1 测试：信息收集（拉取 Jenkins 日志）

```bash
cd /home/node/.agent/workspace/skills/ci-selfheal
source .env
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 -c "
from scripts.orchestrator import Orchestrator
o = Orchestrator()
log = o._collect_logs('example_fauliure_job', 1)
print('日志长度:', len(log), '字符')
print('前 300 字符:')
print(log[:300])
"
```

注意：`example_fauliure_job` 需替换为你的 Jenkins 上实际存在的 Job 名。

**预期**：能打印出构建日志，且日志中 token、IP 已被替换为 `[REDACTED]` / `[INTERNAL_IP]`。

### 5.2 测试：AI 诊断

```bash
cd /home/node/.agent/workspace/skills/ci-selfheal
source .env
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 -c "
from scripts.orchestrator import Orchestrator
o = Orchestrator()
ctx = {'job': 'test', 'build': 1, 'branch': 'dev', 'repo': 'root/model_test'}
result = o._diagnose('error: command not found: make', ctx)
import json
print(json.dumps(result, indent=2, ensure_ascii=False))
"
```

**预期**：返回 JSON，包含 `root_cause`、`error_type`、`confidence`、`fix_diff` 四个字段。`confidence` 在 0~1 之间。

> ⚠️ AI 调用可能耗时 30~120 秒，请耐心等待。

### 5.3 测试：GitLab 操作

```bash
export GITLAB_HOST="https://devopsagent-nginx:8441"
export GITLAB_TOKEN="glpat-imZiYsNETLhKnLsIsOkEwG86MQp1OnoH.01.0w0rr1066"

agent agent --agent main --message "使用 gitlab-skill 在仓库 root/model_test 列出所有分支" --json
```

**预期**：返回分支列表。如果没有 `model_test` 仓库，替换为你在 GitLab 上实际存在的仓库。

### 5.4 测试：Jenkins 构建触发

```bash
baseDir="/home/node/.agent/workspace/skills/jenkins"
export JENKINS_URL="https://devopsagent-nginx:8440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec81c11241d5a3897ab45608c6851"
export NODE_TLS_REJECT_UNAUTHORIZED=0

# 触发构建（替换为你的实际 Job 名）
node ${baseDir}/scripts/jenkins.mjs build --job "example_fauliure_job"
```

**预期**：返回新构建的编号。如果队列中有等待，会显示队列信息。

### 5.5 测试：Webhook 端点（本地）

启动 Webhook 监听器（前台模式，方便观察日志）：

```bash
cd /home/node/.agent/workspace/skills/ci-selfheal
source .env
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 -m scripts.webhook_listener --host 0.0.0.0 --port 8080
```

**另开一个终端**，进容器后测试：

```bash
# 测试正常的失败事件（branch=dev 能通过白名单）
curl -X POST http://localhost:8080/webhook/ci-failure \
  -H "Content-Type: application/json" \
  -d '{"job":"test_job","build":1,"status":"FAILURE","branch":"dev","repo":"root/model_test"}'

# 预期返回: {"status": "accepted"}
```

```bash
# 测试健康检查
curl http://localhost:8080/health

# 预期返回: {"status":"ok","circuit_breakers":{},"active_chains":0}
```

```bash
# 测试 SUCCESS 事件被过滤（核心设计：仅失败时触发，成功由 orchestrator 自己轮询发现）
curl -X POST http://localhost:8080/webhook/ci-failure \
  -H "Content-Type: application/json" \
  -d '{"job":"test_job","build":1,"status":"SUCCESS"}'

# 预期返回: {"status":"skipped","reason":"not a failure: SUCCESS"}
```

> ✅ **用 Ctrl+C 停掉前台服务，进入第 6 章。**

---

## 6. 启动生产服务

### 6.1 后台运行

```bash
cd /home/node/.agent/workspace/skills/ci-selfheal
source .env
nohup env PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 -m scripts.webhook_listener --host 0.0.0.0 --port 8080 > selfheal.log 2>&1 &
echo "PID: $!"
```

### 6.2 验证服务存活

```bash
sleep 2
curl -s http://localhost:8080/health | python3 -m json.tool
```

预期输出：

```json
{
    "status": "ok",
    "circuit_breakers": {},
    "active_chains": 0
}
```

### 6.3 查看实时日志

```bash
tail -f /home/node/.agent/workspace/skills/ci-selfheal/selfheal.log
```

### 6.4 查看自愈状态

```bash
cd /home/node/.agent/workspace/skills/ci-selfheal
source .env
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 bin/ci-selfheal status
```

### 6.5 开机自启（可选）

如果容器重启后想自动恢复服务：

```bash
cat >> ~/.bashrc << 'EOF'

# === ci-selfheal auto-start ===
if ! pgrep -f "scripts.webhook_listener" > /dev/null; then
  cd /home/node/.agent/workspace/skills/ci-selfheal
  source .env
  nohup env PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 -m scripts.webhook_listener --host 0.0.0.0 --port 8080 > selfheal.log 2>&1 &
  echo "[ci-selfheal] Webhook listener started"
fi
EOF
```

> ✅ **服务启动成功后，进入第 7 章。**

---

## 7. 配置 Jenkins Webhook + 容器内 HTTPS 通信

### 7.1 容器间通信地址（已验证通过 ✅）

| 目标服务 | 容器内访问地址 | 验证结果 |
|---------|---------------|---------|
| **Jenkins API** | `https://devopsagent-nginx:8440/jenkins/api/json` | ✅ 403（需 API Token） |
| **Jenkins Skill** | `node jenkins.mjs jobs`（URL=同上） | ✅ 返回 Job 列表 |
| **GitLab API** | `https://devopsagent-nginx:8441/api/v4/user` | ✅ 401（Token 需确认） |

> 这些地址走 nginx 容器 DNS 名（devopsagent-nginx），**不使用**宿主机网关（172.19.0.1:184xx），容器重建后 IP 自动更新。

### 7.2 确认 Agent 容器的 IP

Jenkins 需要知道往哪发 Webhook。在宿主机执行：

```powershell
docker inspect devopsagent-agent | Select-String "IPAddress"
```

或者在容器内：

```bash
hostname -I
```

假设容器 IP 是 `172.19.0.x`，Webhook URL 就是：

```
http://172.19.0.x:8080/webhook/ci-failure
```

### 7.2 Jenkins 配置

进入 Jenkins → 你的 Job → 配置 → 构建后操作 → 添加 "HTTP Request"：

| 字段 | 值 |
|------|-----|
| URL | `http://<容器IP>:8080/webhook/ci-failure` |
| HTTP Method | POST |
| Content-Type | `application/json` |
| Request Body | 见下方 |

```json
{
  "job": "$JOB_NAME",
  "build": "$BUILD_NUMBER",
  "status": "$BUILD_STATUS",
  "branch": "$GIT_BRANCH",
  "repo": "<你的仓库路径，如 root/model_test>"
}
```

> ⚠️ 注意：`$GIT_BRANCH` 可能需要安装 Git Parameter 插件才能获取到。如果获取不到，可以写死或从环境变量取。

### 7.3 触发条件（关键设计）

**Jenkins 只在失败时发 Webhook，成功由 ci-selfheal 自己轮询发现。**

```
Jenkins 构建失败 ──Webhook──▶ ci-selfheal 收到（唯一入口）
                                    │
                          自愈流程：AI诊断 → fix分支 → 触发重建
                                    │
                          ci-selfheal 每5秒轮询 Jenkins API
                                    │
                          ├── SUCCESS → 创建 MR
                          └── FAILURE → 拿新日志重试（最多5轮）
```

**为什么不让 Jenkins 成功时也发 Webhook？**

因为 Jenkins 的成功通知可能被误判为新失败；而且修复后的成功是 ci-selfheal 自己触发的构建，由自己轮询发现是最直接、最可靠的方式。所有状态管理集中在 ci-selfheal 一端，Jenkins 全程只当工具。

**Jenkins 端配置**：在 Jenkins Job 的"构建后操作"中，仅当 `$BUILD_STATUS == "FAILURE"` 时才发 HTTP Request。或者在 webhook_listener 端已有兜底过滤（非 FAILURE/FAILED 的状态会返回 `skipped`）。

---

## 8. 端到端测试

### 8.1 准备测试 Job

在 Jenkins 上创建一个测试 Job `test-ci-selfheal`，构建脚本故意写错：

```groovy
pipeline {
    agent any
    stages {
        stage('Build') {
            steps {
                sh 'mke'   // 故意拼错 make
            }
        }
    }
}
```

触发一次构建，确认失败。

### 8.2 手动模拟 Webhook

```bash
curl -X POST http://localhost:8080/webhook/ci-failure \
  -H "Content-Type: application/json" \
  -d '{
    "job": "test-ci-selfheal",
    "build": 1,
    "branch": "dev",
    "repo": "root/model_test"
  }'
```

### 8.3 观察流程

```bash
tail -f /home/node/.agent/workspace/skills/ci-selfheal/selfheal.log
```

你应该看到类似这样的日志序列：

```
[INFO] Webhook received: job=test-ci-selfheal build=1 branch=dev repo=root/model_test
[INFO] Attempt 1/5 for test-ci-selfheal #1
[INFO] Agent instruction: 你是 CI/CD 自愈专家...
[INFO] Agent returned: {"root_cause": "command 'mke' not found, should be 'make'", "confidence": 0.95, ...}
[INFO] Trigger build result: {...}
[INFO] Build status: SUCCESS
[INFO] Creating MR...
[INFO] History recorded: SUCCESS
```

### 8.4 验证 GitLab

在 GitLab 上检查：

- [ ] `root/model_test` 仓库下有一个新分支 `fix/ci-selfheal-test-ci-selfheal-1`
- [ ] 有一个新 Merge Request，标题含 `[ci-selfheal]`
- [ ] MR 描述中有诊断信息（根因、置信度、错误类型）
- [ ] MR 被打上 `auto-fix` 和 `ci-selfheal` 标签

---

## 9. 验收清单

逐项确认，全部打勾才算部署成功：

- [ ] **环境连通**：Jenkins API 可访问、GitLab API 可访问、AI 模型可调用
- [ ] **依赖就绪**：`python3 -c "import yaml; import requests"` 不报错
- [ ] **文件完整**：`ci-selfheal/` 目录包含所有必需文件
- [ ] **语法正确**：三个 `.py` 文件 `py_compile` 通过
- [ ] **配置正确**：`config.yaml` + `.env` 中地址和 Token 与实际环境一致
- [ ] **日志拉取**：能打印出构建日志且脱敏生效
- [ ] **AI 诊断**：返回 JSON 含 `root_cause`、`confidence`、`fix_diff`
- [ ] **Git 操作**：gitlab-skill 能列出仓库分支
- [ ] **构建触发**：jenkins skill 能触发构建并返回 build number
- [ ] **Webhook 监听**：`curl POST /webhook/ci-failure` 返回 200
- [ ] **健康检查**：`curl /health` 返回 `{"status":"ok"}`
- [ ] **端到端**：失败构建 → AI 诊断 → fix 分支 → 重建 → MR 全链路跑通
- [ ] **重试逻辑**：修复失败时能看到 `Attempt 2/5` 日志
- [ ] **熔断保护**：连续 5 次失败后进入冷却期，不再自动修复
- [ ] **白名单拦截**：不在白名单的仓库/分支被拒绝

---

## 10. 故障排查速查表

| 现象 | 可能原因 | 排查命令 |
|------|---------|---------|
| `No module named 'yaml'` | 依赖未安装 | `ls /tmp/selfheal-deps/` 看有没有 `yaml/` |
| `jenkins.mjs` 报 `ECONNREFUSED` | 用了宿主机网关 IP | 改用 nginx 容器 DNS 名 `https://devopsagent-nginx:8440/jenkins`，详见 [容器间通信必须经过nginx-HTTPS](../doc/issue/容器间通信必须经过nginx-HTTPS.md) |
| Agent 调用超时 | 日志太长或网络慢 | 减小 `poll_interval_sec`，日志只拉最后 200 行 |
| Agent 返回非 JSON | Agent 输出了额外文本 | 检查 `agent_wrapper.py` 的 JSON 提取逻辑 |
| GitLab 操作报 `401` | Token 过期或权限不足 | `curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" https://.../user` |
| Webhook 收不到 | 端口不通或 IP 不对 | `curl http://localhost:8080/health` |
| 白名单总是拦截 | 正则不匹配 | `python3 -c "import re; print(re.match(r'^(feat|fix)'))"` |
| 构建触发后拿不到 build number | `jenkins.mjs` 输出格式变化 | 查看 `node jenkins.mjs build` 的实际 stdout |

### 快速诊断命令

```bash
# 1. 看服务是否活着
curl -s http://localhost:8080/health | python3 -m json.tool

# 2. 看最近 5 次自愈记录
cd /home/node/.agent/workspace/skills/ci-selfheal
cat .self-heal-state.json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for job,chain in d.get('chains',{}).items():
    hist=chain.get('history',[])
    print(f'\n=== {job} ===')
    for h in hist[-5:]:
        print(f'  [{h[\"timestamp\"][:19]}] {h[\"status\"]}')
"

# 3. 看熔断状态
cat .self-heal-state.json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for job,cb in d.get('circuit_breaker',{}).items():
    print(f'{job}: 熔断中, opened_at={cb.get(\"opened_at\")}, reason={cb.get(\"reason\")}')
"

# 4. 一键清除熔断（无需重启）
curl http://localhost:8080/admin/reset

# 5. 重启服务（注意顺序：先杀进程 → 清状态 → 再启动）
pkill -f "scripts.webhook_listener"
cd /home/node/.agent/workspace/skills/ci-selfheal
echo '{"version":"2.0.0","chains":{},"circuit_breaker":{}}' > .self-heal-state.json
source .env
nohup env PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 -m scripts.webhook_listener --host 0.0.0.0 --port 8080 > selfheal.log 2>&1 &
```

---

## 11. 日常运维命令

```bash
# ===== 服务管理 =====
# 启动服务
cd /home/node/.agent/workspace/skills/ci-selfheal && bash run.sh

# 查看服务状态
curl -s http://localhost:8080/health

# 查看实时日志
tail -f /home/node/.agent/workspace/skills/ci-selfheal/selfheal.log

# 停止服务
pkill -f "scripts.webhook_listener"

# ===== 自愈状态 =====
# 查看所有 Job 的自愈历史
cd /home/node/.agent/workspace/skills/ci-selfheal
source .env
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 bin/ci-selfheal status

# 查看特定 Job
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 bin/ci-selfheal status --job example_fauliure_job

# ===== 手动触发 =====
# 不通过 Webhook，直接手动执行自愈
PYTHONPATH="/tmp/selfheal-deps:$(pwd)" python3 bin/ci-selfheal orchestrate \
  --job example_fauliure_job \
  --build 1 \
  --branch dev \
  --repo root/model_test

# ===== 熔断管理 =====
# 手动清除某个 Job 的熔断状态
cd /home/node/.agent/workspace/skills/ci-selfheal
python3 -c "
import json
state = json.load(open('.self-heal-state.json'))
state['circuit_breaker'].pop('example_fauliure_job', None)
json.dump(state, open('.self-heal-state.json', 'w'), indent=2)
print('熔断已清除')
"

# ===== 清理 =====
# 清理旧状态文件（慎用，会丢失所有自愈记录）
# rm -f .self-heal-state.json
```
---

> **文档结束** — 祝你部署顺利！遇到问题先查第 10 章的故障排查表。
