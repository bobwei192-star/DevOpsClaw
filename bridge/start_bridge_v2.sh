#!/bin/bash
# 启动 Bridge v2 服务

cd "$(dirname "$0")"

# 加载环境变量（从 .env 文件读取）
if [ -f .env ]; then
    set -a
    source .env
    set +a
    echo "已从 .env 加载配置"
fi

echo "启动 Bridge v2 服务..."
echo "DRY_RUN: $DRY_RUN"
python3 bridge_v2.py
