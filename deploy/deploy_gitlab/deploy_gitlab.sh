#!/bin/bash
# =============================================================================
# DevOpsClaw GitLab 部署脚本
# =============================================================================
# 功能：
#   - 部署 GitLab 服务
#   - 配置 GitLab 外部 URL
#   - 获取 GitLab 初始密码
#
# 使用方法：
#   - 独立运行: sudo ./deploy_gitlab/deploy_gitlab.sh
#   - 被主脚本调用: source deploy_gitlab/deploy_gitlab.sh
#
# 端口配置 (新规划):
#   - GitLab HTTP: 19092
#   - GitLab HTTPS: 19443
#   - GitLab SSH: 2222
#   - Nginx GitLab: 18441
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
DEPLOY_LOG="${PROJECT_DIR}/deploy.log"
DOCKER_COMPOSE_CMD=""

source "$LIB_DIR/common.sh"

GITLAB_PORT_HTTP="${GITLAB_PORT_HTTP:-19092}"
GITLAB_PORT_HTTPS="${GITLAB_PORT_HTTPS:-19443}"
GITLAB_PORT_SSH="${GITLAB_PORT_SSH:-2222}"
GITLAB_BIND="${GITLAB_BIND:-127.0.0.1}"
GITLAB_IMAGE="${GITLAB_IMAGE:-gitlab/gitlab-ce:latest}"
GITLAB_CONTAINER_NAME="${GITLAB_CONTAINER_NAME:-devopsclaw-gitlab}"
GITLAB_DATA_DIR="${GITLAB_DATA_DIR:-$PROJECT_DIR/data/gitlab}"
GITLAB_PASSWORD_FILE="/etc/gitlab/initial_root_password"
GITLAB_ROOT_USER="${GITLAB_ROOT_USER:-root}"

GITLAB_USE_HTTPS_PROXY="${GITLAB_USE_HTTPS_PROXY:-false}"
GITLAB_NGINX_PORT="${GITLAB_NGINX_PORT:-18441}"
GITLAB_HOSTNAME="${GITLAB_HOSTNAME:-127.0.0.1}"

if [[ "$GITLAB_USE_HTTPS_PROXY" == "true" ]]; then
    GITLAB_EXTERNAL_URL="${GITLAB_EXTERNAL_URL:-https://$GITLAB_HOSTNAME:$GITLAB_NGINX_PORT}"
else
    GITLAB_EXTERNAL_URL="${GITLAB_EXTERNAL_URL:-http://$GITLAB_HOSTNAME:$GITLAB_PORT_HTTP}"
fi

GITLAB_USE_NAMED_VOLUMES="${GITLAB_USE_NAMED_VOLUMES:-true}"
GITLAB_VOLUME_CONFIG="${GITLAB_VOLUME_CONFIG:-gitlab-config}"
GITLAB_VOLUME_LOGS="${GITLAB_VOLUME_LOGS:-gitlab-logs}"
GITLAB_VOLUME_DATA="${GITLAB_VOLUME_DATA:-gitlab-data}"

deploy_gitlab() {
    log_step "部署 GitLab 服务"
    
    if [[ "$GITLAB_USE_NAMED_VOLUMES" == "true" ]]; then
        log_info "使用 Docker 命名卷存储 (推荐用于 WSL/Windows)"
    else
        if [[ ! -d "$GITLAB_DATA_DIR" ]]; then
            log_info "创建 GitLab 数据目录: $GITLAB_DATA_DIR"
            mkdir -p "$GITLAB_DATA_DIR/config"
            mkdir -p "$GITLAB_DATA_DIR/logs"
            mkdir -p "$GITLAB_DATA_DIR/data"
        fi
    fi
    
    if docker ps -q --filter "name=$GITLAB_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "GitLab 容器已在运行，停止并删除..."
        docker stop "$GITLAB_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$GITLAB_CONTAINER_NAME" 2>/dev/null || true
    elif docker ps -aq --filter "name=$GITLAB_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "删除已停止的 GitLab 容器..."
        docker rm "$GITLAB_CONTAINER_NAME" 2>/dev/null || true
    fi
    
    log_info "创建 GitLab 容器..."
    echo "  - 端口 HTTP: $GITLAB_BIND:$GITLAB_PORT_HTTP -> 80"
    echo "  - 端口 HTTPS: $GITLAB_BIND:$GITLAB_PORT_HTTPS -> 443"
    echo "  - 端口 SSH: $GITLAB_BIND:$GITLAB_PORT_SSH -> 22"
    echo "  - 外部 URL: $GITLAB_EXTERNAL_URL"
    
    local gitlab_omnibus_config="external_url '$GITLAB_EXTERNAL_URL'; gitlab_rails['gitlab_shell_ssh_port'] = $GITLAB_PORT_SSH; nginx['listen_port'] = 80; nginx['listen_https'] = false;"
    
    if [[ "$GITLAB_USE_HTTPS_PROXY" == "true" ]]; then
        echo "  - 模式: HTTPS 反向代理 (Nginx)"
        gitlab_omnibus_config="$gitlab_omnibus_config gitlab_rails['trusted_proxies'] = ['127.0.0.1', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'];"
        gitlab_omnibus_config="$gitlab_omnibus_config gitlab_rails['x_forwarded_ssl'] = true;"
        gitlab_omnibus_config="$gitlab_omnibus_config nginx['proxy_set_headers'] = { 'X-Forwarded-Proto' => 'https', 'X-Forwarded-Ssl' => 'on' };"
    else
        echo "  - 模式: 直接访问 (HTTP)"
    fi
    
    if [[ "$GITLAB_USE_NAMED_VOLUMES" == "true" ]]; then
        echo "  - 存储方式: Docker 命名卷"
        echo "  - 配置卷: $GITLAB_VOLUME_CONFIG"
        echo "  - 日志卷: $GITLAB_VOLUME_LOGS"
        echo "  - 数据卷: $GITLAB_VOLUME_DATA"
        
        docker run -d \
            --name "$GITLAB_CONTAINER_NAME" \
            --network devopsclaw-network \
            --restart unless-stopped \
            --hostname gitlab \
            -p "$GITLAB_BIND:$GITLAB_PORT_HTTP:80" \
            -p "$GITLAB_BIND:$GITLAB_PORT_HTTPS:443" \
            -p "$GITLAB_BIND:$GITLAB_PORT_SSH:22" \
            -v "$GITLAB_VOLUME_CONFIG:/etc/gitlab" \
            -v "$GITLAB_VOLUME_LOGS:/var/log/gitlab" \
            -v "$GITLAB_VOLUME_DATA:/var/opt/gitlab" \
            -e GITLAB_OMNIBUS_CONFIG="$gitlab_omnibus_config" \
            "$GITLAB_IMAGE"
    else
        echo "  - 数据目录: $GITLAB_DATA_DIR"
        
        docker run -d \
            --name "$GITLAB_CONTAINER_NAME" \
            --network devopsclaw-network \
            --restart unless-stopped \
            --hostname gitlab \
            -p "$GITLAB_BIND:$GITLAB_PORT_HTTP:80" \
            -p "$GITLAB_BIND:$GITLAB_PORT_HTTPS:443" \
            -p "$GITLAB_BIND:$GITLAB_PORT_SSH:22" \
            -v "$GITLAB_DATA_DIR/config:/etc/gitlab" \
            -v "$GITLAB_DATA_DIR/logs:/var/log/gitlab" \
            -v "$GITLAB_DATA_DIR/data:/var/opt/gitlab" \
            -e GITLAB_OMNIBUS_CONFIG="$gitlab_omnibus_config" \
            "$GITLAB_IMAGE"
    fi
    
    sleep 10
    
    if docker ps -q --filter "name=$GITLAB_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "✓ GitLab 容器已启动"
        log_warn "GitLab 初始化需要 5-10 分钟，请耐心等待..."
        
        if [[ "$GITLAB_USE_NAMED_VOLUMES" == "true" ]]; then
            echo
            log_info "命名卷管理命令:"
            log_info "  查看卷: docker volume ls"
            log_info "  备份数据: docker run --rm -v $GITLAB_VOLUME_DATA:/data -v $(pwd):/backup alpine tar cvzf /backup/gitlab-data-backup.tar.gz /data"
            log_info "  恢复数据: docker run --rm -v $GITLAB_VOLUME_DATA:/data -v $(pwd):/backup alpine tar xvzf /backup/gitlab-data-backup.tar.gz -C /"
        fi
        
        return 0
    else
        log_error "GitLab 容器启动失败"
        log_warn "检查日志: docker logs $GITLAB_CONTAINER_NAME"
        return 1
    fi
}

get_gitlab_password() {
    local container_name="${1:-$GITLAB_CONTAINER_NAME}"
    
    log_step "获取 GitLab 初始密码"
    
    if ! docker ps -q --filter "name=$container_name" 2>/dev/null | grep -q .; then
        log_warn "GitLab 容器未运行，正在启动..."
        docker start "$container_name" 2>/dev/null
        sleep 15
    fi
    
    local max_attempts=60
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker exec "$container_name" test -f "$GITLAB_PASSWORD_FILE" 2>/dev/null; then
            if docker exec "$container_name" grep -q "Password:" "$GITLAB_PASSWORD_FILE" 2>/dev/null; then
                local password
                password=$(docker exec "$container_name" grep "Password:" "$GITLAB_PASSWORD_FILE" 2>/dev/null | sed 's/.*Password:\s*//')
                if [[ -n "$password" ]]; then
                    echo
                    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
                    echo -e "${BOLD}${GREEN}                           GitLab 登录信息                                      ${NC}"
                    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
                    echo
                    echo -e "  ${CYAN}登录地址:${NC}"
                    echo -e "    - 通过 Nginx: ${YELLOW}https://127.0.0.1:$GITLAB_NGINX_PORT${NC}"
                    echo -e "    - 直接访问: ${YELLOW}http://127.0.0.1:$GITLAB_PORT_HTTP${NC}"
                    echo
                    echo -e "  ${CYAN}用户名:${NC}   ${YELLOW}root${NC}"
                    echo -e "  ${CYAN}密码:${NC}     ${YELLOW}$password${NC}"
                    echo
                    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
                    echo
                    log_warn "此密码文件会在 24 小时后自动删除，请尽快修改密码"
                    echo
                    
                    echo -e "${CYAN}【如何修改密码】${NC}"
                    echo
                    echo -e "方法 1：登录后修改（推荐）"
                    echo -e "  1. 使用上面的用户名和密码登录 GitLab"
                    echo -e "  2. 点击右上角头像 → 选择 \"Preferences\""
                    echo -e "  3. 点击左侧菜单 \"Password\""
                    echo -e "  4. 输入当前密码，然后输入新密码并确认"
                    echo -e "  5. 点击 \"Save password\" 保存"
                    echo
                    
                    echo -e "方法 2：使用命令行修改"
                    echo -e "  docker exec -it $container_name gitlab-rake \"gitlab:password:reset[root]\""
                    echo
                    
                    echo -e "${CYAN}【注意事项】${NC}"
                    echo -e "  - 密码长度至少 8 个字符"
                    echo -e "  - 建议使用强密码，包含大小写字母、数字和特殊字符"
                    echo -e "  - 修改密码后请妥善保管"
                    echo
                    
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
    log_info "请手动执行: docker exec $container_name cat $GITLAB_PASSWORD_FILE"
    return 1
}

get_gitlab_password_simple() {
    local container_name="${1:-$GITLAB_CONTAINER_NAME}"
    
    if docker ps -q --filter "name=$container_name" 2>/dev/null | grep -q .; then
        if docker exec "$container_name" test -f "$GITLAB_PASSWORD_FILE" 2>/dev/null; then
            local password
            password=$(docker exec "$container_name" grep "Password:" "$GITLAB_PASSWORD_FILE" 2>/dev/null | sed 's/.*Password:\s*//')
            if [[ -n "$password" ]]; then
                echo "$password"
                return 0
            fi
        fi
    fi
    
    log_warn "无法获取 GitLab 密码"
    return 1
}

print_gitlab_summary() {
    local mode="${1:-standalone}"
    
    echo
    echo -e "${BOLD}${GREEN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${GREEN}│                      GitLab 服务状态                             │${NC}"
    echo -e "${BOLD}${GREEN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo
    
    if docker ps -q --filter "name=$GITLAB_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "容器: $GITLAB_CONTAINER_NAME - 运行中 ✓"
    else
        log_warn "容器: $GITLAB_CONTAINER_NAME - 未运行"
    fi
    
    if [[ "$mode" == "without_nginx" ]]; then
        echo
        echo -e "${BOLD}GitLab 访问地址:${NC}"
        echo -e "  - 本地访问: ${CYAN}http://127.0.0.1:$GITLAB_PORT_HTTP${NC}"
        echo -e "  - 网络访问: ${YELLOW}http://<主机IP>:$GITLAB_PORT_HTTP${NC}"
        echo -e "  - SSH 端口: $GITLAB_PORT_SSH"
    elif [[ "$mode" == "with_nginx" ]]; then
        echo
        echo -e "${BOLD}GitLab 访问地址:${NC}"
        echo -e "  - Nginx (推荐): ${CYAN}http://127.0.0.1:18441${NC}"
        echo -e "  - 直连: http://127.0.0.1:$GITLAB_PORT_HTTP"
        echo -e "  - SSH 端口: $GITLAB_PORT_SSH"
    fi
    
    echo
    log_warn "GitLab 首次初始化需要 5-10 分钟"
    log_info "默认用户名: root"
    echo
}

show_help() {
    echo
    echo -e "${BOLD}DevOpsClaw GitLab 部署脚本${NC}"
    echo
    echo -e "用法: $0 [选项]"
    echo
    echo -e "选项:"
    echo -e "  ${CYAN}-h, --help${NC}              显示此帮助信息"
    echo -e "  ${CYAN}--deploy${NC}                部署 GitLab 服务 (默认)"
    echo -e "  ${CYAN}--standalone${NC}             独立部署 GitLab（含 Nginx 访问地址摘要）"
    echo -e "  ${CYAN}--get-password${NC}          获取 GitLab 初始密码"
    echo -e "  ${CYAN}--status${NC}                查看 GitLab 服务状态"
    echo -e "  ${CYAN}--stop${NC}                  停止 GitLab 服务"
    echo -e "  ${CYAN}--start${NC}                 启动 GitLab 服务"
    echo -e "  ${CYAN}--restart${NC}               重启 GitLab 服务"
    echo
    echo -e "环境变量:"
    echo -e "  GITLAB_PORT_HTTP=${GITLAB_PORT_HTTP}   GitLab HTTP 端口"
    echo -e "  GITLAB_PORT_HTTPS=${GITLAB_PORT_HTTPS}  GitLab HTTPS 端口"
    echo -e "  GITLAB_PORT_SSH=${GITLAB_PORT_SSH}    GitLab SSH 端口"
    echo -e "  GITLAB_CONTAINER_NAME=${GITLAB_CONTAINER_NAME}"
    echo
    echo -e "存储配置 (重要!):"
    echo -e "  ${YELLOW}GITLAB_USE_NAMED_VOLUMES${NC}=${GITLAB_USE_NAMED_VOLUMES}  ${CYAN}使用 Docker 命名卷 (推荐用于 WSL/Windows)${NC}"
    echo -e "  GITLAB_VOLUME_CONFIG=${GITLAB_VOLUME_CONFIG}"
    echo -e "  GITLAB_VOLUME_LOGS=${GITLAB_VOLUME_LOGS}"
    echo -e "  GITLAB_VOLUME_DATA=${GITLAB_VOLUME_DATA}"
    echo
    echo -e "  或者使用绑定挂载 (不推荐用于 WSL/Windows):"
    echo -e "  GITLAB_USE_NAMED_VOLUMES=false"
    echo -e "  GITLAB_DATA_DIR=${GITLAB_DATA_DIR}"
    echo
    echo -e "HTTPS 反向代理配置 (重要!):"
    echo -e "  ${YELLOW}GITLAB_USE_HTTPS_PROXY${NC}=${GITLAB_USE_HTTPS_PROXY}  ${CYAN}GitLab 知道自己在 HTTPS 反向代理后面${NC}"
    echo -e "  GITLAB_NGINX_PORT=${GITLAB_NGINX_PORT}  Nginx 监听端口"
    echo -e "  GITLAB_HOSTNAME=${GITLAB_HOSTNAME}      用于构建 external_url"
    echo
    echo -e "  【说明】"
    echo -e "  当使用 Nginx 作为 HTTPS 反向代理时："
    echo -e "  - 客户端 -> Nginx (HTTPS) -> GitLab (HTTP)"
    echo -e "  - GitLab 重定向时需要知道原始请求是 HTTPS"
    echo -e "  - 否则会出现重定向到 HTTP 而不是 HTTPS 的问题"
    echo
    echo -e "示例:"
    echo -e "  $0                              部署 GitLab (使用命名卷)"
    echo -e "  $0 --get-password               获取密码"
    echo -e "  $0 --status                     查看状态"
    echo
    echo -e "WSL/Windows 用户注意:"
    echo -e "  ${RED}Windows 文件系统不支持 Linux 权限模型${NC}"
    echo -e "  推荐使用 GITLAB_USE_NAMED_VOLUMES=true (默认)"
    echo
    echo -e "使用 Nginx 反向代理注意:"
    echo -e "  ${RED}确保 GITLAB_USE_HTTPS_PROXY=true${NC}"
    echo -e "  否则 GitLab 会重定向到 HTTP 而不是 HTTPS"
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
            --get-password)
                action="get_password"
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
            deploy_gitlab
            print_gitlab_summary "without_nginx"
            log_info "GitLab 部署完成!"
            ;;
        get_password)
            check_root
            check_docker
            get_gitlab_password
            ;;
        status)
            print_gitlab_summary "standalone"
            ;;
        stop)
            check_root
            log_step "停止 GitLab 服务"
            docker stop "$GITLAB_CONTAINER_NAME" 2>/dev/null || true
            log_info "GitLab 已停止"
            ;;
        start)
            check_root
            log_step "启动 GitLab 服务"
            docker start "$GITLAB_CONTAINER_NAME" 2>/dev/null
            log_info "GitLab 已启动"
            ;;
        restart)
            check_root
            log_step "重启 GitLab 服务"
            docker restart "$GITLAB_CONTAINER_NAME" 2>/dev/null
            log_info "GitLab 已重启"
            ;;
        standalone)
            check_root
            check_docker
            if [[ -f "$PROJECT_DIR/.env" ]]; then
                load_env "$PROJECT_DIR/.env"
            fi
            deploy_gitlab
            print_gitlab_summary "with_nginx"
            log_info "GitLab 独立部署完成"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
