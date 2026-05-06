#!/bin/bash
# 修复 OpenClaw 配置，启用 API 端点
# 注意: 此文件仅供参考，请使用 deploy_all.sh 或 deploy_openclaw.sh

echo "=== 修复 OpenClaw 配置 ==="
echo "注意: 此脚本仅供参考"
echo "推荐使用: ./deploy_all.sh 或 ./deploy_openclaw/deploy_openclaw.sh"
echo

# 停止现有容器
echo "1. 停止 OpenClaw 容器..."
docker stop openclaw 2>/dev/null || true
docker rm openclaw 2>/dev/null || true

# 等待端口释放
sleep 2

# 重新启动 OpenClaw，绑定到所有接口
echo "2. 重新启动 OpenClaw（绑定到 0.0.0.0）..."
echo "注意: 请将 your_secure_gateway_token_here 替换为实际的 Token"
echo "示例命令:"
echo "  docker run -d \\"
echo "    --name openclaw \\"
echo "    --network host \\"
echo "    -e OPENCLAW_GATEWAY_TOKEN=\"your_secure_gateway_token_here\" \\"
echo "    -v /home/node/.openclaw:/home/node/.openclaw \\"
echo "    --restart unless-stopped \\"
echo "    ghcr.io/openclaw/openclaw:latest \\"
echo "    node openclaw.mjs gateway \\"
echo "    --allow-unconfigured \\"
echo "    --bind 0.0.0.0"
echo

# 验证
echo "3. 验证 OpenClaw 状态..."
echo "   启动后运行: curl -s http://127.0.0.1:18789/healthz"

echo ""
echo "=== 完成 ==="
echo "请使用 deploy_all.sh 或 deploy_openclaw.sh 进行完整部署"
