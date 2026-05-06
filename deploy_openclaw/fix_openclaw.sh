#!/bin/bash
# 修复 OpenClaw 配置，启用 API 端点

echo "=== 修复 OpenClaw 配置 ==="

# 停止现有容器
echo "1. 停止 OpenClaw 容器..."
docker stop openclaw 2>/dev/null || true
docker rm openclaw 2>/dev/null || true

# 等待端口释放
sleep 2

# 重新启动 OpenClaw，绑定到所有接口
echo "2. 重新启动 OpenClaw（绑定到 0.0.0.0）..."
docker run -d \
  --name openclaw \
  --network host \
  -e OPENCLAW_GATEWAY_TOKEN="wdO8hDwotUBGIcfNNio6O1jNtPwLbdsM6tsrPVY643DmoGLUVYnkYt6APZcBAy3q" \
  -v /home/node/.openclaw:/home/node/.openclaw \
  --restart unless-stopped \
  ghcr.io/openclaw/openclaw:latest \
  node openclaw.mjs gateway \
  --allow-unconfigured \
  --bind 0.0.0.0

echo "3. 等待 OpenClaw 启动..."
sleep 5

# 验证
echo "4. 验证 OpenClaw 状态..."
curl -s http://127.0.0.1:18789/healthz

echo ""
echo "=== 完成 ==="
echo "OpenClaw 已重启，现在可以通过以下地址访问："
echo "  - 本地: http://127.0.0.1:18789"
echo "  - 外部: http://192.168.43.17:18789"
