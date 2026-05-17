# Agent 固定 IP 部署后 `device pairing required` 处理

## 问题现象

在服务器部署 Agent，并通过固定 IP 访问：

- `https://10.67.69.34:18442/#token=<token>`

页面可以正常打开，但点击连接后出现：

- `device pairing required (requestId: <uuid>)`

或停留在 Gateway Dashboard 页面，无法直接进入聊天界面。

---

## 根因

在 `HTTPS + token` 场景下，浏览器仍可能为 Control UI 自动生成设备身份。  
如果网关没有完全关闭设备配对验证，就会把当前浏览器当成“待批准设备”，即使你已经携带了正确的 Gateway Token。

---

## 处理方式

### 方式 1：手工批准当前请求（最快）

如果页面上已经出现：

- `requestId: 6333d195-1642-4621-a399-e7bf935b54c8`

就在服务器执行：

```bash
cd ~/DevOpsAgent/deploy
sudo bash deploy_agent/deploy_agent.sh --approve-device 6333d195-1642-4621-a399-e7bf935b54c8
```

执行成功后刷新浏览器页面，通常即可进入。

如果不知道当前待配对请求有哪些，可以先列出：

```bash
cd ~/DevOpsAgent/deploy
sudo bash deploy_agent/deploy_agent.sh --list-devices
```

---

### 方式 2：重新写回 token 直连配置（推荐）

如果你希望固定 IP + token 的方式尽量不再弹配对页面，执行：

```bash
cd ~/DevOpsAgent/deploy
sudo bash deploy_agent/deploy_agent.sh --reapply-token-auth
```

这个动作会自动：

1. 读取 `.agent_token`
2. 重写 `agent.json`
3. 设置 `gateway.auth.mode = "token"`
4. 设置 `gateway.controlUi.allowInsecureAuth = true`
5. 设置 `gateway.controlUi.dangerouslyDisableDeviceAuth = true`
6. 根据当前固定 IP / 域名补全 `allowedOrigins`
7. 自动重启 Agent 容器

---

## 当前脚本行为说明

最新版本的：

- `deploy/deploy_agent/deploy_agent.sh`

在执行：

```bash
sudo bash deploy_agent/deploy_agent.sh --deploy
```

后，已经会自动尝试：

1. 部署 Agent
2. 写入 `allowedOrigins`
3. 重写 token 认证模式
4. 设置 `dangerouslyDisableDeviceAuth = true`
5. 自动重启容器

也就是说，脚本现在的目标就是**尽量规避首次配对**。

---

## 如果还是出现配对页面

说明至少有一种情况仍然存在：

1. 服务器上运行的脚本还不是最新版本
2. 浏览器缓存了旧的设备身份
3. Agent 当前版本对 token + HTTPS 的处理仍未完全绕过设备配对

此时建议按下面顺序处理：

1. 用 Chrome 无痕窗口重新打开页面
2. 如果仍然报 `device pairing required`，直接执行一次 `--approve-device <requestId>`
3. 再执行一次：

```bash
sudo bash deploy_agent/deploy_agent.sh --reapply-token-auth
```

---

## 常用命令

```bash
# 查看待配对设备
sudo bash deploy_agent/deploy_agent.sh --list-devices

# 批准某个配对请求
sudo bash deploy_agent/deploy_agent.sh --approve-device <requestId>

# 重写 token 直连配置
sudo bash deploy_agent/deploy_agent.sh --reapply-token-auth

# 查看 Agent 当前状态
sudo bash deploy_agent/deploy_agent.sh --status