#!/bin/bash
# =============================================================================
# DevOpsClaw 通用库文件
# =============================================================================
# 包含：颜色定义、日志函数、通用工具函数
# 使用方法：source lib/common.sh
#
# =============================================================================

# =============================================================================
# 颜色定义
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# 日志函数
# =============================================================================
log_info() {
    local msg="$1"
    local log_file="${DEPLOY_LOG:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local output="${GREEN}[INFO]${NC} $timestamp - $msg"
    
    if [[ -n "$log_file" ]]; then
        echo -e "$output" | tee -a "$log_file"
    else
        echo -e "$output"
    fi
}

log_warn() {
    local msg="$1"
    local log_file="${DEPLOY_LOG:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local output="${YELLOW}[WARN]${NC} $timestamp - $msg"
    
    if [[ -n "$log_file" ]]; then
        echo -e "$output" | tee -a "$log_file"
    else
        echo -e "$output"
    fi
}

log_error() {
    local msg="$1"
    local log_file="${DEPLOY_LOG:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local output="${RED}[ERROR]${NC} $timestamp - $msg"
    
    if [[ -n "$log_file" ]]; then
        echo -e "$output" | tee -a "$log_file"
    else
        echo -e "$output"
    fi
}

log_step() {
    local msg="$1"
    local log_file="${DEPLOY_LOG:-}"
    local output="\n${BLUE}=== $msg ===${NC}"
    
    if [[ -n "$log_file" ]]; then
        echo -e "$output" | tee -a "$log_file"
    else
        echo -e "$output"
    fi
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

# =============================================================================
# 检查函数
# =============================================================================

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
        log_info "请先安装 Docker 或运行: deploy_docker/install_docker.sh"
        exit 1
    fi
    
    log_info "Docker 已安装: $(docker --version)"
    
    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
        log_info "Docker Compose (plugin) 已安装: $(docker compose version --short 2>/dev/null || echo "可用")"
    elif command -v docker-compose &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
        log_info "Docker Compose (standalone) 已安装: $(docker-compose version --short 2>/dev/null || echo "可用")"
    else
        log_error "Docker Compose 未安装"
        exit 1
    fi
    
    export DOCKER_COMPOSE_CMD
}

# =============================================================================
# 环境变量函数
# =============================================================================

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

# =============================================================================
# 端口检查函数
# =============================================================================

check_port() {
    local port="$1"
    local service="$2"
    
    if netstat -tlnp 2>/dev/null | grep -q ":$port " || ss -tlnp 2>/dev/null | grep -q ":$port "; then
        log_warn "端口 $port ($service) 已被占用"
        return 1
    else
        log_info "端口 $port ($service) 可用 ✓"
        return 0
    fi
}

# =============================================================================
# 多源镜像拉取函数
# =============================================================================

pull_image_with_fallback() {
    local service="$1"
    local target_tag="${2:-}"
    
    local -a sources=()
    local -a source_names=()
    
    case "$service" in
        openclaw)
            sources=(
                "ghcr.io/openclaw/openclaw:latest"
                "docker.io/openclaw/openclaw:latest"
            )
            source_names=(
                "github-ghcr"
                "dockerhub"
            )
            ;;
        jenkins)
            sources=(
                "docker.io/jenkins/jenkins:lts-jdk17"
                "registry.cn-hangzhou.aliyuncs.com/library/jenkins:lts-jdk17"
                "docker.mirrors.sjtug.sjtu.edu.cn/library/jenkins:lts-jdk17"
            )
            source_names=(
                "dockerhub"
                "aliyun"
                "sjtug"
            )
            ;;
        gitlab)
            sources=(
                "docker.io/gitlab/gitlab-ce:latest"
                "registry.cn-hangzhou.aliyuncs.com/gitlab/gitlab-ce:latest"
                "docker.mirrors.sjtug.sjtu.edu.cn/gitlab/gitlab-ce:latest"
            )
            source_names=(
                "dockerhub"
                "aliyun"
                "sjtug"
            )
            ;;
        nginx)
            sources=(
                "docker.io/library/nginx:alpine"
                "registry.cn-hangzhou.aliyuncs.com/library/nginx:alpine"
                "docker.mirrors.sjtug.sjtu.edu.cn/library/nginx:alpine"
            )
            source_names=(
                "dockerhub"
                "aliyun"
                "sjtug"
            )
            ;;
        *)
            log_error "未知服务: $service"
            return 1
            ;;
    esac
    
    local max_retries=2
    local pull_timeout=120
    local success=false
    local pulled_image=""
    
    log_info "尝试拉取 $service 镜像（支持多源重试，每个源最多 $max_retries 次，超时 $pull_timeout 秒）..."
    
    local idx=0
    for image in "${sources[@]}"; do
        local source_name="${source_names[$idx]:-$idx}"
        idx=$((idx + 1))
        
        if [[ -z "$image" ]]; then
            continue
        fi
        
        log_info "尝试源 [$source_name]: $image"
        
        for ((i=1; i<=max_retries; i++)); do
            log_info "  第 $i 次尝试拉取... (超时: ${pull_timeout}秒)"
            
            if command -v timeout &>/dev/null; then
                if timeout $pull_timeout docker pull "$image" 2>&1; then
                    log_info "  ✓ 镜像拉取成功: $image"
                    pulled_image="$image"
                    success=true
                    break 2
                else
                    local exit_code=$?
                    if [[ $exit_code -eq 124 ]]; then
                        log_warn "  第 $i 次尝试超时 (${pull_timeout}秒)"
                    else
                        log_warn "  第 $i 次尝试失败 (退出码: $exit_code)"
                    fi
                fi
            else
                if docker pull "$image"; then
                    log_info "  ✓ 镜像拉取成功: $image"
                    pulled_image="$image"
                    success=true
                    break 2
                else
                    log_warn "  第 $i 次尝试失败"
                fi
            fi
            
            if [[ $i -lt $max_retries ]]; then
                log_info "  等待 3 秒后重试..."
                sleep 3
            fi
        done
        
        if [[ "$success" != true ]]; then
            log_warn "源 [$source_name] 失败，尝试下一个源..."
        fi
    done
    
    if [[ "$success" != true ]]; then
        log_error "所有镜像源都尝试过了，仍然失败"
        log_warn "可能的解决方案:"
        echo
        
        echo -e "${CYAN}【方案 1】配置 Docker 镜像加速器${NC}"
        echo "  创建或编辑 /etc/docker/daemon.json:"
        echo
        echo '  {'
        echo '    "registry-mirrors": ['
        echo '      "https://docker.xuanyuan.me",'
        echo '      "https://docker.1ms.run",'
        echo '      "https://xuanyuan.cloud",'
        echo '      "https://docker.m.daocloud.io",'
        echo '      "https://dockerproxy.com",'
        echo '      "https://atomhub.openatom.cn",'
        echo '      "https://docker.nju.edu.cn"'
        echo '    ]'
        echo '  }'
        echo
        echo "  然后执行:"
        echo "    sudo systemctl daemon-reload"
        echo "    sudo systemctl restart docker"
        echo
        
        echo -e "${CYAN}【方案 2】配置代理访问 GHCR${NC}"
        echo "  export HTTP_PROXY=http://127.0.0.1:7890"
        echo "  export HTTPS_PROXY=http://127.0.0.1:7890"
        echo "  sudo -E docker pull ghcr.io/openclaw/openclaw:latest"
        echo
        
        return 1
    fi
    
    if [[ -n "$target_tag" && "$pulled_image" != "$target_tag" ]]; then
        log_info "重命名镜像: $pulled_image -> $target_tag"
        if docker tag "$pulled_image" "$target_tag"; then
            log_info "  ✓ 镜像重命名成功"
        else
            log_warn "  镜像重命名失败，但拉取已成功"
        fi
    fi
    
    return 0
}

# =============================================================================
# 密码获取函数
# =============================================================================

get_jenkins_password() {
    local container_name="${1:-devopsclaw-jenkins}"
    local password_file="/var/jenkins_home/secrets/initialAdminPassword"
    
    log_step "获取 Jenkins 初始密码"
    
    if ! docker ps -q --filter "name=$container_name" 2>/dev/null | grep -q .; then
        log_warn "Jenkins 容器未运行，正在启动..."
        docker start "$container_name" 2>/dev/null
        sleep 10
    fi
    
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker exec "$container_name" test -f "$password_file" 2>/dev/null; then
            local password
            password=$(docker exec "$container_name" cat "$password_file" 2>/dev/null)
            if [[ -n "$password" ]]; then
                echo
                echo -e "${GREEN}Jenkins 初始管理员密码:${NC}"
                echo -e "${YELLOW}$password${NC}"
                echo
                log_info "请保存此密码，用于首次登录 Jenkins"
                JENKINS_INITIAL_PASSWORD="$password"
                export JENKINS_INITIAL_PASSWORD
                return 0
            fi
        fi
        
        attempt=$((attempt + 1))
        log_info "等待密码文件生成... ($attempt/$max_attempts)"
        sleep 5
    done
    
    log_warn "未能自动获取 Jenkins 密码"
    log_info "请手动执行: docker exec $container_name cat $password_file"
    return 1
}

get_gitlab_password() {
    local container_name="${1:-devopsclaw-gitlab}"
    local password_file="/etc/gitlab/initial_root_password"
    
    log_step "获取 GitLab 初始密码"
    
    if ! docker ps -q --filter "name=$container_name" 2>/dev/null | grep -q .; then
        log_warn "GitLab 容器未运行，正在启动..."
        docker start "$container_name" 2>/dev/null
        sleep 15
    fi
    
    local max_attempts=60
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker exec "$container_name" test -f "$password_file" 2>/dev/null; then
            if docker exec "$container_name" grep -q "Password:" "$password_file" 2>/dev/null; then
                local password
                password=$(docker exec "$container_name" grep "Password:" "$password_file" 2>/dev/null | sed 's/.*Password:\s*//')
                if [[ -n "$password" ]]; then
                    echo
                    echo -e "${GREEN}GitLab 初始 root 密码:${NC}"
                    echo -e "${YELLOW}$password${NC}"
                    echo
                    log_warn "此密码文件会在 24 小时后自动删除"
                    GITLAB_INITIAL_PASSWORD="$password"
                    export GITLAB_INITIAL_PASSWORD
                    return 0
                fi
            fi
        fi
        
        attempt=$((attempt + 1))
        log_info "等待密码文件生成... ($attempt/$max_attempts)"
        sleep 10
    done
    
    log_warn "未能自动获取 GitLab 密码"
    log_info "请手动执行: docker exec $container_name cat $password_file"
    return 1
}

# =============================================================================
# OpenClaw 设备管理函数
# =============================================================================

reset_openclaw_device() {
    local container_name="${1:-devopsclaw-openclaw}"
    local openclaw_dir="${2:-/home/openclaw}"
    
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
    
    if [[ -d "$openclaw_dir" ]]; then
        log_info "清除 OpenClaw 数据目录: $openclaw_dir"
        
        rm -f "$openclaw_dir/.gateway_token" 2>/dev/null || true
        rm -f "$openclaw_dir/openclaw.json" 2>/dev/null || true
        rm -f "$openclaw_dir/devices.json" 2>/dev/null || true
        rm -f "$openclaw_dir/sessions.json" 2>/dev/null || true
        
        if [[ -d "$openclaw_dir/.cache" ]]; then
            rm -rf "$openclaw_dir/.cache" 2>/dev/null || true
        fi
        
        if [[ -d "$openclaw_dir/.data" ]]; then
            rm -rf "$openclaw_dir/.data" 2>/dev/null || true
        fi
        
        log_info "数据目录已清理"
    else
        log_warn "未找到 OpenClaw 数据目录: $openclaw_dir"
        log_info "尝试通过 Docker 清理容器内部数据..."
        docker rm -f "$container_name" 2>/dev/null || true
    fi
    
    echo
    echo -e "${GREEN}OpenClaw 设备已重置${NC}"
    echo
    log_info "请重新部署 OpenClaw 或手动执行以下步骤:"
    echo
    echo "  1. 重新生成 Gateway Token 并启动容器"
    echo "  2. 访问 http://127.0.0.1:18789/overview 进行重新配对"
    echo
}

list_openclaw_devices() {
    local container_name="${1:-devopsclaw-openclaw}"
    
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
    local container_name="${2:-devopsclaw-openclaw}"
    
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

# =============================================================================
# 导出函数
# =============================================================================
export RED GREEN YELLOW BLUE PURPLE CYAN BOLD NC
export -f log_info log_warn log_error log_step log_banner
export -f check_root check_docker load_env check_port
export -f pull_image_with_fallback
export -f get_jenkins_password get_gitlab_password
export -f reset_openclaw_device list_openclaw_devices approve_openclaw_device
