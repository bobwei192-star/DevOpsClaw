# OpenClaw × Jenkins 自愈流水线 MVP 工程化部署指南

> **版本**：v2.0.0（实战优化版）  
> **更新日期**：2026-05-02  
> **适用场景**：Jenkins 构建失败时，自动由 OpenClaw + DeepSeek/Kimi 诊断并修复 Pipeline 代码，最多修复 5 轮。

---

## 目录

1. [架构概览](#一架构概览)
2. [前置环境检查](#二前置环境检查)
3. [部署步骤](#三部署步骤)
4. [Jenkins 流水线配置](#四jenkins-流水线配置)
5. [验证测试](#五验证测试)
6. [实施记录与问题排查](#六实施记录与问题排查)
7. [附录](#七附录)

---

## 一、架构概览

### 1.1 系统架构图

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                      宿主机 (Ubuntu)                                     │
│                                                                                         │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐     │
│  │                           Jenkins Master (端口 8081)                             │     │
│  │                                                                                  │     │
│  │  ┌─────────────────────┐         ┌─────────────────────┐                        │     │
│  │  │   demo-success      │         │     demo-fail       │                        │     │
│  │  │   (Declarative)     │         │   (Declarative)     │                        │     │
│  │  │                     │         │                     │                        │     │
│  │  │  stage('运行脚本')  │         │  stage('运行脚本')  │                        │     │
│  │  │    sh 'date'   ✓   │         │    sh 'date--'   ✗  │                        │     │
│  │  │                     │         │                     │                        │     │
│  │  │  post { always }   │         │  post { always }   │                        │     │
│  │  │    curl ───────────┼─────────┼──► Bridge:5000     │                        │     │
│  │  │    {status:SUCCESS}│         │    {status:FAILURE}│                        │     │
│  │  └─────────────────────┘         └──────────┬──────────┘                        │     │
│  │                                               │                                   │     │
│  │  ┌────────────────────────────────────────────┘                                   │     │
│  │  │                                                                                 │     │
│  │  │  ┌─────────────────────────────────────────────────┐                            │     │
│  │  │  │  demo-fail-openclaw-fix-1  (AI 修复后新 Job)    │                            │     │
│  │  │  │                                                 │                            │     │
│  │  │  │  stage('运行脚本')                              │                            │     │
│  │  │  │    sh 'date'   ✓  ←── AI 将 date-- 修复为 date  │                            │     │
│  │  │  │                                                 │                            │     │
│  │  │  │  post { always }                                │                            │     │
│  │  │  │    curl ─────────────────────────► Bridge:5000  │                            │     │
│  │  │  │    {status:SUCCESS, isOpenclaw:true}            │                            │     │
│  │  │  └─────────────────────────────────────────────────┘                            │     │
│  │  │                                                                                 │     │
│  │  │  ←── 最多修复 5 轮: fix-1 → fix-2 → ... → fix-5，仍失败则停止                   │     │
│  │  │                                                                                 │     │
│  │  └─────────────────────────────────────────────────────────────────────────────────┘     │
│  │                                                                                         │
│  │  对外接口: http://127.0.0.1:8081                                                        │
│  │  API Token: 11b28ded03fd5260903f1d6c3a6c8a8c22                                        │
│  │                                                                                         │
│  └─────────────────────────────────────────────────────────────────────────────────┘     │
│                                           │                                              │
│                                           │ HTTP POST /webhook/jenkins                   │
│                                           │ (JSON: jobName, buildNumber, status, ...)      │
│                                           ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐     │
│  │                    OpenClaw Bridge v2 (Python3, 端口 5000)                        │     │
│  │                                                                                  │     │
│  │  部署路径: /home/worker/software/AI/CICD/openclaw/bridge_v2.py                    │     │
│  │  服务管理: 手动启动 / Systemd (待配置)                                            │     │
│  │                                                                                  │     │
│  │  ┌─────────────────────────────────────────────────────────────────────────┐      │     │
│  │  │                         核心处理流程                                     │      │     │
│  │  │                                                                          │      │     │
│  │  │  ① 接收 Jenkins Webhook  ──►  ② 判断 SUCCESS / FAILURE                   │      │     │
│  │  │                                                                          │      │     │
│  │  │  SUCCESS ──► 记录日志 ──► 结束                                           │      │     │
│  │  │                                                                          │      │     │
│  │  │  FAILURE ──► ③ 拉取原始 Job 的 config.xml                                │      │     │
│  │  │              ④ 拉取当前 Build 的 consoleText 日志                        │      │     │
│  │  │              ⑤ 调用 OpenClaw CLI (infer model run)                      │      │     │
│  │  │              ⑥ 提取 AI 返回的修复代码                                    │      │     │
│  │  │                                                                          │      │     │
│  │  │  DRY_RUN=true (L2) ──► 打印修复代码到控制台 ──► 人工确认后切换 false      │      │     │
│  │  │  DRY_RUN=false (L3) ──► ⑦ 调用 Jenkins API createItem 创建新 Job        │      │     │
│  │  │                         ⑧ 调用 Jenkins API build 触发构建               │      │     │
│  │  │                                                                          │      │     │
│  │  └─────────────────────────────────────────────────────────────────────────┘      │     │
│  │                                                                                  │     │
│  │  状态持久化: .self-heal-state.json  (修复链条、轮次、历史)                        │     │
│  │  审计日志:   bridge_v2.log                                                        │     │
│  │  安全配置:   .env (OPENCLAW_TOKEN, JENKINS_TOKEN, DRY_RUN, MAX_RETRY=5)          │     │
│  │                                                                                  │     │
│  │  对外接口:                                                                 │     │
│  │    GET  /health   ──► 健康检查                                                    │     │
│  │    GET  /state    ──► 查看自愈状态                                                │     │
│  │    POST /webhook/jenkins ──► 接收 Jenkins 构建事件                                │     │
│  │                                                                                  │     │
│  └─────────────────────────────────────────────────────────────────────────────────┘     │
│                                           │                                              │
│                                           │ docker exec openclaw node openclaw.mjs       │
│                                           │ infer model run --model <model> --prompt     │
│                                           ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐     │
│  │                  OpenClaw Gateway (Docker, host 网络模式)                         │     │
│  │                                                                                  │     │
│  │  部署方式: Docker (ghcr.io/openclaw/openclaw:latest)                             │     │
│  │  网络模式: host (直接使用宿主机网络栈)                                           │     │
│  │  访问地址: http://127.0.0.1:18789 (宿主机)                                       │     │
│  │            http://192.168.43.17:18789 (宿主机 IP，供容器访问)                    │     │
│  │  持久化卷: /home/node/.openclaw (容器内)                                         │     │
│  │                                                                                  │     │
│  │  配置模型:                                                                         │     │
│  │    - custom-api-moonshot-cn/kimi-k2.5                                           │     │
│  │    - custom-api-deepseek-com/deepseek-reasoner                                  │     │
│  │                                                                                  │     │
│  └─────────────────────────────────────────────────────────────────────────────────┘     │
│                                           │                                              │
│                                           │ HTTPS API 请求                                │
│                                           ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐     │
│  │                              DeepSeek / Kimi API                                  │     │
│  │                                                                                  │     │
│  │  模型: deepseek-reasoner (主用) / kimi-k2.5 (备用)                               │     │
│  │  角色: Jenkins Pipeline 修复专家                                                 │     │
│  │  温度: 0.1 (低温度，减少幻觉)                                                    │     │
│  │  最大 Token: 4000                                                                │     │
│  │                                                                                  │     │
│  └─────────────────────────────────────────────────────────────────────────────────┘     │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 关键变更说明（v2.0.0 vs v1.0.0）

| 项目 | v1.0.0 (原设计) | v2.0.0 (实战优化) | 原因 |
|------|----------------|-------------------|------|
| **AI 调用方式** | HTTP API `/v1/chat/completions` | OpenClaw CLI `infer model run` | OpenClaw Gateway 未实现标准 OpenAI API |
| **网络访问** | `127.0.0.1:18789` | `192.168.43.17:18789` (宿主机 IP) | Docker 容器间网络隔离 |
| **模型选择** | DeepSeek only | DeepSeek + Kimi fallback | Kimi 偶发失败，需要备用模型 |
| **Bridge 代码** | `bridge.py` | `bridge_v2.py` | 适配 CLI 调用方式 |
| **Jenkins 端口** | 8080 | 8081 | 实际部署环境 |
| **Pipeline 类型** | Script Pipeline | Declarative Pipeline | 避免 Jenkins 脚本审批问题 |

### 1.3 网络通信说明

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                    网络访问矩阵                                          │
├──────────────────────────┬──────────────────────────┬──────────────────────────────────┤
│ 源                        │ 目标                      │ 访问地址                          │
├──────────────────────────┼──────────────────────────┼──────────────────────────────────┤
│ Jenkins 容器 (bridge)     │ Bridge 服务              │ http://192.168.43.17:5000        │
│ Bridge (宿主机 Python)    │ OpenClaw Gateway         │ docker exec openclaw ...         │
│ OpenClaw 容器 (host 模式) │ DeepSeek/Kimi API        │ https://api.deepseek.com         │
│ Bridge (宿主机 Python)    │ Jenkins API              │ http://127.0.0.1:8081            │
└──────────────────────────┴──────────────────────────┴──────────────────────────────────┘
```

**重要**：由于 OpenClaw 使用 `host` 网络模式，Jenkins 使用 `bridge` 网络模式，两者无法通过 `localhost` 互通，必须使用**宿主机 IP 地址**（如 `192.168.43.17`）。

---

## 二、前置环境检查

### 2.1 必需服务清单

| 服务 | 验证命令 | 期望结果 |
|------|---------|---------|
| Jenkins | `curl -s http://127.0.0.1:8081/login` | 返回 Jenkins 登录页 HTML |
| OpenClaw Gateway | `docker ps | grep openclaw` | 容器状态为 `healthy` |
| OpenClaw CLI | `docker exec openclaw node openclaw.mjs --version` | 返回版本号 |
| Python3 | `python3 --version` | ≥ 3.8 |
| pip3 | `pip3 --version` | 可用 |
| Docker | `docker --version` | 可用 |

### 2.2 获取宿主机 IP

```bash
# 获取宿主机 IP（用于容器间通信）
HOST_IP=$(hostname -I | awk '{print $1}')
echo "宿主机 IP: $HOST_IP"  # 例如: 192.168.43.17
```

---

## 三、部署步骤

### 3.1 创建项目目录

```bash
mkdir -p /home/worker/software/AI/CICD/openclaw
cd /home/worker/software/AI/CICD/openclaw
```

### 3.2 创建 Python 虚拟环境（推荐）

```bash
python3 -m venv venv
source venv/bin/activate
pip install requests
```

### 3.3 创建环境变量文件

```bash
cat > .env << 'EOF'
# ============================================
# OpenClaw Jenkins Bridge 环境变量
# 警告: 此文件包含敏感信息，已加入 .gitignore，禁止入仓！
# ============================================

# ---------- OpenClaw Gateway ----------
export OPENCLAW_GATEWAY_TOKEN="wdO8hDwotUBGIcfNNio6O1jNtPwLbdsM6tsrPVY643DmoGLUVYnkYt6APZcBAy3q"

# ---------- Jenkins ----------
export JENKINS_URL="http://127.0.0.1:8081"
export JENKINS_USER="zhangsan"
export JENKINS_TOKEN="11b28ded03fd5260903f1d6c3a6c8a8c22"

# ---------- 业务规则 ----------
export DRY_RUN="true"  # L2 保守模式，验证通过后改为 "false"
export MAX_RETRY="5"

# ---------- 服务配置 ----------
export BRIDGE_PORT="5000"

# ---------- 持久化路径 ----------
export STATE_FILE="/home/worker/software/AI/CICD/openclaw/.self-heal-state.json"
export LOG_FILE="/home/worker/software/AI/CICD/openclaw/bridge_v2.log"
EOF
```

**注意**：`DRY_RUN="true