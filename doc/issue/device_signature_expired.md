# Agent "device signature expired" 问题诊断与修复

## 问题现象

- 浏览器访问 Agent Dashboard 时，WebSocket 连接被关闭，返回 `code=1008 reason=device signature expired`
- 或者报错 `origin not allowed (open the Control UI from the gateway host or allow it in gateway.controlUi.allowedOrigins)`

---

## 根因分析（按优先级排序）

### 根因 1：Agent 已知 Bug - `allowInsecureAuth` 无法跳过设备签名验证（**主因**）

**这是 Agent 的已知 Bug**（[GitHub Issue #2248](https://github.com/agent/agent/issues/2248)）。

**问题机制**：
1. `gateway.controlUi.allowInsecureAuth: true` 的设计意图是允许纯 token 认证，跳过设备配对
2. **但是**，这个配置只在**浏览器没有发送设备身份**时生效
3. 在 `localhost` 或 `HTTPS` 环境下，浏览器的 `crypto.subtle` API 可用，Control UI **会自动生成设备身份**
4. 一旦有了设备身份，网关就会执行设备签名验证
5. 如果签名时间戳和网关时间偏差超过 2 分钟，就会返回 `device signature expired`
6. **更关键的是**：即使 `allowInsecureAuth: true`，网关也不会在签名失败后回退到 token 认证

**官方解决方案**：
Agent 维护者在 main 分支添加了 `gateway.controlUi.dangerouslyDisableDeviceAuth: true` 配置，**完全禁用** Control UI 的设备身份验证。

> ⚠️ **注意**：这个配置被标记为 `critical` 安全级别，因为它完全跳过了设备身份验证。只在受信任的内网环境使用。

### 根因 2：时间不同步

Agent Gateway 在 WebSocket 握手时会验证设备签名的时间戳。如果**客户端（浏览器）和服务器（Agent 容器）的时间偏差超过 2 分钟**，签名就会被视为过期。

在 Docker/WSL2 环境中，容器时钟经常与宿主机不同步（常见 8 小时时差，因为容器默认用 UTC，宿主机用 CST）。

### 根因 3：allowedOrigins 未配置

Agent 默认只允许从 localhost 访问 Control UI。如果通过 Nginx 代理或 IP 地址访问，需要在配置中明确允许。

### 根因 4：配置写入后未重启

Agent 启动时读取配置文件，之后不会自动重载。通过 `docker exec` 写入新配置后，**必须重启容器**才能生效。

### 根因 5：浏览器缓存旧设备签名

即使服务器端修复了，浏览器 localStorage 中可能还缓存着旧的设备签名，导致继续报错。

---

## 修复步骤

### 步骤 1：同步时间（关键）

```bash
# 宿主机同步时间
sudo ntpdate -s time.windows.com || sudo ntpdate -s pool.ntp.org

# 检查宿主机和容器时间是否一致
date
docker exec devopsagent-agent date
```

如果时间差超过 2 分钟，必须修复。建议在启动容器时设置 TZ 环境变量：

```bash
-e TZ=Asia/Shanghai
```

### 步骤 2：清理旧配置并重新部署

```bash
cd /mnt/c/Users/Tong/Desktop/DevOpsAgent

# 停止并删除旧容器
docker stop devopsagent-agent
docker rm devopsagent-agent

# 删除旧的坏配置（如果有）
rm -f data/agent/agent.json

# 重新部署
sudo ./deploy_agent/deploy_agent.sh --deploy
```

### 步骤 3：验证配置已写入

```bash
# 查看容器内的配置
docker exec devopsagent-agent cat /home/node/.agent/agent.json
```

确认包含：
- `gateway.controlUi.allowedOrigins` - 包含你的访问地址
- `gateway.controlUi.allowInsecureAuth: true` - 允许纯 token 认证
- `gateway.controlUi.dangerouslyDisableDeviceAuth: true` - **关键：完全禁用设备身份验证**
- `gateway.auth.mode: "token"` - 使用 token 认证

### 步骤 4：重启容器使配置生效

```bash
docker restart devopsagent-agent
sleep 5
```

### 步骤 5：清理浏览器缓存

1. 打开 Chrome 无痕窗口（必须无痕，避免缓存）
2. 访问 `https://127.0.0.1:18442/#token=<你的token>`
3. 如果还报错，按 F12 → Application → Storage → Clear site data
4. 刷新页面

### 步骤 6：验证连通性

```bash
# 测试直连
curl http://127.0.0.1:18789/health

# 测试 Nginx 代理
curl -k https://127.0.0.1:18442/health
```

---

## 一键修复脚本

使用项目自带的诊断修复脚本：

```bash
sudo python3 tests/test_device_signature_expired.py
```

该脚本会自动完成：
1. 生成新的 Gateway Token
2. 同步系统时间
3. 清理旧容器和数据
4. 预写正确的 agent.json 配置（含 `dangerouslyDisableDeviceAuth`）
5. 启动容器并运行 onboard 初始化
6. 验证连通性

---

## 关键配置说明

### agent.json 关键字段

```json
{
  "gateway": {
    "mode": "local",
    "auth": {
      "token": "你的64位token",
      "mode": "token"
    },
    "controlUi": {
      "enabled": true,
      "allowedOrigins": [
        "http://127.0.0.1:18789",
        "https://127.0.0.1:18442"
      ],
      "allowInsecureAuth": true,
      "dangerouslyDisableDeviceAuth": true
    },
    "trustedProxies": [
      "127.0.0.1",
      "172.16.0.0/12"
    ],
    "bind": "lan"
  }
}
```

### 各字段作用

| 字段 | 作用 |
|------|------|
| `allowedOrigins` | 允许访问 Control UI 的来源地址 |
| `allowInsecureAuth` | 允许非安全上下文使用纯 token 认证（但无法解决设备签名问题） |
| `dangerouslyDisableDeviceAuth` | **关键**：完全禁用设备身份验证，绕过所有设备签名检查 |
| `trustedProxies` | 信任的代理服务器 IP 段 |
| `auth.mode` | 认证模式，token 模式使用 Gateway Token |
| `bind` | 绑定地址，`lan` 允许局域网访问（不能用 `0.0.0.0`） |

### 为什么需要 `dangerouslyDisableDeviceAuth`

根据 Agent 官方 Issue #2248 的分析：

1. `allowInsecureAuth: true` 只在**没有设备身份**时生效
2. 浏览器在 `localhost` 和 `HTTPS` 环境下会自动生成设备身份（因为 `crypto.subtle` API 可用）
3. 一旦有了设备身份，网关就会执行签名验证
4. 签名失败后，**不会**回退到 token 认证
5. 所以必须完全禁用设备身份验证

---

## 常见错误排查

### 错误 1：Invalid --bind (use "loopback", "lan", "tailnet", "auto", or "custom")

**原因**：在配置中设置了 `gateway.bind = '0.0.0.0'`，但 Agent 只接受特定的绑定值。

**修复**：使用 `'lan'` 或 `'loopback'`，不要用 `'0.0.0.0'`。

### 错误 2：host not found in upstream "devopsagent-agent:18789"

**原因**：Nginx 无法解析 Agent 容器的主机名。

**修复**：Nginx 配置中使用 `127.0.0.1:18789` 代替容器名，或者确保两个容器在同一个 Docker 网络。

### 错误 3：容器启动后立即退出

**原因**：配置文件中有错误（如无效的 bind 值），导致 Agent 启动失败。

**修复**：删除数据目录中的 `agent.json`，让 Agent 生成默认配置。

### 错误 4：配置已写入但仍然报错

**原因**：Agent 启动时读取配置，之后不会自动重载。

**修复**：写入配置后必须重启容器 `docker restart devopsagent-agent`。

---

## 参考

- Agent 官方 Issue #2248: https://github.com/agent/agent/issues/2248
- Agent 官方 Issue #29298: https://github.com/agent/agent/issues/29298
- 时间同步问题: https://github.com/agent/agent/issues/24455
