# OpenClaw CI 自愈闭环流水线 — 详细施工步骤

> **版本**: v1.0  
> **日期**: 2026-05-10  
> **配套文档**:
> - [11OpenClaw CI 自愈闭环流水线—核心设计方案.md](./11OpenClaw%20CI%20%E8%87%AA%E6%84%88%E9%97%AD%E7%8E%AF%E6%B5%81%E6%B0%B4%E7%BA%BF%E2%80%94%E6%A0%B8%E5%BF%83%E8%AE%BE%E8%AE%A1%E6%96%B9%E6%A1%88.md)
> - [12OpenClaw CI 自愈闭环流水线—详细设计方案.md](./12OpenClaw%20CI%20%E8%87%AA%E6%84%88%E9%97%AD%E7%8E%AF%E6%B5%81%E6%B0%B4%E7%BA%BF%E2%80%94%E8%AF%A6%E7%BB%86%E8%AE%BE%E8%AE%A1%E6%96%B9%E6%A1%88.md)  
> **核心仓库**: `github.com/bobwei192-star/openclaw-skill-ci-selfheal`  
> **全局配置**: `config/.global_settings.yaml`（已预填）

---

## 目录

- [Phase 0：环境准备与基线验证](#phase-0环境准备与基线验证)
- [Phase 1：核心闭环 MVP（G0 + S1 + S2 + S3）](#phase-1核心闭环-mvpg0--s1--s2--s3)
- [Phase 2：扩展功能（G1 + S4 + 反馈闭环）](#phase-2扩展功能g1--s4--反馈闭环)
- [Phase 3：底座与运维完善](#phase-3底座与运维完善)
- [Phase 4：集成测试与上线](#phase-4集成测试与上线)
- [附录：快速命令参考](#附录快速命令参考)

---

## Phase 0：环境准备与基线验证

> **目标**: 确认 OpenClaw 容器、Jenkins、GitLab 连通性，验证已安装 Skill 可用性。  
> **工期**: 0.5 天

### Step 0.1：确认容器运行状态

```bash
# 1. 检查 OpenClaw 容器是否运行
docker ps | grep devopsclaw-openclaw

# 2. 进入容器
docker exec -it devopsclaw-openclaw bash

# 3. 验证 openclaw CLI
openclaw --version
```

**预期结果**: 容器状态为 `Up`，`openclaw --version` 返回版本号。

### Step 0.2：验证 Jenkins 连通性

```bash
# 在容器内执行
# 1. 先设置环境变量（每次新开 shell 都需要执行）
baseDir="/home/node/.openclaw/workspace/skills/jenkins"
export JENKINS_URL="https://172.19.0.1:18440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec81c11241d5a3897ab45608c6851"
export NODE_TLS_REJECT_UNAUTHORIZED=0

# 2. 验证 Jenkins 连通性（查看最后构建状态）
node ${baseDir}/scripts/jenkins.mjs status --job "<job-name>" --last
node@5da26b33f5b4:/app$ node ${baseDir}/scripts/jenkins.mjs status --job "example_fauliure_job" --last



# 3. 测试拉取构建日志（替换为实际 Job 名）
node ${baseDir}/scripts/jenkins.mjs console --job "example_fauliure_job" --last --tail 50
```

**预期结果**: 返回 Jenkins 构建状态和日志，无连接错误。

**排错**:
- 若报错 `ECONNREFUSED 127.0.0.1:18440`：容器内 `127.0.0.1` 指向容器自身，需使用 Docker 网关 IP
  ```bash
  # 查找网关 IP
  ip route | grep default
  # 输出示例: default via 172.19.0.1 dev eth0
  # 则 JENKINS_URL 应设置为 https://172.19.0.1:18440/jenkins
  ```
- 若报错 `404 Not Found - nginx`：Jenkins 前面有 nginx 反向代理，URL 需包含 `/jenkins` 路径
  ```bash
  # 验证方法
  curl -k https://172.19.0.1:18440/api/json
  # 若返回 301 重定向到 /jenkins/login，则 URL 应为 https://172.19.0.1:18440/jenkins
  ```
- 若报错 `Missing required environment variables`：检查变量名是否为 `JENKINS_API_TOKEN`（不是 `JENKINS_TOKEN`）
- 确认 Jenkins 已启用 REST API 并生成 API Token（User → Configure → API Token）

### Step 0.3：验证 GitLab 连通性

```bash
# 在容器内执行
# 1. 设置 GitLab Token 变量（替换为你的实际 Token）
export GITLAB_TOKEN="glpat-imZiYsNETLhKnLsIsOkEwG86MQp1OnoH.01.0w0rr1066"

# 2. 测试 GitLab API 连通性（使用 Docker 网关 IP，不是 127.0.0.1）
curl -k -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://172.19.0.1:18441/api/v4/user"

# 3. 测试获取项目列表
curl -k -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://172.19.0.1:18441/api/v4/projects?per_page=5"

# 4. 测试 Git Clone（可选，验证 Git 凭证）
git clone \
  https://oauth2:${GITLAB_TOKEN}@172.19.0.1:18441/group/backend-api.git \
  /tmp/test-clone 2>/dev/null || echo "Git clone 测试完成"
```

**预期结果**（已验证通过 ✅）：
- `api/v4/user` 返回当前用户信息（JSON 格式），示例：
  ```json
  {"id":35,"username":"project_1_bot_166d76ca2c983c3208ed989d57a46981","name":"fefw","state":"active",...}
  ```
- `api/v4/projects` 返回项目列表，示例：
  ```json
  [{"id":1,"name":"model_test","path_with_namespace":"root/model_test",...}]
  ```
- 无 `ECONNREFUSED`、`SSL certificate problem` 等错误

**实际验证记录**（2026-05-10）：
- ✅ GitLab API `/api/v4/user` — 返回 bot 用户信息
- ✅ GitLab API `/api/v4/projects` — 返回 `root/model_test` 项目
- ✅ Git Clone — 测试完成（项目存在但可能为空仓库或权限问题）

**排错**:
- 若报错 `ECONNREFUSED 127.0.0.1:18441`：容器内 `127.0.0.1` 指向容器自身，必须使用 Docker 网关 IP `172.19.0.1`
  ```bash
  # 查找网关 IP
  ip route | grep default
  # 输出示例: default via 172.19.0.1 dev eth0
  ```
- 若报错 `SSL certificate problem`：GitLab 使用自签名证书，需加 `-k` 参数跳过证书验证
- 若返回 `401 Unauthorized`：检查 Token 是否过期，或权限不足（需要 `api` + `read_repository`）
- 检查 `config/.global_settings.yaml` 中 `gitlab.api_token` 和 `git.token` 是否一致

**网络地址对照**:

| 场景 | GitLab URL |
|------|-----------|
| 宿主机本地 | `https://127.0.0.1:18441` |
| 容器内（推荐） | `https://172.19.0.1:18441` |
| Docker Desktop | `https://host.docker.internal:18441` |

### Step 0.4：验证已安装 Skill

```bash
# 在容器内执行
# 查看已安装的 workspace skills
ls -la /home/node/.openclaw/workspace/skills/

# 查看 jenkins skill 是否已安装
ls -la /home/node/.openclaw/workspace/skills/jenkins/
cat /home/node/.openclaw/workspace/skills/jenkins/SKILL.md

# 验证 jenkins skill 可用
baseDir="/home/node/.openclaw/workspace/skills/jenkins"
export JENKINS_URL="https://172.19.0.1:18440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec81c11241d5a3897ab45608c6851"
export NODE_TLS_REJECT_UNAUTHORIZED=0
node ${baseDir}/scripts/jenkins.mjs jobs
```

**预期结果**（已验证通过 ✅）：
- `/home/node/.openclaw/workspace/skills/jenkins/` 目录存在，包含 `SKILL.md`、`_meta.json`、`scripts/`
- `node jenkins.mjs jobs` 返回 Jenkins Job 列表，示例：
  ```json
  {
    "jobs": [
      {
        "name": "example_fauliure_job",
        "color": "red",
        "lastBuild": {
          "number": 1,
          "result": "FAILURE"
        }
      }
    ],
    "total": 1
  }
  ```

**实际验证记录**（2026-05-10）：
- ✅ `ls /home/node/.openclaw/workspace/skills/` — 共 15 个 Skill 已安装
- ✅ `jenkins` skill — 返回 1 个 Job（`example_fauliure_job`，状态 FAILURE）
- ✅ `ci-monitor` — 已安装
- ✅ `ci-cd-watchdog` — 已安装
- ✅ `cicd-pipeline` — 已安装
- ✅ `claw-summarize-pro` — 已安装
- ✅ `lint` — 已安装
- ✅ `security-auditor` — 已安装
- ✅ `self-improve` — 已安装
- ✅ `git-changelog` — 已安装
- ✅ `tavily` — 已安装
- ✅ `n8n` — 已安装（needs setup）
- ✅ `devops` — 已安装
- ✅ `docker` — 已安装
- ✅ `github` — 已安装
- ✅ `capability-evolver-pro` — 已安装

**重要说明**: Jenkins 安装的是 **workspace skill**，不是 CLI 插件，因此：
- ❌ 没有 `openclaw jenkins` 命令
- ✅ 通过 `node /home/node/.openclaw/workspace/skills/jenkins/scripts/jenkins.mjs` 直接调用
- ✅ 或通过 `openclaw agent --message "列出 Jenkins jobs"` 让 Agent 自动调用

### Step 0.5：验证 AI 模型调用

```bash
# 在容器内执行
# 方法 1: 使用 openclaw agent 交互式聊天（需要指定 --agent 和 --message）
openclaw agent --agent main --message "Hello, test connection"

# 方法 2: 使用 docker exec 调用底层 infer 命令
docker exec devopsclaw-openclaw node openclaw.mjs infer model run \
  --model "custom-api-deepseek-com/deepseek-reasoner" \
  --prompt "Hello, test connection"
```

**预期结果**: 返回 AI 响应，无连接错误或认证失败。

**实际验证记录**（2026-05-10）：
- ✅ `openclaw agent --agent main --message "Hello, test connection"` — Agent 正常响应，显示 "Waiting for agent reply…"
- ⚠️ `openclaw agent` 必须使用 `--message`（不是 `--prompt`），且需要指定 `--agent main`

**排错**:
- 若报错 `required option '-m, --message <text>' not specified`：使用 `--message` 而不是 `--prompt`
- 若报错 `Pass --to <E.164>, --session-id, or --agent to choose a session`：需要加 `--agent main`
- 检查 `config/.global_settings.yaml` 中 `ai_model.api_key`
- 确认 DeepSeek API 余额充足

### Step 0.6：准备测试用 Jenkins Job

创建一个专门用于测试的 Jenkins Job（如 `test-ci-selfheal`），要求：
- 使用 JJB YAML 定义
- 构建脚本故意包含一个可修复的错误（如拼写错误的命令、缺失的环境变量）
- 触发一次构建，确认能正常失败

```bash
# 手动触发测试构建（使用 jenkins workspace skill）
baseDir="/home/node/.openclaw/workspace/skills/jenkins"
export JENKINS_URL="https://172.19.0.1:18440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec81c11241d5a3897ab45608c6851"
export NODE_TLS_REJECT_UNAUTHORIZED=0
node ${baseDir}/scripts/jenkins.mjs build --job "test-ci-selfheal"
```

---

## Phase 1：核心闭环 MVP（G0 + S1 + S2 + S3）

> **目标**: 实现最小可用闭环：Webhook 接收 → 白名单校验 → 信息收集 → AI 诊断 → Patch 生成。  
> **工期**: 2 天

### Step 1.1：重构项目目录结构

将现有 `openclaw-skill-ci-selfheal/` 按模块化设计重构：

```bash
cd openclaw-skill-ci-selfheal

# 创建新目录结构
mkdir -p gate collector diagnoser decider verifier infra tests

# 移动现有文件到对应位置
# 注意：以下移动操作需根据实际文件内容调整
mv scripts/ai_prompt_builder.py diagnoser/prompt_builder.py
mv scripts/jjb_manager.py collector/jjb_reader.py
mv scripts/webhook_listener.py infra/webhook_listener.py
mv scripts/orchestrator.py orchestrator.py
```

**目标目录结构**:

```
openclaw-skill-ci-selfheal/
│
├── gate/
│   ├── __init__.py
│   ├── whitelist.py          # G0: 白名单校验
│   └── precheck.py           # G1: 故障预判（先留空，Phase 2 实现）
│
├── collector/
│   ├── __init__.py
│   ├── jenkins_logs.py       # S1: Jenkins 日志拉取
│   ├── jjb_reader.py         # S1: JJB YAML 只读
│   ├── diff_parser.py        # S1: 源码 diff 获取
│   └── desensitizer.py       # S1: 敏感信息脱敏（先留空，Phase 2 实现）
│
├── diagnoser/
│   ├── __init__.py
│   ├── prompt_builder.py     # S2: Prompt 组装
│   └── ai_client.py          # S2: AI 调用封装
│
├── decider/
│   ├── __init__.py
│   ├── matrix.py             # S3: 决策矩阵
│   ├── git_branch.py         # S3: Git 分支操作
│   └── patch_writer.py       # S3: Patch/报告生成
│
├── verifier/
│   ├── __init__.py
│   ├── ci_trigger.py         # S4: CI 触发重建（先留空，Phase 2 实现）
│   ├── pr_manager.py         # S4: PR 创建（先留空，Phase 2 实现）
│   └── feedback.py           # S4: 结果入库（先留空，Phase 2 实现）
│
├── infra/
│   ├── __init__.py
│   ├── lock.py               # 并发控制（先留空，Phase 3 实现）
│   ├── audit.py              # 审计日志（先留空，Phase 3 实现）
│   ├── notify.py             # 通知推送
│   └── webhook_listener.py   # HTTP Webhook 入口
│
├── tests/
│   ├── __init__.py
│   ├── test_gate.py
│   ├── test_collector.py
│   ├── test_diagnoser.py
│   └── test_decider.py
│
├── orchestrator.py           # 主编排器
├── skill.toml                # OpenClaw manifest
├── SKILL.md                  # Skill 定义
├── requirements.txt
└── README.md
```

### Step 1.2：实现 G0 白名单校验（`gate/whitelist.py`）

**功能要求**:
- 读取 `config/.global_settings.yaml` 中 `white_list` 配置
- 校验 Repo 是否在白名单中
- 校验分支名是否匹配 `branch_pattern` 正则
- 返回校验结果：通过 / 拦截（附原因）

**实现要点**:
```python
# 伪代码示意
import yaml
import re
from pathlib import Path

class WhitelistChecker:
    def __init__(self, config_path: str = "config/.global_settings.yaml"):
        self.config = yaml.safe_load(Path(config_path).read_text())
        self.repos = self.config["white_list"]["repos"]
        self.pattern = re.compile(self.config["white_list"]["branch_pattern"])
    
    def check(self, repo: str, branch: str) -> dict:
        # 1. Repo 白名单校验
        # 2. 分支命名规范校验
        # 3. 保护分支拦截（main/master/release/*）
        pass
```

**单元测试**:
```bash
python -m pytest tests/test_gate.py -v
```

### Step 1.3：实现 S1 信息收集（`collector/`）

#### 1.3.1 `collector/jenkins_logs.py`

**功能要求**:
- 封装 `openclaw jenkins logs` 调用
- 支持按 Job Name + Build Number 拉取日志
- 返回原始日志文本

#### 1.3.2 `collector/jjb_reader.py`

**功能要求**:
- 从现有 `scripts/jjb_manager.py` 迁移
- 只读读取 JJB YAML，提取 DSL 内容
- 支持按 Job Name 查找 YAML 文件

#### 1.3.3 `collector/diff_parser.py`

**功能要求**:
- 获取触发构建的 Commit 与上一次成功构建的 diff
- 调用 `git diff` 或 GitLab API 获取变更内容
- 返回 diff 文本，供 AI 诊断参考

**单元测试**:
```bash
python -m pytest tests/test_collector.py -v
```

### Step 1.4：实现 S2 AI 诊断（`diagnoser/`）

#### 1.4.1 `diagnoser/prompt_builder.py`

**功能要求**:
- 从现有 `scripts/ai_prompt_builder.py` 迁移并增强
- 支持组装多源上下文：日志 + DSL + diff + 历史故障
- 实现上下文截断策略（尾部优先 + 头部环境信息）
- 预留脱敏接口（Phase 2 接入）

#### 1.4.2 `diagnoser/ai_client.py`

**功能要求**:
- 封装 AI 模型调用
- 支持多模型切换（DeepSeek / GPT-4 / Claude）
- 实现重试机制（网络超时自动重试 3 次）
- 解析 AI 返回的 JSON 格式诊断结果

**Prompt 模板要求**:
- 系统角色：CI/CD 自愈代理
- 约束：不修改业务代码、仅修复构建配置
- 输出格式：强制 JSON Schema（根因、错误类型、修复代码、置信度）

**单元测试**:
```bash
python -m pytest tests/test_diagnoser.py -v
```

### Step 1.5：实现 S3 修复决策（`decider/`）

#### 1.5.1 `decider/matrix.py`

**功能要求**:
- 实现决策矩阵：错误类型 × Git 权限 × 置信度 → 修复行为
- 支持从 YAML/JSON 配置文件加载矩阵规则
- 返回决策结果：自动修复 / Patch / 诊断报告 / 终止

**决策矩阵配置示例** (`config/decision_matrix.yaml`):
```yaml
matrix:
  compile:
    has_git_write: auto_fix_branch
    no_git_write: generate_patch
    no_git: generate_patch
  test:
    has_git_write: generate_patch_notify
    no_git_write: generate_patch
    no_git: generate_report
  cannot_fix:
    all: terminate_notify
```

#### 1.5.2 `decider/git_branch.py`

**功能要求**:
- 创建 fix 分支：`fix/ci-selfheal-{job}-{build}`
- 应用修复（Commit）
- Push 到远程仓库
- 错误处理：分支已存在、Push 失败、权限不足

#### 1.5.3 `decider/patch_writer.py`

**功能要求**:
- 生成 Unified Diff 格式 Patch 文件
- 生成 Markdown 诊断报告
- 输出到 `patches/` 和 `reports/` 目录
- 文件名包含时间戳，避免覆盖

**单元测试**:
```bash
python -m pytest tests/test_decider.py -v
```

### Step 1.6：实现通知模块（`infra/notify.py`）

**功能要求**:
- 支持多通道：Slack / 钉钉 / 邮件 / n8n Webhook
- 按场景选择通知级别：Info / Warn / Critical
- 通知内容模板化，含构建信息、诊断摘要、操作链接

**配置方式**:
```yaml
# config/notify.yaml
channels:
  slack:
    webhook_url: "https://hooks.slack.com/..."
  dingtalk:
    webhook_url: "https://oapi.dingtalk.com/..."
  n8n:
    api_url: "https://n8n.example.com/webhook/..."
```

### Step 1.7：重构主编排器（`orchestrator.py`）

**功能要求**:
- 串联 G0 → S1 → S2 → S3 全流程
- 管理状态机（JSON 文件）
- 记录处理历史（重试次数、每轮结果）
- 异常捕获与降级处理

**状态文件结构** (`.self-heal-state.json`):
```json
{
  "version": "5.0.0",
  "chains": {
    "test-ci-selfheal": {
      "current_retry": 0,
      "status": "idle",
      "original_build": 42,
      "processed_builds": [42],
      "history": [
        {
          "round": 0,
          "timestamp": "2026-05-10T12:00:00Z",
          "result": "PATCH_GENERATED",
          "error": null
        }
      ]
    }
  }
}
```

### Step 1.8：更新 Skill Manifest

更新 `skill.toml`，修正 entrypoint 路径：

```toml
[skill]
name = "ci-selfheal"
version = "2.0.0"
description = "Jenkins CI Self-Healing — auto-diagnose build failures, generate fixes, and trigger rebuilds"

[tools.orchestrate]
description = "Run the full self-heal orchestration"
entrypoint = "orchestrator.py"

[tools.analyze]
description = "Analyze build failure from logs"
entrypoint = "diagnoser/prompt_builder.py"

[tools.status]
description = "Show self-heal status for a job"
entrypoint = "orchestrator.py"
```

### Step 1.9：MVP 端到端测试

**测试场景 1：编译错误 → Patch 生成**

```bash
# 1. 准备测试 Job（构建脚本含语法错误）
# 2. 触发构建失败
baseDir="/home/node/.openclaw/workspace/skills/jenkins"
export JENKINS_URL="https://172.19.0.1:18440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec81c11241d5a3897ab45608c6851"
export NODE_TLS_REJECT_UNAUTHORIZED=0
node ${baseDir}/scripts/jenkins.mjs build --job "test-ci-selfheal"

# 3. 手动触发自愈流程（使用 Python 脚本）
cd /app/.trae/skills/ci-selfheal
python ci_selfheal.py \
  --job-name test-ci-selfheal \
  --build-number 1 \
  --status FAILURE

# 4. 检查输出
# 预期：生成 Patch 文件到 patches/test-ci-selfheal_fix_*.groovy
# 预期：生成诊断报告到 reports/test-ci-selfheal_diag_*.md
```

**测试场景 2：白名单拦截**

```bash
# 使用非白名单 Repo 触发
# 预期：状态为 blocked，原因 whitelist_check_failed
```

**测试场景 3：保护分支拦截**

```bash
# 使用 main 分支触发
# 预期：状态为 blocked，原因 protected_branch
```

**验收标准**:
- [ ] 白名单校验通过/拦截正常
- [ ] 保护分支拦截正常
- [ ] 能拉取 Jenkins 日志和 JJB YAML
- [ ] AI 诊断返回结构化结果（含置信度）
- [ ] Patch 文件格式正确（Unified Diff）
- [ ] 诊断报告包含根因、修复建议、证据日志
- [ ] 状态文件正确记录处理历史

---

## Phase 2：扩展功能（G1 + S4 + 反馈闭环）

> **目标**: 实现故障预判、自动分支修复、CI 重建验证、PR 创建、反馈闭环。  
> **工期**: 2 天

### Step 2.1：实现 G1 故障预判（`gate/precheck.py`）

**功能要求**:
- 识别 6 类不可自愈场景：
  1. Flaky Test（历史波动率检测）
  2. 基础设施故障（Slave 离线、磁盘满、网络不可达）
  3. 安全门禁阻断（SonarQube、漏洞扫描）
  4. 第三方服务不可用（外部 API 5xx）
  5. 业务逻辑 Bug（断言失败指向 src/main/）
  6. 全局基础设施故障（Jenkins 宕机）

**实现要点**:
```python
class PrecheckFilter:
    def check(self, logs: str, analysis: str, diff: str) -> dict:
        # 1. 检查基础设施关键字
        # 2. 检查安全扫描关键字
        # 3. 检查 Flaky Test 模式（需历史数据）
        # 4. 检查业务代码变更（diff 指向 src/main/）
        # 返回: {"action": "proceed" | "block", "reason": "...", "notify": "..."}
```

**单元测试**:
```bash
python -m pytest tests/test_gate.py::test_precheck -v
```

### Step 2.2：实现 S4 验证闭环（`verifier/`）

#### 2.2.1 `verifier/ci_trigger.py`

**功能要求**:
- 触发 Jenkins Job 对 fix 分支重建
- 支持参数化构建（指定分支名）
- 轮询构建结果，超时处理（默认 30 分钟）
- 返回构建结果：SUCCESS / FAILURE / ABORTED / TIMEOUT

#### 2.2.2 `verifier/pr_manager.py`

**功能要求**:
- 自动创建 Merge Request / Pull Request
- PR 标题模板：`[ci-selfheal] Auto-fix: {job_name} #{build_number} — {error_type}`
- PR 描述包含：诊断摘要、根因、修复说明、验证结果、检查清单
- 自动打标签：`auto-fix`、`ci-selfheal`、`{error_type}`
- 自动指派 Reviewer（Code Owner 或最近修改者）

**GitLab API 调用示例**:
```bash
curl -X POST "https://gitlab.example.com/api/v4/projects/:id/merge_requests" \
  -H "PRIVATE-TOKEN: <token>" \
  -d "source_branch=fix/ci-selfheal-test-1" \
  -d "target_branch=main" \
  -d "title=[ci-selfheal] Auto-fix: test-ci-selfheal #1" \
  -d "description=..."
```

#### 2.2.3 `verifier/feedback.py`

**功能要求**:
- 监听 PR/MR 状态变更（合并、关闭、评论）
- 采集标签：`ai-fix-accepted` / `ai-fix-rejected` / `ai-fix-modified`
- 记录拒绝原因（如 Reviewer 填写）
- 更新状态文件，标记最终状态

### Step 2.3：实现自动修复完整路径

**流程**:
```
AI 诊断 → 决策矩阵判断 → 创建 fix 分支 → Commit 修复 → Push
→ 触发 CI 重建 → 轮询结果
→ 成功: 创建 MR/PR → 等待人工 Review
→ 失败: 进入重试逻辑（Phase 3）
```

**集成测试**:
```bash
# 1. 准备测试 Job（可修复的编译错误）
# 2. 触发构建失败
baseDir="/home/node/.openclaw/workspace/skills/jenkins"
export JENKINS_URL="https://172.19.0.1:18440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec81c11241d5a3897ab45608c6851"
export NODE_TLS_REJECT_UNAUTHORIZED=0
node ${baseDir}/scripts/jenkins.mjs build --job "test-ci-selfheal"

# 3. 执行完整自愈流程（使用 Python 脚本）
cd /app/.trae/skills/ci-selfheal
python ci_selfheal.py \
  --job-name test-ci-selfheal \
  --build-number 2 \
  --status FAILURE

# 4. 验证 fix 分支已创建
# 5. 验证 CI 重建已触发
# 6. 验证 MR/PR 已创建（如重建成功）
```

### Step 2.4：实现反馈闭环

**功能要求**:
- PR 合并后，自动标记为 `ai-fix-accepted`
- PR 关闭（未合并），自动标记为 `ai-fix-rejected`
- 记录正负样本到本地 JSON 文件（后续用于模型微调）
- 样本结构：
```json
{
  "timestamp": "2026-05-10T12:00:00Z",
  "job": "test-ci-selfheal",
  "build": 2,
  "context_hash": "sha256:...",
  "diagnosis": "...",
  "fix": "...",
  "result": "accepted",
  "reject_reason": null
}
```

### Step 2.5：Phase 2 验收测试

**测试场景 1：编译错误 → 自动修复 → 重建成功 → 提 PR**

```bash
# 预期流程：
# 1. 构建失败触发
# 2. G0 通过
# 3. G1 通过（非不可自愈类型）
# 4. S1 收集信息
# 5. S2 AI 诊断（置信度 ≥ 0.85）
# 6. S3 决策：auto_fix_branch
# 7. 创建 fix 分支，Commit，Push
# 8. S4 触发重建
# 9. 重建成功，创建 MR/PR
# 10. 通知维护者
```

**测试场景 2：业务逻辑 Bug → G1 拦截**

```bash
# 预期：G1 识别为 cannot_fix_src，生成诊断报告，通知人工
```

**测试场景 3：无 Git 权限 → Patch 输出**

```bash
# 预期：生成 Patch 文件和诊断报告，不创建分支
```

**验收标准**:
- [ ] G1 能正确识别 6 类不可自愈场景
- [ ] 自动修复路径完整：分支 → Commit → Push → 重建 → PR
- [ ] CI 重建结果轮询正常
- [ ] PR/MR 自动创建，标题/描述/标签正确
- [ ] 反馈闭环能正确标记 accepted/rejected
- [ ] 样本库正确记录正负样本

---

## Phase 3：底座与运维完善

> **目标**: 实现并发控制、审计日志、重试熔断、信息脱敏、监控告警。  
> **工期**: 1.5 天

### Step 3.1：实现并发控制（`infra/lock.py`）

**功能要求**:
- 锁粒度：`repo + branch + error_type` 三元组
- 实现方式：文件锁（默认）或 Redis 分布式锁（可选）
- 锁过期：30 分钟自动释放
- 锁冲突：同一三元组新事件直接丢弃

```python
class DistributedLock:
    def acquire(self, key: str, ttl: int = 1800) -> bool:
        # 尝试获取锁，成功返回 True，失败返回 False
        pass
    
    def release(self, key: str):
        pass
```

### Step 3.2：实现审计日志（`infra/audit.py`）

**功能要求**:
- 全链路操作记录：谁/何时/对什么/做了什么/结果
- 日志级别：DEBUG / INFO / WARN / ERROR
- 输出方式：控制台 + 文件（按天轮转）
- 保留周期：1 年

**日志格式**:
```
2026-05-10 12:00:00.123 | INFO | audit | job=test-ci-selfheal build=42
| phase=G0 | action=whitelist_check | result=pass | repo=group/backend-api branch=feat/test
```

### Step 3.3：实现信息脱敏（`collector/desensitizer.py`）

**功能要求**:
- 脱敏规则：
  - 密钥/Token：匹配关键字后替换为 `[REDACTED]`
  - 内网 IP：替换为 `[INTERNAL_IP]`
  - 内部域名：替换为 `[INTERNAL_DOMAIN]`
  - 个人邮箱/用户名：替换为 `[USER]`
- 脱敏时机：采集后、入 AI 前
- 支持正则配置化

### Step 3.4：实现重试与熔断（`infra/circuit_breaker.py`）

**功能要求**:
- 最大重试：5 次（可配置）
- 退避策略：指数退避（1min → 5min → 15min → 30min → 60min）
- 熔断触发：
  - 单 Job 连续 5 次失败
  - 1 小时内全局失败率 > 80%
- 熔断行为：停止自动修复，仅生成诊断报告，升级通知
- 熔断恢复：手动解除或 2 小时后自动解除

```python
class CircuitBreaker:
    def __init__(self, failure_threshold: int = 5, recovery_timeout: int = 7200):
        pass
    
    def record_failure(self, job: str):
        pass
    
    def record_success(self, job: str):
        pass
    
    def is_open(self, job: str = None) -> bool:
        pass
```

### Step 3.5：实现监控指标暴露

**功能要求**:
- 暴露 Prometheus 格式指标（可选）
- 核心指标：
  - `ci_selfheal_requests_total`（按结果分类：success/failure/blocked）
  - `ci_selfheal_retry_total`（按重试次数分类）
  - `ci_selfheal_duration_seconds`（各阶段耗时）
  - `ci_selfheal_ai_tokens_total`（AI Token 消耗）
  - `ci_selfheal_circuit_breaker_state`（熔断状态：0=关闭, 1=开启）

### Step 3.6：更新 requirements.txt

```txt
pyyaml>=6.0
requests>=2.28.0
python-gitlab>=3.0.0
prometheus-client>=0.15.0
```

### Step 3.7：Phase 3 验收测试

**测试场景 1：去重锁**

```bash
# 快速连续触发同一 Job 同一 Build 两次
# 预期：第二次被去重，返回 skipped/duplicate
```

**测试场景 2：熔断**

```bash
# 构造连续 5 次失败场景
# 预期：第 6 次触发熔断，返回 circuit_breaker_open
```

**测试场景 3：脱敏**

```bash
# 在日志中包含 fake token: glpat-xxxxxxxx
# 预期：入 AI 前的日志中 token 被替换为 [REDACTED]
```

**验收标准**:
- [ ] 去重锁能防止重复处理
- [ ] 熔断在 5 次连续失败后触发
- [ ] 审计日志全链路可追溯
- [ ] 敏感信息正确脱敏
- [ ] 监控指标正确暴露

---

## Phase 4：集成测试与上线

> **目标**: 完整端到端测试、性能测试、灰度上线。  
> **工期**: 1 天

### Step 4.1：端到端集成测试

**测试矩阵**:

| 场景 | 输入 | 预期输出 |
|------|------|---------|
| 编译错误 + 有权限 | Jenkins 构建失败，日志含编译错误 | fix 分支 → 重建成功 → PR 创建 |
| 编译错误 + 无权限 | 同上，但 Git Token 只读 | Patch 文件 + 诊断报告 |
| 保护分支 | main 分支构建失败 | 拦截，原因 protected_branch |
| 非白名单 Repo | 未授权仓库构建失败 | 拦截，原因 whitelist_check_failed |
| 业务逻辑 Bug | 测试断言失败，diff 指向 src/main/ | G1 拦截，诊断报告 |
| Flaky Test | 同一测试时好时坏 | G1 拦截，标记 flaky |
| 基础设施故障 | Slave 离线 | G1 拦截，通知运维 |
| 低置信度 | AI 置信度 0.4 | 降级为诊断报告 |
| 连续失败 → 熔断 | 同一 Job 连续 6 次失败 | 第 6 次熔断 |

**执行方式**:
```bash
# 运行全部测试
python -m pytest tests/ -v --tb=short

# 运行集成测试（需真实 Jenkins/GitLab 环境）
python -m pytest tests/integration/ -v
```

### Step 4.2：性能测试

**测试项**:
- AI 诊断平均响应时间（目标 < 30 秒）
- 并发处理 10 个构建失败事件
- 状态文件读写性能（1000 条记录）
- Webhook 接收吞吐量

```bash
# 使用 locust 或自定义脚本压测
python tests/perf/test_concurrent.py
```

### Step 4.3：灰度上线

**上线策略**:

| 阶段 | 范围 | 观察期 |
|------|------|--------|
| 内测 | 1 个测试 Job | 1 天 |
| 灰度 | 1 个团队（2~3 个 Repo） | 3 天 |
| 扩大 | 5 个团队（10 个 Repo） | 1 周 |
| 全量 | 全部白名单 Repo | 持续观察 |

**观察指标**:
- 自愈成功率
- 误修率（人工反馈）
- AI Token 消耗
- 系统稳定性（无崩溃、无死锁）

### Step 4.4：上线检查清单

- [ ] 所有单元测试通过
- [ ] 所有集成测试通过
- [ ] 性能测试达标
- [ ] 灰度期间无重大事故
- [ ] 监控告警配置完成
- [ ] 运维手册更新
- [ ] 回滚方案准备（保留上一版本镜像）

---

---

## Phase 5：`openclaw-skill-ci-selfheal` 模块化构建与 Hub 发布

> **目标**: 按模块依赖顺序完成 Skill 的开发、测试、打包与 OpenClaw Hub 发布。  
> **工期**: 3 天

### Step 5.1：模块构建顺序与依赖关系

各模块存在明确的依赖关系，必须按以下顺序构建：

```
                    ┌─────────────────┐
                    │  skill.toml     │ ← ① 先定义 (Skill 元信息)
                    │  SKILL.md       │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
    │ jjb_manager  │ │ai_prompt_    │ │webhook_      │
    │ .py          │ │builder.py    │ │listener.py   │
    │ ② 无外部依赖  │ │② 无外部依赖  │ │③ 依赖编排器   │
    └──────┬───────┘ └──────┬───────┘ └──────┬───────┘
           │                │                │
           └────────┬───────┘                │
                    │                        │
                    ▼                        │
          ┌──────────────┐                   │
          │ orchestrator │ ← ④ 核心（依赖②的所有模块）
          │ .py          │                   │
          └──────┬───────┘                   │
                 │                            │
                 │        ┌───────────────────┘
                 │        │
                 ▼        ▼
          ┌──────────────┐
          │ bin/ci-self  │ ← ⑤ CLI 入口（依赖④）
          │ heal         │
          └──────┬───────┘
                 │
                 ▼
          ┌──────────────┐
          │ 集成测试 +    │ ← ⑥ 完整验证
          │ Hub 发布      │
          └──────────────┘
```

### Step 5.2：skill.toml 与 SKILL.md 构建

**step 5.2.1 `skill.toml`**

| 操作 | 说明 |
|------|------|
| `[skill]` 段 | 定义 `name = "ci-selfheal"`，`version` 按 SemVer 起始 `1.0.0` |
| `[tools.orchestrate]` | 注册主编排入口，`entrypoint = "scripts/orchestrator.py"` |
| `[tools.status]` | 注册状态查询入口，`entrypoint = "scripts/orchestrator.py"` |

**验证**:
```bash
cat skill.toml
# 确认 name、version、description 完整
# 确认每个 [tools.*] 有 entrypoint 路径
```

**Step 5.2.2 `SKILL.md`**

| 章节 | 必须内容 |
|------|---------|
| Description | 一句话概述 + 五步自愈流程说明 |
| Dependencies | 列出 9 个依赖 Skill（→ OpenClaw Hub 自动解析依赖） |
| Usage | `openclaw ci-selfheal orchestrate/status` 命令示例 |
| Configuration | 必填环境变量表格（`JENKINS_URL`、`JENKINS_USER`、`JENKINS_TOKEN`、`JJB_CONFIG_PATH`） |
| State File | `.self-heal-state.json` 位置与格式说明 |

**验证**:
```bash
cat SKILL.md
# 确认：Description / Dependencies / Usage / Configuration / State File 五个章节完整
```

---

### Step 5.3：无依赖模块构建

#### Step 5.3.1 `scripts/jjb_manager.py`

| 方法 | 输入 | 输出 | 测试方法 |
|------|------|------|---------|
| `read_job(job_name)` | 字符串 | YAML 文本 | 准备测试 `.yaml` 文件，验证能按名称读出 |
| `extract_dsl(job_name)` | 字符串 | DSL 文本 | 准备含 `dsl:` 字段的 YAML，验证提取内容 |
| `validate_syntax(job_name)` | 字符串 | `{"valid": bool, ...}` | 分别用合法/非法 YAML 测试 |
| `list_jobs()` | 无 | `[文件名列表]` | 准备测试目录，验证文件列表正确 |

**测试场景**：
- ✅ YAML 存在 → 返回完整内容
- ✅ YAML 不存在 → 抛 `FileNotFoundError`
- ✅ YAML 语法错误 → `validate_syntax` 返回 `valid: False`
- ✅ 空的 JJB 配置目录 → `list_jobs` 返回空列表

```bash
python -c "
from scripts.jjb_manager import JjbManager
mgr = JjbManager('./jjb-configs')
print(mgr.list_jobs())
print(mgr.validate_syntax('<job-name>'))
"
```

#### Step 5.3.2 `scripts/ai_prompt_builder.py`

| 方法 | 输入 | 输出 | 测试方法 |
|------|------|------|---------|
| `build(info)` | `{"logs":..., "analysis":..., "yaml_content":...}` | Prompt 字符串 | 验证输出含系统角色 + 约束 + 上下文 |
| `_truncate(text, max_len)` | 字符串 + 长度 | 截断字符串 | 分别测试超长/正常/空文本 |

**Prompt 质量验证**（必须同时满足）：
- [ ] 含系统角色声明（"CI/CD self-healing agent"）
- [ ] 含 CANNOT_FIX_SRC 约束
- [ ] 含不修改 src/main/ 约束  
- [ ] 含输出格式要求（```groovy code block```）
- [ ] 日志超 8000 字符时正确截断
- [ ] 空数据源显示 `[No data available]`

```bash
python -c "
from scripts.ai_prompt_builder import build_prompt
prompt = build_prompt({
    'logs': 'error: command not found',
    'analysis': 'root cause: missing executable',
    'yaml_content': 'job:\n  name: test'
})
assert 'CI/CD self-healing agent' in prompt
assert 'CANNOT_FIX_SRC' in prompt
print('✅ Prompt 结构验证通过')
"
```

---

### Step 5.4：核心编排模块构建

#### Step 5.4.1 `scripts/orchestrator.py`

| 方法 | 职责 | 测试方法 |
|------|------|---------|
| `load_state() / save_state()` | 状态持久化 | 空文件 → 返回默认结构；修改后保存 → 再次加载 → 修改生效 |
| `get_chain()` | 获取/创建 Job 状态链 | 新 Job → 自动初始化；已存在 → 返回已有数据 |
| `is_duplicate(build_number)` | 去重检查 | 第一次 → False；第二次 → True |
| `collect_info()` | 多源上下文收集 | 需真实 Jenkins 环境 |
| `diagnose(info)` | AI 诊断入口 | 需 DeepSeek 环境 |
| `run()` | 全流程编排 | 端到端测试 |
| `_extract_dsl(response)` | DSL 提取 | 模拟 AI 返回的 ```groovy ... ``` 块 |
| `update_status(result)` | 状态更新 | 不同 result → 不同 status |

**去重测试**:
```bash
python -c "
from scripts.orchestrator import CISelfHealOrchestrator
# 同一个 job+ build 调用两次
o = CISelfHealOrchestrator('test-job', 42)
assert o.is_duplicate(42) == False   # 第一次不重复
assert o.is_duplicate(42) == True    # 第二次重复
print('✅ 去重逻辑验证通过')
"
```

**DSL 提取测试**:
```bash
python -c "
from scripts.orchestrator import CISelfHealOrchestrator
response = '''Root cause: missing semicolon
\`\`\`groovy
pipeline { stages { stage('build') { steps { sh 'make' } } } }
\`\`\`'''
dsl = CISelfHealOrchestrator._extract_dsl(response)
assert 'pipeline' in dsl
assert 'make' in dsl
print('✅ DSL 提取验证通过')
"
```

**状态流转测试**:
```bash
python -c "
from scripts.orchestrator import CISelfHealOrchestrator
o = CISelfHealOrchestrator('test-job', 1)
# 测试 PATCH_GENERATED 状态
o.update_status({'status': 'PATCH_GENERATED'})
chain = o.get_chain()
assert chain['status'] == 'patch_ready'
# 测试 CANNOT_FIX 状态
o.update_status({'status': 'CANNOT_FIX', 'reason': 'test'})
chain = o.get_chain()
assert chain['status'] == 'failed'
print('✅ 状态流转验证通过')
"
```

---

### Step 5.5：HTTP 入口模块构建

#### Step 5.5.1 `scripts/webhook_listener.py`

| 测试场景 | 输入 | 预期 |
|---------|------|------|
| 正常失败事件 | `{"jobName":"test", "buildNumber":1, "status":"FAILURE"}` | 200 + JSON 结果 |
| 非失败事件 | `{"jobName":"test", "buildNumber":1, "status":"SUCCESS"}` | 200 + `{"status":"skipped"}` |
| 缺少参数 | `{"jobName":"test"}` | 200 + `{"status":"error"}` |
| 错误路径 | POST 到 `/wrong-path` | 404 |

```bash
# 启动 Webhook Listener
python scripts/webhook_listener.py &
LISTENER_PID=$!

# 测试正常流程（需提前设置环境变量）
curl -X POST http://localhost:5000/webhook/jenkins \
  -H "Content-Type: application/json" \
  -d '{"jobName":"test-job","buildNumber":1,"status":"FAILURE"}'

# 测试跳过非失败事件
curl -X POST http://localhost:5000/webhook/jenkins \
  -H "Content-Type: application/json" \
  -d '{"jobName":"test-job","buildNumber":1,"status":"SUCCESS"}'

kill $LISTENER_PID
```

---

### Step 5.6：CLI 入口验证

#### Step 5.6.1 `bin/ci-selfheal`

```bash
# 测试 orchestrate 子命令
python bin/ci-selfheal orchestrate --job test-job --build 42

# 测试 status 子命令（指定 job）
python bin/ci-selfheal status --job test-job

# 测试 status 子命令（全局）
python bin/ci-selfheal status

# 测试无参数（应显示帮助）
python bin/ci-selfheal

# 验证退出码
echo $?  # orchestrate 成功 → 0，失败/拦截 → 1
```

---

### Step 5.7：Skill 打包前检查清单

在发布至 OpenClaw Hub 之前，必须逐项确认：

| # | 检查项 | 验证方法 |
|---|--------|---------|
| 1 | `skill.toml` 中 `name`、`version`、`description` 完整 | `cat skill.toml` |
| 2 | `skill.toml` 中每个 `[tools.*]` 都有 `entrypoint` | `cat skill.toml` |
| 3 | `SKILL.md` 含 Dependencies 章节，列出所有依赖 Skill | `cat SKILL.md` |
| 4 | `SKILL.md` 含 Configuration 章节，列出所有环境变量 | `cat SKILL.md` |
| 5 | `requirements.txt` 包含所有 Python 依赖 | `cat requirements.txt` |
| 6 | `LICENSE` 文件存在 | `cat LICENSE` |
| 7 | `README.md` 含项目说明 | `cat README.md` |
| 8 | `bin/ci-selfheal` 可执行权限正确 | `python bin/ci-selfheal --help` |
| 9 | 无 Python 语法错误 | `python -m py_compile scripts/*.py` |
| 10 | 去重逻辑正常 | 按 Step 5.4 测试 |
| 11 | 状态流转正常 | 按 Step 5.4 测试 |
| 12 | DSL 提取正常 | 按 Step 5.4 测试 |
| 13 | Prompt 结构完整 | 按 Step 5.3 测试 |

**一键验证脚本**:
```bash
#!/bin/bash
ERRORS=0

echo "=== openclaw-skill-ci-selfheal 发布前检查 ==="
echo ""

# 1. 必需文件检查
for f in skill.toml SKILL.md requirements.txt LICENSE README.md bin/ci-selfheal; do
  if [ -f "$f" ]; then echo "✅ $f 存在"; else echo "❌ $f 缺失"; ERRORS=$((ERRORS+1)); fi
done

# 2. Python 语法检查
for f in scripts/*.py; do
  python -m py_compile "$f" 2>/dev/null && echo "✅ $f 语法正确" || { echo "❌ $f 语法错误"; ERRORS=$((ERRORS+1)); }
done

# 3. CLI 可执行性
python bin/ci-selfheal --help >/dev/null 2>&1 && echo "✅ CLI 入口正常" || { echo "❌ CLI 入口异常"; ERRORS=$((ERRORS+1)); }

echo ""
echo "=== 检查完成: $ERRORS 个错误 ==="
```

---

### Step 5.8：OpenClaw Hub 发布步骤

**发布流程**:

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 版本号定稿 | 修改 `skill.toml` 中 `version`，如 `1.0.0` |
| 2 | Git Tag | `git tag v1.0.0 && git push origin v1.0.0` |
| 3 | GitHub Release | 基于 Tag 创建 Release，Release Notes 写清变更 |
| 4 | Hub 索引更新 | OpenClaw Hub 自动检测新 Release 并更新索引（或手动提 PR 更新索引仓库） |
| 5 | 安装验证 | 在全新 OpenClaw 环境中 `openclaw skills install ci-selfheal` 验证可安装 |

**Release Notes 模板**:
```markdown
## v1.0.0 - Initial Release

### Features
- CI build failure auto-detection via webhook (Jenkins/GitLab CI/GitHub Actions)
- Multi-source context collection (build logs + JJB YAML + watchdog analysis)
- AI-powered root cause diagnosis (DeepSeek)
- Four-branch decision matrix (auto-fix / patch / diagnose / CANNOT_FIX)
- Patch file generation (Unified Diff format)
- State machine with retry control and duplicate detection

### Dependencies
- ci-monitor, jenkins, ci-cd-watchdog, cicd-pipeline
- claw-summarize-pro, lint, security-auditor
- self-improve, capability-evolver-pro, n8n

### Installation
\`\`\`bash
openclaw skills install ci-selfheal
\`\`\`
```

**发布后验证**:
```bash
# 1. 全新环境中安装
openclaw skills install ci-selfheal

# 2. 确认依赖 Skill 已自动拉取
ls /home/node/.openclaw/workspace/skills/

# 3. 配置环境变量
export JENKINS_URL="https://172.19.0.1:18440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec81c11241d5a3897ab45608c6851"
export NODE_TLS_REJECT_UNAUTHORIZED=0
export JJB_CONFIG_PATH="./jjb-configs"

# 4. 测试 CLI
python bin/ci-selfheal --help

# 5. 测试编排（需要真实 Jenkins Job）
python bin/ci-selfheal orchestrate --job test-job --build 1

# 6. 验证状态文件
cat .self-heal-state.json | python -m json.tool
```

---

## 附录：快速命令参考

### 日常开发

```bash
# 进入 OpenClaw 容器
docker exec -it devopsclaw-openclaw bash

# 运行 Skill 主流程（使用 Python 脚本）
cd /app/.trae/skills/ci-selfheal
python ci_selfheal.py \
  --job-name <job> \
  --build-number <number> \
  --status FAILURE

# 查看状态
python ci_selfheal.py --status

# 运行单元测试
python -m pytest tests/ -v

# 查看状态文件
cat .self-heal-state.json | python -m json.tool
```

### Jenkins Webhook 配置

1. 安装 Jenkins `Notification Plugin`
2. Job 配置 → 构建后操作 → Add post-build action → HTTP Request
3. URL: `http://openclaw-host:5000/webhook/jenkins`
4. Method: POST
5. Content-Type: application/json
6. Body:
```json
{
  "jobName": "$JOB_NAME",
  "buildNumber": "$BUILD_NUMBER",
  "status": "$BUILD_STATUS",
  "branch": "$GIT_BRANCH"
}
```

### GitLab Webhook 配置（Pipeline 失败时）

1. Project → Settings → Webhooks
2. URL: `http://openclaw-host:5000/webhook/gitlab`
3. Trigger: Pipeline events
4. 勾选 `Enable SSL verification`（如适用）

### 环境变量速查

| 变量 | 说明 | 位置 | 备注 |
|------|------|------|------|
| `JENKINS_URL` | Jenkins 完整 URL（含 `/jenkins` 路径） | 环境变量 | 容器内用网关 IP，如 `https://172.19.0.1:18440/jenkins` |
| `JENKINS_USER` | Jenkins 用户名 | 环境变量 | 如 `zx` |
| `JENKINS_API_TOKEN` | Jenkins API Token | 环境变量 | **注意变量名是 `API_TOKEN`，不是 `TOKEN`** |
| `NODE_TLS_REJECT_UNAUTHORIZED` | 跳过 SSL 证书验证 | 环境变量 | 自签名证书必需，设为 `0` |
| `GITLAB_TOKEN` | GitLab Personal Token | `.global_settings.yaml` | 用于 Git 操作 |
| `AI_API_KEY` | DeepSeek/GPT API Key | `.global_settings.yaml` | 用于 AI 诊断 |
| `MAX_RETRY` | 最大重试次数 | 环境变量 | 默认 5 |
| `BRIDGE_PORT` | Webhook 监听端口 | 环境变量 | 默认 5000 |
| `SLACK_WEBHOOK_URL` | Slack 通知地址 | 环境变量 | 可选 |
| `N8N_API_URL` | n8n 工作流地址 | 环境变量 | 可选 |

---

> **文档结束**
