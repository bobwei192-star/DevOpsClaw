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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ -n "$DEPLOY_LOG" ]]; then
        echo -e "${GREEN}[INFO]${NC} $timestamp - $msg" | tee -a "$DEPLOY_LOG"
    else
        echo -e "${GREEN}[INFO]${NC} $timestamp - $msg"
    fi
}

log_warn() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ -n "$DEPLOY_LOG" ]]; then
        echo -e "${YELLOW}[WARN]${NC} $timestamp - $msg" | tee -a "$DEPLOY_LOG"
    else
        echo -e "${YELLOW}[WARN]${NC} $timestamp - $msg"
    fi
}

log_error() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ -n "$DEPLOY_LOG" ]]; then
        echo -e "${RED}[ERROR]${NC} $timestamp - $msg" | tee -a "$DEPLOY_LOG"
    else
        echo -e "${RED}[ERROR]${NC} $timestamp - $msg"
    fi
}

log_step() {
    local msg="$1"
    echo -e "\n${BLUE}=== $msg ===${NC}"
}

log_banner() {
    echo -e "${PURPLE}"
    cat << 'EOF'
  ____             ____  _             ____ _                    
 |  _ \  _____   _/ ___|| | _____     / ___| | __ ___      ____
 | | | |/ _ \ \ / /\___ \| |/ _ \ \   / /   | |/ _` \ \ /\ / /
 | |_| |  __/\ V /  ___) | | (_) \ \_/ /    | | (_| |\ V  V / 
 |____/ \___| \_/  |____/|_|\___/ \___/     |_|\__,_| \_/\_/  
                                                                   
EOF
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        log_info "请使用: sudo $0"
        exit 1
    fi
}

check_docker() {
    log_step "检查 Docker 环境"
    
    if ! command -v docker &>/dev/null; then
        log_error "Docker 未安装"
        log_info "请先运行: $PROJECT_DIR/deploy_docker/install_docker.sh"
        exit 1
    fi
    
    log_info "Docker 已安装: $(docker --version)"
    
    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
        log_info "Docker Compose (plugin) 已安装"
    elif command -v docker-compose &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
        log_info "Docker Compose (standalone) 已安装"
    else
        log_error "Docker Compose 未安装"
        exit 1
    fi
}

load_env() {
    local env_file="$1"
    
    if [[ -f "$env_file" ]]; then
        log_info "加载环境变量: $env_file"
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^[A-Z_]+= ]]; then
                var_name="${line%%=*}"
                var_value="${line#*=}"
                var_value="${var_value//\"/}"
                var_value="${var_value//\'/}"
                export "$var_name"="$var_value"
            fi
        done < "$env_file"
    else
        log_warn "环境变量文件不存在: $env_file"
    fi
}

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
    
    log_info "创建 OpenClaw 容器..."
    echo "  - 端口 Web: $OPENCLAW_BIND:$OPENCLAW_PORT_WEB -> 18789"
    echo "  - 端口 Agent: $OPENCLAW_BIND:$OPENCLAW_PORT_AGENT -> 8080"
    echo "  - 数据目录: $OPENCLAW_DATA_DIR"
    echo "  - Gateway Token: $OPENCLAW_TOKEN"
    
    docker run -d \
        --name "$OPENCLAW_CONTAINER_NAME" \
        --network devopsclaw-network \
        --restart unless-stopped \
        -p "$OPENCLAW_BIND:$OPENCLAW_PORT_WEB:18789" \
        -p "$OPENCLAW_BIND:$OPENCLAW_PORT_AGENT:8080" \
        -v "$OPENCLAW_DATA_DIR:/home/openclaw" \
        -e OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_TOKEN" \
        -e GATEWAY_TOKEN="$OPENCLAW_TOKEN" \
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
    local mode="${1:-standalone}"
    
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
    
    if [[ "$mode" == "without_nginx" ]]; then
        echo
        echo -e "${BOLD}OpenClaw 访问地址:${NC}"
        echo -e "  - 本地访问: ${CYAN}http://127.0.0.1:$OPENCLAW_PORT_WEB${NC}"
        echo -e "  - 网络访问: ${YELLOW}http://<主机IP>:$OPENCLAW_PORT_WEB${NC}"
        echo -e "  - Agent 端口: $OPENCLAW_PORT_AGENT"
    elif [[ "$mode" == "with_nginx" ]]; then
        echo
        echo -e "${BOLD}OpenClaw 访问地址:${NC}"
        echo -e "  - Nginx (推荐): ${CYAN}http://127.0.0.1:18442${NC}"
        echo -e "  - 直连: http://127.0.0.1:$OPENCLAW_PORT_WEB"
        echo -e "  - Agent 端口: $OPENCLAW_PORT_AGENT"
    fi
    
    echo
    log_info "Gateway Token 文件: $OPENCLAW_TOKEN_FILE"
    
    if [[ -f "$OPENCLAW_TOKEN_FILE" ]]; then
        local token
        token=$(cat "$OPENCLAW_TOKEN_FILE")
        if [[ -n "$token" ]]; then
            log_info "当前 Token: ${token:0:8}...${token: -8}"
        fi
    fi
    
    echo
}

show_help() {
    echo
    echo -e "${BOLD}DevOpsClaw OpenClaw 部署脚本${NC}"
    echo
    echo -e "用法: $0 [选项]"
    echo
    echo -e "选项:"
    echo -e "  ${CYAN}-h, --help${NC}                      显示此帮助信息"
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
            print_openclaw_summary "without_nginx"
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
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
