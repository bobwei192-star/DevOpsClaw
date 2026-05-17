/home/zx/CICD/DevOpsAgent/doc/12Agent CI 自愈闭环流水线—详细设计方案_极简.md Agent CI 自愈闭环流水线 — 详细施工步骤（基于现有 Skill 整合版 v2.0）
版本: v2.0
日期: 2026-05-12
配套核心方案: 极简核心设计
目标: 基于 Agent 已安装的 15 个 Skill + ClawHub 上的 GitLab Skill，实现 Jenkins 失败 → 自动抓日志 → AI 诊断 → 创建 fix 分支 → 触发重建 → 成功自动提 MR，最多重试 5 次，全程零人工。

一、前期准备
1.1 已确认可用的 Skill 清单
Skill	闭环中的角色	调用方式
jenkins	获取构建日志、触发构建	Agent Agent 自动调用
ci-monitor	监控流水线状态	同上
ci-cd-watchdog	解析日志、根因定位、修复建议	同上
cicd-pipeline	管理 CI/CD 流程，触发重建	同上
claw-summarize-pro	长日志摘要	同上
n8n	通知推送（钉钉/邮件等）	同上
（待安装）GitLab Skill	操作 GitLab（分支、提交、MR）	同上
1.2 安装 GitLab 操作 Skill
从 ClawHub 安装一个适合的 GitLab Skill（推荐 gitlab-skill 或 Gitlab Manager，因为支持创建分支、提交和 MR）。
执行命令（以 gitlab-skill 为例）：

bash
agent skills install gitlab-skill
配置环境变量：在 Agent 的 Secret Manager 中设置 GITLAB_TOKEN 和 GITLAB_URL。

二、ci-selfheal Skill 代码框架
在已有 skills 目录下创建新 Skill，整个 Skill 只负责编排，所有底层操作委托给已有的 Skill。

bash
mkdir -p /home/node/.agent/workspace/skills/ci-selfheal/scripts
2.1 目录结构
text
ci-selfheal/
├── SKILL.md                         # Skill 说明
├── skill.toml                       # 依赖声明
├── config.yaml                      # 用户配置（仓库白名单、分支规则、重试次数等）
└── scripts/
    ├── orchestrator.py               # 主编排器（状态机 + 重试循环）
    ├── webhook_listener.py           # HTTP 入口，接收 Jenkins 失败通知
    └── agent_wrapper.py              # 封装 agent agent 调用，返回结构化结果
2.2 SKILL.md（示例）
markdown
# ci-selfheal

全自动 Jenkins 构建失败自愈闭环。
1. 接收 Webhook
2. 通过 Agent 调用 jenkins / ci-cd-watchdog 获取并解析日志
3. Agent AI 诊断生成修复代码
4. 通过 Agent 调用 gitlab Skill 创建 fix 分支并提交修复
5. 通过 Agent 调用 jenkins / cicd-pipeline 触发重建并轮询
6. 构建成功后通过 Agent 调用 gitlab Skill 创建 MR
7. 失败自动重试（最多5次），熔断后通过 n8n 告警
2.3 skill.toml
toml
name = "ci-selfheal"
version = "1.0.0"
dependencies = [
    "jenkins",
    "ci-monitor",
    "ci-cd-watchdog",
    "cicd-pipeline",
    "gitlab-skill",   # 或者你实际安装的 GitLab Skill 名称
    "n8n"
]
2.4 config.yaml
yaml
jenkins:
  base_url: "https://jenkins.example.com"
gitlab:
  base_url: "https://gitlab.example.com"
  token: "${GITLAB_TOKEN}"
repair:
  max_retries: 5
  poll_interval_seconds: 5
  build_timeout_minutes: 30
notify:
  dingtalk_webhook: "${DINGTALK_WEBHOOK}"
whitelist:
  repos:
    - "group/project1"
    - "group/project2"
  protected_branches:
    - "main"
    - "release/*"
三、施工步骤（P0 → P1 → P2）
P0 · 核心闭环（一次性全自动修复 + 自动 MR）
任务 1：编写 agent_wrapper.py（让 Agent 高效执行任务）
Agent Agent 可以通过命令行调用，并让它利用已安装的 Skill 去完成具体操作。
包装一个函数，传入自然语言指令，Agent 返回我们希望的结构化 JSON。

伪代码：

python
import json
import subprocess
from typing import Any


def ask_agent(instruction: str, expect_json: bool = True) -> Any:
    # instruction 示例: "用 jenkins skill 获取 job 'xxx' build 123 的日志"
    result = subprocess.run(
        ["agent", "agent", "--message", instruction, "--json"],
        check=True,
        capture_output=True,
        text=True,
    )
    stdout = result.stdout
    if expect_json:
        try:
            return json.loads(stdout)
        except json.JSONDecodeError as exc:
            raise ValueError(f"Agent 未返回有效 JSON: {stdout}") from exc
    return stdout
注意事项：

如果 Agent 返回的不是 JSON，你可以通过特定的输出标记（如 ---RESULT---）来提取。

确保 Agent 已配置好所有 Skill 的 API 密钥。

任务 2：搭建 Webhook 监听器
文件: webhook_listener.py

使用 Python 启动服务，监听 POST /webhook/ci-failure。

收到 Webhook 后，校验仓库是否在白名单、分支是否为保护分支（G0 校验）。

校验通过则调用 orchestrator.run(payload)。

验证：

bash
curl -X POST http://localhost:8080/webhook/ci-failure \
  -d '{"job":"example_fauliure_job","build":1,"branch":"dev","repo":"group/project"}'
# 查看 orchestrator 日志输出 "Start self-heal for ..."
任务 3：编排主流程（第一步：收集信息）
在 orchestrator.py 中实现 run(payload) 函数，每步都通过 Agent 调用现有 Skill。

Step 1: 获取并解析日志

python
log_result = ask_agent(
    f"""
  使用 jenkins skill 获取 job '{payload.job}' build {payload.build} 的完整控制台日志，
  然后用 ci-cd-watchdog 分析日志，提取关键错误信息。
  返回 JSON: {{ "raw_log": "...", "error_summary": "...", "error_type": "compile|dependency|config|test|env|other" }}
"""
)
此时 raw_log 可以自行脱敏（Agent 返回后，在 orchestrator 中做一次正则替换），然后存入上下文 ctx.log、ctx.error_summary。

Step 2: 克隆仓库（如果尚未克隆）

python
# 直接执行 shell 命令，或让 Agent 通过 gitlab Skill 克隆
subprocess.run(
    ["git", "clone", "--depth", "1", "-b", payload.branch, repo_url, ctx.repo_dir],
    check=True,
)
或者使用 Agent 指令：

python
ask_agent(
    f"使用 gitlab-skill 克隆仓库 {payload.repo} 分支 {payload.branch} 到 {ctx.repo_dir}",
    False,
)
任务 4：AI 诊断并生成修复
仍然通过 Agent，但这次我们需要让 AI 生成具体可用的补丁。

指令设计：

python
fix = ask_agent(
    f"""
  当前 CI 构建失败，错误摘要：{ctx.error_summary}
  构建日志（脱敏后）：{ctx.log}
  仓库路径：{ctx.repo_dir}

  请使用 ci-cd-watchdog 进一步分析，然后生成修复方案。
  修复必须只改动构建脚本、CI 配置文件、环境变量等，不能修改 src/ 下的业务代码。
  输出 JSON：
  {{
    "root_cause": "...",
    "error_type": "...",
    "confidence": 0.85,
    "fix_diff": {{ "path/to/file": "新的完整内容" }}
  }}
  如果 confidence < 0.6，请在 root_cause 中说明原因，且 fix_diff 为空。
"""
)
Agent 会利用 ci-cd-watchdog 和内置 AI 能力生成修复。我们接收 JSON。

处理低置信度：若 confidence < 0.6，直接生成诊断报告并通过 n8n 通知，流程终止。

任务 5：创建 fix 分支并提交修复
依赖: 已安装的 gitlab Skill。

指令：

python
fix_branch = f"fix/ci-selfheal-{payload.job}-{payload.build}"
ask_agent(
    f"""
  使用 gitlab-skill，在仓库 {payload.repo} 上做以下操作：
  1. 基于分支 {payload.branch} 创建新分支 {fix_branch}
  2. 将以下文件内容写入工作区：
     {json.dumps(fix['fix_diff'], ensure_ascii=False)}
  3. 提交并推送到远程，commit 信息为 "[ci-selfheal] auto fix {payload.job} #{payload.build}"
""",
    False,
)
备选：如果 gitlab Skill 功能有限，可以直接在 orchestrator 中用 Python 调用 GitLab API，但优先使用 Skill 保持统一。

任务 6：触发 Jenkins 重建并轮询
指令：

python
trigger_result = ask_agent(
    f"""
  使用 cicd-pipeline skill 或 jenkins skill，触发 job '{payload.job}' 的构建，参数 branch={fix_branch}。
  返回 JSON: {{ "build_number": 新的构建号 }}
"""
)
new_build = trigger_result["build_number"]
轮询结果：

python
import time

build_result = None
deadline = time.time() + 30 * 60
while time.time() < deadline:
    status = ask_agent(
        f"""
      使用 jenkins skill 查询 job '{payload.job}' build {new_build} 的状态。
      返回 JSON: {{ "result": "SUCCESS" | "FAILURE" | "ABORTED" | null }}
"""
    )
    if status["result"] == "SUCCESS":
        build_result = "SUCCESS"
        break
    if status["result"] in {"FAILURE", "ABORTED"}:
        build_result = "FAILURE"
        break
    time.sleep(5)
（此处可用定时器，超时未完成视为失败进入重试）

任务 7：成功则创建 MR
指令：

python
if build_result == "SUCCESS":
    ask_agent(
        f"""
      使用 gitlab-skill，在仓库 {payload.repo} 上创建 Merge Request：
      - 源分支：{fix_branch}
      - 目标分支：{payload.branch}
      - 标题：[ci-selfheal] Auto-fix: {payload.job} #{payload.build} — {fix['error_type']}
      - 描述：{generate_mr_description(fix, payload)}
      - 添加标签：auto-fix,ci-selfheal
"""
    )
    # 向相关开发者发送通知（n8n）
P0 验收标准：
构造一个 Jenkins Job 故意失败 → 向 Webhook 发送请求 → 整个流程无人工介入，最终 GitLab 上出现 MR 且描述中包含诊断信息。

P1 · 鲁棒增强（重试、熔断、边界）
任务 8：实现重试循环
在 orchestrator.py 中加入重试逻辑：for attempt in range(1, max_retries + 1):。

每次重试前，使用最新失败构建的日志（带上 reward 信号）：

python
ctx.log = ask_agent(f"用 jenkins skill 获取 job '{payload.job}' build {last_failed_build} 日志")
# prompt 中加入：前一次修复尝试失败，新错误信息：...
第 3 轮后可通过 Agent 指令切换更强模型（在指令中说明“请使用更高能力的模型进行诊断”）。

重试间隔可采用指数退避。

任务 9：熔断与告警
当重试次数 > 5 后，设置全局冷却期（例如 2 小时），该时间段内同一 job+分支的失败事件只产生诊断报告，不自动修复。

通过 Agent 调用 n8n skill 发送告警消息：

python
ask_agent(f"使用 n8n 发送消息到钉钉：CI自愈熔断，job: {payload.job}，详情...")
任务 10：边界处理
修复前检查目标分支是否有新提交，若有则 rebase：

python
ask_agent(f"使用 gitlab-skill 将 {fix_branch} 基于 {payload.branch} 的最新提交 rebase")
Jenkins 队列堆积：在触发构建前检查队列长度，若过大则延迟触发。

熔断后自动清理多余的 fix 分支（通过 Agent 调用 gitlab Skill 删除分支）。

P2 · 运维与可视化（管理面板、配置、审计）
任务 11：审计日志
每次自愈流程生成一个 JSON 日志文件，保存在 ci-selfheal/logs/ 下，记录所有 Agent 调用的输入输出摘要、各阶段耗时、最终结果。

通过 agent agent --message "将今日自愈报告发送到 n8n" 定时发送摘要。

任务 12：配置热加载 & 健康检查
webhook_listener.py 暴露 GET /health 返回 Self-Heal 系统状态（熔断状态、进行中的任务数等）。

监听 config.yaml 变化自动重新加载白名单和参数。

四、与已存在 Skill 的协作图
text
Jenkins Webhook → webhook_listener.py
                       │
                       ▼
               orchestrator.run()
                       │
           ┌───────────┼───────────┐
           │           │           │
      (收集日志)   (诊断修复)   (Git 操作)
           │           │           │
    jenkins Skill  ci-cd-watchdog  gitlab-skill
    ci-monitor     AI (Agent)     (创建分支/提交/MR)
           │           │           │
           └───────────┼───────────┘
                       │
                 cicd-pipeline   (触发重建)
                       │
            (轮询结果) jenkins Skill
                       │
                  n8n (告警/通知)
五、总结
零新轮子：所有核心能力（日志、诊断、Git 操作、通知）全部由现有 Skill 提供。

编排极简：ci-selfheal 只做流程控制和 Call Agent。

落地顺序：先跑通 P0（一条命令式的 Agent 调用链路），再加固 P1/P2。

验证方式：每步都能手动模拟 Webhook 后观察 Agent 输出和 GitLab 变化。

六、同类 Skill 参考
6.1 ClawHub 现有 DevOps 相关 Skill
Skill	简介	与 ci-selfheal 的关系
agentic-devops（tkuehnl）	CLI 工具箱：Docker 容器管理、进程检查、日志分析、HTTP 健康检查。纯 Python 标准库，零外部依赖。	互补关系。agentic-devops 提供通用运维诊断能力（查容器状态、找 CPU 占用进程、扫日志错误模式），ci-selfheal 在此基础上做 CI 构建失败的自动修复闭环。可以组合使用：用 agentic-devops 做系统级健康检查，用 ci-selfheal 做 Pipeline 级自愈。
crash-fixer（ryce）	自主 Crash 分析和 Bug 修复	侧重点不同：crash-fixer 修应用运行时 Crash，ci-selfheal 修 CI 构建脚本失败
solo-retro（fortunto2）	事后 Pipeline 复盘：解析日志、评分、建议补丁	最接近但不同：solo-retro 是事后复盘建议，ci-selfheal 是实时拦截 + 自动修复 + 重建验证闭环
6.2 agentic-devops 详细分析
安装方式：

bash
agent skills install tkuehnl/agentic-devops
核心能力清单：

功能	说明	ci-selfheal 是否已有
Docker 容器管理	查看容器状态、重启、日志	部分（不直接管理 Docker）
进程检查	找 CPU/内存占用最高的进程	❌ 没有
日志分析	扫描错误模式、统计频率	部分（Jenkins 日志拉取 + AI 诊断）
HTTP 健康检查	验证端点响应	✅ /health 端点
系统快照	CPU、内存、磁盘、端口一次性快照	❌ 没有
典型使用场景：

# 部署后检查 Docker 容器健康
# 找生产服务器上 CPU 最高的进程
# 扫描应用日志中的错误模式
# 值班前验证 HTTP 端点
# 一条命令获取完整系统快照
与 ci-selfheal 的组合建议：
ci-selfheal 处理 Jenkins Pipeline 层面的失败（编译错误、Shell 语法、配置缺失），agentic-devops 处理基础设施层面的诊断（容器挂了、CPU 爆了、磁盘满了）。两者配合可以覆盖从基础设施到 CI Pipeline 的全栈自愈。