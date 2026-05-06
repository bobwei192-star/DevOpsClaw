#!/bin/bash
# --------------------------- 安装依赖 ---------------------------
apt-get update -qq
apt-get install -y -qq openssh-client

# =============================================================================
# OpenClaw Docker 一键安全安装脚本 (Ubuntu) - 修订版
# =============================================================================
# 修订记录:
#   - Token 生成去掉 echo ''，避免末尾换行符
#   - --read-only 添加 --tmpfs /tmp 解决临时文件写入失败
#   - 添加 --workdir 指定工作目录
#   - 目录权限显式设为 750
#   - 内存检查增加容错
#   - 修正 ufw 对 Docker 端口管控的说明
#   - 添加日志轮转建议
#   - 脚本开头安装必要依赖
#
# 使用方法:
#   1. 赋予执行权限: chmod +x install_openclaw.sh
#   2. 运行脚本:     sudo ./install_openclaw.sh
# --------------------------- 启动/停止 方法 ---------------------------
#
# 【方法一：Docker 命令】
#   启动容器:  docker start openclaw
#   停止容器:  docker stop openclaw
#   查看状态:  docker ps | grep openclaw
#   查看日志:  docker logs -f openclaw
#   重启容器:  docker restart openclaw
#
# 【方法二：Systemd 服务】（脚本会自动创建）
#   启动服务:  sudo systemctl start openclaw
#   停止服务:  sudo systemctl stop openclaw
#   查看状态:  sudo systemctl status openclaw
#   开机自启:  sudo systemctl enable openclaw
#   禁用自启:  sudo systemctl disable openclaw
#
    # 方法三：
    # # 2. 重新初始化（用 host 网络，去掉 --bind loopback）
    # docker run -d \
    #   --name openclaw \
    #   --restart unless-stopped \
    #   --user 1000:1000 \
    #   --cap-drop=ALL \
    #   --security-opt=no-new-privileges \
    #   --read-only \
    #   --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    #   --network host \
    #   -v /home/openclaw:/home/node/.openclaw \
    #   -e OPENCLAW_GATEWAY_TOKEN="wdO8hDwotUBGIcfNNio6O1jNtPwLbdsM6tsrPVY643DmoGLUVYnkYt6APZcBAy3q" \
    #   ghcr.io/openclaw/openclaw:latest \
    #   node openclaw.mjs gateway --allow-unconfigured

    # # 3. 等待 ready
    # docker logs -f openclaw

# =============================================================================

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置变量
OPENCLAW_DIR="/home/openclaw"
CONTAINER_NAME="openclaw"
IMAGE="ghcr.io/openclaw/openclaw:latest"
PORT="18789"

# 日志函数
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行，请使用 sudo"
        exit 1
    fi
}

# 检查系统
check_system() {
    log_step "检查系统环境"

    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        log_warn "未检测到 Ubuntu 系统，脚本可能不完全兼容"
    fi

    ARCH=$(dpkg --print-architecture)
    log_info "系统架构: $ARCH"

    # 内存检查（增加容错，处理 free 输出异常的情况）
    MEM_TOTAL=0
    if command -v free &>/dev/null; then
        MEM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)
    fi

    if [[ -z "$MEM_TOTAL" || "$MEM_TOTAL" == "" || "$MEM_TOTAL" -eq 0 ]]; then
        # 备用方案：读取 /proc/meminfo
        MEM_TOTAL=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    fi

    if [[ "$MEM_TOTAL" -lt 2048 ]]; then
        log_warn "内存仅 ${MEM_TOTAL}MB，建议至少 2GB"
    else
        log_info "内存: ${MEM_TOTAL}MB ✓"
    fi
}

# 安装 Docker
install_docker() {
    log_step "安装 Docker"

    if command -v docker &> /dev/null && docker --version &> /dev/null; then
        log_info "Docker 已安装: $(docker --version)"
    else
        log_info "正在安装 Docker..."
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl gnupg lsb-release software-properties-common

        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"             > /etc/apt/sources.list.d/docker.list

        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

        systemctl enable docker --now

        log_info "Docker 安装完成: $(docker --version)"
    fi

    if docker compose version &> /dev/null || docker-compose --version &> /dev/null; then
        log_info "Docker Compose 可用"
    else
        log_warn "Docker Compose 插件未找到，尝试安装..."
        apt-get install -y -qq docker-compose-plugin
    fi
}

# 创建专用目录
create_directories() {
    log_step "创建 OpenClaw 专用目录"

    mkdir -p "$OPENCLAW_DIR/workspace"

    # 设置 UID 1000:1000 所有权
    chown -R 1000:1000 "$OPENCLAW_DIR"

    # 显式设置目录权限，防止明文 Token 被其他用户读取
    chmod 750 "$OPENCLAW_DIR"

    log_info "目录所有权已设置为 1000:1000"
    log_info "目录权限已设置为 750"
    log_info "工作目录: $OPENCLAW_DIR"
}

# 生成 Gateway Token
generate_token() {
    log_step "生成高强度 Gateway Token"

    if [[ -f "$OPENCLAW_DIR/.gateway_token" ]]; then
        log_warn "已存在旧的 Token 文件，自动使用已有 Token"
        OPENCLAW_GATEWAY_TOKEN=$(tr -d '\n' < "$OPENCLAW_DIR/.gateway_token")
        log_info "使用已有 Token"
        return
    fi

    # 修复：去掉 echo ''，避免末尾换行符
    OPENCLAW_GATEWAY_TOKEN=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64)
    printf '%s' "$OPENCLAW_GATEWAY_TOKEN" > "$OPENCLAW_DIR/.gateway_token"
    chmod 600 "$OPENCLAW_DIR/.gateway_token"
    chown 1000:1000 "$OPENCLAW_DIR/.gateway_token"

    log_info "Gateway Token 已生成并保存到 $OPENCLAW_DIR/.gateway_token"
    log_warn "请妥善保存以下 Token（仅显示一次）:"
    echo -e "${YELLOW}$OPENCLAW_GATEWAY_TOKEN${NC}"
    echo ""
    log_info "Token 已保存，继续执行安装..."
}

# 拉取镜像
pull_image() {
    log_step "拉取 OpenClaw 官方镜像"

    log_info "正在拉取 $IMAGE ..."
    if docker pull "$IMAGE"; then
        log_info "镜像拉取成功"
    else
        log_error "镜像拉取失败，请检查网络连接"
        exit 1
    fi
}

# 清理旧容器
cleanup_old() {
    log_step "清理旧容器"

    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_warn "检测到已存在的 openclaw 容器"
        docker stop "$CONTAINER_NAME" &>/dev/null || true
        docker rm "$CONTAINER_NAME" &>/dev/null || true
        log_info "旧容器已清理"
    fi
}

# 启动容器
start_container() {
    log_step "启动 OpenClaw 容器"

    # 修复：添加 --tmpfs /tmp 解决 --read-only 导致的临时文件写入失败
    # 注意：使用默认入口命令，不指定 --bind loopback，避免 IPv4/IPv6 绑定问题
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --user 1000:1000 \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=64m \
        -p "127.0.0.1:${PORT}:${PORT}" \
        -v "$OPENCLAW_DIR:/home/node/.openclaw" \
        -e "OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN" \
        "$IMAGE"

    if [[ $? -eq 0 ]]; then
        log_info "容器启动成功"
    else
        log_error "容器启动失败"
        exit 1
    fi

    log_info "等待服务启动（约 30 秒）..."
    sleep 30

    # 关键修复：将 token 写入配置文件，确保认证生效
    # OpenClaw 优先使用配置文件中的 token，而非环境变量
    log_info "配置 Gateway Token 到 openclaw.json..."
    docker exec "$CONTAINER_NAME" sh -c "cat > /home/node/.openclaw/openclaw.json << EOF
{
  \"gateway\": {
    \"auth\": {
      \"mode\": \"token\",
      \"token\": \"$OPENCLAW_GATEWAY_TOKEN\"
    },
    \"controlUi\": {
      \"allowedOrigins\": [
        \"http://localhost:${PORT}\",
        \"http://127.0.0.1:${PORT}\"
      ]
    }
  }
}
EOF"

    log_info "重启容器使配置生效..."
    docker restart "$CONTAINER_NAME" > /dev/null
    sleep 10
}

# 验证运行状态
verify_status() {
    log_step "验证运行状态"

    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "容器未在运行"
        docker logs "$CONTAINER_NAME" --tail 50
        exit 1
    fi

    log_info "容器运行状态: ✓"

    PORT_BIND=$(docker port "$CONTAINER_NAME" 2>/dev/null | grep "$PORT" || true)
    if echo "$PORT_BIND" | grep -q "127.0.0.1"; then
        log_info "端口绑定正确: 127.0.0.1:$PORT ✓"
    else
        log_warn "端口绑定: $PORT_BIND"
    fi

    if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:$PORT"; then
        log_info "服务监听在 127.0.0.1:$PORT ✓"
    fi
}

# 创建 Systemd 服务
create_systemd_service() {
    log_step "创建 Systemd 服务"

    cat > /etc/systemd/system/openclaw.service << 'EOF'
[Unit]
Description=OpenClaw AI Gateway (Docker)
Documentation=https://openclaw.ai/docs
Requires=docker.service
After=docker.service network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start openclaw
ExecStop=/usr/bin/docker stop -t 30 openclaw
ExecStopPost=/usr/bin/docker rm -f openclaw
ExecReload=/usr/bin/docker restart openclaw

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable openclaw.service

    log_info "Systemd 服务已创建: openclaw.service"
    log_info "  启动: sudo systemctl start openclaw"
    log_info "  停止: sudo systemctl stop openclaw"
    log_info "  状态: sudo systemctl status openclaw"
}

# 显示配对指引
show_pairing_guide() {
    log_step "设备配对指引"

    TOKEN=$(tr -d '\n' < "$OPENCLAW_DIR/.gateway_token" 2>/dev/null || echo "<Token>")

    cat << EOF

${GREEN}╔══════════════════════════════════════════════════════════════╗
║                    OpenClaw 安装完成                         ║
╚══════════════════════════════════════════════════════════════╝${NC}

${BLUE}1. 浏览器访问:${NC}
   http://127.0.0.1:${PORT}/overview

${BLUE}2. 输入 Gateway Token:${NC}
   ${YELLOW}$TOKEN${NC}

${BLUE}3. 点击 Connect 后，若显示 "pairing required"，执行:${NC}
   docker exec -it openclaw node openclaw.mjs devices list
   docker exec -it openclaw node openclaw.mjs devices approve <UUID>

${BLUE}4. 配对成功后运行初始化:${NC}
   docker exec -it openclaw node openclaw.mjs onboard

${BLUE}5. 安全扫描:${NC}
   docker exec -it openclaw node openclaw.mjs security audit
   docker exec -it openclaw node openclaw.mjs security audit --deep

${GREEN}────────────────── 启动/停止 命令速查 ──────────────────${NC}

  Docker 方式:
    启动:  docker start openclaw
    停止:  docker stop openclaw
    日志:  docker logs -f openclaw

  Systemd 方式:
    启动:  sudo systemctl start openclaw
    停止:  sudo systemctl stop openclaw
    自启:  sudo systemctl enable openclaw
    禁用:  sudo systemctl disable openclaw

${YELLOW}────────────────── 日志轮转建议 ──────────────────${NC}

  防止容器日志写爆磁盘，配置 Docker 日志轮转:

  编辑 /etc/docker/daemon.json:
  {
    "log-driver": "json-file",
    "log-opts": {
      "max-size": "10m",
      "max-file": "3"
    }
  }

  然后执行: sudo systemctl restart docker

${RED}⚠️  安全提醒:${NC}
  • 不要将端口直接暴露到公网
  • 不要在 OpenClaw 中处理银行卡、密码等敏感信息
  • Docker 端口映射会直接操作 iptables，ufw 无法管控 Docker 暴露的端口
  • 由于已绑定 127.0.0.1，外部本身不可达，但仍建议配置防火墙作为第二层防御
  • 定期运行 security audit 检查环境

EOF
}

# 主函数
main() {
    echo -e "${GREEN}"
    cat << 'EOF'
   ____                   ___________      __        
  / __ \____  ___  ____  / ____/ __ )____/ /___ ___ 
 / / / / __ \/ _ \/ __ \/ /   / __  / __  / __ `__ / /_/ / /_/ /  __/ / / / /___/ /_/ / /_/ / / / / / /
\____/ .___/\___/_/ /_/\____/_____/\__,_/_/ /_/ /_/ 
    /_/                                                
EOF
    echo -e "${NC}"

    log_info "OpenClaw Docker 安全安装脚本（修订版）"
    log_info "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"

    check_root
    check_system
    install_docker
    create_directories
    generate_token
    pull_image
    cleanup_old
    start_container
    verify_status
    create_systemd_service
    show_pairing_guide

    log_info "安装完成!"
}

trap 'log_error "脚本被中断"; exit 1' INT TERM

main "$@"