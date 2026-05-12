# 容器内 ECONNREFUSED 172.19.0.1:18440 — 问题诊断与解决方案

> **日期**: 2026-05-12  
> **关联文档**: [Jenkins + GitLab 连通性验证通过](./Jenkins%20%2B%20GitLab%20连通性验证通过.md)、[ECONNREFUSED](./ECONNREFUSED.md)

---

## 一、故障现象

在 OpenClaw 容器内执行 Jenkins Skill 时报错：

```
Error: connect ECONNREFUSED 172.19.0.1:18440
  errno: -111, code: 'ECONNREFUSED',
  address: '172.19.0.1', port: 18440
```

同一时期宿主机浏览器 `https://127.0.0.1:18440/jenkins/` 访问 Jenkins 正常。

---

## 二、网络拓扑分析

### 2.1 架构全景

```
┌─────────────────────────────────────────────────────────────────────────┐
│  WSL 宿主机                                                               │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  Docker Network: devopsclaw-network (bridge, 172.19.0.0/16)         │ │
│  │                                                                       │ │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │ │
│  │  │   nginx          │  │   Jenkins        │  │   GitLab          │  │ │
│  │  │ 172.19.0.5       │  │ 172.19.0.4       │  │ 172.19.0.3       │  │ │
│  │  │                  │  │                  │  │                  │  │ │
│  │  │ :8440→jenkins    │  │ :8080/jenkins    │  │ :80 (HTTP)       │  │ │
│  │  │ :8441→gitlab     │  │                  │  │                  │  │ │
│  │  │ :8442→openclaw   │  │                  │  │                  │  │ │
│  │  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘  │ │
│  │           │                     │                      │             │ │
│  │  ┌────────┴─────────────────────┴──────────────────────┴─────────┐  │ │
│  │  │   OpenClaw                                                     │  │ │
│  │  │   172.19.0.3 (docker inspect devopsclaw-openclaw)              │  │ │
│  │  │   :18789 (内部 API)                                            │  │ │
│  │  │   ci-selfheal Skill 在此运行                                    │  │ │
│  │  └────────────────────────────────────────────────────────────────┘  │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│  Docker 网关: 172.19.0.1 ← 容器访问宿主机的唯一路径                        │
│                                                                           │
│  宿主机端口映射:                                                            │
│    127.0.0.1:18440 → nginx:8440 (Jenkins HTTPS)                          │
│    127.0.0.1:18441 → nginx:8441 (GitLab  HTTPS)                          │
│    127.0.0.1:18442 → nginx:8442 (OpenClaw HTTPS)                        │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 为什么 `172.19.0.1:18440` 之前能通、现在不通？

| 时间 | 链路 | 状态 |
|------|------|------|
| 5 月 10 日 | 容器 → 172.19.0.1（Docker 网关）→ 宿主机端口映射 18440 → nginx:8440 | ✅ 通 |
| 5 月 12 日 | 同上 | ❌ ECONNREFUSED |

**根本原因**：WSL 重启后，Docker Desktop 的桥接网络 NAT 表可能丢失或未正确重建。容器的 Docker 网关 (`172.19.0.1`) 理论上应该能到达宿主机端口，但 WSL 网络层的端口转发偶发失效。这是 WSL2 + Docker Desktop 的已知不稳定点——**网关直通宿主机端口不是 100% 可靠**。

---

## 三、设计原则：容器间通信应走 nginx HTTPS

### 3.1 为什么必须走 nginx？

| 维度 | 容器直连 | 经过 nginx |
|------|---------|-----------|
| **统一入口** | 各自暴露端口，散乱 | 所有流量经 nginx 443/844x |
| **SSL 加密** | 需要各自配置 | nginx 集中管理证书 |
| **URL 稳定** | IP 可能随容器重建变化 | 用容器名 `devopsclaw-nginx` 访问 |
| **访问控制** | 无 | nginx 可做限流/白名单/日志 |
| **与外部一致** | 内部外部用不同 URL | 内外部走同一套 nginx 规则 |

### 3.2 容器内正确的访问地址

| 目标服务 | 走 nginx (推荐) | 直连 (不推荐) |
|---------|----------------|-------------|
| **Jenkins** | `https://nginx:8440/jenkins` | `http://jenkins:8080/jenkins` |
| **GitLab** | `https://nginx:8441` | `http://gitlab:80` |
| **OpenClaw** | `https://nginx:8442` | `http://openclaw:18789` |

或使用 IP（容器名 DNS 在部分 OpenClaw 环境下可能不可用）：

| 目标服务 | 走 nginx (推荐) |
|---------|----------------|
| **Jenkins** | `https://172.19.0.5:8440/jenkins` |
| **GitLab** | `https://172.19.0.5:8441` |
| **OpenClaw** | `https://172.19.0.5:8442` |

---

## 四、逐步验证指令

以下命令全部在 **OpenClaw 容器内** 执行（`docker exec -it devopsclaw-openclaw bash`）。

### 4.1 验证 Docker 网络拓扑

```bash
echo "=== 1. 查看网关 ==="
cat /proc/net/route | awk 'NR>1 && $2=="00000000"{printf "Gateway: %d.%d.%d.%d\n", strtonum("0x"substr($3,7,2)), strtonum("0x"substr($3,5,2)), strtonum("0x"substr($3,3,2)), strtonum("0x"substr($3,1,2))}'

echo "=== 2. 查看本容器 IP ==="
hostname -I

echo "=== 3. DNS 解析测试 ==="
getent hosts nginx 2>/dev/null || nslookup nginx 2>/dev/null || echo "DNS 不可用"
getent hosts jenkins 2>/dev/null || nslookup jenkins 2>/dev/null || echo "DNS 不可用"
getent hosts gitlab 2>/dev/null || nslookup gitlab 2>/dev/null || echo "DNS 不可用"
```

### 4.2 验证 Jenkins 的三种访问路径

```bash
echo "========== Jenkins 连通性 =========="

echo "--- 路径 A: 宿主机网关（已确认不稳定） ---"
curl -k -s -o /dev/null -w "172.19.0.1:18440 → HTTP %{http_code}\n" https://172.19.0.1:18440/jenkins/api/json || echo "  ❌ 不通"

echo "--- 路径 B: nginx 容器直连（推荐） ---"
curl -k -s -o /dev/null -w "172.19.0.5:8440 → HTTP %{http_code}\n" https://172.19.0.5:8440/jenkins/api/json || echo "  ❌ 不通"

echo "--- 路径 C: Jenkins 容器直连（HTTP 明文） ---"
curl -s -o /dev/null -w "172.19.0.4:8080 → HTTP %{http_code}\n" http://172.19.0.4:8080/jenkins/api/json || echo "  ❌ 不通"

echo ""
echo "========== 结论 =========="
echo "推荐使用路径 B（nginx 容器直连 HTTPS）"
echo "备选使用路径 C（Jenkins HTTP 直连，仅容器内）"
```

**预期结果**：路径 B 返回 **403**（需要认证，说明 HTTPS 通了）；路径 A 可能 000 或 403/200。

### 4.3 验证 Jenkins Skill

```bash
echo "========== Jenkins Skill 测试（通过 nginx） =========="

baseDir="/home/node/.openclaw/workspace/skills/jenkins"
export JENKINS_URL="https://172.19.0.5:8440/jenkins"
export JENKINS_USER="zx"
export JENKINS_API_TOKEN="11e9fec81c11241d5a3897ab45608c6851"
export NODE_TLS_REJECT_UNAUTHORIZED=0

node ${baseDir}/scripts/jenkins.mjs jobs
```

**预期结果**：返回 Jenkins Job 列表 JSON。

### 4.4 验证 GitLab 的三条访问路径

```bash
echo "========== GitLab 连通性 =========="

GITLAB_TOKEN="glpat-imZiYsNETLhKnLsIsOkEwG86MQp1OnoH.01.0w0rr1066"

echo "--- 路径 A: 宿主机网关 ---"
curl -k -s -o /dev/null -w "172.19.0.1:18441 → HTTP %{http_code}\n" -H "PRIVATE-TOKEN: $GITLAB_TOKEN" https://172.19.0.1:18441/api/v4/user || echo "  ❌ 不通"

echo "--- 路径 B: nginx 容器直连（推荐） ---"
curl -k -s -o /dev/null -w "172.19.0.5:8441 → HTTP %{http_code}\n" -H "PRIVATE-TOKEN: $GITLAB_TOKEN" https://172.19.0.5:8441/api/v4/user || echo "  ❌ 不通"

echo "--- 路径 C: GitLab 容器直连（HTTP 明文） ---"
curl -s -o /dev/null -w "172.19.0.3:80 → HTTP %{http_code}\n" -H "PRIVATE-TOKEN: $GITLAB_TOKEN" http://172.19.0.3:80/api/v4/user || echo "  ❌ 不通"

echo ""
echo "--- 路径 B 完整验证 ---"
curl -k -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" https://172.19.0.5:8441/api/v4/user | python3 -m json.tool 2>/dev/null || echo "  ❌ 返回非 JSON"
```

**预期结果**：路径 B 返回用户信息 JSON（`username`、`id`、`name` 等），路径 A 可能不通。

### 4.5 验证 OpenClaw 内部 API

```bash
echo "========== OpenClaw API 连通性 =========="

echo "--- 路径 A: 本机 localhost ---"
curl -s -o /dev/null -w "127.0.0.1:18789 → HTTP %{http_code}\n" http://127.0.0.1:18789/health

echo "--- 路径 B: 通过 nginx HTTPS ---"
curl -k -s -o /dev/null -w "172.19.0.5:8442 → HTTP %{http_code}\n" https://172.19.0.5:8442/health
```

### 4.6 完整连通性一键测试脚本

```bash
#!/bin/bash
# 在 OpenClaw 容器内执行

GITLAB_TOKEN="glpat-imZiYsNETLhKnLsIsOkEwG86MQp1OnoH.01.0w0rr1066"
PASS=0
FAIL=0

check() {
    local name="$1"
    local url="$2"
    local extra="$3"
    local code
    code=$(curl -k -s -o /dev/null -w "%{http_code}" $extra "$url" 2>/dev/null)
    if [ "$code" = "000" ]; then
        echo "  ❌ $name → $url (连接失败)"
        FAIL=$((FAIL + 1))
    elif [ "$code" = "404" ]; then
        echo "  ⚠️  $name → $url (HTTP $code)"
        PASS=$((PASS + 1))
    else
        echo "  ✅ $name → $url (HTTP $code)"
        PASS=$((PASS + 1))
    fi
}

echo "══════════════════════════════════════════════"
echo "  OpenClaw 容器 → 各服务连通性测试"
echo "══════════════════════════════════════════════"
echo ""

echo "=== Jenkins ==="
check "nginx HTTPS" "https://172.19.0.5:8440/jenkins/api/json"
check "nginx HTTP"  "http://172.19.0.5:8440/jenkins/api/json"
check "Jenkins直连" "http://172.19.0.4:8080/jenkins/api/json"

echo ""
echo "=== GitLab ==="
check "nginx HTTPS" "https://172.19.0.5:8441/api/v4/user" "-H 'PRIVATE-TOKEN: $GITLAB_TOKEN'"
check "GitLab直连" "http://172.19.0.3:80/api/v4/user" "-H 'PRIVATE-TOKEN: $GITLAB_TOKEN'"

echo ""
echo "=== OpenClaw ==="
check "local API"   "http://127.0.0.1:18789/health"
check "nginx HTTPS" "https://172.19.0.5:8442/health"

echo ""
echo "══════════════════════════════════════════════"
echo "  通过: $PASS  失败: $FAIL"
echo "══════════════════════════════════════════════"
```

---

## 五、ci-selfheal 配置修正

根据以上诊断结论，`config.yaml` 应修改为使用 nginx 容器直连：

```yaml
jenkins:
  url: "https://172.19.0.5:8440/jenkins"    # nginx → Jenkins
  user: "zx"
  token_env: "JENKINS_API_TOKEN_1"

gitlab:
  url: "https://172.19.0.5:8441"            # nginx → GitLab
  token_env: "GITLAB_TOKEN"

repair:
  max_retries: 5
  poll_interval_sec: 5
  build_timeout_min: 30

whitelist:
  repos:
    - "root/model_test"
    - "group/backend-api"
  branch_pattern: "^(feat|fix|dev|feature)/.*"
  protected_branches:
    - "main"
    - "master"
    - "release/*"
```

**关键改动**：

| 配置项 | 旧值 | 新值 | 原因 |
|--------|------|------|------|
| `jenkins.url` | `http://172.18.0.1:8084` | `https://172.19.0.5:8440/jenkins` | 走 nginx HTTPS，不依赖宿主机端口映射 |
| `jenkins.token_env` | `JENKINS_API_TOKEN_2` | `JENKINS_API_TOKEN_1` | 实例 1 的 Token |
| `gitlab.url` | `https://172.19.0.1:18441` | `https://172.19.0.5:8441` | 走 nginx HTTPS |

---

## 六、总结

| 问题 | 根因 | 解决方案 |
|------|------|---------|
| ECONNREFUSED 172.19.0.1:18440 | WSL 重启后 Docker NAT 端口转发失效 | 改用容器直连 nginx |
| host.docker.internal 不可解析 | WSL 下不支持此主机名 | 用容器名或容器 IP |
| curl -k 才能访问 | nginx 使用自签名证书 | 保持 `-k` 或 `NODE_TLS_REJECT_UNAUTHORIZED=0` |

**核心原则**：同一 Docker 网络上的容器间通信，走 nginx 容器直连（`172.19.0.5:844x`）而非宿主机网关（`172.19.0.1:184xx`）。容器 IP 只要容器不重建就不会变，远比依赖 WSL NAT 端口转发稳定。

**端口对照速查**：

| 服务 | nginx 内部端口 | 宿主机映射端口 |
|------|---------------|---------------|
| Jenkins | `172.19.0.5:8440` | `127.0.0.1:18440` |
| GitLab | `172.19.0.5:8441` | `127.0.0.1:18441` |
| OpenClaw | `172.19.0.5:8442` | `127.0.0.1:18442` |
