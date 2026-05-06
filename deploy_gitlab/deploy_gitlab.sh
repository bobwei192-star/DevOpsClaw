#!/bin/bash
# =============================================================================
# GitLab CE Docker 安装脚本 v4.0.0
# =============================================================================
# 注意: 推荐使用项目根目录的 deploy_all.sh 或 docker-compose up 进行部署
#
# 此脚本作为备选方案，用于单独部署 GitLab
#
# 端口配置 (与 docker-compose.yml 一致):
#   - HTTP:  8082 (宿主机) -> 80 (容器)
#   - HTTPS: 8443 (宿主机) -> 443 (容器)
#   - SSH:   2222 (宿主机) -> 22 (容器)
#
# 使用方法:
#   chmod +x deploy_gitlab.sh
#   sudo ./deploy_gitlab.sh
#
# =============================================================================

set -euo pipefail

# =============================================================================
# 配置变量
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# 端口配置 (从环境变量读取，或使用默认值)
GITLAB_PORT_HTTP=${GITLAB_PORT_HTTP:-8082}
GITLAB_PORT_HTTPS=${GITLAB_PORT_HTTPS:-8443}
GITLAB_PORT_SSH=${GITLAB_PORT_SSH:-2222}
GITLAB_CONTAINER_NAME=${GITLAB_CONTAINER_NAME:-devopsclaw-gitlab}
GITLAB_IMAGE=${GITLAB_IMAGE:-gitlab/gitlab-ce:latest}
GITLAB_HOSTNAME=${GITLAB_HOSTNAME:-gitlab.devopsclaw.local}
GITLAB_SHM_SIZE=${GITLAB_SHM_SIZE:-512m}

# 数据目录
GITLAB_CONFIG_DIR=${GITLAB_CONFIG_DIR:-/srv/gitlab/config}
GITLAB_LOGS_DIR=${GITLAB_LOGS_DIR:-/srv/gitlab/logs}
GITLAB_DATA_DIR=${GITLAB_DATA_DIR:-/srv/gitlab/data}

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
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_step() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

log_banner() {
    echo -e "${PURPLE}"
    cat << 'EOF'
   ____ _ _   _           _     
  / ___(_) |_| |    __ _| |__  
 | |  _| | __| |   / _` | '_ \ 
 | |_| | | |_| |__| (_| | |_) |
  \____|_|\__|_____\__,_|_.__/ 
                                 
EOF
    echo -e "${NC}"
    echo -e "${CYAN}GitLab CE Docker 安装脚本 v4.0.0${NC}"
    echo -e "${CYAN}========================================${NC}"
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
        log_warn "Docker 未安装，正在安装..."
        install_docker
    else
        log_info "Docker 已安装: $(docker --version)"
    fi
    
    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
        log_info "Docker Compose (plugin) 可用"
    elif command -v docker-compose &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
        log_info "Docker Compose (standalone) 可用"
    fi
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

check_docker_compose() {
    log_step "检查 Docker Compose 配置"
    
    if [[ -f "$PROJECT_ROOT/docker-compose.yml" ]]; then
        log_info "找到项目根目录的 docker-compose.yml:"
        log_info "推荐使用以下命令进行部署:"
        echo
        echo -e "${CYAN}  cd $PROJECT_ROOT${NC}"
        echo -e "${CYAN}  $DOCKER_COMPOSE_CMD up -d gitlab${NC}"
        echo
        read -p "是否使用 docker-compose 方式部署? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "使用 docker-compose 方式部署..."
            cd "$PROJECT_ROOT"
            $DOCKER_COMPOSE_CMD up -d gitlab
            log_info "GitLab 部署命令已执行"
            log_info "请等待 GitLab 启动（约 5-10 分钟）"
            exit 0
        fi
    fi
}

# =============================================================================
# 部署函数 (Docker run 方式)
# =============================================================================

create_directories() {
    log_step "创建数据目录"
    
    mkdir -p "$GITLAB_CONFIG_DIR"
    mkdir -p "$GITLAB_LOGS_DIR"
    mkdir -p "$GITLAB_DATA_DIR"
    
    log_info "配置目录: $GITLAB_CONFIG_DIR"
    log_info "日志目录: $GITLAB_LOGS_DIR"
    log_info "数据目录: $GITLAB_DATA_DIR"
}

pull_image() {
    log_step "拉取 GitLab 镜像"
    
    log_info "镜像: $GITLAB_IMAGE"
    log_info "注意: 镜像约 2GB，下载可能需要一些时间"
    
    if docker pull "$GITLAB_IMAGE"; then
        log_info "GitLab 镜像拉取成功 ✓"
    else
        log_error "镜像拉取失败，请检查网络连接"
        exit 1
    fi
}

cleanup_old() {
    log_step "清理旧容器"
    
    if docker ps -a --format '{{.Names}}' | grep -q "^${GITLAB_CONTAINER_NAME}$"; then
        log_warn "检测到已存在的容器: $GITLAB_CONTAINER_NAME"
        read -p "是否删除旧容器? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker stop "$GITLAB_CONTAINER_NAME" 2>/dev/null || true
            docker rm "$GITLAB_CONTAINER_NAME" 2>/dev/null || true
            log_info "旧容器已清理"
        else
            log_warn "保留旧容器，退出部署"
            exit 0
        fi
    fi
}

start_container() {
    log_step "启动 GitLab 容器"
    
    log_info "容器名: $GITLAB_CONTAINER_NAME"
    log_info "主机名: $GITLAB_HOSTNAME"
    log_info "端口映射:"
    log_info "  HTTP:  $GITLAB_PORT_HTTP -> 80"
    log_info "  HTTPS: $GITLAB_PORT_HTTPS -> 443"
    log_info "  SSH:   $GITLAB_PORT_SSH -> 22"
    log_info "共享内存: $GITLAB_SHM_SIZE"
    
    docker run --detach \
        --hostname "$GITLAB_HOSTNAME" \
        --publish "127.0.0.1:${GITLAB_PORT_HTTP}:80" \
        --publish "127.0.0.1:${GITLAB_PORT_HTTPS}:443" \
        --publish "127.0.0.1:${GITLAB_PORT_SSH}:22" \
        --name "$GITLAB_CONTAINER_NAME" \
        --restart always \
        --volume "${GITLAB_CONFIG_DIR}:/etc/gitlab" \
        --volume "${GITLAB_LOGS_DIR}:/var/log/gitlab" \
        --volume "${GITLAB_DATA_DIR}:/var/opt/gitlab" \
        --shm-size "$GITLAB_SHM_SIZE" \
        "$GITLAB_IMAGE"
    
    if [[ $? -eq 0 ]]; then
        log_info "GitLab 容器启动成功 ✓"
    else
        log_error "容器启动失败"
        exit 1
    fi
}

wait_for_gitlab() {
    log_step "等待 GitLab 启动"
    
    log_warn "GitLab 首次启动通常需要 5-10 分钟，请耐心等待..."
    
    local timeout=600
    local interval=30
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        # 检查日志中是否包含 "gitlab Reconfigured!"
        if docker logs "$GITLAB_CONTAINER_NAME" 2>&1 | grep -q "gitlab Reconfigured!"; then
            log_info "GitLab 配置完成 ✓"
            break
        fi
        
        # 检查容器是否在运行
        if ! docker ps --format '{{.Names}}' | grep -q "^${GITLAB_CONTAINER_NAME}$"; then
            log_error "容器已停止运行"
            docker logs "$GITLAB_CONTAINER_NAME" --tail 50
            exit 1
        fi
        
        elapsed=$((elapsed + interval))
        log_info "等待 GitLab 启动... (${elapsed}s/${timeout}s)"
        sleep $interval
    done
    
    if [[ $elapsed -ge $timeout ]]; then
        log_warn "等待超时，GitLab 可能还在启动中"
        log_info "请稍后检查容器状态"
    fi
}

get_initial_password() {
    log_step "获取初始密码"
    
    local password_file="/etc/gitlab/initial_root_password"
    local max_attempts=60
    local attempt=0
    
    log_info "等待密码文件生成..."
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker exec "$GITLAB_CONTAINER_NAME" test -f "$password_file" 2>/dev/null; then
            if docker exec "$GITLAB_CONTAINER_NAME" grep -q "Password:" "$password_file" 2>/dev/null; then
                echo
                echo -e "${GREEN}GitLab 初始 root 密码:${NC}"
                docker exec "$GITLAB_CONTAINER_NAME" grep "Password:" "$password_file"
                echo
                log_warn "此密码文件会在 24 小时后自动删除"
                return
            fi
        fi
        
        attempt=$((attempt + 1))
        sleep 10
    done
    
    log_warn "未能自动获取密码"
    log_info "请稍后手动执行: docker exec $GITLAB_CONTAINER_NAME cat $password_file"
}

# =============================================================================
# 输出函数
# =============================================================================

print_summary() {
    log_step "部署完成"
    
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    GitLab CE 部署完成                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    echo -e "${CYAN}【访问地址】${NC}"
    echo "  HTTP:  http://127.0.0.1:${GITLAB_PORT_HTTP}"
    echo "  HTTPS: https://127.0.0.1:${GITLAB_PORT_HTTPS} (自签名证书)"
    echo "  SSH:   localhost:${GITLAB_PORT_SSH}"
    echo
    
    echo -e "${CYAN}【默认账户】${NC}"
    echo "  用户名: root"
    echo "  密码: 见上方输出 (24小时后删除)"
    echo
    
    echo -e "${CYAN}【容器信息】${NC}"
    echo "  容器名: $GITLAB_CONTAINER_NAME"
    echo "  主机名: $GITLAB_HOSTNAME"
    echo "  镜像: $GITLAB_IMAGE"
    echo
    
    echo -e "${CYAN}【数据目录】${NC}"
    echo "  配置: $GITLAB_CONFIG_DIR"
    echo "  日志: $GITLAB_LOGS_DIR"
    echo "  数据: $GITLAB_DATA_DIR"
    echo
    
    echo -e "${CYAN}【常用命令】${NC}"
    echo "  查看状态: docker ps | grep gitlab"
    echo "  查看日志: docker logs -f $GITLAB_CONTAINER_NAME"
    echo "  进入容器: docker exec -it $GITLAB_CONTAINER_NAME bash"
    echo "  停止容器: docker stop $GITLAB_CONTAINER_NAME"
    echo "  启动容器: docker start $GITLAB_CONTAINER_NAME"
    echo "  重启容器: docker restart $GITLAB_CONTAINER_NAME"
    echo "  重新配置: docker exec -it $GITLAB_CONTAINER_NAME gitlab-ctl reconfigure"
    echo
    
    echo -e "${YELLOW}【重要提示】${NC}"
    echo "  - 所有端口绑定 127.0.0.1，仅本地可访问"
    echo "  - 如需外部访问，请配置 Nginx 反向代理"
    echo "  - 首次启动可能需要 5-10 分钟"
    echo "  - 初始密码文件 24 小时后自动删除，请及时修改密码"
    echo
    
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    log_banner
    
    # 检查
    check_root
    check_docker
    
    # 检查是否使用 docker-compose
    check_docker_compose
    
    # 部署
    create_directories
    pull_image
    cleanup_old
    start_container
    wait_for_gitlab
    get_initial_password
    
    # 输出
    print_summary
    
    log_info "GitLab 部署完成!"
}

# =============================================================================
# 信号处理
# =============================================================================

trap 'log_warn "脚本被用户中断"; exit 1' INT TERM

# 执行主函数
main "$@"
