---
name: "ci-selfheal"
description: "Automatically diagnoses and fixes Jenkins CI/CD build failures using AI. Invoke when Jenkins build fails, or when user asks to fix CI issues, or when receiving build failure webhook events."
---

# CI Self-Heal Skill (CI/CD 自愈技能)

## 概述

这是一个 **高度自治的 CI/CD 自愈 Skill**，能够自动诊断 Jenkins 构建失败并生成修复方案。

**核心能力**:
- 接收 Jenkins 构建失败事件
- 拉取构建日志和 Pipeline 代码
- 调用 AI 诊断错误原因
- 生成修复后的代码
- 更新 Jenkins Job 配置
- 触发重新构建验证

## 触发场景

**当以下情况发生时，激活此 Skill**:

1. **Jenkins 构建失败**: 收到 `status: FAILURE` 的 Webhook 事件
2. **用户请求**: 用户询问 "如何修复这个构建失败?" 或类似问题
3. **CI 相关问题**: 用户提到 Jenkins、Pipeline、构建失败、CI 错误等关键词

## 架构概览

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        v4.0.0 Skill 架构                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Jenkins ──Webhook──► webhook_listener.py                              │
│                              │                                          │
│                              ▼                                          │
│                    ci_selfheal.process_event()                          │
│                              │                                          │
│          ┌───────────────────┼───────────────────┐                    │
│          ▼                   ▼                   ▼                    │
│  jenkins_client.py    jjb_manager.py      (AI 推理)                  │
│  (Jenkins API)        (JJB 配置管理)      (Agent CLI)             │
│          │                   │                   │                    │
│          └───────────────────┼───────────────────┘                    │
│                              ▼                                          │
│                    更新 JJB 配置 → 触发重新构建                          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**与旧版 Bridge 服务的区别**:

| 维度 | 旧版 (Bridge 服务) | 新版 (Skill 架构) |
|------|-------------------|-------------------|
| **部署方式** | 独立 HTTP 服务 | 集成到 Agent/Trae |
| **状态管理** | 独立服务进程 | 按需激活 |
| **可扩展性** | 需要维护服务 | Skill 原生支持 |
| **与 AI 集成** | 外部调用 Agent | 内部集成，无缝协作 |

## 核心文件说明

| 文件 | 职责 |
|------|------|
| `SKILL.md` | 此文件，Skill 定义和使用指南 |
| `ci_selfheal.py` | 核心自愈逻辑，包含 `process_event()` 主入口 |
| `jenkins_client.py` | Jenkins REST API 封装 |
| `jjb_manager.py` | Jenkins Job Builder (JJB) 配置管理 |
| `webhook_listener.py` | 可选的极简 Webhook 接收器 |

## 闭环流程 (高度自治)

```
阶段 1: 构建失败通知
┌──────────────────────────────────────────────────────────────┐
│  Jenkins Pipeline 执行失败                                     │
│         │                                                      │
│         ▼                                                      │
│  发送 Webhook 事件:                                            │
│  {                                                             │
│    "jobName": "example-pipeline",                             │
│    "buildNumber": 42,                                         │
│    "status": "FAILURE",                                       │
│    "buildTag": "jenkins-example-pipeline-42"                 │
│  }                                                             │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
阶段 2: 接收与解析
┌──────────────────────────────────────────────────────────────┐
│  调用 ci_selfheal.process_event(event)                       │
│                                                              │
│  步骤:                                                        │
│  1. 检查当前自愈状态                                          │
│  2. 验证是否达到最大重试次数 (默认 5 次)                      │
│  3. 准备拉取失败信息                                          │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
阶段 3: 信息收集
┌──────────────────────────────────────────────────────────────┐
│  jenkins_client 和 jjb_manager 协作:                         │
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │ JJB YAML 配置 │───►│ 构建日志     │───►│ 错误片段提取 │  │
│  │ (优先读取)    │    │ (consoleText)│    │              │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
│         │                                                      │
│         └──► 如果 JJB 不可用，回退到 Jenkins API              │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
阶段 4: AI 诊断与修复
┌──────────────────────────────────────────────────────────────┐
│  构建 Prompt 并调用 AI 模型:                                  │
│                                                              │
│  Prompt 包含:                                                 │
│  - 当前 Jenkinsfile (Pipeline 代码)                          │
│  - 构建日志 (最后 200 行)                                    │
│  - 关键错误片段                                               │
│  - 当前修复轮次                                               │
│                                                              │
│  调用方式 (Agent CLI):                                    │
│  docker exec agent node agent.mjs \                  │
│    infer model run \                                         │
│    --model "custom-api-deepseek-com/deepseek-reasoner" \   │
│    --prompt "<完整分析提示>"                                  │
│                                                              │
│  多模型 Fallback:                                             │
│  1. deepseek-reasoner (优先，推理质量高)                     │
│  2. kimi-k2.5 (备用，响应速度快)                              │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
阶段 5: 代码修复与配置更新
┌──────────────────────────────────────────────────────────────┐
│  从 AI 响应提取修复代码:                                      │
│                                                              │
│  提取规则:                                                     │
│  - 查找 ```groovy 代码块                                      │
│  - 查找 ```jenkinsfile 代码块                                 │
│  - 查找 ``` 包裹的代码块                                      │
│  - 兜底: 搜索 node { 和 stage(                                │
│                                                              │
│  如果 AI 返回 "CANNOT_FIX":                                   │
│  - 标记自愈失败                                               │
│  - 等待人工介入                                               │
│                                                              │
│  更新 JJB 配置:                                               │
│  1. 查找 {job_name}.yaml 或 {job_name}.yml                  │
│  2. 更新 dsl 字段 (正则替换，保留格式)                        │
│  3. 执行: jenkins-jobs update {yaml_file}                   │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
阶段 6: 触发验证
┌──────────────────────────────────────────────────────────────┐
│  触发原 Job 重新构建:                                         │
│                                                              │
│  操作:                                                        │
│  POST /job/{job_name}/build                                  │
│                                                              │
│  状态更新:                                                     │
│  - current_rety += 1                                         │
│  - 记录修复历史                                               │
│  - 等待下次构建结果通知                                       │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
阶段 7: 结果判断 (下次 Webhook)
┌──────────────────────────────────────────────────────────────┐
│  收到新的构建结果通知:                                         │
│                                                              │
│  ┌──────────────┐         ┌──────────────┐                  │
│  │   SUCCESS    │         │   FAILURE    │                  │
│  │  (构建成功)   │         │  (构建失败)   │                  │
│  └──────┬───────┘         └──────┬───────┘                  │
│         │                        │                           │
│         ▼                        ▼                           │
│  ┌──────────────┐         ┌──────────────┐                  │
│  │  标记自愈成功 │         │ 检查重试次数 │                  │
│  │  结束流程    │         │  < MAX_RETRY? │                  │
│  └──────────────┘         └──────┬───────┘                  │
│                                   │                           │
│                        ┌────────┴────────┐                  │
│                        ▼                 ▼                  │
│                   ┌─────────┐      ┌─────────┐             │
│                   │   是    │      │   否    │             │
│                   └────┬────┘      └────┬────┘             │
│                        │                 │                  │
│                        ▼                 ▼                  │
│                   回到阶段 2      标记 max_retry           │
│                   (再次修复)       等待人工介入             │
└──────────────────────────────────────────────────────────────┘
```

## 使用方法

### 方法 1: 命令行调用 (推荐用于测试)

```bash
# 处理单个失败事件
python ci_selfheal.py \
  --job-name "example-pipeline" \
  --build-number 42 \
  --status FAILURE

# 从 JSON 文件读取事件
python ci_selfheal.py --event-file event.json

# 查看当前状态
python ci_selfheal.py --status
```

### 方法 2: Python 模块调用

```python
from .trae.skills.ci_selfheal.ci_selfheal import process_event

# 构建事件
event = {
    "jobName": "example-pipeline",
    "buildNumber": 42,
    "status": "FAILURE"
}

# 处理事件
result = process_event(event)
print(result)
```

### 方法 3: Webhook 接收器 (用于 Jenkins 集成)

```bash
# 启动 Webhook 服务
python webhook_listener.py --port 5000

# 然后在 Jenkins 中配置 Webhook:
# URL: http://<host>:5000/webhook/jenkins
```

## 环境变量配置

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `JENKINS_URL` | Jenkins 服务地址 | `http://127.0.0.1:8081/jenkins` |
| `JENKINS_USER` | Jenkins 用户名 | `admin` |
| `JENKINS_TOKEN` | Jenkins API Token (必需) | - |
| `JJB_CONFIG_PATH` | JJB YAML 配置目录 | `./jjb-configs` |
| `JJB_INI_PATH` | JJB jenkins_jobs.ini 路径 | `./jjb-configs/jenkins_jobs.ini` |
| `MAX_RETRY` | 最大修复轮次 | `5` |
| `DEFAULT_MODEL` | 默认 AI 模型 | `deepseek-reasoner` |
| `AGENT_CONTAINER` | Agent 容器名 | `agent` |
| `STATE_FILE` | 状态文件路径 | `./.self-heal-state.json` |

## 状态管理

状态存储在 `STATE_FILE` (默认 `.self-heal-state.json`)：

```json
{
  "version": "4.0.0",
  "chains": {
    "example-pipeline": {
      "current_retry": 1,
      "status": "running",
      "original_build": 42,
      "history": [
        {
          "round": 1,
          "timestamp": "2026-05-06T10:30:00",
          "dsl_preview": "pipeline {\n  agent any\n  ..."
        }
      ],
      "created_at": "2026-05-06T10:25:00",
      "last_update": "2026-05-06T10:30:00"
    }
  }
}
```

**状态值**:
- `idle`: 空闲，没有进行中的自愈
- `running`: 正在进行自愈
- `success`: 自愈成功
- `failed`: 自愈失败 (AI 返回 CANNOT_FIX)
- `max_retry`: 达到最大重试次数

## Jenkins Pipeline Webhook 配置示例

在你的 Jenkins Pipeline 中添加以下 post 块：

```groovy
pipeline {
    agent any
    
    stages {
        stage('Build') {
            steps {
                sh 'make build'
            }
        }
    }
    
    post {
        always {
            script {
                try {
                    def payload = [
                        jobName: env.JOB_NAME,
                        buildNumber: env.BUILD_NUMBER,
                        status: currentBuild.currentResult,
                        buildTag: env.BUILD_TAG,
                        isOpenclaw: false,
                        retryCount: 0
                    ]
                    
                    def bridgeUrl = env.BRIDGE_URL ?: 'http://127.0.0.1:5000'
                    
                    sh """
                        curl -s -X POST \\
                          -H "Content-Type: application/json" \\
                          -d '${groovy.json.JsonOutput.toJson(payload)}' \\
                          ${bridgeUrl}/webhook/jenkins
                    """
                } catch (Exception e) {
                    echo "Failed to notify CI Self-Heal: ${e.getMessage()}"
                }
            }
        }
    }
}
```

## 常见问题排查

### 1. 无法连接 Jenkins

**检查**:
- `JENKINS_URL` 是否正确
- `JENKINS_TOKEN` 是否已设置
- 网络是否可达

**调试**:
```python
from jenkins_client import JenkinsClient
jenkins = JenkinsClient()
print(jenkins.get_job_config("your-job"))
```

### 2. 无法找到 JJB 配置文件

**检查**:
- `JJB_CONFIG_PATH` 是否正确
- Job 名称是否与 YAML 文件名匹配
- YAML 文件中是否包含 `job.name` 字段

**调试**:
```python
from jjb_manager import JJBManager
jjb = JJBManager()
print(jjb.list_all_jobs())  # 列出所有配置的 Job
yaml_file = jjb.find_job_yaml("your-job")
print(f"YAML 文件: {yaml_file}")
```

### 3. AI 调用失败

**检查**:
- Agent 容器是否运行: `docker ps | grep agent`
- `AGENT_CONTAINER` 名称是否正确
- 模型名称是否正确

**调试**:
```bash
# 测试 Agent CLI
docker exec agent node agent.mjs infer model run \
  --model "custom-api-deepseek-com/deepseek-reasoner" \
  --prompt "Hello, please respond with 'OK'"
```

### 4. jenkins-jobs 命令未找到

**安装**:
```bash
pip install jenkins-job-builder
```

**验证**:
```bash
jenkins-jobs --version
```

## 最大重试机制

系统设计了最多 5 轮的修复重试机制：

```
构建 #1 (失败)
    │
    ▼
第 1 轮修复 → 更新 JJB → 构建 #2
    │
    ├── 成功? ──► 结束 (自愈成功)
    │
    └── 失败? ──► 第 2 轮 → 构建 #3
                      │
                      ├── 成功? ──► 结束
                      │
                      └── 失败? ──► 第 3 轮 ...
                                        │
                                        └── 第 5 轮后仍失败
                                                │
                                                ▼
                                           停止自愈
                                           记录 max_retry 状态
                                           等待人工介入
```

**重试终止条件**:
1. 构建成功 → 终止，记录成功
2. 达到最大重试次数 (默认 5) → 终止，记录 max_retry
3. AI 返回 `CANNOT_FIX` → 终止，记录 failed
4. 连续相同错误 3 次 → 终止，防止无限循环

## 与旧版 Bridge 的兼容性

如果您之前使用过 `bridge_v3.py`，以下是迁移指南：

| 旧版 (bridge_v3.py) | 新版 (Skill 架构) |
|---------------------|-------------------|
| `python bridge_v3.py` | `python webhook_listener.py` |
| `handle_build(payload)` | `process_event(event)` |
| `JENKINS_URL` 环境变量 | 相同 |
| `JJB_CONFIG_PATH` 环境变量 | 相同 |
| 状态文件: `.self-heal-state.json` | 相同 (兼容格式) |

**迁移步骤**:
1. 停止旧的 bridge 服务
2. 确保环境变量配置正确
3. 启动新的 webhook_listener (可选)
4. 或直接通过 Python 模块调用 `process_event()`

## 安全注意事项

1. **Jenkins Token**:
   - 不要将 Token 硬编码在代码中
   - 使用环境变量或密钥管理服务
   - Token 应具有最小权限 (仅构建和读取配置)

2. **网络安全**:
   - Webhook 服务建议绑定 `127.0.0.1` 或内网地址
   - 生产环境建议添加认证机制
   - 考虑使用 HTTPS

3. **日志脱敏**:
   - 构建日志可能包含敏感信息
   - 考虑在日志中脱敏密码、密钥等

4. **AI 输出验证**:
   - AI 生成的代码在执行前应经过验证
   - 考虑添加沙箱执行环境
   - 关键流程建议人工审核

## 版本信息

- **Skill 版本**: 4.0.0
- **架构**: Skill 集成式 (v4)
- **更新日期**: 2026-05-06
- **关键变更**:
  - 从独立 Bridge 服务重构为 Agent Skill
  - 简化部署，集成到 AI 工作流
  - 保留所有原有功能 (AI 诊断、JJB 管理、闭环流程)

## 下一步优化建议

1. **添加 Web UI**:
   - 开发简单的管理界面
   - 查看修复历史和统计
   - 手动触发/暂停自愈

2. **支持更多 CI 系统**:
   - GitHub Actions
   - GitLab CI
   - Azure DevOps

3. **增强 AI 能力**:
   - 支持多文件修复
   - 集成代码审查
   - 自动创建 PR/MR

4. **监控告警**:
   - 添加 Prometheus 指标
   - 修复失败时发送通知
   - 自愈成功率统计

---

**当用户询问 CI 构建失败、Jenkins 问题、或需要自动修复时，激活此 Skill 并使用上述流程。**
