# 容器 IP 漂移导致 ECONNREFUSED — 根因与永久修复

> **日期**: 2026-05-13  
> **影响范围**: 所有使用硬编码 Docker 内网 IP（`172.19.0.x`）的配置、脚本、文档  
> **严重程度**: 🔴 高危 — 容器重启后自动触发，无预警  
> **修复策略**: 全局替换 IP → Docker DNS 容器名

---

## 一、故障现象

nginx 容器被 Docker 重启后，所有依赖 `https://172.19.0.5:8440/jenkins` 的命令全部报：

```
Error: connect ECONNREFUSED 172.19.0.5:8440
  errno: -111, code: 'ECONNREFUSED'
```

但 `https://devopsagent-nginx:8440/jenkins` 正常工作。

---

## 二、根因

Docker Compose 的默认 `bridge` 网络在容器重启时**不保证 IP 不变**。

```
重启前:
  devopsagent-nginx    → 172.19.0.5
  devopsagent-jenkins  → 172.19.0.4

重启后 (nginx 容器 23 小时前被重启):
  devopsagent-nginx    → 172.19.0.4  ← 变了!
  devopsagent-jenkins  → 172.19.0.4  ← 冲突风险!

# docker ps 验证
ec7d33885e2a  nginx:alpine    23 hours ago  ← 重启过
5da26b33f5b4  ghcr.io/agent 3 days ago  ← 没重启过
```

**Docker 官方不建议依赖容器 IP**，推荐使用容器名 DNS：

> "Containers connected to the same user-defined bridge network can communicate with each other using container names, without needing IP addresses or links."
> — Docker Networking Documentation

---

## 三、修复：IP → 容器名全局替换

### 3.1 替换映射表

| 旧地址 | 新地址 | 说明 |
|--------|--------|------|
| `172.19.0.5:8440` | `devopsagent-nginx:8440` | Jenkins (via nginx HTTPS) |
| `172.19.0.5:8441` | `devopsagent-nginx:8441` | GitLab (via nginx HTTPS) |
| `172.19.0.4:8080` | `devopsagent-jenkins:8080` | Jenkins 直连 |
| `172.19.0.3:80` | `devopsagent-gitlab:80` | GitLab 直连 |

### 3.2 影响文件清单

| 文件 | 替换数量 | 影响 |
|------|---------|------|
| `ci-selfheal/.env` | 3 处 | JENKINS_URL / GITLAB_HOST |
| `ci-selfheal/config.yaml` | 1 处 | GitLab URL |
| `ci-selfheal/verify-deployment.sh` | 3 处 | 验收脚本默认值 |
| `doc/13Agent CI 自愈…施工步骤-极简.md` | 17 处 | 部署文档 |
| `doc/issue/容器间通信必须经过nginx-HTTPS.md` | 已同步 | 网络诊断文档 |

### 3.3 验证方法

容器内执行：

```bash
getent hosts devopsagent-nginx
# 预期输出: 172.19.0.x  devopsagent-nginx

curl -k -s -o /dev/null -w "%{http_code}" https://devopsagent-nginx:8440/jenkins/api/json
# 预期输出: 403 (或 200)
```

---

## 四、CI-Self-Heal 防护措施

针对此类问题，部署验收脚本 `verify-deployment.sh` 已内置三层检测：

| 检测层 | 检查项 | 失败行为 |
|--------|--------|---------|
| L1 网络层 | `curl` Ping Jenkins/GitLab 可达 | SKIP → 标记为网络问题 |
| L2 证书层 | TLS 自签名证书可接受 | 命令级 fallback |
| L3 DNS 层 | 容器名可解析 | 建议用 `devopsagent-nginx` 代替 IP |

**运行验证**：

```bash
cd /home/node/.agent/workspace/skills/ci-selfheal
bash verify-deployment.sh
```

---

## 五、经验教训

| 教训 | 规范 |
|------|------|
| **不要在配置里硬编码 Docker 内网 IP** | 使用容器名 `devopsagent-nginx` 或 `docker-compose` 的 `links`/`depends_on` |
| **不要假设容器 IP 不变** | Docker bridge 的 IP 分配是动态的，重启/重建都可能变 |
| **验收脚本必须自动读取 `.env`** | `verify-deployment.sh` 首次修复时没 `source .env`，导致用了硬编码的旧默认值 |
| **验收脚本首次跑通后才能信任** | 脚本语法通过 ≠ 网络连通性通过，必须是"部署 → 验证"闭环 |

---

## 六、相关文档

- [容器间通信必须经过 nginx-HTTPS](./容器间通信必须经过nginx-HTTPS.md) — 网关 vs 容器直连的设计讨论
- [ECONNREFUSED](./ECONNREFUSED.md) — 原始网络问题排查记录  
- [Jenkins + GitLab 连通性验证通过](./Jenkins%20%2B%20GitLab%20连通性验证通过.md) — 首次连通性验证记录
