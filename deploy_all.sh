#!/bin/bash
# =============================================================================
# DevOpsClaw 一键部署脚本 v4.1.0
# =============================================================================
# 功能:
#   - 检查系统环境 (Docker, Docker Compose)
#   - 交互式选择部署模式
#   - 配置环境变量 (包括 Nginx 反向代理)
#   - 执行 Docker Compose 部署
#   - 配置服务间集成
#   - 输出部署结果
#
# 使用方法:
#   chmod +x deploy_all.sh
#   sudo ./deploy_all.sh
#
# 部署模式:
#   - full:      完整部署 (Jenkins + OpenClaw + GitLab + Nginx)
#   - full-no-nginx: 完整部署 (Jenkins + OpenClaw + GitLab，无 Nginx)
#   - core:      核心部署 (Jenkins + OpenClaw + Nginx)
#   - core-no-nginx: 核心部署 (Jenkins + OpenClaw，无 Nginx)
#   - openclaw:  仅 OpenClaw
#   - jenkins:   仅 Jenkins
#   - gitlab:    仅 GitLab
#   - nginx:     仅 Nginx 反向代理
#   - existing:  配置集成 (使用已有服务)
#
# =============================================================================

set -euo pipefail

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
# 配置变量
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
ENV_FILE="$PROJECT_ROOT/.env"
ENV_EXAMPLE="$PROJECT_ROOT/.env.example"
DOCKER_COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"
DEPLOY_LOG="$PROJECT_ROOT/deploy.log"

# 端口配置
PORTS=(
    "OpenClaw:18789"
    "Jenkins Web:8081"
    "Jenkins Agent:50000"
    "GitLab HTTP:8082"
    "GitLab HTTPS:8443"
    "GitLab SSH:2222"
)

# Nginx 端口配置
NGINX_PORTS=(
    "Nginx 默认 HTTPS:443"
    "Nginx GitLab:8929"
    "Nginx Jenkins:8080"
    "Nginx OpenClaw:18789"
    "Nginx Harbor:8443"
    "Nginx Artifactory:8081"
    "Nginx TRM:8085"
    "Nginx RabbitMQ:15672"
)

# =============================================================================
# 日志函数
# =============================================================================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$DEPLOY_LOG"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$DEPLOY_LOG"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$DEPLOY_LOG"
}

log_step() {
    echo -e "\n${BLUE}=== $1 ===${NC}" | tee -a "$DEPLOY_LOG"
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
    echo -e "${CYAN}DevOpsClaw 一键部署脚本 v4.1.0${NC}" | tee -a "$DEPLOY_LOG"
    echo -e "${CYAN}========================================${NC}" | tee -a "$DEPLOY_LOG"
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
    
    # 检查独立的 Docker 安装脚本
    local docker_install_script="$PROJECT_ROOT/deploy_docker/install_docker.sh"
    
    if ! command -v docker &>/dev/null; then
        log_warn "Docker 未安装"
        echo
        echo -e "${CYAN}选项:${NC}"
        echo "  [1] 使用独立脚本安装 Docker (推荐，更完善)"
        echo "  [2] 使用内置逻辑安装 Docker"
        echo "  [3] 退出，手动安装"
        echo
        read -p "请选择 (1-3): " choice
        
        case $choice in
            1)
                if [[ -f "$docker_install_script" ]]; then
                    log_info "调用独立安装脚本: $docker_install_script"
                    chmod +x "$docker_install_script"
                    "$docker_install_script"
                    log_info "Docker 安装完成，请重新运行 deploy_all.sh"
                    exit 0
                else
                    log_error "独立安装脚本不存在: $docker_install_script"
                    log_info "使用内置逻辑安装..."
                    install_docker
                fi
                ;;
            2)
                log_info "使用内置逻辑安装 Docker..."
                install_docker
                ;;
            3)
                log_info "用户选择退出"
                echo
                echo -e "${YELLOW}手动安装 Docker 的方法:${NC}"
                echo "  方法 1: 运行独立脚本"
                echo "    chmod +x $docker_install_script"
                echo "    sudo $docker_install_script"
                echo
                echo "  方法 2: 使用 Docker Desktop（WSL 环境推荐）"
                echo "    1. 安装 Docker Desktop for Windows"
                echo "    2. Settings → Resources → WSL Integration → 启用你的发行版"
                echo
                exit 0
                ;;
            *)
                log_error "无效选项"
                exit 1
                ;;
        esac
    else
        log_info "Docker 已安装: $(docker --version)"
    fi
    
    if docker compose version &>/dev/null; then
        log_info "Docker Compose (plugin) 已安装: $(docker compose version --short)"
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        log_info "Docker Compose (standalone) 已安装: $(docker-compose version --short)"
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        log_warn "Docker Compose 未安装，正在安装..."
        install_docker_compose
    fi
    
    log_info "Docker Compose 命令: $DOCKER_COMPOSE_CMD"
}

install_docker_compose() {
    log_info "尝试多种方式安装 Docker Compose..."
    
    # 方法 1: 尝试从 Docker 官方源安装
    if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
        log_info "方法 1: 从 Docker 官方源安装 docker-compose-plugin"
        if apt-get update -qq; then
            if apt-get install -y -qq docker-compose-plugin 2>/dev/null; then
                log_info "✓ 成功安装 docker-compose-plugin"
                DOCKER_COMPOSE_CMD="docker compose"
                return 0
            fi
        fi
        log_warn "方法 1 失败，尝试方法 2..."
    else
        log_warn "Docker 官方源未配置，跳过方法 1"
    fi
    
    # 方法 2: 安装 Ubuntu 官方源的 docker-compose（旧版本）
    log_info "方法 2: 从 Ubuntu 官方源安装 docker-compose"
    if apt-get update -qq && apt-get install -y -qq docker-compose 2>/dev/null; then
        log_info "✓ 成功安装 docker-compose (standalone)"
        DOCKER_COMPOSE_CMD="docker-compose"
        return 0
    fi
    log_warn "方法 2 失败，尝试方法 3..."
    
    # 方法 3: 直接从 GitHub 下载二进制
    log_info "方法 3: 从 GitHub 直接下载 Docker Compose 二进制"
    local COMPOSE_VERSION="v2.24.0"
    local ARCH="x86_64"
    
    if [[ "$(uname -m)" == "aarch64" ]]; then
        ARCH="aarch64"
    fi
    
    local DOWNLOAD_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH}"
    
    log_info "下载: $DOWNLOAD_URL"
    
    if curl -fsSL "$DOWNLOAD_URL" -o /tmp/docker-compose 2>/dev/null; then
        chmod +x /tmp/docker-compose
        mv /tmp/docker-compose /usr/local/bin/docker-compose
        
        if /usr/local/bin/docker-compose version &>/dev/null; then
            log_info "✓ 成功安装 Docker Compose: $(/usr/local/bin/docker-compose version --short)"
            DOCKER_COMPOSE_CMD="/usr/local/bin/docker-compose"
            return 0
        fi
    fi
    log_warn "方法 3 失败..."
    
    # 方法 4: 使用 pip 安装
    log_info "方法 4: 使用 pip 安装 docker-compose"
    if command -v pip3 &>/dev/null; then
        if pip3 install docker-compose 2>/dev/null; then
            log_info "✓ 成功通过 pip 安装 docker-compose"
            DOCKER_COMPOSE_CMD="docker-compose"
            return 0
        fi
    fi
    log_warn "方法 4 失败..."
    
    # 所有方法都失败
    log_error "所有安装方法都失败了！"
    echo
    echo -e "${YELLOW}请手动安装 Docker Compose:${NC}"
    echo
    echo -e "${CYAN}方法 A（推荐，Docker Desktop WSL 集成）:${NC}"
    echo "  如果你在 Windows 上使用 Docker Desktop，请确保:"
    echo "  1. 打开 Docker Desktop Settings"
    echo "  2. 进入 Resources -> WSL Integration"
    echo "  3. 启用你的 WSL 发行版集成"
    echo "  4. 重启 WSL: wsl --shutdown"
    echo
    echo -e "${CYAN}方法 B（手动安装 Docker Compose 插件）:${NC}"
    echo "  # 添加 Docker 官方源"
    echo "  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    echo "  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null"
    echo "  sudo apt-get update"
    echo "  sudo apt-get install docker-compose-plugin"
    echo
    echo -e "${CYAN}方法 C（直接下载二进制）:${NC}"
    echo "  DOCKER_CONFIG=\${DOCKER_CONFIG:-\$HOME/.docker}"
    echo "  mkdir -p \$DOCKER_CONFIG/cli-plugins"
    echo "  curl -SL https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-linux-x86_64 -o \$DOCKER_CONFIG/cli-plugins/docker-compose"
    echo "  chmod +x \$DOCKER_CONFIG/cli-plugins/docker-compose"
    echo
    log_error "请安装 Docker Compose 后重新运行此脚本"
    exit 1
}

install_docker() {
    log_info "正在安装 Docker..."
    
    apt-get update -qq
    apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common
    
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    
    apt-get update -qq
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-compose-plugin
    
    systemctl enable docker --now
    
    log_info "Docker 安装完成: $(docker --version)"
}

check_ports() {
    log_step "检查端口占用"
    
    local conflicts=()
    
    for port_info in "${PORTS[@]}"; do
        local service="${port_info%%:*}"
        local port="${port_info##*:}"
        
        if netstat -tlnp 2>/dev/null | grep -q ":$port " || ss -tlnp 2>/dev/null | grep -q ":$port "; then
            log_warn "端口 $port ($service) 已被占用"
            conflicts+=("$port ($service)")
        else
            log_info "端口 $port ($service) 可用 ✓"
        fi
    done
    
    if [[ ${#conflicts[@]} -gt 0 ]]; then
        log_warn "检测到端口冲突: ${conflicts[*]}"
        read -p "是否继续? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "用户取消部署"
            exit 0
        fi
    fi
}

# =============================================================================
# 环境变量函数
# =============================================================================

setup_env() {
    log_step "配置环境变量"
    
    if [[ -f "$ENV_FILE" ]]; then
        log_info "找到现有的 .env 文件"
        read -p "是否使用现有配置? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            log_info "创建新的 .env 文件..."
            create_env_file
        else
            log_info "使用现有 .env 文件"
        fi
    else
        log_info "创建新的 .env 文件..."
        create_env_file
    fi
    
    validate_env
}

create_env_file() {
    if [[ ! -f "$ENV_EXAMPLE" ]]; then
        log_error "未找到 .env.example 文件"
        exit 1
    fi
    
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    log_info "已从 .env.example 复制到 .env"
    
    generate_openclaw_token
    
    log_info "请编辑 .env 文件，填写必要的配置"
    log_info "必需配置: OPENCLAW_GATEWAY_TOKEN (已自动生成)"
    log_info "部署后配置: JENKINS_TOKEN"
}

generate_openclaw_token() {
    log_step "生成 OpenClaw Gateway Token"
    
    local token
    if command -v tr &>/dev/null && [[ -r /dev/urandom ]]; then
        token=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64)
    else
        log_warn "使用备用方式生成 Token"
        token=$(date +%s%N | sha256sum | base64 | head -c 64)
    fi
    
    if [[ -f "$ENV_FILE" ]]; then
        if grep -q "^OPENCLAW_GATEWAY_TOKEN=your_secure_gateway_token_here$" "$ENV_FILE"; then
            sed -i "s/^OPENCLAW_GATEWAY_TOKEN=your_secure_gateway_token_here$/OPENCLAW_GATEWAY_TOKEN=$token/" "$ENV_FILE"
            log_info "已更新 .env 中的 OPENCLAW_GATEWAY_TOKEN"
        fi
    fi
    
    log_info "Token 已生成 (仅显示一次):"
    echo -e "${YELLOW}$token${NC}"
    echo
}

validate_env() {
    log_step "验证环境变量配置"
    
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "未找到 .env 文件"
        exit 1
    fi
    
    local missing=()
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^OPENCLAW_GATEWAY_TOKEN= ]]; then
            local value="${line#*=}"
            if [[ -z "$value" || "$value" == "your_secure_gateway_token_here" ]]; then
                missing+=("OPENCLAW_GATEWAY_TOKEN")
            fi
        fi
    done < "$ENV_FILE"
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "以下环境变量未配置: ${missing[*]}"
        log_warn "请编辑 .env 文件进行配置"
    else
        log_info "环境变量配置验证通过 ✓"
    fi
}

# =============================================================================
# 部署函数
# =============================================================================

select_deploy_mode() {
    log_step "选择部署模式"
    
    echo
    echo -e "${BOLD}请选择部署模式:${NC}"
    echo
    echo -e "${CYAN}【带 Nginx 反向代理（推荐生产环境使用）】${NC}"
    echo -e "${CYAN}[1]${NC} 完整部署 (Jenkins + OpenClaw + GitLab + Nginx)"
    echo -e "${CYAN}[2]${NC} 核心部署 (Jenkins + OpenClaw + Nginx)"
    echo
    echo -e "${CYAN}【无 Nginx（本地开发/测试环境）】${NC}"
    echo -e "${CYAN}[3]${NC} 完整部署 (Jenkins + OpenClaw + GitLab，无 Nginx)"
    echo -e "${CYAN}[4]${NC} 核心部署 (Jenkins + OpenClaw，无 Nginx) - 本地开发推荐"
    echo
    echo -e "${CYAN}【单独部署】${NC}"
    echo -e "${CYAN}[5]${NC} 仅 OpenClaw"
    echo -e "${CYAN}[6]${NC} 仅 Jenkins"
    echo -e "${CYAN}[7]${NC} 仅 GitLab"
    echo -e "${CYAN}[8]${NC} 仅 Nginx 反向代理"
    echo
    echo -e "${CYAN}【配置集成】${NC}"
    echo -e "${CYAN}[9]${NC} 配置集成 (使用已有服务)"
    echo
    read -p "请输入选项 (1-9): " choice
    
    case $choice in
        1)
            DEPLOY_MODE="full"
            DEPLOY_SERVICES="openclaw jenkins gitlab nginx"
            USE_NGINX=true
            ;;
        2)
            DEPLOY_MODE="core"
            DEPLOY_SERVICES="openclaw jenkins nginx"
            USE_NGINX=true
            ;;
        3)
            DEPLOY_MODE="full-no-nginx"
            DEPLOY_SERVICES="openclaw jenkins gitlab"
            USE_NGINX=false
            ;;
        4)
            DEPLOY_MODE="core-no-nginx"
            DEPLOY_SERVICES="openclaw jenkins"
            USE_NGINX=false
            ;;
        5)
            DEPLOY_MODE="openclaw"
            DEPLOY_SERVICES="openclaw"
            USE_NGINX=false
            ;;
        6)
            DEPLOY_MODE="jenkins"
            DEPLOY_SERVICES="jenkins"
            USE_NGINX=false
            ;;
        7)
            DEPLOY_MODE="gitlab"
            DEPLOY_SERVICES="gitlab"
            USE_NGINX=false
            ;;
        8)
            DEPLOY_MODE="nginx"
            DEPLOY_SERVICES="nginx"
            USE_NGINX=true
            ;;
        9)
            DEPLOY_MODE="existing"
            DEPLOY_SERVICES=""
            USE_NGINX=false
            ;;
        *)
            log_error "无效选项: $choice"
            exit 1
            ;;
    esac
    
    log_info "已选择部署模式: $DEPLOY_MODE"
    log_info "部署服务: $DEPLOY_SERVICES"
    if [[ "$USE_NGINX" == true ]]; then
        log_info "启用 Nginx 反向代理"
    fi
}

# =============================================================================
# Nginx 配置函数
# =============================================================================

check_nginx_ssl_certificates() {
    log_step "检查 Nginx SSL 证书"
    
    local ssl_dir="$PROJECT_ROOT/deploy_nginx/nginx/ssl"
    local cert_file="$ssl_dir/devopsclaw.crt"
    local key_file="$ssl_dir/devopsclaw.key"
    
    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        log_info "SSL 证书已存在"
        if command -v openssl &>/dev/null; then
            openssl x509 -in "$cert_file" -noout -subject -dates 2>/dev/null || true
        fi
        return 0
    else
        log_warn "SSL 证书不存在"
        return 1
    fi
}

generate_nginx_ssl_certificates() {
    log_step "生成 Nginx SSL 证书"
    
    local generate_script="$PROJECT_ROOT/deploy_nginx/generate_certs.sh"
    
    if [[ -f "$generate_script" ]]; then
        log_info "运行证书生成脚本..."
        chmod +x "$generate_script"
        if "$generate_script"; then
            log_info "SSL 证书生成成功 ✓"
        else
            log_error "SSL 证书生成失败"
            exit 1
        fi
    else
        log_warn "证书生成脚本不存在: $generate_script"
        log_info "请手动运行: ./deploy_nginx/generate_certs.sh"
        read -p "是否继续部署? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "用户取消部署"
            exit 0
        fi
    fi
}

# =============================================================================
# 部署函数
# =============================================================================

# =============================================================================
# Docker 镜像源配置（多源重试）
# =============================================================================
# 为每个服务配置多个备选镜像源，防止网络问题导致拉取失败
# 按优先级排序，第一个失败后自动尝试下一个

# Jenkins 镜像源
declare -A JENKINS_IMAGE_SOURCES=(
    ["primary"]="jenkins/jenkins:lts-jdk17"
    ["dockerhub"]="jenkins/jenkins:lts-jdk17"
    ["aliyun_mirror"]="registry.cn-hangzhou.aliyuncs.com/library/jenkins:lts-jdk17"
    ["tencent_mirror"]="ccr.ccs.tencentyun.com/library/jenkins:lts-jdk17"
)

# GitLab 镜像源
declare -A GITLAB_IMAGE_SOURCES=(
    ["primary"]="gitlab/gitlab-ce:latest"
    ["dockerhub"]="gitlab/gitlab-ce:latest"
    ["aliyun_mirror"]="registry.cn-hangzhou.aliyuncs.com/gitlab/gitlab-ce:latest"
    ["tencent_mirror"]="ccr.ccs.tencentyun.com/gitlab/gitlab-ce:latest"
)

# OpenClaw 镜像源
declare -A OPENCLAW_IMAGE_SOURCES=(
    ["primary"]="ghcr.io/openclaw/openclaw:latest"
    ["github"]="ghcr.io/openclaw/openclaw:latest"
    # 注意: OpenClaw 镜像主要在 GHCR，国内可能需要配置代理
)

# Nginx 镜像源
declare -A NGINX_IMAGE_SOURCES=(
    ["primary"]="nginx:alpine"
    ["dockerhub"]="nginx:alpine"
    ["aliyun_mirror"]="registry.cn-hangzhou.aliyuncs.com/library/nginx:alpine"
    ["tencent_mirror"]="ccr.ccs.tencentyun.com/library/nginx:alpine"
)

# 拉取镜像（支持多源重试）
# 参数:
#   $1: 服务名称 (openclaw, jenkins, gitlab, nginx)
#   $2: 目标标签名 (可选，用于 docker tag)
pull_image_with_fallback() {
    local service="$1"
    local target_tag="${2:-}"
    local -n sources  # 引用对应的镜像源数组
    
    # 选择对应的镜像源数组
    case "$service" in
        openclaw)
            sources=("${!OPENCLAW_IMAGE_SOURCES[@]}")
            ;;
        jenkins)
            sources=("${!JENKINS_IMAGE_SOURCES[@]}")
            ;;
        gitlab)
            sources=("${!GITLAB_IMAGE_SOURCES[@]}")
            ;;
        nginx)
            sources=("${!NGINX_IMAGE_SOURCES[@]}")
            ;;
        *)
            log_error "未知服务: $service"
            return 1
            ;;
    esac
    
    local max_retries=3
    local attempt=1
    local success=false
    local pulled_image=""
    
    log_info "尝试拉取 $service 镜像（支持多源重试，最多 $max_retries 次）..."
    
    # 按顺序尝试每个镜像源
    for source_name in "${sources[@]}"; do
        local image_var="${service^^}_IMAGE_SOURCES[$source_name]"
        local image="${!image_var}"
        
        if [[ -z "$image" ]]; then
            continue
        fi
        
        log_info "尝试源 [$source_name]: $image"
        
        # 每个源最多尝试 max_retries 次
        for ((i=1; i<=max_retries; i++)); do
            log_info "  第 $i 次尝试拉取..."
            
            if docker pull "$image"; then
                log_info "  ✓ 镜像拉取成功: $image"
                pulled_image="$image"
                success=true
                break 2  # 跳出双重循环
            else
                log_warn "  第 $i 次尝试失败"
                if [[ $i -lt $max_retries ]]; then
                    log_info "  等待 5 秒后重试..."
                    sleep 5
                fi
            fi
        done
    done
    
    # 如果所有源都失败了
    if [[ "$success" != true ]]; then
        log_error "所有镜像源都尝试过了，仍然失败"
        log_warn "可能的解决方案:"
        echo
        echo "  1. 检查网络连接"
        echo "  2. 配置 Docker 镜像加速器:"
        echo "     编辑 /etc/docker/daemon.json 添加:"
        echo '     {'
        echo '       "registry-mirrors": ['
        echo '         "https://docker.1ms.run",'
        echo '         "https://docker.xuanyuan.me",'
        echo '         "https://docker.xuanyuan.us.kg",'
        echo '         "https://docker.chenby.cn",'
        echo '         "https://docker.xuanyuan.in"'
        echo '       ]'
        echo '     }'
        echo "     然后执行: sudo systemctl restart docker"
        echo
        echo "  3. 配置代理（如需访问 GHCR）"
        echo "     export HTTP_PROXY=http://127.0.0.1:7890"
        echo "     export HTTPS_PROXY=http://127.0.0.1:7890"
        echo
        return 1
    fi
    
    # 如果需要重命名标签（用于与 docker-compose 中定义的标签匹配）
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

# 简化版本：根据服务名获取目标标签
get_target_image_tag() {
    local service="$1"
    local image_var="${service^^}_IMAGE"
    
    # 尝试从 .env 文件获取
    local image=$(grep "^${image_var}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || true)
    
    if [[ -n "$image" ]]; then
        echo "$image"
        return 0
    fi
    
    # 使用默认值
    case "$service" in
        openclaw)
            echo "ghcr.io/openclaw/openclaw:latest"
            ;;
        jenkins)
            echo "jenkins/jenkins:lts-jdk17"
            ;;
        gitlab)
            echo "gitlab/gitlab-ce:latest"
            ;;
        nginx)
            echo "nginx:alpine"
            ;;
        *)
            echo ""
            ;;
    esac
}

pull_images() {
    log_step "拉取 Docker 镜像"
    
    local services=($DEPLOY_SERVICES)
    
    for service in "${services[@]}"; do
        # 获取目标镜像标签（与 docker-compose.yml 一致）
        local target_tag=$(get_target_image_tag "$service")
        
        log_info "拉取 $service 镜像 (目标: $target_tag)..."
        
        # 使用多源重试机制
        if pull_image_with_fallback "$service" "$target_tag"; then
            log_info "$service 镜像拉取成功 ✓"
        else
            log_warn "$service 镜像拉取失败，将在启动时尝试"
            log_warn "建议: 配置 Docker 镜像加速器后重试"
        fi
        
        echo
    done
}

start_services() {
    log_step "启动服务"
    
    if [[ -z "$DEPLOY_SERVICES" ]]; then
        log_info "跳过服务启动 (配置集成模式)"
        return
    fi
    
    local services=($DEPLOY_SERVICES)
    
    log_info "启动服务: ${services[*]}"
    
    if $DOCKER_COMPOSE_CMD up -d ${services[@]}; then
        log_info "服务启动命令执行成功"
    else
        log_error "服务启动失败"
        exit 1
    fi
}

wait_for_services() {
    log_step "等待服务就绪"
    
    if [[ -z "$DEPLOY_SERVICES" ]]; then
        log_info "跳过等待 (配置集成模式)"
        return
    fi
    
    local services=($DEPLOY_SERVICES)
    
    for service in "${services[@]}"; do
        local timeout=300
        local interval=10
        local elapsed=0
        
        log_info "等待 $service 服务就绪..."
        
        while [[ $elapsed -lt $timeout ]]; do
            local health_status
            health_status=$(docker inspect --format='{{.State.Health.Status}}' "${COMPOSE_PROJECT_NAME:-devopsclaw}-$service-1" 2>/dev/null || 
                           docker inspect --format='{{.State.Health.Status}}' "devopsclaw-$service" 2>/dev/null ||
                           echo "unknown")
            
            if [[ "$health_status" == "healthy" ]]; then
                log_info "$service 服务就绪 ✓"
                break
            elif [[ "$health_status" == "unhealthy" ]]; then
                log_warn "$service 服务健康检查失败，继续等待..."
            else
                log_info "等待 $service... (${elapsed}s/${timeout}s)"
            fi
            
            sleep $interval
            elapsed=$((elapsed + interval))
        done
        
        if [[ $elapsed -ge $timeout ]]; then
            log_warn "$service 服务等待超时"
            log_warn "可能需要更长时间，请稍后检查服务状态"
        fi
    done
}

# =============================================================================
# 配置函数
# =============================================================================

get_jenkins_password() {
    log_step "获取 Jenkins 初始密码"
    
    local container_name="${JENKINS_CONTAINER_NAME:-devopsclaw-jenkins}"
    local password_file="/var/jenkins_home/secrets/initialAdminPassword"
    
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker exec "$container_name" test -f "$password_file" 2>/dev/null; then
            local password
            password=$(docker exec "$container_name" cat "$password_file" 2>/dev/null)
            if [[ -n "$password" ]]; then
                log_info "Jenkins 初始管理员密码:"
                echo -e "${YELLOW}$password${NC}"
                echo
                log_info "请保存此密码，用于首次登录 Jenkins"
                JENKINS_INITIAL_PASSWORD="$password"
                return
            fi
        fi
        
        attempt=$((attempt + 1))
        log_info "等待密码文件生成... ($attempt/$max_attempts)"
        sleep 5
    done
    
    log_warn "未能自动获取 Jenkins 密码"
    log_info "请手动执行: docker exec $container_name cat $password_file"
}

get_gitlab_password() {
    log_step "获取 GitLab 初始密码"
    
    local container_name="${GITLAB_CONTAINER_NAME:-devopsclaw-gitlab}"
    local password_file="/etc/gitlab/initial_root_password"
    
    local max_attempts=60
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker exec "$container_name" test -f "$password_file" 2>/dev/null; then
            if docker exec "$container_name" grep -q "Password:" "$password_file" 2>/dev/null; then
                log_info "GitLab 初始 root 密码:"
                docker exec "$container_name" grep "Password:" "$password_file"
                echo
                log_warn "此密码文件会在 24 小时后自动删除"
                return
            fi
        fi
        
        attempt=$((attempt + 1))
        log_info "等待密码文件生成... ($attempt/$max_attempts)"
        sleep 10
    done
    
    log_warn "未能自动获取 GitLab 密码"
    log_info "请手动执行: docker exec $container_name cat $password_file"
}

configure_integration() {
    log_step "配置服务集成"
    
    if [[ "$DEPLOY_MODE" == "existing" ]]; then
        log_info "配置集成模式"
        configure_existing_services
    else
        log_info "配置新部署的服务集成"
        configure_new_services
    fi
}

configure_new_services() {
    log_info "服务已通过 Docker Compose 自动配置"
    log_info "容器间通信网络: devopsclaw-network"
    
    if [[ " $DEPLOY_SERVICES " =~ " jenkins " ]]; then
        log_info "Jenkins 已配置访问 OpenClaw 的环境变量"
    fi
}

configure_existing_services() {
    log_info "检测现有服务配置..."
    
    local jenkins_url=""
    local openclaw_url=""
    local gitlab_url=""
    
    read -p "请输入 Jenkins URL (留空跳过): " jenkins_url
    read -p "请输入 OpenClaw URL (留空跳过): " openclaw_url
    read -p "请输入 GitLab URL (留空跳过): " gitlab_url
    
    if [[ -n "$jenkins_url" ]]; then
        log_info "Jenkins URL: $jenkins_url"
        update_env_var "JENKINS_URL" "$jenkins_url"
    fi
    
    if [[ -n "$openclaw_url" ]]; then
        log_info "OpenClaw URL: $openclaw_url"
    fi
    
    if [[ -n "$gitlab_url" ]]; then
        log_info "GitLab URL: $gitlab_url"
        update_env_var "GITLAB_HOSTNAME" "$(echo "$gitlab_url" | sed -e 's|^https\?://||' -e 's|/.*$||')"
    fi
    
    log_info "服务集成配置完成"
}

update_env_var() {
    local key="$1"
    local value="$2"
    
    if [[ -f "$ENV_FILE" ]]; then
        if grep -q "^${key}=" "$ENV_FILE"; then
            sed -i "s|^${key}=.*$|${key}=${value}|" "$ENV_FILE"
        else
            echo "${key}=${value}" >> "$ENV_FILE"
        fi
        log_info "已更新 .env: $key=$value"
    fi
}

# =============================================================================
# 输出函数
# =============================================================================

print_summary() {
    log_step "部署完成"
    
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    DevOpsClaw 部署完成                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    echo -e "${BOLD}部署模式:${NC} $DEPLOY_MODE"
    echo -e "${BOLD}部署服务:${NC} ${DEPLOY_SERVICES:-配置集成}"
    if [[ "$USE_NGINX" == true ]]; then
        echo -e "${BOLD}反向代理:${NC} Nginx (HTTPS)"
    fi
    echo
    
    if [[ "$USE_NGINX" == true ]]; then
        echo -e "${CYAN}【Nginx 反向代理访问地址（HTTPS）】${NC}"
        echo
        if [[ " $DEPLOY_SERVICES " =~ " nginx " ]] || [[ " $DEPLOY_SERVICES " =~ " jenkins " ]]; then
            echo "  Jenkins:   https://<your-ip>:${NGINX_PORT_JENKINS:-8080}/jenkins"
        fi
        if [[ " $DEPLOY_SERVICES " =~ " nginx " ]] || [[ " $DEPLOY_SERVICES " =~ " openclaw " ]]; then
            echo "  OpenClaw:  https://<your-ip>:${NGINX_PORT_OPENCLAW:-18789}/overview"
        fi
        if [[ " $DEPLOY_SERVICES " =~ " gitlab " ]]; then
            echo "  GitLab:    https://<your-ip>:${NGINX_PORT_GITLAB:-8929}"
            echo "  默认 HTTPS: https://<your-ip>:443 (转发到 GitLab)"
        fi
        echo "  Nginx 容器名: ${NGINX_CONTAINER_NAME:-devopsclaw-nginx}"
        echo
        echo -e "${YELLOW}【TCP 直连端口】${NC}"
        echo "  Jenkins Agent: ${JENKINS_PORT_AGENT:-50000}"
        echo "  GitLab SSH:    ${GITLAB_PORT_SSH:-2222}"
        echo
        echo -e "${YELLOW}【SSL 证书说明】${NC}"
        echo "  - 使用自签名证书，浏览器访问时会有安全警告"
        echo "  - 点击 '高级' -> '继续前往' 即可访问"
        echo "  - 生产环境请使用可信 CA 签发的证书"
        echo
    fi
    
    if [[ " $DEPLOY_SERVICES " =~ " openclaw " ]] || [[ -z "$DEPLOY_SERVICES" ]]; then
        echo -e "${CYAN}【OpenClaw】${NC}"
        if [[ "$USE_NGINX" != true ]]; then
            echo "  访问地址: http://127.0.0.1:${OPENCLAW_PORT:-18789}/overview"
        else
            echo "  容器名: ${OPENCLAW_CONTAINER_NAME:-devopsclaw-openclaw}"
            echo "  容器内访问: http://devopsclaw-openclaw:18789"
        fi
        echo
    fi
    
    if [[ " $DEPLOY_SERVICES " =~ " jenkins " ]] || [[ -z "$DEPLOY_SERVICES" ]]; then
        echo -e "${CYAN}【Jenkins】${NC}"
        if [[ "$USE_NGINX" != true ]]; then
            echo "  访问地址: http://127.0.0.1:${JENKINS_PORT_WEB:-8081}/jenkins"
        fi
        echo "  容器名: ${JENKINS_CONTAINER_NAME:-devopsclaw-jenkins}"
        if [[ "$USE_NGINX" != true ]]; then
            echo "  Agent 端口: ${JENKINS_PORT_AGENT:-50000}"
        fi
        if [[ -n "${JENKINS_INITIAL_PASSWORD:-}" ]]; then
            echo "  初始密码: 见上方输出"
        fi
        echo
    fi
    
    if [[ " $DEPLOY_SERVICES " =~ " gitlab " ]]; then
        echo -e "${CYAN}【GitLab】${NC}"
        if [[ "$USE_NGINX" != true ]]; then
            echo "  访问地址: http://127.0.0.1:${GITLAB_PORT_HTTP:-8082}"
        fi
        echo "  容器名: ${GITLAB_CONTAINER_NAME:-devopsclaw-gitlab}"
        echo "  默认用户: root"
        echo "  初始密码: 见上方输出 (24小时后删除)"
        echo
    fi
    
    echo -e "${BOLD}下一步操作:${NC}"
    echo
    echo "  1. 访问各服务进行初始配置"
    echo "  2. 在 Jenkins 中生成 API Token 并更新 .env 文件"
    echo "  3. 部署 JJB 配置: jenkins-jobs --conf jjb-configs/jenkins_jobs.ini update jjb-configs/"
    echo "  4. 测试自愈功能: 运行测试 Pipeline"
    if [[ "$USE_NGINX" == true ]]; then
        echo "  5. (可选) 安装 CA 证书到客户端以消除安全警告"
    fi
    echo
    
    echo -e "${BOLD}常用命令:${NC}"
    echo
    echo "  查看服务状态:  $DOCKER_COMPOSE_CMD ps"
    echo "  查看服务日志:  $DOCKER_COMPOSE_CMD logs -f [service]"
    echo "  停止服务:     $DOCKER_COMPOSE_CMD stop"
    echo "  启动服务:     $DOCKER_COMPOSE_CMD start"
    echo "  重启服务:     $DOCKER_COMPOSE_CMD restart"
    echo "  删除服务:     $DOCKER_COMPOSE_CMD down"
    if [[ "$USE_NGINX" == true ]]; then
        echo "  查看 Nginx 访问日志: docker exec ${NGINX_CONTAINER_NAME:-devopsclaw-nginx} cat /var/log/nginx/access.log"
        echo "  查看 Nginx 错误日志: docker exec ${NGINX_CONTAINER_NAME:-devopsclaw-nginx} cat /var/log/nginx/error.log"
        echo "  重载 Nginx 配置:   docker exec ${NGINX_CONTAINER_NAME:-devopsclaw-nginx} nginx -s reload"
    fi
    echo
    
    echo -e "${YELLOW}【重要提示】${NC}"
    if [[ "$USE_NGINX" == true ]]; then
        echo "  - Nginx 是唯一暴露 Web 端口的容器，后端服务不直接暴露"
        echo "  - 使用自签名证书，浏览器访问时需确认安全例外"
        echo "  - 所有 Web 请求统一记录在 Nginx 的 access.log"
    else
        echo "  - 所有服务默认绑定 127.0.0.1，仅本地可访问"
        echo "  - 如需外部访问，请选择带 Nginx 的部署模式"
    fi
    echo "  - 请妥善保存初始密码和 Token"
    echo "  - 部署日志已保存到: $DEPLOY_LOG"
    echo
    
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    # 初始化日志文件
    echo "DevOpsClaw 部署日志 - $(date '+%Y-%m-%d %H:%M:%S')" > "$DEPLOY_LOG"
    
    log_banner
    
    # 检查
    check_root
    check_docker
    
    # 选择部署模式
    select_deploy_mode
    
    # 配置
    if [[ "$DEPLOY_MODE" != "existing" ]]; then
        check_ports
    fi
    setup_env
    
    # Nginx SSL 证书检查
    if [[ "$USE_NGINX" == true ]]; then
        if ! check_nginx_ssl_certificates; then
            read -p "是否生成自签名 SSL 证书? (y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                generate_nginx_ssl_certificates
            else
                log_warn "跳过证书生成，Nginx 可能无法正常启动"
                read -p "是否继续部署? (y/n): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    log_info "用户取消部署"
                    exit 0
                fi
            fi
        fi
    fi
    
    # 部署
    if [[ "$DEPLOY_MODE" != "existing" ]]; then
        pull_images
        start_services
        wait_for_services
    fi
    
    # 获取密码
    if [[ " $DEPLOY_SERVICES " =~ " jenkins " ]]; then
        get_jenkins_password
    fi
    if [[ " $DEPLOY_SERVICES " =~ " gitlab " ]]; then
        get_gitlab_password
    fi
    
    # 配置集成
    configure_integration
    
    # 输出结果
    print_summary
    
    log_info "部署流程完成!"
}

# =============================================================================
# 信号处理
# =============================================================================

trap 'log_warn "脚本被用户中断"; exit 1' INT TERM

# 执行主函数
main "$@"
