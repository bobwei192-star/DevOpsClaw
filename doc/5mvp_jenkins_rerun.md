# DevOpsClaw 自愈流水线 MVP 工程化部署指南

> **版本**: v4.0.0 (OpenClaw Skill 架构版)  
> **更新日期**: 2026-05-06  
> **部署方式**: Docker Compose 统一编排 + OpenClaw Skill 集成  
> **Job 管理**: Jenkins Job Builder (JJB) YAML 配置管理

---

## 目录

1. [架构概览](#一架构概览)
2. [Docker Compose 服务编排](#二docker-compose-服务编排)
3. [OpenClaw Skill 架构](#三openclaw-skill-架构)
4. [JJB (Jenkins Job Builder) 配置](#四jjb-jenkins-job-builder-配置)
5. [核心闭环流程](#五核心闭环流程)
6. [部署步骤](#六部署步骤)
7. [验证测试](#七验证测试)
8. [监控与运维](#八监控与运维)
9. [故障排查](#九故障排查)

---

## 一、架构概览

### 1.1 系统架构图 (v4.0.0)

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                              Docker Compose 统一编排网络                                               │
│                          (devopsclaw-network, bridge 模式)                                           │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  核心服务层                                                                                            │
├─────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                       │
│  ┌───────────────────────────────────────────────────────────────────────────────────────────────┐ │
│  │                              Jenkins (CI/CD 引擎)                                               │ │
│  │  ┌─────────────────────────────────────────────────────────────────────────────────────────┐ │ │
│  │  │                                                                                           │ │ │
│  │  │   Job 管理方式: JJB YAML 配置 (不再创建新 Job，而是更新原 Job)                              │ │ │
│  │  │                                                                                           │ │ │
│  │  │   ┌─────────────────────────────────────────────────────────────────────────────────┐   │ │ │
│  │  │   │                                                                                   │   │ │ │
│  │  │   │  example-pipeline (由 JJB 管理)                                                  │   │ │ │
│  │  │   │  ┌─────────────────────────────────────────────────────────────────────────┐     │   │ │ │
│  │  │   │  │ 构建 #1: 失败 (date-- 命令错误)                                          │     │   │ │ │
│  │  │   │  │ 构建 #2: 触发 (AI 修复后重新运行同一 Job)                                │     │   │ │ │
│  │  │   │  │ 构建 #3: 成功 (date 命令正确执行)                                        │     │   │ │ │
│  │  │   │  └─────────────────────────────────────────────────────────────────────────┘     │   │ │ │
│  │  │   │                                                                                   │   │ │ │
│  │  │   │  【关键改进】同一 Job，多次构建，历史记录完整保留                                     │   │ │ │
│  │  │   │                                                                                   │   │ │ │
│  │  │   └─────────────────────────────────────────────────────────────────────────────────┘   │ │ │
│  │  │                                                                                           │ │ │
│  │  │  容器名: devopsclaw-jenkins                                                              │ │ │
│  │  │  端口: 127.0.0.1:8081:8080 (外部), 50000 (代理)                                        │ │ │
│  │  │  网络: devopsclaw-network                                                                 │ │ │
│  │  │                                                                                           │ │ │
│  │  └─────────────────────────────────────────────────────────────────────────────────────────┘ │ │
│  └───────────────────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                                       │
│                                      │                                                               │
│                                      │ 1. Pipeline 执行                                              │
│                                      │ 2. 失败后发送 Webhook / 直接通知                              │
│                                      │ 3. 接收 JJB 更新后的新配置                                     │
│                                      │ 4. 触发新构建 (同一 Job)                                       │
│                                      ▼                                                               │
│  ┌───────────────────────────────────────────────────────────────────────────────────────────────┐ │
│  │                      OpenClaw/Trae (AI 平台 + Skill 引擎)                                      │ │
│  │  ┌─────────────────────────────────────────────────────────────────────────────────────────┐ │ │
│  │  │                                                                                           │ │ │
│  │  │  ┌─────────────────────────────────────────────────────────────────────────────────────┐ │ │ │
│  │  │  │                         CI Self-Heal Skill (ci-selfheal)                              │ │ │ │
│  │  │  │                                                                                         │ │ │ │
│  │  │  │  存储位置: .trae/skills/ci-selfheal/                                                  │ │ │ │
│  │  │  │                                                                                         │ │ │ │
│  │  │  │  核心职责:                                                                              │ │ │ │
│  │  │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │ │ │ │
│  │  │  │  │ 接收构建事件  │  │ AI 诊断调度  │  │ JJB 配置更新  │  │ 状态追踪      │           │ │ │ │
│  │  │  │  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘           │ │ │ │
│  │  │  │                                                                                         │ │ │ │
│  │  │  │  【架构变化】不再是独立的 Bridge 服务                                                    │ │ │ │
│  │  │  │  而是:                                                                                   │ │ │ │
│  │  │  │  1. 作为 OpenClaw Skill 原生集成                                                        │ │ │ │
│  │  │  │  2. 无需独立容器/进程                                                                    │ │ │ │
│  │  │  │  3. 与 AI 引擎无缝协作                                                                   │ │ │ │
│  │  │  │                                                                                         │ │ │ │
│  │  │  │  工作流程:                                                                              │ │ │ │
│  │  │  │  1. 从 Jenkins 获取失败日志、Jenkinsfile                                                 │ │ │ │
│  │  │  │  2. 读取 JJB YAML 配置文件 (优先)                                                       │ │ │ │
│  │  │  │  3. 调用 OpenClaw AI 诊断                                                                │ │ │ │
│  │  │  │  4. AI 返回修复后的 Jenkinsfile                                                          │ │ │ │
│  │  │  │  5. 更新 JJB YAML 配置文件                                                               │ │ │ │
│  │  │  │  6. 执行 `jenkins-jobs update` 更新原 Job                                                │ │ │ │
│  │  │  │  7. 触发原 Job 的新构建                                                                   │ │ │ │
│  │  │  │                                                                                         │ │ │ │
│  │  │  └─────────────────────────────────────────────────────────────────────────────────────┘ │ │ │
│  │  │                                                                                           │ │ │
│  │  │  容器名: devopsclaw-openclaw                                                               │ │ │
│  │  │  端口: 127.0.0.1:18789:18789                                                              │ │ │
│  │  │  网络: devopsclaw-network                                                                 │ │ │
│  │  │                                                                                           │ │ │
│  │  └─────────────────────────────────────────────────────────────────────────────────────────┘ │ │
│  └───────────────────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                                       │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘

                                      │
                                      │ HTTPS API 调用
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  外部 AI 模型服务                                                                                      │
├─────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                       │
│  ┌──────────────────┐   ┌──────────────────┐                                                        │
│  │  DeepSeek API    │   │    Kimi API      │                                                        │
│  │ deepseek-reasoner│   │   kimi-k2.5      │                                                        │
│  │                  │   │                  │                                                        │
│  │ 主用模型 (推荐)   │   │ 备用模型 (Fallback)                                                       │
│  │ - 推理质量高      │   │ - 响应速度快      │                                                        │
│  │ - 代码理解强      │   │ - 多语言支持      │                                                        │
│  └──────────────────┘   └──────────────────┘                                                        │
│                                                                                                       │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  可选服务: GitLab CE (代码仓库)                                                                       │
├─────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                       │
│  使用 GitLab CE 内置的 PostgreSQL 和 Redis，无需单独安装:                                             │
│  - 内置 PostgreSQL: GitLab Omnibus 自带，自动配置                                                    │
│  - 内置 Redis: GitLab Omnibus 自带，自动配置                                                         │
│                                                                                                       │
│  容器名: devopsclaw-gitlab                                                                            │
│  端口: 127.0.0.1:8082:80 (HTTP), 8443:443 (HTTPS), 2222:22 (SSH)                                  │
│                                                                                                       │
│ 【重要】自愈功能本身不需要 GitLab，可替换为 GitHub、Gitea 等                                          │
│                                                                                                       │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 关键变更说明 (v4.0.0 vs v3.0.0)

| 维度 | v3.0.0 (旧方式) | v4.0.0 (新方式) | 原因 |
|------|-----------------|-----------------|------|
| **中间件架构** | Bridge 独立服务 (Docker 容器) | **OpenClaw Skill 原生集成** | 消除额外服务，简化部署 |
| **PostgreSQL** | 独立容器 (为 GitLab) | **GitLab 内置** | GitLab CE 自带，无需单独管理 |
| **Redis** | 独立容器 (为 GitLab) | **GitLab 内置** | GitLab CE 自带，无需单独管理 |
| **服务数量** | 7 个服务 (PostgreSQL, Redis, GitLab, Jenkins, Bridge, OpenClaw) | **3-4 个服务** | 大幅简化运维 |
| **状态管理** | Bridge 服务内部 | **本地 JSON 文件** | Skill 原生，无需额外存储 |
| **AI 调用** | Bridge 调用 OpenClaw CLI | **Skill 内部直接调用** | 更高效，无缝集成 |

### 1.3 服务清单 (v4.0.0)

| 服务 | 是否必需 | 说明 | 独立服务？ |
|------|---------|------|-----------|
| **OpenClaw** | ✅ 必需 | AI 网关 + Skill 引擎 | ✅ Docker 容器 |
| **Jenkins** | ✅ 必需 | CI/CD 引擎 | ✅ Docker 容器 |
| **GitLab CE** | ❌ 可选 | 代码仓库 (使用内置 PostgreSQL/Redis) | ✅ Docker 容器 (可选) |
| **PostgreSQL** | ❌ 已移除 | 之前为 GitLab，**现在 GitLab 内置** | ❌ 不再需要 |
| **Redis** | ❌ 已移除 | 之前为 GitLab，**现在 GitLab 内置** | ❌ 不再需要 |
| **Bridge** | ❌ 已移除 | **整合为 OpenClaw Skill** | ❌ 不再需要 |
| **CI Self-Heal Skill** | ✅ 必需 | 自愈核心逻辑 | ❌ Skill (非独立服务) |

### 1.4 网络访问矩阵

| 源 | 目标 | 访问地址 | 说明 |
|------|------|---------|------|
| Jenkins 容器 | Skill (通过 Webhook) | `http://host.docker.internal:5000` | 可选的 Webhook Listener |
| Skill (本地) | Jenkins | `http://127.0.0.1:8081/jenkins` 或容器名 | 直接调用 Jenkins API |
| OpenClaw 容器 | AI API | `https://api.deepseek.com` | 外部 HTTPS 调用 |
| Skill | OpenClaw CLI | `docker exec devopsclaw-openclaw ...` | 调用 AI 模型 |

---

## 二、Docker Compose 服务编排

### 2.1 docker-compose.yml 配置说明

```yaml
version: '3.8'

networks:
  devopsclaw-network:
    driver: bridge
    name: devopsclaw-network

volumes:
  jenkins-home:      # Jenkins 数据持久化
  openclaw-data:     # OpenClaw 数据持久化
  gitlab-config:     # GitLab 配置 (可选)
  gitlab-logs:       # GitLab 日志 (可选)
  gitlab-data:       # GitLab 数据 (可选)
```

### 2.2 服务详解

#### 2.2.1 OpenClaw (AI 网关 + Skill 引擎)

```yaml
openclaw:
  image: ghcr.io/openclaw/openclaw:latest
  container_name: devopsclaw-openclaw
  restart: unless-stopped
  user: "1000:1000"                    # 非 root 用户
  cap_drop:
    - ALL                              # 丢弃所有 capabilities
  security_opt:
    - no-new-privileges:true          # 禁止提权
  read_only: true                       # 只读文件系统
  tmpfs:
    - /tmp:rw,noexec,nosuid,size=64m  # 临时可写目录
  networks:
    - devopsclaw-network
  ports:
    - "127.0.0.1:18789:18789"         # 仅本地绑定
  volumes:
    - openclaw-data:/home/node/.openclaw
  environment:
    - OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
  working_dir: /home/node/openclaw
  command: node openclaw.mjs gateway --allow-unconfigured
```

#### 2.2.2 Jenkins (CI/CD 引擎)

```yaml
jenkins:
  image: jenkins/jenkins:lts-jdk17
  container_name: devopsclaw-jenkins
  restart: unless-stopped
  user: root
  networks:
    - devopsclaw-network
  ports:
    - "127.0.0.1:8081:8080"    # Web UI
    - "127.0.0.1:50000:50000"  # Agent 连接
  volumes:
    - jenkins-home:/var/jenkins_home
    - /var/run/docker.sock:/var/run/docker.sock  # Docker-in-Docker
  environment:
    - JENKINS_OPTS=--prefix=/jenkins
    - JAVA_OPTS=-Xmx2g -Xms512m
```

#### 2.2.3 GitLab CE (可选，代码仓库)

**重要**: GitLab CE 使用内置的 PostgreSQL 和 Redis，无需单独安装这些服务。

```yaml
gitlab:
  image: gitlab/gitlab-ce:latest
  container_name: devopsclaw-gitlab
  restart: unless-stopped
  hostname: ${GITLAB_HOSTNAME:-gitlab.devopsclaw.local}
  networks:
    - devopsclaw-network
  ports:
    - "127.0.0.1:8082:80"      # HTTP
    - "127.0.0.1:8443:443"     # HTTPS
    - "127.0.0.1:2222:22"      # SSH
  volumes:
    - gitlab-config:/etc/gitlab
    - gitlab-logs:/var/log/gitlab
    - gitlab-data:/var/opt/gitlab
  environment:
    - GITLAB_OMNIBUS_CONFIG="
        external_url 'http://${GITLAB_HOSTNAME:-gitlab.devopsclaw.local}';
        gitlab_rails['gitlab_shell_ssh_port'] = 2222;
      "
```

**配置说明**:
- 没有设置 `postgresql['enable'] = false` → **使用 GitLab 内置 PostgreSQL**
- 没有设置 `redis['enable'] = false` → **使用 GitLab 内置 Redis**
- 不再需要 `depends_on: [postgresql, redis]`

### 2.3 环境变量配置 (.env)

```bash
# ============================================
# DevOpsClaw 环境变量配置
# ============================================

# ---------- OpenClaw Gateway ----------
# 生成命令: tr -dc A-Za-z0-9 < /dev/urandom | head -c 64
OPENCLAW_GATEWAY_TOKEN=your_secure_token_here

# ---------- Jenkins ----------
JENKINS_URL=http://127.0.0.1:8081/jenkins
JENKINS_USER=admin
# 从 Jenkins 用户设置中生成 API Token
JENKINS_TOKEN=your_jenkins_token_here

# ---------- AI 模型配置 ----------
# 可选: deepseek-reasoner, kimi-k2.5
DEFAULT_MODEL=deepseek-reasoner

# ---------- 业务规则 ----------
# 最大修复轮次
MAX_RETRY=5

# ---------- GitLab (可选) ----------
GITLAB_HOSTNAME=gitlab.devopsclaw.local

# ---------- JJB 配置 ----------
JJB_CONFIG_PATH=./jjb-configs
```

---

## 三、OpenClaw Skill 架构

### 3.1 Skill 文件结构

Skill 存储在项目的 `.trae/skills/ci-selfheal/` 目录：

```
.trae/skills/ci-selfheal/
├── SKILL.md                   # Skill 定义 (必需)
│                              # 包含:
│                              # - name: "ci-selfheal"
│                              # - description: 何时激活此 Skill
│                              # - 详细使用指南
│
├── ci_selfheal.py             # 核心自愈逻辑
│                              # 主入口: process_event(event)
│
├── jenkins_client.py          # Jenkins API 封装
│                              # - 拉取构建日志
│                              # - 触发构建
│                              # - 获取 Job 配置
│
├── jjb_manager.py             # JJB 配置管理
│                              # - 查找 YAML 配置
│                              # - 读取/更新 dsl
│                              # - 执行 jenkins-jobs 命令
│
└── webhook_listener.py        # 可选: 极简 Webhook 接收器
                               # - 监听端口 5000
                               # - 接收 Jenkins Webhook
                               # - 调用 process_event()
```

### 3.2 SKILL.md 定义示例

```markdown
---
name: "ci-selfheal"
description: "Automatically diagnoses and fixes Jenkins CI/CD build failures using AI. Invoke when Jenkins build fails, or when user asks to fix CI issues, or when receiving build failure webhook events."
---

# CI Self-Heal Skill (自愈式流水线)

## 概述

此 Skill 用于自动化诊断和修复 Jenkins CI/CD 构建失败。
```

### 3.3 触发条件

**Skill 在以下情况被激活**:

1. **Jenkins 构建失败事件**:
   - 收到包含 `"status": "FAILURE"` 的 Webhook
   - 用户提供了构建失败的 Job 名称和构建号

2. **用户询问 CI 相关问题**:
   - "如何修复这个 Jenkins 构建失败?"
   - "这个 Pipeline 为什么失败了?"
   - "帮我看一下 CI 错误"

3. **关键词触发**:
   - Jenkins、Pipeline、构建失败、CI/CD 错误
   - JJB、Jenkins Job Builder
   - 自愈、自动修复

### 3.4 使用方式

#### 方式 1: 作为 Skill 自动激活

当 Skill 被正确配置后，OpenClaw/Trae 会自动检测并使用。

#### 方式 2: Python 模块调用

```python
from .trae.skills.ci-selfheal.ci_selfheal import process_event

event = {
    "jobName": "example-pipeline",
    "buildNumber": 42,
    "status": "FAILURE"
}

result = process_event(event)
print(result)
```

#### 方式 3: 命令行调用

```bash
# 处理单个失败事件
python .trae/skills/ci-selfheal/ci_selfheal.py \
  --job-name "example-pipeline" \
  --build-number 42 \
  --status FAILURE

# 查看当前状态
python .trae/skills/ci-selfheal/ci_selfheal.py --status
```

#### 方式 4: Webhook 接收器 (用于 Jenkins 集成)

```bash
# 启动 Webhook 服务
python .trae/skills/ci-selfheal/webhook_listener.py --port 5000
```

---

## 四、JJB (Jenkins Job Builder) 配置

### 4.1 为什么选择 JJB？

**传统方式的问题**:
- Job 配置存储在 Jenkins 内部，难以版本控制
- 手动修改容易出错，难以追溯
- AI 修复需要创建新 Job，历史分散
- 回滚困难，多环境不一致

**JJB 方式的优势**:
1. **配置即代码**: 所有 Job 定义在 YAML 文件中
2. **版本控制**: Git 管理，支持回滚、审查
3. **工程化**: 可复用、可测试、可自动化
4. **AI 友好**: AI 修复直接更新 YAML 配置
5. **历史集中**: 同一 Job，多次构建，历史记录完整

### 4.2 JJB 配置结构

```
jjb-configs/
├── defaults.yaml              # 全局默认配置
├── jenkins_jobs.ini           # JJB 连接配置
├── example-pipeline.yaml      # 示例业务 Pipeline
└── test-failure-pipeline.yaml # 测试用 Pipeline
```

### 4.3 核心配置文件

#### 4.3.1 全局默认配置 (defaults.yaml)

```yaml
- defaults:
    name: global
    description: 'Managed by Jenkins Job Builder - DO NOT EDIT MANUALLY'
    project-type: pipeline
    concurrent: false
    disabled: false
    logrotate:
      daysToKeep: 30
      numToKeep: 50
    parameters:
      - string:
          name: BUILD_BRANCH
          default: main
          description: 'Git branch to build'
```

#### 4.3.2 JJB 连接配置 (jenkins_jobs.ini)

```ini
[jenkins]
user=${JENKINS_USER}
password=${JENKINS_TOKEN}
url=${JENKINS_URL}

[job_builder]
ignore_cache=True
keep_descriptions=False
recursive=True
allow_duplicates=False
```

#### 4.3.3 Pipeline Job 配置示例

```yaml
- job:
    name: example-pipeline
    defaults: global
    description: 'Example Business Pipeline - Managed by JJB'
    
    dsl: |
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
            echo 'Build complete'
          }
        }
      }
```

### 4.4 JJB 常用命令

```bash
# 1. 安装 JJB
pip install jenkins-job-builder

# 2. 测试配置 (不实际更新 Jenkins)
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini \
  test jjb-configs/example-pipeline.yaml

# 3. 更新单个 Job 到 Jenkins
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini \
  update jjb-configs/example-pipeline.yaml

# 4. 更新所有 Job
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini \
  update jjb-configs/
```

---

## 五、核心闭环流程

### 5.1 新旧流程对比

#### 旧流程 (v3.0.0: Bridge 独立服务)

```
Jenkins 构建失败
     │
     ▼ Webhook
     │
Bridge 服务 (独立 Docker 容器)
     │
     ├──► 接收 Webhook
     ├──► 拉取日志
     ├──► 调用 OpenClaw CLI
     ├──► AI 诊断
     ├──► 更新 JJB 配置
     ├──► 触发重构建
     │
     ▼ 等待下次构建结果
```

#### 新流程 (v4.0.0: OpenClaw Skill)

```
Jenkins 构建失败
     │
     ▼ Webhook / 直接调用
     │
OpenClaw Skill (ci-selfheal) 被激活
     │
     ├──► 内置在 OpenClaw/Trae 中
     ├──► 无需独立服务
     ├──► 与 AI 无缝协作
     │
     ▼ 执行自愈流程
```

### 5.2 完整闭环流程图 (v4.0.0)

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                              高度自治闭环流水线 (v4.0.0 Skill 版)                                    │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘

阶段 1: 代码推送与构建触发
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                                       │
│   开发者推送代码                                                                                       │
│        │                                                                                              │
│        ▼                                                                                              │
│   Jenkins Pipeline 执行                                                                               │
│        │                                                                                              │
│        ├──► 成功: 结束流程                                                                            │
│        │                                                                                              │
│        └──► 失败: 发送 Webhook / 激活 Skill                                                          │
│                                                                                                       │
│   Webhook 事件格式:                                                                                   │
│   {                                                                                                   │
│       "jobName": "example-pipeline",                                                                 │
│       "buildNumber": 42,                                                                             │
│       "status": "FAILURE",                                                                           │
│       "buildTag": "jenkins-example-pipeline-42"                                                     │
│   }                                                                                                   │
│                                                                                                       │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘

                                      │
                                      ▼
阶段 2: Skill 激活与信息收集
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                                       │
│   Skill 被激活 (ci-selfheal)                                                                         │
│                                                                                                       │
│   步骤 1: 检查状态                                                                                    │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │  - 读取 .self-heal-state.json (本地文件)                                                       │   │
│   │  - 获取当前 Job 的自愈状态:                                                                     │   │
│   │    - current_retry: 当前重试轮次                                                               │   │
│   │    - status: idle / running / success / failed / max_retry                                    │   │
│   │                                                                                                 │   │
│   │  - 如果 status == running: 检查是否达到 MAX_RETRY (默认 5)                                    │   │
│   │  - 如果是新失败: 开始新的自愈链 (current_retry = 0)                                           │   │
│   └─────────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                                       │
│   步骤 2: 收集信息                                                                                    │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                                                                                 │   │
│   │  信息来源 1: Jenkins API                                                                       │   │
│   │  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                                  │   │
│   │  │ 拉取构建日志   │───►│ 提取错误片段   │───►│ 获取 Jenkinsfile│                                  │   │
│   │  │ consoleText   │    │ (关键错误)    │    │ config.xml   │                                  │   │
│   │  └──────────────┘    └──────────────┘    └──────────────┘                                  │   │
│   │                                                                                                 │   │
│   │  信息来源 2: JJB 配置 [优先]                                                                   │   │
│   │  ┌──────────────┐    ┌──────────────┐                                                         │   │
│   │  │ 查找 YAML 文件│───►│ 读取 dsl     │                                                         │   │
│   │  │ {job}.yaml   │    │ (Jenkinsfile) │                                                         │   │
│   │  └──────────────┘    └──────────────┘                                                         │   │
│   │                                                                                                 │   │
│   │  优先级: JJB YAML > Jenkins API                                                                 │   │
│   │  (因为 JJB 配置是真实的配置源，支持版本控制)                                                   │   │
│   └─────────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                                       │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘

                                      │
                                      ▼
阶段 3: AI 诊断与修复代码生成
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                                       │
│   步骤 1: 构建 Prompt                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │  Prompt 包含:                                                                                   │   │
│   │  - 任务说明: 分析并修复 Jenkins Pipeline 错误                                                   │   │
│   │  - 上下文: Job 名称、当前轮次                                                                   │   │
│   │  - 当前 Jenkinsfile 代码                                                                         │   │
│   │  - 构建错误日志                                                                                  │   │
│   │  - 修复规则 (严格遵守)                                                                          │   │
│   └─────────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                                       │
│   步骤 2: 调用 AI 模型                                                                                │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                                                                                 │   │
│   │  调用方式: OpenClaw CLI (Skill 内部直接调用)                                                   │   │
│   │                                                                                                 │   │
│   │  docker exec devopsclaw-openclaw node openclaw.mjs \                                         │   │
│   │      infer model run \                                                                         │   │
│   │      --model "custom-api-deepseek-com/deepseek-reasoner" \                                   │   │
│   │      --prompt "<完整 Prompt>"                                                                  │   │
│   │                                                                                                 │   │
│   │  模型选择:                                                                                      │   │
│   │  - 主用: deepseek-reasoner (推理质量高)                                                        │   │
│   │  - 备用: kimi-k2.5 (响应速度快) [Fallback]                                                    │   │
│   └─────────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                                       │
│   步骤 3: 提取修复代码                                                                                │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                                                                                 │   │
│   │  从 AI 响应提取代码的顺序:                                                                      │   │
│   │  1. 检查是否包含 "CANNOT_FIX" → 标记失败                                                       │   │
│   │  2. 尝试提取代码块: ```groovy ... ``` 或 ```jenkinsfile ... ```                                │   │
│   │  3. 兜底: 搜索 "node {" 和 "stage(" 开头的内容                                                 │   │
│   │  4. 验证: 代码长度必须 > 50 字符                                                                │   │
│   └─────────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                                       │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘

                                      │
                                      ▼
阶段 4: 配置更新与重新构建
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                                       │
│   步骤 1: 更新 JJB 配置                                                                                │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                                                                                 │   │
│   │  方式 A: 正则替换 (推荐，保留格式和注释)                                                        │   │
│   │  - 匹配 dsl: | 后的多行内容                                                                     │   │
│   │  - 替换为修复后的代码 (保持相同缩进)                                                             │   │
│   │                                                                                                 │   │
│   │  方式 B: YAML 解析重写 (备用，会丢失注释)                                                      │   │
│   │  - 使用 yaml.safe_load() 解析                                                                   │   │
│   │  - 递归查找并更新 'dsl' 字段                                                                    │   │
│   │  - 使用 yaml.dump() 重写                                                                         │   │
│   └─────────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                                       │
│   步骤 2: 同步到 Jenkins                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │  执行命令:                                                                                      │   │
│   │  jenkins-jobs --conf jjb-configs/jenkins_jobs.ini \                                          │   │
│   │    update jjb-configs/{job_name}.yaml                                                          │   │
│   │                                                                                                 │   │
│   │  作用:                                                                                          │   │
│   │  - 连接 Jenkins                                                                                 │   │
│   │  - 更新原 Job 配置 (不创建新 Job)                                                                │   │
│   │  - 历史记录完整保留                                                                              │   │
│   └─────────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                                       │
│   步骤 3: 触发新构建                                                                                  │
│   ┌─────────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │  操作: POST /job/{job_name}/build                                                              │   │
│   │                                                                                                 │   │
│   │  状态更新:                                                                                      │   │
│   │  - current_retry += 1                                                                           │   │
│   │  - 记录修复历史                                                                                 │   │
│   │  - 等待下次构建结果通知                                                                         │   │
│   └─────────────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                                       │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘

                                      │
                                      ▼
阶段 5: 结果判断 (下次事件)
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                                       │
│   收到新的构建结果:                                                                                   │
│                                                                                                       │
│   ┌──────────────┐              ┌──────────────┐                                                    │
│   │   SUCCESS    │              │   FAILURE    │                                                    │
│   │  (构建成功)   │              │  (构建失败)   │                                                    │
│   └──────┬───────┘              └──────┬───────┘                                                    │
│          │                             │                                                             │
│          ▼                             ▼                                                             │
│   ┌──────────────┐              ┌──────────────┐                                                    │
│   │ 标记自愈成功 │              │ 检查重试次数 │                                                    │
│   │ 结束流程     │              │  < MAX_RETRY? │                                                    │
│   └──────────────┘              └──────┬───────┘                                                    │
│                                          │                                                             │
│                               ┌──────────┴──────────┐                                                │
│                               ▼                     ▼                                                │
│                          ┌─────────┐           ┌─────────┐                                         │
│                          │   是    │           │   否    │                                         │
│                          └────┬────┘           └────┬────┘                                         │
│                               │                     │                                                  │
│                               ▼                     ▼                                                  │
│                          回到阶段 3         标记 max_retry                                           │
│                          (再次修复)         等待人工介入                                             │
│                                                                                                       │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 六、部署步骤

### 6.1 前置条件

- Docker 20.10+
- Docker Compose 2.0+
- Python 3.8+ (用于本地运行 Skill)
- Git (可选，用于版本控制)

### 6.2 部署流程

#### 步骤 1: 克隆项目

```bash
cd C:\Users\Tong\Desktop
git clone <repository-url> DevOpsClaw
cd DevOpsClaw
```

#### 步骤 2: 配置环境变量

```bash
# 复制环境变量模板
copy .env.example .env

# 编辑 .env，填入实际值
# 至少需要配置:
# - OPENCLAW_GATEWAY_TOKEN
# - JENKINS_TOKEN
```

#### 步骤 3: 启动核心服务

```bash
# 启动所有服务 (OpenClaw, Jenkins, GitLab)
docker-compose up -d

# 或者只启动必需服务 (不包含 GitLab)
# docker-compose up -d openclaw jenkins
```

#### 步骤 4: 等待服务启动

```bash
# 查看服务状态
docker-compose ps

# 查看日志
docker-compose logs -f openclaw
docker-compose logs -f jenkins
docker-compose logs -f gitlab  # 如果使用了
```

**启动时间参考**:
- OpenClaw: ~30 秒
- Jenkins: ~2-3 分钟
- GitLab: ~5-10 分钟 (首次启动)

#### 步骤 5: 配置 Jenkins

1. **获取初始密码**:
```bash
docker exec devopsclaw-jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

2. **访问 Jenkins UI**:
   - URL: http://127.0.0.1:8081/jenkins
   - 使用初始密码登录

3. **安装推荐插件**

4. **创建 API Token**:
   - 用户 → 设置 → API Token → 添加新 Token
   - 将 Token 保存到 `.env` 文件

#### 步骤 6: 配置 JJB

```bash
# 安装 JJB
pip install jenkins-job-builder

# 验证配置
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini test jjb-configs/

# 部署 Job 到 Jenkins
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini update jjb-configs/
```

#### 步骤 7: 验证 Skill

```bash
# 检查 Skill 目录结构
dir .trae\skills\ci-selfheal

# 验证 Python 文件语法
python -m py_compile .trae\skills\ci-selfheal\ci_selfheal.py
python -m py_compile .trae\skills\ci-selfheal\jenkins_client.py
python -m py_compile .trae\skills\ci-selfheal\jjb_manager.py

# 查看帮助
python .trae\skills\ci-selfheal\ci_selfheal.py --help
```

### 6.3 最小化部署 (不使用 GitLab)

如果不需要 GitLab，可以只启动核心服务：

```bash
# 只启动 OpenClaw 和 Jenkins
docker-compose up -d openclaw jenkins
```

**代码仓库替代方案**:
- GitHub
- Gitea
- Bitbucket
- 本地 Git 仓库

---

## 七、验证测试

### 7.1 测试自愈功能

#### 方法 1: 使用测试 Pipeline

项目中已包含测试用的 Pipeline: `test-failure-pipeline.yaml`

```bash
# 1. 确保测试 Job 已部署
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini update jjb-configs/test-failure-pipeline.yaml

# 2. 触发测试构建 (会失败)
# 通过 Jenkins UI 或 API 触发
```

测试 Pipeline 包含故意的错误:
```groovy
sh 'date--'  // 错误: 应该是 'date' 或 'date --'
```

#### 方法 2: 手动触发 Skill

```bash
# 模拟一个构建失败事件
python .trae\skills\ci-selfheal\ci_selfheal.py \
  --job-name "test-failure-pipeline" \
  --build-number 1 \
  --status FAILURE
```

### 7.2 验证闭环流程

**预期行为**:

1. **构建 #1**: 失败 (date-- 命令错误)
2. **Skill 激活**: 自动检测到失败
3. **信息收集**: 拉取日志、读取 JJB 配置
4. **AI 诊断**: 调用 OpenClaw 分析错误
5. **配置更新**: 更新 JJB YAML，将 `date--` 修复为 `date`
6. **触发重构建**: 构建 #2
7. **构建 #2**: 成功 (date 命令正确执行)

### 7.3 查看状态

```bash
# 查看自愈状态
python .trae\skills\ci-selfheal\ci_selfheal.py --status

# 查看状态文件
type .self-heal-state.json
```

### 7.4 预期结果

| 检查项 | 预期结果 |
|--------|---------|
| JJB 配置更新 | `date--` → `date` |
| Jenkins Job 配置 | 同步更新 |
| 构建 #2 状态 | SUCCESS |
| 状态文件 | `status: "success"` |
| 重试次数 | `current_retry: 1` |

---

## 八、监控与运维

### 8.1 服务监控

#### Docker 命令

```bash
# 查看所有服务状态
docker-compose ps

# 查看特定服务日志
docker-compose logs -f openclaw
docker-compose logs -f jenkins
docker-compose logs -f gitlab

# 查看资源使用
docker stats
```

### 8.2 Skill 监控

#### 状态文件

```bash
# 查看自愈状态
type .self-heal-state.json
```

状态文件格式:
```json
{
  "jobs": {
    "example-pipeline": {
      "status": "idle",
      "current_retry": 0,
      "max_retry": 5,
      "last_build_number": null,
      "history": []
    }
  }
}
```

#### 状态值说明

| 状态值 | 说明 |
|--------|------|
| `idle` | 空闲，等待新事件 |
| `running` | 正在执行自愈流程 |
| `success` | 自愈成功 |
| `failed` | 自愈失败 (CANNOT_FIX) |
| `max_retry` | 达到最大重试次数，等待人工介入 |

### 8.3 日志管理

| 服务 | 日志位置 |
|------|---------|
| OpenClaw | Docker logs |
| Jenkins | Docker logs + Jenkins UI |
| GitLab | Docker logs + `/var/log/gitlab` (容器内) |
| Skill | 控制台输出 + 可选文件日志 |

### 8.4 备份策略

#### 数据备份

```bash
# 备份 Jenkins 数据
docker run --rm --volumes-from devopsclaw-jenkins -v $(pwd):/backup ubuntu tar cvf /backup/jenkins-backup.tar /var/jenkins_home

# 备份 OpenClaw 数据
docker run --rm --volumes-from devopsclaw-openclaw -v $(pwd):/backup ubuntu tar cvf /backup/openclaw-backup.tar /home/node/.openclaw

# 备份 GitLab 数据 (如果使用)
docker exec devopsclaw-gitlab gitlab-backup create
```

#### 配置备份

```bash
# 备份 JJB 配置
copy jjb-configs\* backup\jjb-configs\

# 备份环境变量
copy .env backup\.env

# 备份 Skill
xcopy .trae\skills backup\.trae\skills /E /I
```

### 8.5 日常运维清单

| 频率 | 任务 | 命令/操作 |
|------|------|-----------|
| 每日 | 检查服务状态 | `docker-compose ps` |
| 每日 | 检查自愈状态 | `python .trae/skills/ci-selfheal/ci_selfheal.py --status` |
| 每周 | 查看错误日志 | `docker-compose logs jenkins \| findstr ERROR` |
| 每周 | 清理无用镜像 | `docker image prune` |
| 每月 | 数据备份 | 执行备份命令 |
| 每月 | 安全更新 | `docker-compose pull && docker-compose up -d` |

---

## 九、故障排查

### 9.1 常见问题

#### 问题 1: Jenkins 无法连接

**症状**: Skill 无法调用 Jenkins API

**排查步骤**:
```bash
# 1. 检查 Jenkins 容器状态
docker-compose ps jenkins

# 2. 检查端口监听
netstat -ano | findstr :8081

# 3. 测试 API 连接
curl http://127.0.0.1:8081/jenkins/api/json

# 4. 验证 Token
# 在 Jenkins UI 中检查用户权限和 Token
```

**解决方案**:
- 确保 Jenkins 容器正在运行
- 验证 `JENKINS_URL`、`JENKINS_USER`、`JENKINS_TOKEN` 配置
- 检查 Jenkins 安全设置 (是否允许 API 访问)

---

#### 问题 2: JJB 命令失败

**症状**: `jenkins-jobs update` 报错

**排查步骤**:
```bash
# 1. 验证配置文件语法
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini test jjb-configs/

# 2. 检查 Jenkins 连接
curl http://127.0.0.1:8081/jenkins/api/json --user admin:$JENKINS_TOKEN

# 3. 检查 YAML 语法
python -c "import yaml; yaml.safe_load(open('jjb-configs/example-pipeline.yaml'))"
```

**常见错误**:
| 错误 | 原因 | 解决方案 |
|------|------|---------|
| 403 Forbidden | Token 无效或权限不足 | 重新生成 API Token |
| 404 Not Found | Jenkins URL 错误 | 检查 `JENKINS_URL` 配置 |
| YAML 解析错误 | 缩进或格式问题 | 检查 YAML 语法 |

---

#### 问题 3: OpenClaw 调用失败

**症状**: 无法调用 AI 模型

**排查步骤**:
```bash
# 1. 检查 OpenClaw 容器状态
docker-compose ps openclaw

# 2. 检查健康检查
curl http://127.0.0.1:18789/health

# 3. 测试 CLI 调用
docker exec devopsclaw-openclaw node openclaw.mjs --help
```

**解决方案**:
- 验证 `OPENCLAW_GATEWAY_TOKEN` 配置
- 检查网络连接 (能否访问外部 AI API)
- 查看 OpenClaw 日志: `docker-compose logs openclaw`

---

#### 问题 4: Skill 未被激活

**症状**: 构建失败后没有自动修复

**排查步骤**:
```bash
# 1. 检查 Skill 目录结构
dir .trae\skills\ci-selfheal

# 2. 检查 SKILL.md 是否正确
type .trae\skills\ci-selfheal\SKILL.md

# 3. 手动测试 Skill
python .trae\skills\ci-selfheal\ci_selfheal.py \
  --job-name "test-pipeline" \
  --build-number 1 \
  --status FAILURE
```

**可能原因**:
- Skill 目录位置不正确
- SKILL.md 格式错误
- OpenClaw/Trae 未正确加载 Skill

---

#### 问题 5: AI 返回 CANNOT_FIX

**症状**: 状态变为 `failed`，日志显示 `CANNOT_FIX`

**原因**:
- AI 无法确定错误原因
- 错误过于复杂，无法安全修复
- 错误不是 Jenkinsfile 中的问题 (如依赖问题、网络问题)

**处理方式**:
```bash
# 1. 查看详细错误日志
# 检查构建日志中的真实错误

# 2. 手动修复后重置状态
# 删除状态文件或手动编辑
del .self-heal-state.json

# 3. 手动触发重新构建
# 通过 Jenkins UI
```

**预防建议**:
- 确保构建日志包含足够的调试信息
- 对于复杂的依赖问题，考虑在 Pipeline 中添加更多检查
- 可以自定义修复规则提示词，让 AI 更了解项目情况

---

#### 问题 6: 达到最大重试次数

**症状**: 状态变为 `max_retry`，停止自愈

**原因**:
- 连续 5 次修复都失败
- 修复方向错误，每次修复引入新问题

**处理方式**:
```bash
# 1. 查看修复历史
python .trae\skills\ci-selfheal\ci_selfheal.py --status

# 2. 分析每次修复的问题
# 查看 JJB 配置的变更历史 (如果使用了 Git)
git log jjb-configs/

# 3. 手动修复正确的问题
# 编辑 JJB YAML 配置

# 4. 重置状态
del .self-heal-state.json

# 5. 手动同步到 Jenkins
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini update jjb-configs/
```

---

### 9.2 调试模式

#### 启用详细日志

在调用 Skill 时添加调试参数:

```bash
# 设置环境变量启用调试
set LOG_LEVEL=DEBUG

# 调用 Skill
python .trae\skills\ci-selfheal\ci_selfheal.py \
  --job-name "example-pipeline" \
  --build-number 1 \
  --status FAILURE
```

#### 检查各组件状态

```bash
# 1. Docker 服务状态
docker info

# 2. 所有容器状态
docker ps -a

# 3. 网络状态
docker network inspect devopsclaw-network

# 4. 卷状态
docker volume ls
```

### 9.3 快速恢复

#### 重置所有状态

```bash
# 1. 停止服务
docker-compose down

# 2. 清理数据 (谨慎操作!)
# docker volume rm devopsclaw_jenkins-home
# docker volume rm devopsclaw_openclaw-data

# 3. 清理状态文件
del .self-heal-state.json

# 4. 重新启动
docker-compose up -d

# 5. 重新部署 Job
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini update jjb-configs/
```

### 9.4 联系支持

如果问题无法解决，请收集以下信息:

1. **环境信息**:
   - Docker 版本: `docker --version`
   - Docker Compose 版本: `docker-compose --version`
   - Python 版本: `python --version`
   - 操作系统: `ver` (Windows) 或 `uname -a` (Linux)

2. **服务状态**:
   - `docker-compose ps` 输出
   - `docker-compose logs` 最近 100 行

3. **Skill 状态**:
   - `.self-heal-state.json` 内容
   - 手动调用 Skill 的输出

4. **配置文件**:
   - `.env` (脱敏后)
   - `docker-compose.yml`
   - 相关的 JJB YAML 配置

---

## 附录

### A. 架构演进历史

| 版本 | 日期 | 关键变更 |
|------|------|---------|
| v1.0.0 | - | Bridge 服务 + 创建新 Job |
| v2.0.0 | - | Bridge 服务 + JJB 更新原 Job + 高度自治 |
| v3.0.0 | 2026-05-06 | Docker Compose 编排 + 独立 PostgreSQL/Redis + GitLab |
| **v4.0.0** | **2026-05-06** | **OpenClaw Skill 架构 + GitLab 内置数据库** |

### B. 服务端口清单

| 服务 | 端口 | 绑定地址 | 说明 |
|------|------|---------|------|
| OpenClaw | 18789 | 127.0.0.1 | AI 网关 |
| Jenkins | 8081 | 127.0.0.1 | Web UI |
| Jenkins | 50000 | 127.0.0.1 | Agent 连接 |
| GitLab | 8082 | 127.0.0.1 | HTTP |
| GitLab | 8443 | 127.0.0.1 | HTTPS |
| GitLab | 2222 | 127.0.0.1 | SSH |
| Webhook Listener | 5000 | 127.0.0.1 | 可选 |

### C. 目录结构

```
DevOpsClaw/
├── .trae/
│   └── skills/
│       └── ci-selfheal/           # CI Self-Heal Skill
│           ├── SKILL.md            # Skill 定义
│           ├── ci_selfheal.py      # 核心逻辑
│           ├── jenkins_client.py   # Jenkins API
│           ├── jjb_manager.py      # JJB 管理
│           └── webhook_listener.py # 可选 Webhook
│
├── bridge/                         # 已废弃 (v4.0.0 不再使用)
│   ├── Dockerfile.bridge
│   └── ...
│
├── doc/
│   ├── 3自愈式流水线.md            # 核心设计文档
│   └── 5mvp_jenkins_rerun.md      # 本文档
│
├── jjb-configs/                    # JJB 配置
│   ├── defaults.yaml
│   ├── jenkins_jobs.ini
│   ├── example-pipeline.yaml
│   └── test-failure-pipeline.yaml
│
├── .env                            # 环境变量 (私有)
├── .env.example                    # 环境变量模板
├── docker-compose.yml              # Docker Compose 配置
└── README.md                       # 项目说明
```

### D. 参考资源

- [Jenkins Job Builder 文档](https://docs.openstack.org/infra/jenkins-job-builder/)
- [Jenkins Pipeline 语法](https://www.jenkins.io/doc/book/pipeline/syntax/)
- [GitLab Omnibus 配置](https://docs.gitlab.com/omnibus/settings/)
- [Docker Compose 文档](https://docs.docker.com/compose/)

---

**文档结束**

*版本: v4.0.0*  
*最后更新: 2026-05-06*
