#!/bin/bash
# =============================================================================
# Nginx 反向代理部署脚本 v4.1.0
# =============================================================================
# 用于部署 Nginx 作为 DevOpsClaw CI 平台的统一反向代理入口
#
# 功能:
#   - SSL 终结（统一 HTTPS 证书管理）
#   - 反向代理（按端口转发到后端服务）
#   - 统一访问日志
#   - 安全隔离（后端服务不直接暴露端口）
#
# 使用方法:
#   chmod +x deploy_nginx.sh
#   sudo ./deploy_nginx.sh
#
# =============================================================================

set -euo pipefail

# =============================================================================
# 配置变量
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
NGINX_CONFIG_DIR="$SCRIPT_DIR/nginx"
SSL_DIR="$NGINX_CONFIG_DIR/ssl"

# Nginx 配置（从环境变量读取，或使用默认值）
NGINX_CONTAINER_NAME=${NGINX_CONTAINER_NAME:-devopsclaw-nginx}
NGINX_IMAGE=${NGINX_IMAGE:-nginx:alpine}
NGINX_NETWORK=${NGINX_NETWORK:-devopsclaw-network}

# Nginx 端口配置
NGINX_PORT_GITLAB=${NGINX_PORT_GITLAB:-8929}
NGINX_PORT_JENKINS=${NGINX_PORT_JENKINS:-8080}
NGINX_PORT_OPENCLAW=${NGINX_PORT_OPENCLAW:-18789}
NGINX_PORT_HARBOR=${NGINX_PORT_HARBOR:-8443}
NGINX_PORT_ARTIFACTORY=${NGINX_PORT_ARTIFACTORY:-8081}
NGINX_PORT_TRM=${NGINX_PORT_TRM:-8085}
NGINX_PORT_RABBITMQ=${NGINX_PORT_RABBITMQ:-15672}

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
   _   _  ______ _   _     _____          
  | \ | |/ ____| \ | |   |  __ \         
  |  \| | |  __|  \| |   | |__) | __ ___ 
  | . ` | | |_ | . ` |   |  _  / '__/ _ \
  | |\  | |__| | |\  |   | | \ \ | | (_) |
  |_| \_|\_____|_| \_|   |_|  \_\_|  \___/
                                            
EOF
    echo -e "${NC}"
    echo -e "${CYAN}Nginx 反向代理部署脚本 v4.1.0${NC}"
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
        log_error "Docker 未安装，请先安装 Docker"
        exit 1
    fi
    
    log_info "Docker 已安装: $(docker --version)"
}

load_env() {
    log_step "加载环境变量"
    
    if [[ -f "$ENV_FILE" ]]; then
        log_info "加载环境变量文件: $ENV_FILE"
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^[A-Z_]+= ]]; then
                var_name="${line%%=*}"
                var_value="${line#*=}"
                var_value="${var_value//\"/}"
                var_value="${var_value//\'/}"
                export "$var_name"="$var_value"
            fi
        done < "$ENV_FILE"
    else
        log_warn "环境变量文件不存在: $ENV_FILE"
        log_info "使用默认配置"
    fi
}

check_ssl_certificates() {
    log_step "检查 SSL 证书"
    
    local cert_file="$SSL_DIR/devopsclaw.crt"
    local key_file="$SSL_DIR/devopsclaw.key"
    
    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        log_info "SSL 证书已存在"
        openssl x509 -in "$cert_file" -noout -subject -dates
        return 0
    else
        log_warn "SSL 证书不存在"
        return 1
    fi
}

generate_ssl_certificates() {
    log_step "生成 SSL 证书"
    
    local generate_script="$SCRIPT_DIR/generate_certs.sh"
    
    if [[ -f "$generate_script" ]]; then
        log_info "运行证书生成脚本: $generate_script"
        chmod +x "$generate_script"
        "$generate_script"
    else
        log_error "证书生成脚本不存在: $generate_script"
        exit 1
    fi
}

check_docker_network() {
    log_step "检查 Docker 网络"
    
    if docker network inspect "$NGINX_NETWORK" &>/dev/null; then
        log_info "Docker 网络已存在: $NGINX_NETWORK"
    else
        log_warn "Docker 网络不存在，将由 docker-compose 创建"
    fi
}

check_backend_services() {
    log_step "检查后端服务"
    
    local services=("jenkins" "gitlab" "openclaw")
    local all_running=true
    
    for service in "${services[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "${service}"; then
            log_info "✓ $service 服务正在运行"
        else
            log_warn "✗ $service 服务未运行"
            all_running=false
        fi
    done
    
    if [[ "$all_running" == false ]]; then
        echo
        read -p "后端服务未全部运行，是否继续部署 Nginx? (y/n): " -n 1 -r
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

check_docker_compose() {
    log_step "检查 Docker Compose 配置"
    
    if [[ -f "$PROJECT_ROOT/docker-compose.yml" ]]; then
        log_info "找到项目根目录的 docker-compose.yml"
        log_info "推荐使用以下命令部署 Nginx:"
        echo
        echo -e "${CYAN}  cd $PROJECT_ROOT${NC}"
        echo -e "${CYAN}  docker compose up -d nginx${NC}"
        echo
        read -p "是否使用 docker-compose 方式部署? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "使用 docker-compose 方式部署..."
            cd "$PROJECT_ROOT"
            docker compose up -d nginx
            log_info "Nginx 部署命令已执行"
            print_summary
            exit 0
        fi
    fi
}

pull_nginx_image() {
    log_step "拉取 Nginx 镜像"
    
    log_info "镜像: $NGINX_IMAGE"
    
    if docker pull "$NGINX_IMAGE"; then
        log_info "Nginx 镜像拉取成功 ✓"
    else
        log_error "镜像拉取失败"
        exit 1
    fi
}

cleanup_old_container() {
    log_step "清理旧容器"
    
    if docker ps -a --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER_NAME}$"; then
        log_warn "检测到已存在的 Nginx 容器"
        read -p "是否删除旧容器? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker stop "$NGINX_CONTAINER_NAME" 2>/dev/null || true
            docker rm "$NGINX_CONTAINER_NAME" 2>/dev/null || true
            log_info "旧容器已清理"
        else
            log_warn "保留旧容器，退出部署"
            exit 0
        fi
    fi
}

start_nginx_container() {
    log_step "启动 Nginx 容器"
    
    log_info "容器名: $NGINX_CONTAINER_NAME"
    log_info "网络: $NGINX_NETWORK"
    log_info "端口映射:"
    log_info "  443 (默认 HTTPS)"
    log_info "  $NGINX_PORT_GITLAB (GitLab)"
    log_info "  $NGINX_PORT_JENKINS (Jenkins)"
    log_info "  $NGINX_PORT_OPENCLAW (OpenClaw)"
    log_info "  $NGINX_PORT_HARBOR (Harbor)"
    log_info "  $NGINX_PORT_ARTIFACTORY (Artifactory)"
    log_info "  $NGINX_PORT_TRM (TRM)"
    log_info "  $NGINX_PORT_RABBITMQ (RabbitMQ 管理)"
    
    docker run --detach \
        --name "$NGINX_CONTAINER_NAME" \
        --restart always \
        --network "$NGINX_NETWORK" \
        --publish "0.0.0.0:443:443" \
        --publish "0.0.0.0:${NGINX_PORT_GITLAB}:8929" \
        --publish "0.0.0.0:${NGINX_PORT_JENKINS}:8080" \
        --publish "0.0.0.0:${NGINX_PORT_OPENCLAW}:18789" \
        --publish "0.0.0.0:${NGINX_PORT_HARBOR}:8443" \
        --publish "0.0.0.0:${NGINX_PORT_ARTIFACTORY}:8081" \
        --publish "0.0.0.0:${NGINX_PORT_TRM}:8085" \
        --publish "0.0.0.0:${NGINX_PORT_RABBITMQ}:15672" \
        --volume "${NGINX_CONFIG_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro" \
        --volume "${NGINX_CONFIG_DIR}/conf.d:/etc/nginx/conf.d:ro" \
        --volume "${SSL_DIR}:/etc/nginx/ssl:ro" \
        --volume "devopsclaw_nginx-logs:/var/log/nginx" \
        "$NGINX_IMAGE"
    
    if [[ $? -eq 0 ]]; then
        log_info "Nginx 容器启动成功 ✓"
    else
        log_error "容器启动失败"
        exit 1
    fi
}

wait_for_nginx() {
    log_step "等待 Nginx 启动"
    
    local timeout=30
    local interval=2
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        # 检查 nginx 配置语法
        if docker exec "$NGINX_CONTAINER_NAME" nginx -t &>/dev/null; then
            log_info "Nginx 配置语法正确 ✓"
            break
        fi
        
        # 检查容器是否在运行
        if ! docker ps --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER_NAME}$"; then
            log_error "容器已停止运行"
            docker logs "$NGINX_CONTAINER_NAME" --tail 50
            exit 1
        fi
        
        elapsed=$((elapsed + interval))
        log_info "等待 Nginx 启动... (${elapsed}s/${timeout}s)"
        sleep $interval
    done
    
    if [[ $elapsed -ge $timeout ]]; then
        log_warn "等待超时"
        log_info "请检查容器日志: docker logs $NGINX_CONTAINER_NAME"
    fi
}

# =============================================================================
# 输出函数
# =============================================================================

print_summary() {
    log_step "部署完成"
    
    echo
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    Nginx 反向代理部署完成                        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    echo -e "${CYAN}【访问地址（HTTPS）】${NC}"
    echo "  默认:    https://<your-ip>:443"
    echo "  GitLab:  https://<your-ip>:${NGINX_PORT_GITLAB}"
    echo "  Jenkins: https://<your-ip>:${NGINX_PORT_JENKINS}"
    echo "  OpenClaw: https://<your-ip>:${NGINX_PORT_OPENCLAW}"
    echo "  Harbor:  https://<your-ip>:${NGINX_PORT_HARBOR} (可选)"
    echo "  Artifactory: https://<your-ip>:${NGINX_PORT_ARTIFACTORY} (可选)"
    echo "  TRM:     https://<your-ip>:${NGINX_PORT_TRM} (可选)"
    echo "  RabbitMQ: https://<your-ip>:${NGINX_PORT_RABBITMQ} (可选)"
    echo
    
    echo -e "${CYAN}【TCP 直连端口】${NC}"
    echo "  GitLab SSH:      2222"
    echo "  Jenkins Agent:   50000"
    echo
    
    echo -e "${CYAN}【容器信息】${NC}"
    echo "  容器名: $NGINX_CONTAINER_NAME"
    echo "  镜像: $NGINX_IMAGE"
    echo "  网络: $NGINX_NETWORK"
    echo
    
    echo -e "${CYAN}【常用命令】${NC}"
    echo "  查看状态:   docker ps | grep nginx"
    echo "  查看日志:   docker logs -f $NGINX_CONTAINER_NAME"
    echo "  访问日志:   docker exec $NGINX_CONTAINER_NAME cat /var/log/nginx/access.log"
    echo "  错误日志:   docker exec $NGINX_CONTAINER_NAME cat /var/log/nginx/error.log"
    echo "  重载配置:   docker exec $NGINX_CONTAINER_NAME nginx -s reload"
    echo "  重启容器:   docker restart $NGINX_CONTAINER_NAME"
    echo
    
    echo -e "${YELLOW}【重要提示】${NC}"
    echo "  1. 使用自签名证书，浏览器访问时会有安全警告"
    echo "  2. 点击 '高级' -> '继续前往' 即可访问"
    echo "  3. 生产环境请使用可信 CA 签发的证书"
    echo "  4. 后端服务端口不再直接暴露，统一通过 Nginx 访问"
    echo "  5. 所有 Web 请求统一记录在 /var/log/nginx/access.log"
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
    load_env
    
    # 检查 SSL 证书
    if ! check_ssl_certificates; then
        read -p "是否生成自签名证书? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            generate_ssl_certificates
        else
            log_error "SSL 证书是必需的，无法继续部署"
            exit 1
        fi
    fi
    
    # 检查 Docker Compose
    check_docker_compose
    
    # 检查后端服务
    check_backend_services
    check_docker_network
    
    # 部署
    pull_nginx_image
    cleanup_old_container
    start_nginx_container
    wait_for_nginx
    
    # 输出
    print_summary
    
    log_info "Nginx 反向代理部署完成!"
}

# =============================================================================
# 信号处理
# =============================================================================

trap 'log_warn "脚本被用户中断"; exit 1' INT TERM

# 执行主函数
main "$@"
