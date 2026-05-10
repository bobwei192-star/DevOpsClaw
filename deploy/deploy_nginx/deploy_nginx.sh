#!/bin/bash
# =============================================================================
# DevOpsClaw Nginx 部署脚本
# =============================================================================
# 功能：
#   - 部署 Nginx 反向代理服务
#   - 配置 SSL 证书
#   - 配置各服务的反向代理
#
# 使用方法：
#   - 独立运行: sudo ./deploy_nginx/deploy_nginx.sh
#   - 被主脚本调用: source deploy_nginx/deploy_nginx.sh
#
# 端口配置 (新规划):
#   - 注意: 使用 18440-18449 范围，避免与 GitLab 内置 HTTPS 端口 8443 冲突！
#   - Nginx Jenkins: 18440
#   - Nginx GitLab: 18441
#   - Nginx OpenClaw: 18442
#   - Nginx Registry: 18444
#   - Nginx Harbor: 18445
#   - Nginx SonarQube: 18446
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

NGINX_PORT_JENKINS="${NGINX_PORT_JENKINS:-18440}"
NGINX_PORT_GITLAB="${NGINX_PORT_GITLAB:-18441}"
NGINX_PORT_OPENCLAW="${NGINX_PORT_OPENCLAW:-18442}"
NGINX_PORT_REGISTRY="${NGINX_PORT_REGISTRY:-18444}"
NGINX_PORT_HARBOR="${NGINX_PORT_HARBOR:-18445}"
NGINX_PORT_SONARQUBE="${NGINX_PORT_SONARQUBE:-18446}"
NGINX_BIND="${NGINX_BIND:-127.0.0.1}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:alpine}"
NGINX_CONTAINER_NAME="${NGINX_CONTAINER_NAME:-devopsclaw-nginx}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-$SCRIPT_DIR/nginx}"
NGINX_SSL_DIR="${NGINX_SSL_DIR:-$SCRIPT_DIR/nginx/ssl}"

check_nginx_ssl_certificates() {
    log_step "检查 Nginx SSL 证书"
    
    local cert_files=(
        "jenkins.crt"
        "gitlab.crt"
        "openclaw.crt"
        "registry.crt"
        "harbor.crt"
        "sonarqube.crt"
    )
    
    local all_valid=true
    
    for cert in "${cert_files[@]}"; do
        local cert_path="$NGINX_SSL_DIR/$cert"
        local key_path="${cert_path%.crt}.key"
        
        if [[ -f "$cert_path" && -f "$key_path" ]]; then
            log_info "✓ SSL 证书已存在: $cert"
        else
            log_warn "✗ SSL 证书不存在: $cert"
            all_valid=false
        fi
    done
    
    if [[ "$all_valid" == false ]]; then
        log_warn "部分 SSL 证书不存在，将生成自签名证书"
    fi
    
    echo
}

generate_nginx_ssl_certificates() {
    log_step "生成 Nginx SSL 自签名证书"
    
    if [[ ! -d "$NGINX_SSL_DIR" ]]; then
        log_info "创建 SSL 目录: $NGINX_SSL_DIR"
        mkdir -p "$NGINX_SSL_DIR"
    fi
    
    local domains=(
        "jenkins"
        "gitlab"
        "openclaw"
        "registry"
        "harbor"
        "sonarqube"
    )
    
    local country="CN"
    local state="Beijing"
    local locality="Beijing"
    local organization="DevOpsClaw"
    local organizational_unit="DevOps"
    
    for domain in "${domains[@]}"; do
        local cert_path="$NGINX_SSL_DIR/$domain.crt"
        local key_path="$NGINX_SSL_DIR/$domain.key"
        
        if [[ -f "$cert_path" && -f "$key_path" ]]; then
            log_info "跳过已存在的证书: $domain"
            continue
        fi
        
        log_info "生成自签名证书: $domain"
        
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$key_path" \
            -out "$cert_path" \
            -subj "/C=$country/ST=$state/L=$locality/O=$organization/OU=$organizational_unit/CN=$domain.local"
        
        if [[ -f "$cert_path" && -f "$key_path" ]]; then
            log_info "✓ 证书生成成功: $domain"
        else
            log_error "✗ 证书生成失败: $domain"
        fi
    done
    
    echo
    log_info "SSL 证书生成完成"
    log_info "证书目录: $NGINX_SSL_DIR"
    echo
}

deploy_nginx() {
    log_step "部署 Nginx 反向代理服务"
    
    if [[ ! -d "$NGINX_CONF_DIR/conf.d" ]]; then
        log_error "Nginx 配置目录不存在: $NGINX_CONF_DIR/conf.d"
        log_info "请确保 Nginx 配置文件已存在"
        return 1
    fi
    
    check_nginx_ssl_certificates
    generate_nginx_ssl_certificates
    
    if docker ps -q --filter "name=$NGINX_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "Nginx 容器已在运行，停止并删除..."
        docker stop "$NGINX_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$NGINX_CONTAINER_NAME" 2>/dev/null || true
    elif docker ps -aq --filter "name=$NGINX_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "删除已停止的 Nginx 容器..."
        docker rm "$NGINX_CONTAINER_NAME" 2>/dev/null || true
    fi
    
    log_info "创建 Nginx 容器..."
    echo "  - 端口 Jenkins: $NGINX_BIND:$NGINX_PORT_JENKINS -> 8440"
    echo "  - 端口 GitLab: $NGINX_BIND:$NGINX_PORT_GITLAB -> 8441"
    echo "  - 端口 OpenClaw: $NGINX_BIND:$NGINX_PORT_OPENCLAW -> 8442"
    echo "  - 端口 Registry: $NGINX_BIND:$NGINX_PORT_REGISTRY -> 8444"
    echo "  - 端口 Harbor: $NGINX_BIND:$NGINX_PORT_HARBOR -> 8445"
    echo "  - 端口 SonarQube: $NGINX_BIND:$NGINX_PORT_SONARQUBE -> 8446"
    echo "  - 配置目录: $NGINX_CONF_DIR"
    
    docker run -d \
        --name "$NGINX_CONTAINER_NAME" \
        --network devopsclaw-network \
        --restart unless-stopped \
        -p "$NGINX_BIND:$NGINX_PORT_JENKINS:8440" \
        -p "$NGINX_BIND:$NGINX_PORT_GITLAB:8441" \
        -p "$NGINX_BIND:$NGINX_PORT_OPENCLAW:8442" \
        -p "$NGINX_BIND:$NGINX_PORT_REGISTRY:8444" \
        -p "$NGINX_BIND:$NGINX_PORT_HARBOR:8445" \
        -p "$NGINX_BIND:$NGINX_PORT_SONARQUBE:8446" \
        -v "$NGINX_CONF_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$NGINX_CONF_DIR/conf.d:/etc/nginx/conf.d:ro" \
        -v "$NGINX_SSL_DIR:/etc/nginx/ssl:ro" \
        "$NGINX_IMAGE"
    
    sleep 3
    
    if docker ps -q --filter "name=$NGINX_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "✓ Nginx 容器已启动"
        log_info "测试 Nginx 配置..."
        if docker exec "$NGINX_CONTAINER_NAME" nginx -t; then
            log_info "✓ Nginx 配置语法正确"
        else
            log_warn "Nginx 配置有问题，请检查日志"
        fi
        return 0
    else
        log_error "Nginx 容器启动失败"
        log_warn "检查日志: docker logs $NGINX_CONTAINER_NAME"
        return 1
    fi
}

print_nginx_summary() {
    echo
    echo -e "${BOLD}${GREEN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${GREEN}│                      Nginx 服务状态                              │${NC}"
    echo -e "${BOLD}${GREEN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo
    
    if docker ps -q --filter "name=$NGINX_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "容器: $NGINX_CONTAINER_NAME - 运行中 ✓"
    else
        log_warn "容器: $NGINX_CONTAINER_NAME - 未运行"
    fi
    
    echo
    echo -e "${BOLD}Nginx 反向代理访问地址 (HTTPS):${NC}"
    echo -e "  - Jenkins: ${CYAN}https://127.0.0.1:$NGINX_PORT_JENKINS/jenkins/${NC}"
    echo -e "  - GitLab: ${CYAN}https://127.0.0.1:$NGINX_PORT_GITLAB${NC}"
    echo -e "  - OpenClaw: ${CYAN}https://127.0.0.1:$NGINX_PORT_OPENCLAW${NC}"
    if [[ "$NGINX_PORT_REGISTRY" != "" ]]; then
        echo -e "  - Registry: ${CYAN}https://127.0.0.1:$NGINX_PORT_REGISTRY${NC}"
        echo -e "    注意: Registry 服务需要单独部署才能访问${NC}"
    fi
    if [[ "$NGINX_PORT_HARBOR" != "" ]]; then
        echo -e "  - Harbor: ${CYAN}https://127.0.0.1:$NGINX_PORT_HARBOR${NC}"
        echo -e "    注意: Harbor 服务需要单独部署才能访问${NC}"
    fi
    if [[ "$NGINX_PORT_SONARQUBE" != "" ]]; then
        echo -e "  - SonarQube: ${CYAN}https://127.0.0.1:$NGINX_PORT_SONARQUBE${NC}"
        echo -e "    注意: SonarQube 服务需要单独部署才能访问${NC}"
    fi
    
    echo
    log_info "配置目录: $NGINX_CONF_DIR"
    log_info "SSL 证书目录: $NGINX_SSL_DIR"
    echo
}

show_help() {
    echo
    echo -e "${BOLD}DevOpsClaw Nginx 部署脚本${NC}"
    echo
    echo -e "用法: $0 [选项]"
    echo
    echo -e "选项:"
    echo -e "  ${CYAN}-h, --help${NC}              显示此帮助信息"
    echo -e "  ${CYAN}--deploy${NC}                部署 Nginx 服务 (默认)"
    echo -e "  ${CYAN}--generate-ssl${NC}          生成 SSL 自签名证书"
    echo -e "  ${CYAN}--check-ssl${NC}             检查 SSL 证书"
    echo -e "  ${CYAN}--status${NC}                查看服务状态"
    echo -e "  ${CYAN}--stop${NC}                  停止服务"
    echo -e "  ${CYAN}--start${NC}                 启动服务"
    echo -e "  ${CYAN}--restart${NC}               重启服务"
    echo -e "  ${CYAN}--reload${NC}                重载 Nginx 配置"
    echo
    echo -e "环境变量:"
    echo -e "  NGINX_PORT_JENKINS=${NGINX_PORT_JENKINS}     Nginx Jenkins 端口"
    echo -e "  NGINX_PORT_GITLAB=${NGINX_PORT_GITLAB}       Nginx GitLab 端口"
    echo -e "  NGINX_PORT_OPENCLAW=${NGINX_PORT_OPENCLAW}   Nginx OpenClaw 端口"
    echo -e "  NGINX_CONTAINER_NAME=${NGINX_CONTAINER_NAME}"
    echo
    echo -e "示例:"
    echo -e "  $0                              部署 Nginx"
    echo -e "  $0 --generate-ssl               生成 SSL 证书"
    echo -e "  $0 --check-ssl                  检查 SSL 证书"
    echo -e "  $0 --reload                     重载配置"
    echo
}

main() {
    local action="deploy"
    
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
            --generate-ssl)
                action="generate_ssl"
                shift
                ;;
            --check-ssl)
                action="check_ssl"
                shift
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
            --reload)
                action="reload"
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
            deploy_nginx
            print_nginx_summary
            log_info "Nginx 部署完成!"
            ;;
        generate_ssl)
            generate_nginx_ssl_certificates
            log_info "SSL 证书生成完成!"
            ;;
        check_ssl)
            check_nginx_ssl_certificates
            ;;
        status)
            print_nginx_summary
            ;;
        stop)
            check_root
            log_step "停止 Nginx 服务"
            docker stop "$NGINX_CONTAINER_NAME" 2>/dev/null || true
            log_info "Nginx 已停止"
            ;;
        start)
            check_root
            log_step "启动 Nginx 服务"
            docker start "$NGINX_CONTAINER_NAME" 2>/dev/null
            log_info "Nginx 已启动"
            ;;
        restart)
            check_root
            log_step "重启 Nginx 服务"
            docker restart "$NGINX_CONTAINER_NAME" 2>/dev/null
            log_info "Nginx 已重启"
            ;;
        reload)
            check_root
            log_step "重载 Nginx 配置"
            if docker exec "$NGINX_CONTAINER_NAME" nginx -t; then
                docker exec "$NGINX_CONTAINER_NAME" nginx -s reload
                log_info "Nginx 配置已重载"
            else
                log_error "Nginx 配置有错误，无法重载"
            fi
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
