#!/bin/bash
# =============================================================================
# Jenkins Docker 安装脚本 v4.0.0
# =============================================================================
# 注意: 推荐使用项目根目录的 deploy_all.sh 或 docker-compose up 进行部署
#
# 此脚本作为备选方案，用于单独部署 Jenkins
#
# 端口配置 (与 docker-compose.yml 一致):
#   - Web:   8081 (宿主机) -> 8080 (容器)
#   - Agent: 50000 (宿主机) -> 50000 (容器)
#
# 使用方法:
#   chmod +x deploy_jenkins.sh
#   sudo ./deploy_jenkins.sh
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
JENKINS_PORT_WEB=${JENKINS_PORT_WEB:-8081}
JENKINS_PORT_AGENT=${JENKINS_PORT_AGENT:-50000}
JENKINS_CONTAINER_NAME=${JENKINS_CONTAINER_NAME:-devopsclaw-jenkins}
JENKINS_IMAGE=${JENKINS_IMAGE:-jenkins/jenkins:lts-jdk17}
JENKINS_PREFIX=${JENKINS_PREFIX:-/jenkins}
JENKINS_JAVA_OPTS=${JENKINS_JAVA_OPTS:--Xmx2g -Xms512m}

# 数据目录
JENKINS_HOME_DIR=${JENKINS_HOME_DIR:-/srv/jenkins/home}

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
     _            _    _             
    | | ___ _ __ | | _(_)_ __  ___  
 _  | |/ _ \ '_ \| |/ / | '_ \/ __| 
| |_| |  __/ | | |   <| | | | \__ \ 
 \___/ \___|_| |_|_|\_\_|_| |_|___/ 
                                      
EOF
    echo -e "${NC}"
    echo -e "${CYAN}Jenkins Docker 安装脚本 v4.0.0${NC}"
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
        echo -e "${CYAN}  $DOCKER_COMPOSE_CMD up -d jenkins${NC}"
        echo
        read -p "是否使用 docker-compose 方式部署? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "使用 docker-compose 方式部署..."
            cd "$PROJECT_ROOT"
            $DOCKER_COMPOSE_CMD up -d jenkins
            log_info "Jenkins 部署命令已执行"
            log_info "请等待 Jenkins 启动（约 2-3 分钟）"
            exit 0
        fi
    fi
}

# =============================================================================
# 部署函数 (Docker run 方式)
# =============================================================================

create_directories() {
    log_step "创建数据目录"
    
    mkdir -p "$JENKINS_HOME_DIR"
    
    log_info "Jenkins Home 目录: $JENKINS_HOME_DIR"
}

pull_image() {
    log_step "拉取 Jenkins 镜像"
    
    log_info "镜像: $JENKINS_IMAGE"
    
    if docker pull "$JENKINS_IMAGE"; then
        log_info "Jenkins 镜像拉取成功 ✓"
    else
        log_error "镜像拉取失败，请检查网络连接"
        exit 1
    fi
}

cleanup_old() {
    log_step "清理旧容器"
    
    if docker ps -a --format '{{.Names}}' | grep -q "^${JENKINS_CONTAINER_NAME}$"; then
        log_warn "检测到已存在的容器: $JENKINS_CONTAINER_NAME"
        read -p "是否删除旧容器? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker stop "$JENKINS_CONTAINER_NAME" 2>/dev/null || true
            docker rm "$JENKINS_CONTAINER_NAME" 2>/dev/null || true
            log_info "旧容器已清理"
        else
            log_warn "保留旧容器，退出部署"
            exit 0
        fi
    fi
}

start_container() {
    log_step "启动 Jenkins 容器"
    
    log_info "容器名: $JENKINS_CONTAINER_NAME"
    log_info "端口映射:"
    log_info "  Web:   $JENKINS_PORT_WEB -> 8080"
    log_info "  Agent: $JENKINS_PORT_AGENT -> 50000"
    log_info "路径前缀: $JENKINS_PREFIX"
    log_info "JVM 参数: $JENKINS_JAVA_OPTS"
    
    docker run --detach \
        --name "$JENKINS_CONTAINER_NAME" \
        --restart unless-stopped \
        --user root \
        --publish "127.0.0.1:${JENKINS_PORT_WEB}:8080" \
        --publish "127.0.0.1:${JENKINS_PORT_AGENT}:50000" \
        --volume "${JENKINS_HOME_DIR}:/var/jenkins_home" \
        --volume "/var/run/docker.sock:/var/run/docker.sock" \
        --env "JENKINS_OPTS=--prefix=${JENKINS_PREFIX}" \
        --env "JAVA_OPTS=${JENKINS_JAVA_OPTS}" \
        "$JENKINS_IMAGE"
    
    if [[ $? -eq 0 ]]; then
        log_info "Jenkins 容器启动成功 ✓"
    else
        log_error "容器启动失败"
        exit 1
    fi
}

wait_for_jenkins() {
    log_step "等待 Jenkins 启动"
    
    log_warn "Jenkins 首次启动通常需要 2-3 分钟，请耐心等待..."
    
    local timeout=300
    local interval=10
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        # 检查容器是否在运行
        if ! docker ps --format '{{.Names}}' | grep -q "^${JENKINS_CONTAINER_NAME}$"; then
            log_error "容器已停止运行"
            docker logs "$JENKINS_CONTAINER_NAME" --tail 50
            exit 1
        fi
        
        # 尝试访问 Jenkins
        if curl -s -f "http://127.0.0.1:${JENKINS_PORT_WEB}${JENKINS_PREFIX}/login" >/dev/null 2>&1; then
            log_info "Jenkins 启动完成 ✓"
            break
        fi
        
        elapsed=$((elapsed + interval))
        log_info "等待 Jenkins 启动... (${elapsed}s/${timeout}s)"
        sleep $interval
    done
    
    if [[ $elapsed -ge $timeout ]]; then
        log_warn "等待超时，Jenkins 可能还在启动中"
        log_info "请稍后检查容器状态"
    fi
}

get_initial_password() {
    log_step "获取初始密码"
    
    local password_file="/var/jenkins_home/secrets/initialAdminPassword"
    local max_attempts=30
    local attempt=0
    
    log_info "等待密码文件生成..."
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker exec "$JENKINS_CONTAINER_NAME" test -f "$password_file" 2>/dev/null; then
            local password
            password=$(docker exec "$JENKINS_CONTAINER_NAME" cat "$password_file" 2>/dev/null)
            if [[ -n "$password" ]]; then
                echo
                echo -e "${GREEN}Jenkins 初始管理员密码:${NC}"
                echo -e "${YELLOW}$password${NC}"
                echo
                log_info "请保存此密码，用于首次登录 Jenkins"
                JENKINS_INITIAL_PASSWORD="$password"
                return
            fi
        fi
        
        attempt=$((attempt + 1))
        sleep 5
    done
    
    log_warn "未能自动获取密码"
    log_info "请稍后手动执行: docker exec $JENKINS_CONTAINER_NAME cat $password_file"
}

# =============================================================================
# 输出函数
# =============================================================================

print_summary() {
    log_step "部署完成"
    
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    Jenkins 部署完成                            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    echo -e "${CYAN}【访问地址】${NC}"
    echo "  Web UI:  http://127.0.0.1:${JENKINS_PORT_WEB}${JENKINS_PREFIX}"
    echo "  Agent:   127.0.0.1:${JENKINS_PORT_AGENT}"
    echo
    
    echo -e "${CYAN}【初始密码】${NC}"
    if [[ -n "${JENKINS_INITIAL_PASSWORD:-}" ]]; then
        echo "  密码: 见上方输出"
    else
        echo "  密码: 请使用命令获取"
        echo "  docker exec $JENKINS_CONTAINER_NAME cat /var/jenkins_home/secrets/initialAdminPassword"
    fi
    echo
    
    echo -e "${CYAN}【容器信息】${NC}"
    echo "  容器名: $JENKINS_CONTAINER_NAME"
    echo "  镜像: $JENKINS_IMAGE"
    echo "  路径前缀: $JENKINS_PREFIX"
    echo
    
    echo -e "${CYAN}【数据目录】${NC}"
    echo "  Jenkins Home: $JENKINS_HOME_DIR"
    echo
    
    echo -e "${CYAN}【常用命令】${NC}"
    echo "  查看状态: docker ps | grep jenkins"
    echo "  查看日志: docker logs -f $JENKINS_CONTAINER_NAME"
    echo "  进入容器: docker exec -it $JENKINS_CONTAINER_NAME bash"
    echo "  停止容器: docker stop $JENKINS_CONTAINER_NAME"
    echo "  启动容器: docker start $JENKINS_CONTAINER_NAME"
    echo "  重启容器: docker restart $JENKINS_CONTAINER_NAME"
    echo
    
    echo -e "${CYAN}【后续操作】${NC}"
    echo "  1. 访问 Jenkins Web UI 进行初始配置"
    echo "  2. 安装推荐插件"
    echo "  3. 创建管理员用户"
    echo "  4. 生成 API Token (用户 -> 设置 -> API Token)"
    echo "  5. 更新 .env 文件中的 JENKINS_TOKEN"
    echo
    
    echo -e "${YELLOW}【重要提示】${NC}"
    echo "  - 所有端口绑定 127.0.0.1，仅本地可访问"
    echo "  - 如需外部访问，请配置 Nginx 反向代理"
    echo "  - 首次启动可能需要 2-3 分钟"
    echo "  - 初始密码仅显示一次，请妥善保存"
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
    wait_for_jenkins
    get_initial_password
    
    # 输出
    print_summary
    
    log_info "Jenkins 部署完成!"
}

# =============================================================================
# 信号处理
# =============================================================================

trap 'log_warn "脚本被用户中断"; exit 1' INT TERM

# 执行主函数
main "$@"
