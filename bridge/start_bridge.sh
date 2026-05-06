#!/bin/bash
# 启动 Bridge 服务
# 注意: Bridge 服务已整合为 OpenClaw Skill，此文件仅供参考

cd "$(dirname "$0")"

# 加载环境变量
# 请从 .env 文件或环境变量中获取真实的 Token
export OPENCLAW_GATEWAY_TOKEN="your_secure_gateway_token_here"
export JENKINS_URL="http://127.0.0.1:8081"
export JENKINS_USER="your_jenkins_user"
export JENKINS_TOKEN="your_jenkins_api_token_here"
export DRY_RUN="true"
export MAX_RETRY="5"
export BRIDGE_PORT="5000"
export STATE_FILE="./.self-heal-state.json"
export LOG_FILE="./bridge.log"

echo "注意: Bridge 服务已整合为 OpenClaw Skill"
echo "请使用 deploy_all.sh 部署完整的 DevOpsClaw 系统"
echo "或直接使用 OpenClaw 的 Skill 功能"
# python3 bridge.py
