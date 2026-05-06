#!/bin/bash
# 启动 Bridge 服务

cd "$(dirname "$0")"

# 加载环境变量
export OPENCLAW_GATEWAY_TOKEN="wdO8hDwotUBGIcfNNio6O1jNtPwLbdsM6tsrPVY643DmoGLUVYnkYt6APZcBAy3q"
export JENKINS_URL="http://127.0.0.1:8081"
export JENKINS_USER="zhangsan"
export JENKINS_TOKEN="11b28ded03fd5260903f1d6c3a6c8a8c22"
export DRY_RUN="true"
export MAX_RETRY="5"
export BRIDGE_PORT="5000"
export STATE_FILE="/home/worker/software/AI/CICD/openclaw/.self-heal-state.json"
export LOG_FILE="/home/worker/software/AI/CICD/openclaw/bridge.log"

echo "启动 Bridge 服务..."
python3 bridge.py
