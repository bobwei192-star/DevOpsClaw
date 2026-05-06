# DevOpsClaw CI 工具链部署设计文档

> **版本**: v4.0.0  
> **更新日期**: 2026-05-06  
> **部署方式**: Docker Compose 统一编排



版本信息：

Jenkins	2.528.3 或更高
Java	17 或更高
---

## 目录

1. [架构概览](#一架构概览)
2. [端口分配](#二端口分配)
3. [Docker Compose 配置](#三docker-compose-配置)
4. [环境变量设计](#四环境变量设计)
5. [部署脚本设计](#五部署脚本设计)
6. [服务间集成](#六服务间集成)
7. [部署流程](#七部署流程)
8. [验证测试](#八验证测试)
9. [故障排查](#九故障排查)

---

## 一、架构概览

### 1.1 整体架构图

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                              Docker Compose 统一编排网络                                               │
│                          (devopsclaw-network, bridge 模式)                                           │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  外部访问层 (仅本地绑定 127.0.0.1)                                                                    │
├─────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                       │
│  ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐                                │
│  │     Jenkins      │   │     OpenClaw     │   │     GitLab       │                                │
│  │    (CI/CD)       │   │    (AI 网关)     │   │   (代码仓库)      │                                │
│  │                  │   │                  │   │                  │                                │
│  │  端口: 8081      │   │  端口: 18789     │   │  端口: 8082      │                                │
│  │        50000     │   │                  │   │        8443      │                                │
│  │                  │   │                  │   │        2222      │                                │
│  └──────────────────┘   └──────────────────┘   └──────────────────┘                                │
│                                                                                                       │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘

                                      │
                                      │ Docker 内部网络通信
                                      │ (devopsclaw-network)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│  内部服务通信                                                                                          │
├─────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                       │
│   Jenkins ─────────────────► OpenClaw (通过 CLI: docker exec)                                       │
│     │                            ▲                                                                   │
│     │                            │                                                                   │
│     │     触发构建、拉取日志       │     AI 诊断、生成修复代码                                        │
│     │                            │                                                                   │
│     ▼                            │                                                                   │
│   JJB 配置 ──────────────────────┘                                                                   │
│   (jjb-configs/*.yaml)                                                                                │
│                                                                                                       │
│   GitLab (代码仓库) ──────────────────────────────────────────────────────────────────────────────► │
│     │                                                                                                 │
│     ├──► 推送代码触发 Jenkins Pipeline                                                                │
│     └──► 存储源代码、配置文件                                                                          │
│                                                                                                       │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 服务清单

| 服务 | 镜像 | 容器名 | 是否必需 | 说明 |
|------|------|--------|---------|------|
| **Jenkins** | `jenkins/jenkins:lts-jdk17` | `devopsclaw-jenkins` | ✅ 必需 | CI/CD 引擎，执行 Pipeline |
| **OpenClaw** | `ghcr.io/openclaw/openclaw:latest` | `devopsclaw-openclaw` | ✅ 必需 | AI 网关 + Skill 引擎 |
| **GitLab CE** | `gitlab/gitlab-ce:latest` | `devopsclaw-gitlab` | ❌ 可选 | 代码仓库 (使用内置 PostgreSQL/Redis) |

### 1.3 关键设计决策

#### 决策 1: 不单独部署 PostgreSQL/Redis

**原因**:
- GitLab CE Omnibus 包内置了 PostgreSQL 和 Redis
- 单独部署会增加运维复杂度
- 自愈功能本身不需要这些服务

**实现**:
- GitLab 配置中不设置 `postgresql['enable'] = false`
- GitLab 配置中不设置 `redis['enable'] = false`
- 使用 GitLab 内置的数据库和缓存

#### 决策 2: 不使用独立 Bridge 服务

**原因**:
- Bridge 服务的功能可以整合到 OpenClaw Skill 中
- 减少服务数量，降低运维复杂度
- Skill 与 AI 引擎无缝集成

**实现**:
- 创建 `.trae/skills/ci-selfheal/` 目录
- 将原有 Bridge 代码重构为 Skill 可调用的形式
- 提供可选的 Webhook Listener 用于 Jenkins 集成

#### 决策 3: 所有端口绑定 127.0.0.1

**原因**:
- 安全考虑：不直接暴露到公网
- 本地开发/测试环境使用
- 生产环境可通过反向代理（Nginx）暴露

**实现**:
- 所有 `ports` 配置使用 `127.0.0.1:HOST_PORT:CONTAINER_PORT`
- 如需外部访问，配置 Nginx 反向代理

---

## 二、端口分配

### 2.1 端口规划表

| 服务 | 主机端口 | 容器端口 | 绑定地址 | 协议 | 说明 |
|------|---------|---------|---------|------|------|
| **Jenkins Web UI** | 8081 | 8080 | 127.0.0.1 | TCP | Jenkins Web 界面 |
| **Jenkins Agent** | 50000 | 50000 | 127.0.0.1 | TCP | Jenkins Agent 连接端口 |
| **OpenClaw Gateway** | 18789 | 18789 | 127.0.0.1 | TCP | OpenClaw AI 网关 |
| **GitLab HTTP** | 8082 | 80 | 127.0.0.1 | TCP | GitLab Web 界面 (HTTP) |
| **GitLab HTTPS** | 8443 | 443 | 127.0.0.1 | TCP | GitLab Web 界面 (HTTPS) |
| **GitLab SSH** | 2222 | 22 | 127.0.0.1 | TCP | GitLab SSH 克隆 |
| **Webhook Listener (可选)** | 5000 | 5000 | 127.0.0.1 | TCP | Jenkins Webhook 接收器 (本地运行) |

### 2.2 端口冲突检查

**部署前检查命令**:

```bash
# 检查端口是否被占用
netstat -ano | findstr ":8081 :50000 :18789 :8082 :8443 :2222 :5000"

# 或者使用 PowerShell
Get-NetTCPConnection -LocalPort 8081,50000,18789,8082,8443,2222,5000 -ErrorAction SilentlyContinue
```

**端口冲突解决方案**:

| 端口 | 冲突时替代方案 |
|------|--------------|
| 8081 | 18081, 28081 |
| 50000 | 50001 |
| 18789 | 28789 (不建议修改，OpenClaw 默认端口) |
| 8082 | 18082, 28082 |
| 8443 | 18443 |
| 2222 | 2223 |
| 5000 | 5001 |

### 2.3 访问地址汇总

| 服务 | 本地访问地址 | 容器内访问地址 |
|------|-------------|---------------|
| Jenkins | http://127.0.0.1:8081/jenkins | http://devopsclaw-jenkins:8080/jenkins |
| OpenClaw | http://127.0.0.1:18789 | http://devopsclaw-openclaw:18789 |
| GitLab HTTP | http://127.0.0.1:8082 | http://devopsclaw-gitlab:80 |
| GitLab HTTPS | https://127.0.0.1:8443 | https://devopsclaw-gitlab:443 |

---

## 三、Docker Compose 配置

### 3.1 完整配置

```yaml
version: '3.8'

networks:
  devopsclaw-network:
    driver: bridge
    name: devopsclaw-network

volumes:
  jenkins-home:
    driver: local
  openclaw-data:
    driver: local
  gitlab-config:
    driver: local
  gitlab-logs:
    driver: local
  gitlab-data:
    driver: local

services:
  openclaw:
    image: ghcr.io/openclaw/openclaw:latest
    container_name: devopsclaw-openclaw
    restart: unless-stopped
    user: "1000:1000"
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=64m
    networks:
      - devopsclaw-network
    ports:
      - "127.0.0.1:18789:18789"
    volumes:
      - openclaw-data:/home/node/.openclaw
    environment:
      - OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
    working_dir: /home/node/openclaw
    command: >
      node openclaw.mjs gateway --allow-unconfigured
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:18789/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  jenkins:
    image: jenkins/jenkins:lts-jdk17
    container_name: devopsclaw-jenkins
    restart: unless-stopped
    user: root
    networks:
      - devopsclaw-network
    ports:
      - "127.0.0.1:8081:8080"
      - "127.0.0.1:50000:50000"
    volumes:
      - jenkins-home:/var/jenkins_home
      - /var/run/docker.sock:/var/run/docker.sock
      - ./jjb-configs:/var/jenkins_home/jjb-configs:ro
    environment:
      - JENKINS_OPTS=--prefix=/jenkins
      - JAVA_OPTS=-Xmx2g -Xms512m
      - JENKINS_URL=${JENKINS_URL:-http://127.0.0.1:8081/jenkins}
      - OPENCLAW_HOST=devopsclaw-openclaw
      - OPENCLAW_PORT=18789
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:8080/jenkins/login"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
    depends_on:
      - openclaw

  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: devopsclaw-gitlab
    restart: unless-stopped
    hostname: ${GITLAB_HOSTNAME:-gitlab.devopsclaw.local}
    networks:
      - devopsclaw-network
    ports:
      - "127.0.0.1:8082:80"
      - "127.0.0.1:8443:443"
      - "127.0.0.1:2222:22"
    volumes:
      - gitlab-config:/etc/gitlab
      - gitlab-logs:/var/log/gitlab
      - gitlab-data:/var/opt/gitlab
    shm_size: '512m'
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://${GITLAB_HOSTNAME:-gitlab.devopsclaw.local}';
        gitlab_rails['gitlab_shell_ssh_port'] = 2222;
        nginx['listen_port'] = 80;
        nginx['listen_https'] = false;
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:80/-/health"]
      interval: 60s
      timeout: 10s
      retries: 10
      start_period: 300s
```

### 3.2 配置详解

#### 3.2.1 Network 配置

```yaml
networks:
  devopsclaw-network:
    driver: bridge
    name: devopsclaw-network
```

**说明**:
- 创建独立的 bridge 网络 `devopsclaw-network`
- 所有服务加入此网络，通过容器名互相访问
- 容器名解析: `devopsclaw-jenkins`, `devopsclaw-openclaw`, `devopsclaw-gitlab`

#### 3.2.2 Volume 配置

| Volume 名 | 挂载路径 (容器内) | 用途 |
|----------|------------------|------|
| `jenkins-home` | `/var/jenkins_home` | Jenkins 数据、配置、插件、Job 历史 |
| `openclaw-data` | `/home/node/.openclaw` | OpenClaw 配置、模型缓存 |
| `gitlab-config` | `/etc/gitlab` | GitLab 配置文件 |
| `gitlab-logs` | `/var/log/gitlab` | GitLab 日志 |
| `gitlab-data` | `/var/opt/gitlab` | GitLab 数据（仓库、数据库等） |

#### 3.2.3 OpenClaw 安全配置

```yaml
user: "1000:1000"                    # 非 root 用户运行
cap_drop:
  - ALL                              # 丢弃所有 Linux capabilities
security_opt:
  - no-new-privileges:true          # 禁止提权
read_only: true                       # 只读文件系统
tmpfs:
  - /tmp:rw,noexec,nosuid,size=64m  # 临时可写目录
ports:
  - "127.0.0.1:18789:18789"          # 仅本地绑定
```

**安全设计原则**:
1. **最小权限原则**: 使用非 root 用户，丢弃所有 capabilities
2. **只读文件系统**: 防止容器被篡改
3. **临时目录限制**: `/tmp` 目录限制大小，禁止 setuid
4. **网络隔离**: 仅绑定 127.0.0.1，不暴露到公网

#### 3.2.4 Jenkins 配置

**关键挂载**:
```yaml
volumes:
  - jenkins-home:/var/jenkins_home
  - /var/run/docker.sock:/var/run/docker.sock    # Docker-in-Docker
  - ./jjb-configs:/var/jenkins_home/jjb-configs:ro  # JJB 配置（只读）
```

**说明**:
- `/var/run/docker.sock`: 允许 Jenkins 容器调用宿主机 Docker
- `jjb-configs`: 只读挂载 JJB 配置目录，供 Jenkins 参考

#### 3.2.5 GitLab 配置

**关键设计**:
- **不单独部署 PostgreSQL/Redis**: 使用 GitLab 内置的服务
- **shm_size**: 分配 512MB 共享内存，GitLab 需要
- **HTTP 配置**: 默认使用 HTTP，如需 HTTPS 可修改配置

**环境变量**:
```yaml
environment:
  GITLAB_OMNIBUS_CONFIG: |
    external_url 'http://${GITLAB_HOSTNAME:-gitlab.devopsclaw.local}';
    gitlab_rails['gitlab_shell_ssh_port'] = 2222;
    nginx['listen_port'] = 80;
    nginx['listen_https'] = false;
```

**注意**:
- 没有设置 `postgresql['enable'] = false` → 使用内置 PostgreSQL
- 没有设置 `redis['enable'] = false` → 使用内置 Redis
- `nginx['listen_https'] = false` → 禁用 HTTPS（如需启用可修改）

---

## 四、环境变量设计

### 4.1 环境变量分类

| 分类 | 变量名 | 是否必需 | 默认值 | 说明 |
|------|--------|---------|--------|------|
| **OpenClaw** | `OPENCLAW_GATEWAY_TOKEN` | ✅ 必需 | 无 | OpenClaw Gateway 认证 Token |
| **Jenkins** | `JENKINS_URL` | ❌ 可选 | `http://127.0.0.1:8081/jenkins` | Jenkins 访问地址 |
| **Jenkins** | `JENKINS_USER` | ❌ 可选 | `admin` | Jenkins 用户名 |
| **Jenkins** | `JENKINS_TOKEN` | ✅ 必需 | 无 | Jenkins API Token |
| **GitLab** | `GITLAB_HOSTNAME` | ❌ 可选 | `gitlab.devopsclaw.local` | GitLab 主机名 |
| **AI 模型** | `DEFAULT_MODEL` | ❌ 可选 | `deepseek-reasoner` | 默认 AI 模型 |
| **业务规则** | `MAX_RETRY` | ❌ 可选 | `5` | 最大自愈重试次数 |
| **JJB 配置** | `JJB_CONFIG_PATH` | ❌ 可选 | `./jjb-configs` | JJB 配置目录路径 |

### 4.2 .env.example 完整配置

```bash
# ============================================
# DevOpsClaw 环境变量配置文件
# ============================================
# 复制此文件为 .env 并填入实际值
# 命令: copy .env.example .env

# ============================================
# 1. OpenClaw 配置 (必需)
# ============================================

# OpenClaw Gateway Token
# 用于 OpenClaw API 认证
# 生成命令: tr -dc A-Za-z0-9 < /dev/urandom | head -c 64
# 或使用 PowerShell: -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 64 | ForEach-Object {[char]$_})
OPENCLAW_GATEWAY_TOKEN=your_secure_gateway_token_here

# ============================================
# 2. Jenkins 配置
# ============================================

# Jenkins 访问地址
# 容器内访问: http://devopsclaw-jenkins:8080/jenkins
# 宿主机访问: http://127.0.0.1:8081/jenkins
JENKINS_URL=http://127.0.0.1:8081/jenkins

# Jenkins 管理员用户名
JENKINS_USER=admin

# Jenkins API Token
# 从 Jenkins 用户设置中生成: 用户 -> 设置 -> API Token
JENKINS_TOKEN=your_jenkins_api_token_here

# ============================================
# 3. GitLab 配置 (可选)
# ============================================

# GitLab 主机名
# 用于配置 external_url
GITLAB_HOSTNAME=gitlab.devopsclaw.local

# ============================================
# 4. AI 模型配置 (可选)
# ============================================

# 默认使用的 AI 模型
# 可选值:
#   - deepseek-reasoner (推荐，推理质量高)
#   - kimi-k2.5 (响应速度快)
#   - 其他自定义模型
DEFAULT_MODEL=deepseek-reasoner

# ============================================
# 5. 业务规则配置 (可选)
# ============================================

# 最大自愈重试次数
# 达到此次数后停止自动修复，等待人工介入
MAX_RETRY=5

# ============================================
# 6. JJB 配置 (可选)
# ============================================

# JJB 配置文件存放路径
# 相对于项目根目录的路径，或绝对路径
JJB_CONFIG_PATH=./jjb-configs

# ============================================
# 7. 调试配置 (可选)
# ============================================

# 日志级别
# 可选: DEBUG, INFO, WARN, ERROR
LOG_LEVEL=INFO

# Webhook Listener 端口
# 仅在使用 webhook_listener.py 时需要
WEBHOOK_PORT=5000
```

### 4.3 环境变量生成指南

#### 生成 OpenClaw Gateway Token

**Linux/Mac**:
```bash
tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64
```

**Windows PowerShell**:
```powershell
-join ((65..90) + (97..122) + (48..57) | Get-Random -Count 64 | ForEach-Object {[char]$_})
```

#### 获取 Jenkins API Token

1. 登录 Jenkins Web UI
2. 点击右上角用户名 → 选择 "设置"
3. 找到 "API Token" 部分
4. 点击 "添加新 Token"
5. 输入名称（如 "devopsclaw"）
6. 点击 "生成"
7. **复制 Token**（仅显示一次）
8. 将 Token 填入 `.env` 文件

#### GitLab 初始密码

GitLab 启动后，初始 root 密码存储在容器内:
```bash
# 从容器获取初始密码
docker exec devopsclaw-gitlab cat /etc/gitlab/initial_root_password
```

**注意**: 此密码文件会在 24 小时后自动删除。

---

## 五、部署脚本设计

### 5.1 脚本架构

```
DevOpsClaw/
├── deploy_all.sh              # 主部署脚本（统一入口）
│
├── deploy_gitlab/
│   └── deploy_gitlab.sh       # GitLab 单独部署脚本
│
├── deploy_jenkins/
│   └── deploy_jenkins.sh      # Jenkins 单独部署脚本
│
├── deploy_openclaw/
│   └── deploy_openclaw.sh     # OpenClaw 单独部署脚本
│
├── docker/
│   └── install_docker.sh      # Docker 安装脚本
│
├── docker-compose.yml         # Docker Compose 配置
└── .env.example               # 环境变量模板
```

### 5.2 deploy_all.sh 主脚本设计

**功能**:
1. 检查环境（Docker、Docker Compose）
2. 交互式选择部署模式
3. 验证环境变量配置
4. 执行 Docker Compose 部署
5. 配置服务间集成
6. 输出部署结果和访问信息

**部署模式**:

| 模式 | 说明 |
|------|------|
| `full` | 完整部署：Jenkins + OpenClaw + GitLab |
| `core` | 核心部署：Jenkins + OpenClaw（不包含 GitLab） |
| `existing` | 配置集成：使用已有的 Jenkins/GitLab/OpenClaw |

**脚本流程**:

```
┌─────────────────────────────────────────────────────────────────┐
│                    deploy_all.sh 执行流程                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  1. 环境检查                                                      │
│     - 检查是否以 root 运行                                        │
│     - 检查 Docker 是否安装                                        │
│     - 检查 Docker Compose 是否可用                                │
│     - 检查端口是否被占用                                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  2. 交互选择部署模式                                               │
│                                                                   │
│  提示:                                                            │
│  "是否需要部署 Jenkins、OpenClaw、GitLab？(y/n)"                 │
│                                                                   │
│  - 选择 y: 进入部署模式选择                                       │
│  - 选择 n: 进入配置集成模式                                       │
└─────────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          │                                       │
          ▼                                       ▼
┌─────────────────────┐               ┌─────────────────────┐
│   部署模式 (y)      │               │   配置模式 (n)      │
├─────────────────────┤               ├─────────────────────┤
│  选择部署组件:       │               │  检测已有服务:       │
│  [1] 完整部署        │               │  - Jenkins 地址      │
│  [2] 核心部署        │               │  - GitLab 地址       │
│  [3] 仅 OpenClaw     │               │  - OpenClaw 地址     │
│  [4] 仅 Jenkins      │               │                     │
│  [5] 仅 GitLab       │               │  配置服务间集成      │
└─────────────────────┘               └─────────────────────┘
          │                                       │
          └───────────────────┬───────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  3. 环境变量配置                                                  │
│     - 检查 .env 文件是否存在                                      │
│     - 不存在则从 .env.example 复制                                │
│     - 提示用户填写必要的环境变量                                   │
│     - 验证必填项是否已填写                                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  4. 执行部署                                                      │
│     - 拉取 Docker 镜像（可选配置镜像加速）                        │
│     - 创建 Docker 网络                                            │
│     - 启动 Docker Compose 服务                                    │
│     - 等待服务健康检查通过                                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  5. 服务集成配置                                                  │
│     - 配置 Jenkins API Token                                      │
│     - 配置 Jenkins → OpenClaw 集成                                │
│     - 配置 GitLab Webhook（如使用 GitLab）                        │
│     - 部署 JJB 配置到 Jenkins                                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  6. 输出部署结果                                                  │
│     - 各服务访问地址                                              │
│     - 初始密码/Token 信息                                         │
│     - 下一步操作指引                                              │
│     - 验证测试命令                                                │
└─────────────────────────────────────────────────────────────────┘
```

### 5.3 脚本函数设计

#### 核心函数列表

| 函数名 | 功能 | 参数 | 返回值 |
|--------|------|------|--------|
| `check_root()` | 检查是否以 root 运行 | 无 | 退出码（非 root 则退出） |
| `check_docker()` | 检查 Docker 安装 | 无 | 成功/失败 |
| `check_ports()` | 检查端口占用 | 端口列表 | 冲突端口列表 |
| `load_env()` | 加载环境变量 | 文件路径 | 成功/失败 |
| `validate_env()` | 验证必填环境变量 | 无 | 缺失的变量列表 |
| `pull_images()` | 拉取 Docker 镜像 | 服务名列表 | 成功/失败 |
| `start_services()` | 启动服务 | 服务名列表 | 成功/失败 |
| `wait_healthy()` | 等待服务健康 | 服务名、超时时间 | 成功/失败 |
| `get_jenkins_password()` | 获取 Jenkins 初始密码 | 无 | 密码字符串 |
| `get_gitlab_password()` | 获取 GitLab 初始密码 | 无 | 密码字符串 |
| `configure_jenkins()` | 配置 Jenkins | 无 | 成功/失败 |
| `deploy_jjb_configs()` | 部署 JJB 配置 | 无 | 成功/失败 |
| `print_summary()` | 输出部署摘要 | 无 | 无 |

---

## 六、服务间集成

### 6.1 集成关系图

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                              服务间集成关系                                                      │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

┌──────────────────┐                                                                 ┌──────────────────┐
│     GitLab       │                                                                 │    OpenClaw      │
│   (代码仓库)      │                                                                 │   (AI 引擎)      │
└────────┬─────────┘                                                                 └────────┬─────────┘
         │                                                                                        │
         │ 1. 代码推送                                                                            │
         │ 2. Webhook 触发 Jenkins                                                                 │
         ▼                                                                                        │
┌──────────────────┐                                                                              │
│     Jenkins      │                                                                              │
│    (CI/CD)       │                                                                              │
└────────┬─────────┘                                                                              │
         │                                                                                        │
         │ 1. 构建失败发送 Webhook                                                                 │
         │ 2. 或直接调用 Skill                                                                    │
         ▼                                                                                        │
┌─────────────────────────────────────────────────────────────────────────────────────────────┐  │
│                         CI Self-Heal Skill (ci-selfheal)                                      │  │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐    │  │
│  │ jenkins_client   │──►│ jjb_manager      │──►│ 核心自愈逻辑     │◄──│  webhook_listener │    │  │
│  │ - 拉取日志        │  │ - 读取 YAML      │  │ - AI 诊断        │  │ - 接收 Webhook    │    │  │
│  │ - 触发构建        │  │ - 更新配置       │  │ - 代码修复        │  │ - 调用 process_   │    │  │
│  │ - 获取配置        │  │ - 执行 JJB 命令  │  │ - 状态管理        │  │   event()         │    │  │
│  └──────────────────┘  └──────────────────┘  └────────┬─────────┘  └──────────────────┘    │  │
│                                                         │                                      │  │
│                                                         │ 调用 OpenClaw CLI                    │  │
│                                                         ▼                                      │  │
│                                                    ┌──────────────────┐                      │  │
│                                                    │  OpenClaw CLI    │                      │  │
│                                                    │ docker exec      │                      │  │
│                                                    └────────┬─────────┘                      │  │
└─────────────────────────────────────────────────────────────┼──────────────────────────────────┘  │
                                                              │                                     │
                                                              └─────────────────────────────────────┘
```

### 6.2 Jenkins 与 OpenClaw 集成

#### 方式 1: 通过 Skill 直接调用

**Skill 调用 OpenClaw CLI**:

```bash
# 在 Skill 中调用 OpenClaw AI 模型
docker exec devopsclaw-openclaw node openclaw.mjs \
    infer model run \
    --model "custom-api-deepseek-com/deepseek-reasoner" \
    --prompt "<完整分析提示>"
```

**说明**:
- Skill 运行在宿主机或容器内
- 通过 `docker exec` 调用 OpenClaw 容器内的 CLI
- 无需网络 API 调用，直接执行

#### 方式 2: 通过 Webhook 触发

**Jenkins Pipeline 中配置 Webhook**:

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
                def payload = [
                    jobName: env.JOB_NAME,
                    buildNumber: env.BUILD_NUMBER,
                    status: currentBuild.currentResult
                ]
                
                // 发送到 Webhook Listener
                sh """
                    curl -s -X POST \
                      -H "Content-Type: application/json" \
                      -d '${groovy.json.JsonOutput.toJson(payload)}' \
                      http://host.docker.internal:5000/webhook/jenkins
                """
            }
        }
    }
}
```

**Webhook Listener**:

```bash
# 启动 Webhook Listener（在宿主机运行）
python .trae/skills/ci-selfheal/webhook_listener.py --port 5000
```

### 6.3 Jenkins 与 GitLab 集成

#### GitLab 触发 Jenkins Pipeline

**方式 1: GitLab Webhook**

1. 在 GitLab 项目中进入: 设置 → 集成
2. 添加 Webhook:
   - URL: `http://<jenkins-host>/project/<job-name>`
   - 触发器: 推送事件、标签推送事件等
3. 点击 "添加 Webhook"

**方式 2: Jenkins 轮询 SCM**

在 Jenkins Pipeline 中配置:

```groovy
pipeline {
    triggers {
        // 每 5 分钟轮询一次
        cron('H/5 * * * *')
        
        // 或者使用 SCM 轮询
        pollSCM('H/15 * * * *')
    }
    
    stages {
        stage('Checkout') {
            steps {
                checkout([
                    $class: 'GitSCM',
                    branches: [[name: '*/main']],
                    userRemoteConfigs: [[
                        url: 'http://devopsclaw-gitlab/my-group/my-project.git'
                    ]]
                ])
            }
        }
    }
}
```

### 6.4 JJB 配置集成

#### JJB 配置目录结构

```
jjb-configs/
├── jenkins_jobs.ini      # JJB 连接配置（从环境变量读取）
├── defaults.yaml          # 全局默认配置
├── example-pipeline.yaml  # 示例业务 Pipeline
└── test-failure-pipeline.yaml  # 测试用 Pipeline
```

#### JJB 连接配置 (jenkins_jobs.ini)

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

#### 部署 JJB 配置到 Jenkins

```bash
# 安装 JJB
pip install jenkins-job-builder

# 测试配置
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini test jjb-configs/

# 更新所有 Job
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini update jjb-configs/

# 更新单个 Job
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini update jjb-configs/example-pipeline.yaml
```

---

## 七、部署流程

### 7.1 快速部署流程

#### 步骤 1: 准备环境

```bash
# 进入项目目录
cd /path/to/DevOpsClaw

# 检查 Docker
docker --version
docker compose version
```

#### 步骤 2: 配置环境变量

```bash
# 复制环境变量模板
copy .env.example .env

# 编辑 .env 文件，填写必要配置
# 至少需要配置:
# - OPENCLAW_GATEWAY_TOKEN
# - JENKINS_TOKEN（部署后获取）
```

#### 步骤 3: 执行部署脚本

```bash
# 添加执行权限
chmod +x deploy_all.sh

# 执行部署
sudo ./deploy_all.sh
```

#### 步骤 4: 按照提示操作

部署脚本会交互式询问:
1. 是否需要部署服务 (y/n)
2. 选择部署模式
3. 确认配置

### 7.2 手动部署流程

#### 步骤 1: 创建 Docker 网络

```bash
# 创建网络（docker-compose 会自动创建）
docker network create devopsclaw-network
```

#### 步骤 2: 配置环境变量

```bash
# 生成 OpenClaw Token (Linux)
tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64

# 或 Windows PowerShell
-join ((65..90) + (97..122) + (48..57) | Get-Random -Count 64 | ForEach-Object {[char]$_})

# 编辑 .env 文件
```

#### 步骤 3: 启动服务

```bash
# 启动所有服务
docker compose up -d

# 或只启动核心服务（不包含 GitLab）
docker compose up -d openclaw jenkins

# 查看服务状态
docker compose ps

# 查看日志
docker compose logs -f
```

#### 步骤 4: 获取初始密码

**Jenkins**:
```bash
# 获取 Jenkins 初始管理员密码
docker exec devopsclaw-jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

**GitLab**:
```bash
# 获取 GitLab 初始 root 密码
# 注意: 此文件 24 小时后会自动删除
docker exec devopsclaw-gitlab cat /etc/gitlab/initial_root_password
```

#### 步骤 5: 配置 Jenkins

1. 访问 http://127.0.0.1:8081/jenkins
2. 输入初始密码
3. 安装推荐插件
4. 创建管理员用户
5. 生成 API Token: 用户 → 设置 → API Token
6. 将 Token 填入 `.env` 文件

#### 步骤 6: 部署 JJB 配置

```bash
# 安装 JJB
pip install jenkins-job-builder

# 部署所有 Job
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini update jjb-configs/
```

### 7.3 部署时间表

| 阶段 | 任务 | 预计时间 |
|------|------|---------|
| **准备** | 环境检查、配置环境变量 | 2-5 分钟 |
| **拉取镜像** | 下载 Docker 镜像 | 5-15 分钟（取决于网络） |
| **启动服务** | 创建容器、启动服务 | 1-2 分钟 |
| **等待就绪** | 服务健康检查 |
|        | - OpenClaw: | ~1 分钟 |
|        | - Jenkins: | ~2-3 分钟 |
|        | - GitLab: | ~5-10 分钟 |
| **配置** | Jenkins 初始配置、JJB 部署 | 5-10 分钟 |
| **总计** | | **15-35 分钟** |

---

## 八、验证测试

### 8.1 服务状态验证

#### 检查容器状态

```bash
# 查看所有服务状态
docker compose ps

# 预期输出:
# NAME                    IMAGE                         COMMAND                  SERVICE             STATUS              PORTS
# devopsclaw-jenkins      jenkins/jenkins:lts-jdk17   "/usr/bin/tini -- /u…"   jenkins             running (healthy)   127.0.0.1:50000->50000/tcp, 127.0.0.1:8081->8080/tcp
# devopsclaw-openclaw     ghcr.io/openclaw/openclaw:latest   "node openclaw.mjs …"   openclaw        running (healthy)   127.0.0.1:18789->18789/tcp
# devopsclaw-gitlab       gitlab/gitlab-ce:latest      "/assets/wrapper"        gitlab              running (healthy)   127.0.0.1:2222->22/tcp, 127.0.0.1:8082->80/tcp, 127.0.0.1:8443->443/tcp
```

#### 检查服务健康

```bash
# 查看容器健康状态
docker inspect --format='{{.State.Health.Status}}' devopsclaw-openclaw
docker inspect --format='{{.State.Health.Status}}' devopsclaw-jenkins
docker inspect --format='{{.State.Health.Status}}' devopsclaw-gitlab

# 预期输出: healthy
```

### 8.2 服务访问验证

#### OpenClaw

```bash
# 访问健康检查端点
curl http://127.0.0.1:18789/health

# 预期输出: {"status":"ok"}

# 浏览器访问
# http://127.0.0.1:18789/overview
```

#### Jenkins

```bash
# 访问 Jenkins
curl -I http://127.0.0.1:8081/jenkins/login

# 预期输出: HTTP/1.1 200 OK

# 浏览器访问
# http://127.0.0.1:8081/jenkins
```

#### GitLab

```bash
# 访问 GitLab 健康检查
curl http://127.0.0.1:8082/-/health

# 预期输出: {"status":"ok"}

# 浏览器访问
# http://127.0.0.1:8082
```

### 8.3 自愈功能验证

#### 测试 Pipeline

项目中包含测试用的 Pipeline: `jjb-configs/test-failure-pipeline.yaml`

```yaml
- job:
    name: test-failure-pipeline
    defaults: global
    description: 'Test Pipeline for CI Self-Heal - Contains intentional error'
    
    dsl: |
      pipeline {
        agent any
        
        stages {
          stage('Test') {
            steps {
              // 故意的错误: date-- 不是有效命令
              // 正确的应该是: date 或 date --
              sh 'date--'
            }
          }
        }
      }
```

#### 验证步骤

**步骤 1: 部署测试 Job**

```bash
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini update jjb-configs/test-failure-pipeline.yaml
```

**步骤 2: 触发构建**

方式 1: 通过 Jenkins UI
- 访问 http://127.0.0.1:8081/jenkins/job/test-failure-pipeline/
- 点击 "立即构建"

方式 2: 通过 API
```bash
curl -X POST http://127.0.0.1:8081/jenkins/job/test-failure-pipeline/build \
  --user admin:$JENKINS_TOKEN
```

**步骤 3: 触发自愈**

方式 1: 使用 Webhook Listener
```bash
# 启动 Webhook Listener
python .trae/skills/ci-selfheal/webhook_listener.py --port 5000 &

# 模拟 Webhook 调用
curl -X POST http://127.0.0.1:5000/webhook/jenkins \
  -H "Content-Type: application/json" \
  -d '{"jobName": "test-failure-pipeline", "buildNumber": 1, "status": "FAILURE"}'
```

方式 2: 直接调用 Skill
```bash
python .trae/skills/ci-selfheal/ci_selfheal.py \
  --job-name "test-failure-pipeline" \
  --build-number 1 \
  --status FAILURE
```

**步骤 4: 验证结果**

```bash
# 查看自愈状态
python .trae/skills/ci-selfheal/ci_selfheal.py --status

# 查看状态文件
cat .self-heal-state.json

# 检查 JJB 配置是否被修复
# date-- 应该被修复为 date
grep "sh 'date" jjb-configs/test-failure-pipeline.yaml
```

**预期结果**:

| 检查项 | 预期值 |
|--------|--------|
| 构建 #1 状态 | FAILURE |
| JJB 配置中 `date--` | 修复为 `date` |
| 状态文件 status | `running` 或 `success` |
| 构建 #2 | 被自动触发 |
| 构建 #2 状态 | SUCCESS |

### 8.4 集成验证清单

| 验证项 | 命令/操作 | 预期结果 |
|--------|-----------|---------|
| Docker 网络 | `docker network inspect devopsclaw-network` | 网络存在，服务已加入 |
| 容器间通信 | `docker exec devopsclaw-jenkins ping devopsclaw-openclaw` | 能 ping 通 |
| OpenClaw API | `curl http://127.0.0.1:18789/health` | `{"status":"ok"}` |
| Jenkins UI | 浏览器访问 http://127.0.0.1:8081/jenkins | 显示登录页面 |
| GitLab UI | 浏览器访问 http://127.0.0.1:8082 | 显示 GitLab 登录页面 |
| JJB 连接 | `jenkins-jobs --conf jjb-configs/jenkins_jobs.ini test jjb-configs/` | 无错误输出 |
| Skill 语法 | `python -m py_compile .trae/skills/ci-selfheal/*.py` | 无语法错误 |

---

## 九、故障排查

### 9.1 常见问题

#### 问题 1: 容器启动失败

**症状**: `docker compose up` 报错，容器无法启动

**排查步骤**:

```bash
# 查看容器状态
docker compose ps -a

# 查看容器日志
docker compose logs <service-name>

# 查看详细日志（最后 100 行）
docker compose logs --tail 100 <service-name>
```

**常见原因**:

| 错误信息 | 原因 | 解决方案 |
|---------|------|---------|
| `port is already allocated` | 端口被占用 | 检查并释放端口，或修改端口配置 |
| `pull access denied` | 镜像拉取失败 | 检查网络连接，配置镜像加速 |
| `no space left on device` | 磁盘空间不足 | 清理 Docker 镜像/容器，扩容磁盘 |
| `permission denied` | 权限问题 | 使用 sudo 运行，检查目录权限 |

#### 问题 2: Jenkins 无法访问

**症状**: 浏览器无法打开 http://127.0.0.1:8081/jenkins

**排查步骤**:

```bash
# 检查 Jenkins 容器状态
docker compose ps jenkins

# 检查端口监听
netstat -ano | findstr :8081

# 检查容器日志
docker compose logs jenkins

# 检查健康状态
docker inspect --format='{{.State.Health.Status}}' devopsclaw-jenkins
```

**可能原因**:

1. **Jenkins 正在初始化**:
   - 首次启动需要 2-3 分钟
   - 查看日志等待 "Jenkins is fully up and running"

2. **端口被占用**:
   ```bash
   # 查看哪个进程占用了端口
   netstat -ano | findstr :8081
   ```

3. **防火墙阻止**:
   - 检查 Windows 防火墙或 iptables
   - 虽然绑定了 127.0.0.1，但仍需确认

#### 问题 3: OpenClaw 健康检查失败

**症状**: 健康检查返回 unhealthy 或超时

**排查步骤**:

```bash
# 查看 OpenClaw 日志
docker compose logs openclaw

# 检查 Token 配置
docker exec devopsclaw-openclaw cat /home/node/.openclaw/openclaw.json

# 尝试手动调用
docker exec devopsclaw-openclaw node openclaw.mjs --help
```

**常见原因**:

1. **Token 配置问题**:
   - 检查 `OPENCLAW_GATEWAY_TOKEN` 环境变量
   - 检查配置文件 `/home/node/.openclaw/openclaw.json`

2. **资源不足**:
   - OpenClaw 需要一定内存
   - 检查宿主机内存: `docker stats`

3. **镜像问题**:
   - 重新拉取镜像: `docker compose pull openclaw`

#### 问题 4: GitLab 启动太慢

**症状**: GitLab 容器启动后很长时间无法访问

**说明**:
- GitLab 首次启动通常需要 **5-10 分钟**
- 需要初始化数据库、配置服务等
- 这是正常现象

**监控启动进度**:

```bash
# 实时查看 GitLab 日志
docker compose logs -f gitlab

# 等待 "gitlab Reconfigured!" 出现
# 或检查健康状态
while true; do
  docker inspect --format='{{.State.Health.Status}}' devopsclaw-gitlab
  sleep 10
done
```

**加速建议**:
- 确保宿主机有足够内存（建议 8GB+）
- 确保磁盘 I/O 性能良好
- 配置 Docker 镜像加速

#### 问题 5: JJB 命令失败

**症状**: `jenkins-jobs update` 报错

**排查步骤**:

```bash
# 测试 JJB 配置
jenkins-jobs --conf jjb-configs/jenkins_jobs.ini test jjb-configs/

# 检查 Jenkins 连接
curl http://127.0.0.1:8081/jenkins/api/json --user admin:$JENKINS_TOKEN

# 检查 YAML 语法
python -c "import yaml; yaml.safe_load(open('jjb-configs/example-pipeline.yaml'))"
```

**常见错误**:

| 错误 | 原因 | 解决方案 |
|------|------|---------|
| 403 Forbidden | Token 无效或权限不足 | 重新生成 API Token，确认用户权限 |
| 404 Not Found | Jenkins URL 错误 | 检查 `JENKINS_URL` 配置 |
| YAML 解析错误 | 缩进或格式问题 | 检查 YAML 语法，使用在线验证工具 |
| Connection refused | Jenkins 未启动或端口错误 | 检查 Jenkins 状态和端口配置 |

#### 问题 6: Skill 无法调用 OpenClaw

**症状**: 调用 OpenClaw CLI 失败

**排查步骤**:

```bash
# 测试 Docker exec 是否正常
docker exec devopsclaw-openclaw echo "test"

# 测试 OpenClaw CLI
docker exec devopsclaw-openclaw node openclaw.mjs --help

# 检查容器是否在运行
docker compose ps openclaw
```

**可能原因**:

1. **Docker 权限问题**:
   - 确保当前用户有 Docker 权限
   - 或使用 sudo 运行

2. **容器未运行**:
   - 启动容器: `docker compose start openclaw`

3. **路径问题**:
   - 检查 `docker` 命令是否在 PATH 中
   - Skill 中使用的是完整路径还是命令名

### 9.2 日志收集

#### 收集所有服务日志

```bash
# 收集所有服务最近 500 行日志
docker compose logs --tail 500 > devopsclaw-logs.txt

# 按服务分别收集
docker compose logs openclaw --tail 200 > openclaw-logs.txt
docker compose logs jenkins --tail 200 > jenkins-logs.txt
docker compose logs gitlab --tail 200 > gitlab-logs.txt
```

#### 收集容器状态信息

```bash
# 容器状态
docker compose ps > container-status.txt

# 详细信息
docker inspect devopsclaw-openclaw > openclaw-inspect.json
docker inspect devopsclaw-jenkins > jenkins-inspect.json
docker inspect devopsclaw-gitlab > gitlab-inspect.json

# 网络信息
docker network inspect devopsclaw-network > network-info.txt

# 卷信息
docker volume ls > volume-list.txt
```

### 9.3 重置环境

#### 完全重置（谨慎操作）

```bash
# 停止所有服务
docker compose down

# 删除所有数据卷（警告: 会丢失所有数据！）
docker compose down -v

# 清理状态文件
del .self-heal-state.json

# 重新启动
docker compose up -d
```

#### 选择性重置

| 目标 | 命令 |
|------|------|
| 仅重置 Jenkins | `docker compose down jenkins && docker compose up -d jenkins` |
| 仅重置 OpenClaw | `docker compose down openclaw && docker compose up -d openclaw` |
| 仅重置 GitLab | `docker compose down gitlab && docker compose up -d gitlab` |
| 重置 Jenkins 数据 | `docker volume rm devopsclaw_jenkins-home` |
| 重置 OpenClaw 数据 | `docker volume rm devopsclaw_openclaw-data` |
| 重置 GitLab 数据 | `docker volume rm devopsclaw_gitlab-config devopsclaw_gitlab-logs devopsclaw_gitlab-data` |

### 9.4 快速检查清单

遇到问题时，按以下顺序检查:

1. **Docker 状态**:
   ```bash
   docker info
   docker compose ps
   ```

2. **容器日志**:
   ```bash
   docker compose logs <service> --tail 50
   ```

3. **健康检查**:
   ```bash
   docker inspect --format='{{.State.Health.Status}}' <container>
   ```

4. **端口占用**:
   ```bash
   netstat -ano | findstr :<port>
   ```

5. **环境变量**:
   ```bash
   # Windows
   type .env
   
   # Linux/Mac
   cat .env
   ```

6. **网络连通性**:
   ```bash
   # 容器间通信
   docker exec devopsclaw-jenkins ping -c 3 devopsclaw-openclaw
   ```

---

## 十、Nginx 反向代理设计（v4.1.0 新增）

### 10.1 定位与职责

Nginx 是整个 CI 平台的唯一流量入口，负责：

| 职责 | 说明 |
|------|------|
| **SSL 终结** | 统一处理 HTTPS 加密，后端服务用 HTTP 明文通信 |
| **反向代理** | 根据端口将请求转发到对应的后端容器 |
| **访问日志** | 所有 Web 请求统一记录在 `/var/log/nginx/access.log` |
| **安全隔离** | 后端 Web 服务不暴露宿主机端口，仅通过 Docker 内部网络可达 |

### 10.2 网络架构图

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                        用户浏览器                                                   │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
                                            │
                                            │ HTTPS
                                            ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    宿主机端口（Nginx 容器对外监听）                                                  │
│     443, 8080, 8081, 8082, 8085, 8443, 8929, 15672, 18789                                      │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
                                            │
                                            ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                          Nginx 容器 (devopsclaw-nginx)                                            │
│  ┌─────────────────────────────────────────────────────────────────────────────────────────────┐  │
│  │  · SSL 终结（统一证书管理）                                                                     │  │
│  │  · 按端口转发到后端容器                                                                          │  │
│  │  · 统一记录访问日志                                                                              │  │
│  │  · 负载均衡（可选）                                                                             │  │
│  └─────────────────────────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
                                            │
                                            │ HTTP（Docker 内部网络 devopsclaw-network）
                                            ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    后端服务（不暴露宿主机端口）                                                        │
│                                                                                                   │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐     │
│  │    GitLab        │  │    Jenkins       │  │    OpenClaw      │  │    Harbor        │     │
│  │  gitlab:80       │  │  jenkins:8080    │  │  openclaw:18789  │  │  harbor:8080     │     │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘  └──────────────────┘     │
│                                                                                                   │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐                           │
│  │    Artifactory   │  │    TRM           │  │    RabbitMQ      │                           │
│  │  artifactory:8082│  │  trm:8080        │  │  rabbitmq:15672  │                           │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘                           │
│                                                                                                   │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
                                            │
                                            │ TCP 直连（不经过 Nginx）
                                            ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    TCP 直连端口（暴露宿主机，不经过 Nginx）                                           │
│                                                                                                   │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐                           │
│  │  GitLab SSH      │  │  Jenkins Agent   │  │  PostgreSQL      │                           │
│  │  2222            │  │  50000           │  │  5432            │                           │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘                           │
│                                                                                                   │
│  ┌──────────────────┐  ┌──────────────────┐                                                   │
│  │  Redis           │  │  RabbitMQ AMQP   │                                                   │
│  │  6379            │  │  5672            │                                                   │
│  └──────────────────┘  └──────────────────┘                                                   │
│                                                                                                   │
│  说明: 这些服务需要原生 TCP 连接，不适合 HTTP 反向代理                                               │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 10.3 端口转发映射表

#### Web 服务（经过 Nginx）

| 用户访问地址（示例） | Nginx 监听端口 | 转发到后端容器 | 说明 |
|---------------------|----------------|---------------|------|
| `https://10.67.167.53:8929` | 8929 | `http://gitlab:80` | GitLab |
| `https://10.67.167.53:8080` | 8080 | `http://jenkins:8080` | Jenkins |
| `https://10.67.167.53:18789` | 18789 | `http://openclaw:18789` | OpenClaw |
| `https://10.67.167.53:8443` | 8443 | `http://harbor:8080` | Harbor (可选) |
| `https://10.67.167.53:8081` | 8081 | `http://artifactory:8082` | Artifactory (可选) |
| `https://10.67.167.53:8085` | 8085 | `http://trm:8080` | TRM (可选) |
| `https://10.67.167.53:15672` | 15672 | `http://rabbitmq:15672` | RabbitMQ 管理 (可选) |
| `https://10.67.167.53:443` | 443 | `http://gitlab:80` | 默认 HTTPS (可配置) |

#### TCP 直连服务（不经过 Nginx）

| 服务 | 端口 | 绑定地址 | 说明 |
|------|------|---------|------|
| GitLab SSH | 2222 | 0.0.0.0 或 127.0.0.1 | Git 命令行操作 |
| Jenkins Agent | 50000 | 127.0.0.1 | Jenkins 主从通信 |
| PostgreSQL | 5432 | 127.0.0.1 | 仅内部使用 |
| Redis | 6379 | 127.0.0.1 | 仅内部使用 |
| RabbitMQ AMQP | 5672 | 127.0.0.1 | 仅内部使用 |

### 10.4 核心设计原则

| 原则 | 说明 |
|------|------|
| **Nginx 是唯一暴露 Web 端口的容器** | 后端服务不绑定宿主机端口，仅在 Docker 内部网络可达 |
| **通过容器名转发** | 不走 127.0.0.1，走 Docker 内部 DNS |
| **按端口隔离** | 不同服务用不同端口，不用子路径，避免兼容性问题 |
| **SSL 统一管理** | 一套证书，一处更新，全站生效 |
| **分层安全** | Web 流量经过 Nginx 认证和日志，TCP 直连端口限制绑定地址 |

### 10.5 防火墙规则建议

```bash
# ============================================
# 对外开放的 Nginx HTTPS 端口（Web 服务）
# ============================================
sudo ufw allow 443/tcp        # 默认 HTTPS
sudo ufw allow 8929/tcp       # GitLab
sudo ufw allow 8080/tcp       # Jenkins
sudo ufw allow 18789/tcp      # OpenClaw
sudo ufw allow 8443/tcp       # Harbor (可选)
sudo ufw allow 8081/tcp       # Artifactory (可选)
sudo ufw allow 8085/tcp       # TRM (可选)
sudo ufw allow 15672/tcp      # RabbitMQ 管理 (可选)

# ============================================
# TCP 直连端口
# ============================================
sudo ufw allow 2222/tcp       # GitLab SSH (如需外部 Git 操作)
sudo ufw allow 50000/tcp      # Jenkins Agent (如需外部 Agent)

# ============================================
# 拒绝 HTTP 明文（可选，根据需要）
# ============================================
sudo ufw deny 80/tcp

# ============================================
# 查看防火墙状态
# ============================================
sudo ufw status numbered
```

### 10.6 方案优势

| 维度 | 说明 |
|------|------|
| **SSL 统一管理** | 一套证书，一处更新，无需在每个服务配置 |
| **统一审计日志** | 所有 Web 访问记录在一个文件，便于审计 |
| **后端不暴露公网** | 后端服务仅通过 Docker 内部网络可达，更安全 |
| **无兼容性坑** | 不用子路径、不用域名，每个服务独立端口 |
| **各数据库独立** | GitLab/Harbor 用内置数据库，互不影响 |
| **易于扩展** | 新增服务只需添加 Nginx 端口配置 |
| **灵活配置** | 可配置负载均衡、限流、缓存等高级功能 |

### 10.7 风险与应对

| 风险 | 应对措施 |
|------|---------|
| **Nginx 单点故障** | `restart: always` + 健康检查 + 监控告警 |
| **证书管理** | 使用环境变量或 Docker Secret 管理证书，定期轮换 |
| **配置复杂** | 提供配置模板和一键生成工具 |
| **性能开销** | Nginx 性能损耗很小，可忽略；高并发时可横向扩展 |
| **调试困难** | 统一日志输出，提供 access.log 和 error.log 分析工具 |
| **自签名证书不被信任** | 所有客户端安装 CA 证书或配置 `insecure-registries` |

### 10.8 为什么用端口隔离而不是子路径？

子路径方案（如 `https://IP/gitlab`、`https://IP/jenkins`）在实际落地时有严重的兼容性问题：

**问题 1: 绝对路径问题**
- GitLab、Jenkins、Harbor 等应用的页面链接、API 调用、WebSocket 连接会大量使用绝对路径
- 应用内部可能硬编码了 `/assets/`、`/api/` 等路径，无法识别子路径前缀

**问题 2: 配置复杂度**
- 需要修改每个应用的 `external_url`、`context path` 等配置
- 不同应用的配置方式不同：
  - Jenkins: `--prefix=/jenkins`
  - GitLab: `external_url 'http://example.com/gitlab'`
  - Harbor: 需要修改 Nginx 配置和多个组件配置

**问题 3: 功能限制**
- WebSocket 连接可能无法正常工作
- 某些插件/扩展不支持子路径
- API 文档、重定向链接可能出错

**问题 4: 排查困难**
- 问题排查极其困难，而且每个应用行为不同
- 需要同时检查 Nginx 配置和应用配置

**端口隔离是最简单、最稳定、零兼容性问题的方案**：
- 每个服务独立端口，互不干扰
- 应用内部使用默认配置，无需修改
- 任何支持标准 HTTP 的应用都可以无缝接入
- 问题排查清晰：Nginx 层或应用层

### 10.9 版本对比

| 特性 | v4.0.0（无 Nginx） | v4.1.0（带 Nginx） |
|------|-------------------|-------------------|
| 后端服务端口绑定 | 绑定 127.0.0.1 | 不绑定宿主机端口 |
| SSL 配置 | 每个服务单独配置 | Nginx 统一配置 |
| 访问日志 | 分散在各容器 | 统一在 Nginx |
| 安全等级 | 中等（本地绑定） | 高（后端不暴露） |
| 配置复杂度 | 低 | 中等（需配置 Nginx） |
| 扩展性 | 一般 | 好 |

---

## 附录

### A. 配置文件速查表

| 文件 | 用途 | 位置 |
|------|------|------|
| `docker-compose.yml` | 服务编排配置 | 项目根目录 |
| `.env` | 环境变量（私有） | 项目根目录 |
| `.env.example` | 环境变量模板 | 项目根目录 |
| `deploy_all.sh` | 主部署脚本 | 项目根目录 |
| `jjb-configs/jenkins_jobs.ini` | JJB 连接配置 | `jjb-configs/` |
| `jjb-configs/defaults.yaml` | JJB 默认配置 | `jjb-configs/` |
| `.trae/skills/ci-selfheal/SKILL.md` | Skill 定义 | `.trae/skills/ci-selfheal/` |

### B. 命令速查表

#### Docker Compose 命令

| 命令 | 说明 |
|------|------|
| `docker compose up -d` | 启动所有服务（后台） |
| `docker compose up -d <service>` | 启动指定服务 |
| `docker compose down` | 停止并删除所有容器 |
| `docker compose down -v` | 停止并删除容器和数据卷 |
| `docker compose ps` | 查看服务状态 |
| `docker compose logs -f` | 实时查看所有日志 |
| `docker compose logs -f <service>` | 实时查看指定服务日志 |
| `docker compose start` | 启动已创建的服务 |
| `docker compose stop` | 停止服务 |
| `docker compose restart` | 重启服务 |
| `docker compose pull` | 拉取最新镜像 |

#### JJB 命令

| 命令 | 说明 |
|------|------|
| `jenkins-jobs --conf <ini> test <config>` | 测试配置（不实际更新） |
| `jenkins-jobs --conf <ini> update <config>` | 更新 Job 到 Jenkins |
| `jenkins-jobs --conf <ini> delete <job>` | 删除 Job |
| `jenkins-jobs --conf <ini> update -r <dir>` | 递归更新目录下所有配置 |

#### Skill 命令

| 命令 | 说明 |
|------|------|
| `python ci_selfheal.py --help` | 查看帮助 |
| `python ci_selfheal.py --status` | 查看自愈状态 |
| `python ci_selfheal.py --job-name <name> --build-number <num> --status <status>` | 处理构建事件 |
| `python webhook_listener.py --port 5000` | 启动 Webhook 接收器 |

### C. 版本信息

| 组件 | 版本 | 说明 |
|------|------|------|
| 本文档 | v4.0.0 | 2026-05-06 |
| Docker Compose | 3.8 | 配置文件版本 |
| Jenkins | lts-jdk17 | 长期支持版，JDK 17 |
| GitLab CE | latest | 最新社区版 |
| OpenClaw | latest | 最新版 |

### D. 参考资源

- [Docker Compose 官方文档](https://docs.docker.com/compose/)
- [Jenkins 官方文档](https://www.jenkins.io/doc/)
- [GitLab Omnibus 文档](https://docs.gitlab.com/omnibus/)
- [Jenkins Job Builder 文档](https://docs.openstack.org/infra/jenkins-job-builder/)
- [OpenClaw 文档](https://openclaw.ai/docs)

---

**文档结束**

*版本: v4.0.0*  
*最后更新: 2026-05-06*
