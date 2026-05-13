#!/bin/bash
# =============================================================================
# DevOpsClaw OpenClaw 部署脚本
# =============================================================================
# 功能：
#   - 部署 OpenClaw 服务
#   - 生成 Gateway Token
#   - 设备管理 (reset, list, approve)
#
# 使用方法：
#   - 独立运行: sudo ./deploy_openclaw/deploy_openclaw.sh
#   - 被主脚本调用: source deploy_openclaw/deploy_openclaw.sh
#
# 端口配置 (新规划):
#   - OpenClaw Web: 18789
#   - OpenClaw Agent: 8080
#   - Nginx OpenClaw: 18442
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
DEPLOY_LOG="${PROJECT_DIR}/deploy.log"
DOCKER_COMPOSE_CMD=""

source "$LIB_DIR/common.sh"

OPENCLAW_PORT_WEB="${OPENCLAW_PORT_WEB:-18789}"
OPENCLAW_PORT_AGENT="${OPENCLAW_PORT_AGENT:-8080}"
OPENCLAW_BIND="${OPENCLAW_BIND:-127.0.0.1}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
OPENCLAW_CONTAINER_NAME="${OPENCLAW_CONTAINER_NAME:-devopsclaw-openclaw}"
OPENCLAW_DATA_DIR="${OPENCLAW_DATA_DIR:-$PROJECT_DIR/data/openclaw}"
OPENCLAW_TOKEN=""
OPENCLAW_TOKEN_FILE="${OPENCLAW_TOKEN_FILE:-$PROJECT_DIR/.openclaw_token}"

generate_openclaw_token() {
    log_step "生成 OpenClaw Gateway Token"
    
    if [[ -f "$OPENCLAW_TOKEN_FILE" ]]; then
        log_info "发现现有 Token 文件: $OPENCLAW_TOKEN_FILE"
        local existing_token
        existing_token=$(cat "$OPENCLAW_TOKEN_FILE")
        if [[ -n "$existing_token" ]]; then
            log_info "使用现有 Token"
            OPENCLAW_TOKEN="$existing_token"
            return 0
        fi
    fi
    
    log_info "生成新的 Gateway Token..."
    OPENCLAW_TOKEN=$(openssl rand -hex 32)
    
    log_info "保存 Token 到: $OPENCLAW_TOKEN_FILE"
    echo "$OPENCLAW_TOKEN" > "$OPENCLAW_TOKEN_FILE"
    chmod 600 "$OPENCLAW_TOKEN_FILE"
    
    return 0
}

deploy_openclaw() {
    log_step "部署 OpenClaw 服务"
    
    if [[ -z "$OPENCLAW_TOKEN" ]]; then
        if [[ -f "$OPENCLAW_TOKEN_FILE" ]]; then
            OPENCLAW_TOKEN=$(cat "$OPENCLAW_TOKEN_FILE")
        else
            generate_openclaw_token
        fi
    fi
    
    if [[ ! -d "$OPENCLAW_DATA_DIR" ]]; then
        log_info "创建 OpenClaw 数据目录: $OPENCLAW_DATA_DIR"
        mkdir -p "$OPENCLAW_DATA_DIR"
    fi
    
    if docker ps -q --filter "name=$OPENCLAW_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "OpenClaw 容器已在运行，停止并删除..."
        docker stop "$OPENCLAW_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$OPENCLAW_CONTAINER_NAME" 2>/dev/null || true
    elif docker ps -aq --filter "name=$OPENCLAW_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "删除已停止的 OpenClaw 容器..."
        docker rm "$OPENCLAW_CONTAINER_NAME" 2>/dev/null || true
    fi

    # 清理旧配置文件（避免残留坏配置导致启动失败）
    if [[ -f "$OPENCLAW_DATA_DIR/openclaw.json" ]]; then
        log_info "清理旧 openclaw.json..."
        rm -f "$OPENCLAW_DATA_DIR/openclaw.json" 2>/dev/null || true
    fi
    
    log_info "创建 OpenClaw 容器..."
    echo "  - 端口 Web: $OPENCLAW_BIND:$OPENCLAW_PORT_WEB -> 18789"
    echo "  - 端口 Agent: $OPENCLAW_BIND:$OPENCLAW_PORT_AGENT -> 8080"
    echo "  - 数据目录: $OPENCLAW_DATA_DIR"
    echo "  - Gateway Token: $OPENCLAW_TOKEN"
    
    # 关键修复: 同步容器时间，防止 device signature expired
    # 原因: 容器和主机时间偏差超过2分钟会导致 WebSocket 认证失败
    log_info "同步系统时间..."
    if command -v ntpdate &>/dev/null; then
        ntpdate -s time.windows.com 2>/dev/null || ntpdate -s pool.ntp.org 2>/dev/null || true
    fi
    
    docker run -d \
        --name "$OPENCLAW_CONTAINER_NAME" \
        --network devopsclaw-network \
        --restart unless-stopped \
        -p "$OPENCLAW_BIND:$OPENCLAW_PORT_WEB:18789" \
        -p "$OPENCLAW_BIND:$OPENCLAW_PORT_AGENT:8080" \
        -v "$OPENCLAW_DATA_DIR:/home/node/.openclaw" \
        -e OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_TOKEN" \
        -e GATEWAY_TOKEN="$OPENCLAW_TOKEN" \
        -e TZ=Asia/Shanghai \
        -e LOG_LEVEL=INFO \
        "$OPENCLAW_IMAGE"
    
    sleep 5
    
    if docker ps -q --filter "name=$OPENCLAW_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "✓ OpenClaw 容器已启动"
        return 0
    else
        log_error "OpenClaw 容器启动失败"
        log_warn "检查日志: docker logs $OPENCLAW_CONTAINER_NAME"
        return 1
    fi
}

reset_openclaw_device() {
    local container_name="${1:-$OPENCLAW_CONTAINER_NAME}"
    local data_dir="${2:-$OPENCLAW_DATA_DIR}"
    
    log_step "重置 OpenClaw 设备（解决 device signature expired 问题）"
    
    if ! docker ps -q --filter "name=$container_name" 2>/dev/null | grep -q .; then
        if ! docker ps -aq --filter "name=$container_name" 2>/dev/null | grep -q .; then
            log_error "OpenClaw 容器不存在: $container_name"
            return 1
        else
            log_warn "OpenClaw 容器未运行"
        fi
    fi
    
    log_info "正在停止 OpenClaw 容器..."
    docker stop "$container_name" 2>/dev/null || true
    
    log_info "正在清除设备签名和配对数据..."
    
    if [[ -d "$data_dir" ]]; then
        log_info "清除 OpenClaw 数据目录: $data_dir"
        
        rm -f "$data_dir/.gateway_token" 2>/dev/null || true
        rm -f "$data_dir/openclaw.json" 2>/dev/null || true
        rm -f "$data_dir/devices.json" 2>/dev/null || true
        rm -f "$data_dir/sessions.json" 2>/dev/null || true
        
        if [[ -d "$data_dir/.cache" ]]; then
            rm -rf "$data_dir/.cache" 2>/dev/null || true
        fi
        
        if [[ -d "$data_dir/.data" ]]; then
            rm -rf "$data_dir/.data" 2>/dev/null || true
        fi
        
        log_info "数据目录已清理"
    else
        log_warn "未找到 OpenClaw 数据目录: $data_dir"
        log_info "尝试通过 Docker 清理容器内部数据..."
        docker rm -f "$container_name" 2>/dev/null || true
    fi
    
    echo
    echo -e "${GREEN}OpenClaw 设备已重置${NC}"
    echo
    log_info "请重新部署 OpenClaw 或手动执行以下步骤:"
    echo
    echo "  1. 重新生成 Gateway Token 并启动容器"
    echo "  2. 访问 http://127.0.0.1:$OPENCLAW_PORT_WEB/overview 进行重新配对"
    echo
}

list_openclaw_devices() {
    local container_name="${1:-$OPENCLAW_CONTAINER_NAME}"
    
    log_step "列出 OpenClaw 待配对设备"
    
    if ! docker ps -q --filter "name=$container_name" 2>/dev/null | grep -q .; then
        log_error "OpenClaw 容器未运行: $container_name"
        log_info "请先启动 OpenClaw 容器"
        return 1
    fi
    
    echo
    echo -e "${CYAN}待配对设备列表:${NC}"
    echo
    
    docker exec "$container_name" node openclaw.mjs devices list 2>/dev/null || {
        log_warn "命令执行失败，尝试查看设备配置文件..."
        docker exec "$container_name" cat /home/node/.openclaw/devices.json 2>/dev/null || echo "  未找到设备"
    }
    echo
}

approve_openclaw_device() {
    local device_uuid="$1"
    local container_name="${2:-$OPENCLAW_CONTAINER_NAME}"
    
    log_step "批准 OpenClaw 设备配对"
    
    if [[ -z "$device_uuid" ]]; then
        log_error "请提供设备 UUID"
        log_info "用法: approve_openclaw_device <UUID>"
        return 1
    fi
    
    if ! docker ps -q --filter "name=$container_name" 2>/dev/null | grep -q .; then
        log_error "OpenClaw 容器未运行: $container_name"
        log_info "请先启动 OpenClaw 容器"
        return 1
    fi
    
    echo
    log_info "正在批准设备: $device_uuid"
    echo
    
    if docker exec "$container_name" node openclaw.mjs devices approve "$device_uuid"; then
        echo
        log_info "设备配对成功!"
        echo
        log_info "请刷新浏览器页面验证连接状态"
        return 0
    else
        log_error "设备批准失败"
        log_info "请检查 UUID 是否正确"
        return 1
    fi
}

print_openclaw_summary() {
    
    echo
    echo -e "${BOLD}${GREEN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${GREEN}│                      OpenClaw 服务状态                           │${NC}"
    echo -e "${BOLD}${GREEN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo
    
    if docker ps -q --filter "name=$OPENCLAW_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "容器: $OPENCLAW_CONTAINER_NAME - 运行中 ✓"
    else
        log_warn "容器: $OPENCLAW_CONTAINER_NAME - 未运行"
    fi
    
    # 检查 Nginx 容器是否在运行
    local nginx_running=false
    if docker ps -q --filter "name=devopsclaw-nginx" 2>/dev/null | grep -q .; then
        nginx_running=true
    fi

    if [[ "$nginx_running" == "true" ]]; then
        echo
        echo -e "${BOLD}OpenClaw 访问地址:${NC}"
        echo -e "  - Nginx HTTPS (推荐): ${CYAN}https://127.0.0.1:18442${NC}"
        echo -e "  - Nginx HTTP: ${CYAN}http://127.0.0.1:18442${NC}"
        echo -e "  - 直连: http://127.0.0.1:$OPENCLAW_PORT_WEB"
        echo -e "  - Agent 端口: $OPENCLAW_PORT_AGENT"
    else
        echo
        echo -e "${BOLD}OpenClaw 访问地址:${NC}"
        echo -e "  - 本地访问: ${CYAN}http://127.0.0.1:$OPENCLAW_PORT_WEB${NC}"
        echo -e "  - 网络访问: ${YELLOW}http://<主机IP>:$OPENCLAW_PORT_WEB${NC}"
        echo -e "  - Agent 端口: $OPENCLAW_PORT_AGENT"
        echo
        echo -e "${YELLOW}提示: Nginx 未运行，如需 HTTPS 访问请先部署 Nginx${NC}"
    fi
    
    echo
    log_info "Gateway Token 文件: $OPENCLAW_TOKEN_FILE"
    
    if [[ -f "$OPENCLAW_TOKEN_FILE" ]]; then
        local token
        token=$(cat "$OPENCLAW_TOKEN_FILE")
        if [[ -n "$token" ]]; then
            echo -e "  Token: ${BOLD}${YELLOW}$token${NC}"
            echo "  Token 文件: $OPENCLAW_TOKEN_FILE"
        fi
    fi
    
    echo
}

configure_allowed_origins() {
    local container_name="${1:-$OPENCLAW_CONTAINER_NAME}"
    local nginx_openclaw_port="${2:-18442}"
    local openclaw_port="${3:-$OPENCLAW_PORT_WEB}"

    log_step "配置 OpenClaw 允许的访问来源 (allowedOrigins)"

    if ! docker ps -q --filter "name=$container_name" 2>/dev/null | grep -q .; then
        log_warn "OpenClaw 容器未运行，跳过 allowedOrigins 配置"
        return 0
    fi

    local origins="[\"http://127.0.0.1:$openclaw_port\", \"http://localhost:$openclaw_port\", \"https://127.0.0.1:$nginx_openclaw_port\", \"https://localhost:$nginx_openclaw_port\"]"

    log_info "配置允许的来源: $origins"

    docker exec "$container_name" node -e "
const fs = require('fs');
const possiblePaths = [
    '/home/node/.openclaw/openclaw.json',
    '/home/openclaw/openclaw.json'
];
let configPath = null;
let config = {};
for (const p of possiblePaths) {
    if (fs.existsSync(p)) {
        configPath = p;
        try {
            config = JSON.parse(fs.readFileSync(p, 'utf8'));
        } catch(e) {
            config = {};
        }
        break;
    }
}
if (!configPath) {
    configPath = possiblePaths[0];
    const dir = require('path').dirname(configPath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}
if (!config.gateway) config.gateway = {};
if (!config.gateway.controlUi) config.gateway.controlUi = {};
config.gateway.controlUi.allowedOrigins = $origins;
// 关键修复: 允许纯 token 认证，跳过设备签名验证
config.gateway.controlUi.allowInsecureAuth = true;
if (!config.gateway.auth) config.gateway.auth = {};
config.gateway.auth.mode = 'token';
// 绑定到 lan，让 Nginx 可以访问（不能用 0.0.0.0，OpenClaw 只接受 loopback/lan/tailnet/auto/custom）
if (!config.gateway.bind) config.gateway.bind = 'lan';
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('allowedOrigins + allowInsecureAuth configured at: ' + configPath);
" 2>/dev/null && {
        log_info "✓ allowedOrigins 配置完成"
    } || {
        log_warn "allowedOrigins 配置失败，请手动配置"
        log_info "手动配置命令:"
        echo "  docker exec $container_name node -e \"const fs=require('fs');const c=JSON.parse(fs.readFileSync('/home/node/.openclaw/openclaw.json','utf8'));c.gateway.controlUi={allowedOrigins:['http://127.0.0.1:$openclaw_port','https://127.0.0.1:$nginx_openclaw_port']};fs.writeFileSync('/home/node/.openclaw/openclaw.json',JSON.stringify(c,null,2))\""
    }

    echo
}

ENV_FILE="${PROJECT_DIR}/.env"
ENV_EXAMPLE="${PROJECT_DIR}/.env.example"

generate_token() {
    local token
    if command -v openssl &>/dev/null; then
        token=$(openssl rand -hex 32)
    elif command -v date &>/dev/null && command -v sha256sum &>/dev/null; then
        token=$(date +%s%N | sha256sum | awk '{print $1}')
    else
        token="devopsclaw_$(date +%s)"
    fi
    echo "$token"
}

deploy_openclaw_standalone() {
    log_step "Phase 1: 清理旧容器和数据卷"

    if docker ps -q --filter "name=$OPENCLAW_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "停止旧 OpenClaw 容器..."
        docker stop "$OPENCLAW_CONTAINER_NAME" 2>/dev/null || true
    fi
    if docker ps -aq --filter "name=$OPENCLAW_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "删除旧 OpenClaw 容器..."
        docker rm -f "$OPENCLAW_CONTAINER_NAME" 2>/dev/null || true
    fi

    local VOLUME_NAME="devopsclaw_openclaw-data"
    if docker volume ls -q --filter "name=$VOLUME_NAME" 2>/dev/null | grep -q .; then
        log_info "清空数据卷: $VOLUME_NAME"
        docker run --rm -v "${VOLUME_NAME}:/data" alpine sh -c "rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null; echo '已清空'" 2>/dev/null || true
    fi

    log_step "Phase 2: 生成 Gateway Token"

    local token
    token=$(generate_token)

    OPENCLAW_TOKEN="$token"
    echo "$token" > "$OPENCLAW_TOKEN_FILE"
    chmod 600 "$OPENCLAW_TOKEN_FILE"
    log_info "Token 已保存到: $OPENCLAW_TOKEN_FILE"

    if [[ -f "$ENV_FILE" ]]; then
        if grep -q "^OPENCLAW_GATEWAY_TOKEN=your_secure_gateway_token_here" "$ENV_FILE" 2>/dev/null; then
            sed -i "s/^OPENCLAW_GATEWAY_TOKEN=your_secure_gateway_token_here$/OPENCLAW_GATEWAY_TOKEN=$token/" "$ENV_FILE"
            log_info "已替换 .env 中的占位 Token"
        elif grep -q "^OPENCLAW_GATEWAY_TOKEN=" "$ENV_FILE" 2>/dev/null; then
            sed -i "s/^OPENCLAW_GATEWAY_TOKEN=.*$/OPENCLAW_GATEWAY_TOKEN=$token/" "$ENV_FILE"
            log_info "已更新 .env 中的 Token"
        else
            echo "OPENCLAW_GATEWAY_TOKEN=$token" >> "$ENV_FILE"
            log_info "已追加 Token 到 .env"
        fi
    else
        cp "$ENV_EXAMPLE" "$ENV_FILE"
        sed -i "s/^OPENCLAW_GATEWAY_TOKEN=your_secure_gateway_token_here$/OPENCLAW_GATEWAY_TOKEN=$token/" "$ENV_FILE"
        log_info "已创建 .env 并写入 Token"
    fi

    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  你的 Gateway Token（请复制保存）：${NC}"
    echo -e "${BOLD}${YELLOW}  $token${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}\n"

    log_step "Phase 3: 预写入 openclaw.json 到数据卷"

    docker run --rm -v "${VOLUME_NAME}:/data" alpine sh -c "cat > /data/openclaw.json << 'INNEREOF'
{
  \"gateway\": {
    \"mode\": \"local\",
    \"auth\": {
      \"token\": \"$token\"
    },
    \"controlUi\": {
      \"allowedOrigins\": [
        \"http://127.0.0.1:18789\",
        \"http://localhost:18789\",
        \"https://127.0.0.1:18442\",
        \"https://localhost:18442\"
      ]
    },
    \"trustedProxies\": [
      \"127.0.0.1\",
      \"::1\",
      \"172.16.0.0/12\",
      \"10.0.0.0/8\",
      \"192.168.0.0/16\"
    ]
  }
}
INNEREOF" 2>/dev/null && log_info "✓ openclaw.json 已写入数据卷（含 token 认证 + mode=local）" || log_warn "openclaw.json 写入失败"

    log_step "Phase 4: 部署 OpenClaw 容器（token 认证模式）"

    local OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
    local OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
    local OPENCLAW_BIND="${OPENCLAW_BIND:-127.0.0.1}"

    log_info "镜像: $OPENCLAW_IMAGE"
    log_info "端口: $OPENCLAW_BIND:$OPENCLAW_PORT"

    docker run -d \
        --name "$OPENCLAW_CONTAINER_NAME" \
        --network devopsclaw-network \
        --restart unless-stopped \
        --user "1000:1000" \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=64m \
        -p "${OPENCLAW_BIND}:${OPENCLAW_PORT}:18789" \
        -v "${VOLUME_NAME}:/home/node/.openclaw" \
        -e "OPENCLAW_GATEWAY_TOKEN=$token" \
        -e "LOG_LEVEL=${LOG_LEVEL:-INFO}" \
        -e "TZ=Asia/Shanghai" \
        "$OPENCLAW_IMAGE" \
        node openclaw.mjs gateway --bind lan 2>/dev/null

    log_info "等待容器启动（最多 90 秒）..."
    local waited=0
    while [[ $waited -lt 90 ]]; do
        if docker ps --filter "name=$OPENCLAW_CONTAINER_NAME" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
            sleep 3
            if docker exec "$OPENCLAW_CONTAINER_NAME" curl -sf http://127.0.0.1:18789/health 2>/dev/null; then
                log_info "✓ OpenClaw 容器已就绪"
                break
            fi
        fi
        sleep 5
        waited=$((waited + 5))
        echo -n "."
    done
    echo

    if ! docker ps -q --filter "name=$OPENCLAW_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_error "OpenClaw 容器启动失败"
        log_info "查看日志: docker logs $OPENCLAW_CONTAINER_NAME"
        exit 1
    fi

    log_step "Phase 5: 运行 onboard 初始化设备"

    log_info "执行 onboard --mode local（生成设备签名，解决 device signature expired）"
    echo "y" | docker exec -i "$OPENCLAW_CONTAINER_NAME" node openclaw.mjs onboard --mode local 2>&1 | tee -a "${DEPLOY_LOG:-}" || true
    log_info "onboard 完成，重启容器使设备签名生效..."

    docker restart "$OPENCLAW_CONTAINER_NAME" 2>/dev/null
    sleep 10

    log_info "设备初始化完成"

    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              OpenClaw 部署完成                                ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}访问地址:${NC}"
    echo -e "  直连 (token):      ${CYAN}http://127.0.0.1:18789/#token=${token}${NC}"
    echo -e "  Nginx (token):     ${CYAN}https://127.0.0.1:18442/#token=${token}${NC}"
    echo
    echo -e "${BOLD}Gateway Token:${NC}"
    echo -e "  ${YELLOW}$token${NC}"
    echo
    echo -e "${BOLD}Token 保存位置:${NC}"
    echo -e "  - $OPENCLAW_TOKEN_FILE"
    echo -e "  - $ENV_FILE (OPENCLAW_GATEWAY_TOKEN)"
    echo
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"

    OPENCLAW_STANDALONE_DONE=true
    export OPENCLAW_STANDALONE_DONE
}

show_help() {
    echo
    echo -e "${BOLD}DevOpsClaw OpenClaw 部署脚本${NC}"
    echo
    echo -e "用法: $0 [选项]"
    echo
    echo -e "选项:"
    echo -e "  ${CYAN}-h, --help${NC}                      显示此帮助信息"
    echo -e "  ${CYAN}--standalone${NC}                    一键部署/修复 OpenClaw（清数据+Token+部署+onboard+摘要）"
    echo -e "  ${CYAN}--deploy${NC}                        部署 OpenClaw 服务 (默认)"
    echo -e "  ${CYAN}--generate-token${NC}                生成 Gateway Token"
    echo -e "  ${CYAN}--reset-device${NC}                  重置 OpenClaw 设备"
    echo -e "  ${CYAN}--list-devices${NC}                  列出待配对设备"
    echo -e "  ${CYAN}--approve-device <UUID>${NC}         批准设备配对"
    echo -e "  ${CYAN}--status${NC}                        查看服务状态"
    echo -e "  ${CYAN}--stop${NC}                          停止服务"
    echo -e "  ${CYAN}--start${NC}                         启动服务"
    echo -e "  ${CYAN}--restart${NC}                       重启服务"
    echo
    echo -e "环境变量:"
    echo -e "  OPENCLAW_PORT_WEB=${OPENCLAW_PORT_WEB}   OpenClaw Web 端口"
    echo -e "  OPENCLAW_CONTAINER_NAME=${OPENCLAW_CONTAINER_NAME}"
    echo
    echo -e "示例:"
    echo -e "  $0                              部署 OpenClaw"
    echo -e "  $0 --standalone                 一键部署/修复 OpenClaw（推荐）"
    echo -e "  $0 --generate-token             生成 Token"
    echo -e "  $0 --reset-device               重置设备"
    echo -e "  $0 --list-devices               列出设备"
    echo -e "  $0 --approve-device <UUID>      批准设备"
    echo
}

main() {
    local action="deploy"
    local device_uuid=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --deploy)
                action="deploy"
                shift
                ;;
            --generate-token)
                action="generate_token"
                shift
                ;;
            --reset-device)
                action="reset_device"
                shift
                ;;
            --list-devices)
                action="list_devices"
                shift
                ;;
            --approve-device)
                action="approve_device"
                device_uuid="$2"
                shift 2
                ;;
            --status)
                action="status"
                shift
                ;;
            --stop)
                action="stop"
                shift
                ;;
            --start)
                action="start"
                shift
                ;;
            --restart)
                action="restart"
                shift
                ;;
            --standalone)
                action="standalone"
                shift
                ;;
            *)
                log_warn "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    log_banner
    
    case "$action" in
        deploy)
            check_root
            check_docker
            if [[ -f "$PROJECT_DIR/.env" ]]; then
                load_env "$PROJECT_DIR/.env"
            fi
            generate_openclaw_token
            deploy_openclaw
            configure_allowed_origins
            print_openclaw_summary
            log_info "OpenClaw 部署完成!"
            ;;
        generate_token)
            generate_openclaw_token
            log_info "Gateway Token 已生成"
            ;;
        reset_device)
            check_root
            check_docker
            reset_openclaw_device
            ;;
        list_devices)
            check_root
            check_docker
            list_openclaw_devices
            ;;
        approve_device)
            check_root
            check_docker
            approve_openclaw_device "$device_uuid"
            ;;
        status)
            print_openclaw_summary "standalone"
            ;;
        stop)
            check_root
            log_step "停止 OpenClaw 服务"
            docker stop "$OPENCLAW_CONTAINER_NAME" 2>/dev/null || true
            log_info "OpenClaw 已停止"
            ;;
        start)
            check_root
            log_step "启动 OpenClaw 服务"
            docker start "$OPENCLAW_CONTAINER_NAME" 2>/dev/null
            log_info "OpenClaw 已启动"
            ;;
        restart)
            check_root
            log_step "重启 OpenClaw 服务"
            docker restart "$OPENCLAW_CONTAINER_NAME" 2>/dev/null
            log_info "OpenClaw 已重启"
            ;;
        standalone)
            check_root
            check_docker
            if [[ -f "$PROJECT_DIR/.env" ]]; then
                load_env "$PROJECT_DIR/.env"
            fi
            deploy_openclaw_standalone
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
