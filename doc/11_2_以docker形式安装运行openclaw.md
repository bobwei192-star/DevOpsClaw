一、环境准备
1. 安装 Docker 和 Docker Compose
bash
Copy
sudo apt update && sudo apt upgrade -y
sudo apt install -y ca-certificates curl gnupg lsb-release

# 添加 Docker 官方仓库
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# 验证安装
docker --version
docker compose version
二、创建专用低权限用户与目录（最小权限原则）
按照你文档中的最小权限原则，不要放在 /root 下，而是为 OpenClaw 创建独立目录和用户映射：
bash
Copy
# 创建专用目录
sudo mkdir -p /home/openclaw/workspace

# OpenClaw 容器内以 node 用户（UID 1000）运行
# 必须将宿主机目录所有权设为 1000:1000，否则容器会报 EACCES 权限错误 [^15^]
sudo chown -R 1000:1000 /home/openclaw
三、生成强密码并拉取镜像
bash
Copy
# 生成至少32位的高强度随机 Gateway Token
export OPENCLAW_GATEWAY_TOKEN=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 64; echo '')
echo "你的 Gateway Token 是: $OPENCLAW_GATEWAY_TOKEN"
# 请妥善保存此 Token，后续配对设备时需要用到

# 拉取官方镜像
docker pull ghcr.io/openclaw/openclaw:latest
四、以安全方式启动容器
结合你文档中的网络隔离和加固要求，使用以下命令启动，关键安全点：
端口映射到 127.0.0.1（本机回环），不暴露到公网
绑定本地回环地址，防止外部直接访问
使用持久化卷保存配置和数据
bash
Copy
docker run -d \
  --name openclaw \
  --restart unless-stopped \
  --user 1000:1000 \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --read-only \
  -p 127.0.0.1:18789:18789 \
  -v /home/openclaw:/home/node/.openclaw \
  -e OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN \
  ghcr.io/openclaw/openclaw:latest \
  sh -c "node openclaw.mjs gateway --allow-unconfigured --bind loopback"
安全说明：--bind loopback 确保服务只监听 127.0.0.1，外部无法直接访问。如果你需要从局域网其他设备访问，可将 --bind loopback 改为 --bind lan，但必须同时配置防火墙和强认证，且不建议直接暴露到公网 。
五、验证运行状态
bash
Copy
# 查看容器日志
docker logs -f openclaw

# 确认端口绑定正确（应显示 127.0.0.1:18789）
docker port openclaw

# 查看容器状态
docker ps | grep openclaw
六、设备配对与初始化
打开浏览器，访问 http://127.0.0.1:18789/overview
输入刚才生成的 Gateway Token，点击 Connect
此时页面可能显示 disconnected (1008): pairing required
在终端执行配对命令：
bash
Copy
# 查看待批准的设备请求
docker exec -it openclaw node openclaw.mjs devices list

# 复制请求 UUID，然后批准它
docker exec -it openclaw node openclaw.mjs devices approve <request-uuid>
刷新浏览器页面，状态变为 Connected 即配对成功
运行初始化向导：
bash
Copy
docker exec -it openclaw node openclaw.mjs onboard
七、安装后的关键加固（必做）
根据你文档中的安全建议，完成以下加固：
1. 强制启用身份认证
确保 OPENCLAW_GATEWAY_TOKEN 已设置（上文已配置），并在配置文件中确认：
bash
Copy
docker exec -it openclaw cat /home/node/.openclaw/openclaw.json
确认包含：
JSON
Copy
{
  "gateway": {
    "auth": {
      "token": "你的64位随机字符串"
    }
  }
}
2. 检查端口绑定
确保没有监听 0.0.0.0，只监听 127.0.0.1：
bash
Copy
sudo ss -tlnp | grep 18789
# 正确输出应包含 127.0.0.1:18789
3. 运行安全扫描
bash
Copy
docker exec -it openclaw node openclaw.mjs security audit
# 或深度扫描
docker exec -it openclaw node openclaw.mjs security audit --deep
4. 防火墙加固（建议）
bash
Copy
# 仅允许本机访问 18789 端口
sudo ufw default deny incoming
sudo ufw allow from 127.0.0.1 to any port 18789
sudo ufw enable
八、日常使用命令
Table
操作	命令
停止容器	docker stop openclaw
启动容器	docker start openclaw
重启容器	docker restart openclaw
查看日志	docker logs -f openclaw
进入容器	docker exec -it openclaw sh
更新镜像	docker pull ghcr.io/openclaw/openclaw:latest && docker restart openclaw
删除容器	docker rm -f openclaw
⚠️ 绝对禁止的操作
不要将 18789 端口直接映射到公网（如 -p 18789:18789）而不配置反向代理 + HTTPS + 强认证
不要在 OpenClaw 中处理银行卡、密码、身份证等敏感信息 — API 密钥默认明文存储，存在泄露风险
不要使用 root 用户运行容器 — 已在上文通过 --user 1000:1000 避免