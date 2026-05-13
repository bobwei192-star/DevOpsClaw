#!/bin/bash
# =============================================================================
# DevOpsClaw Jenkins 部署脚本
# =============================================================================
# 功能：
#   - 部署 Jenkins 服务
#   - 配置 Jenkins 上下文路径
#   - 获取 Jenkins 初始密码
#
# 使用方法：
#   - 独立运行: sudo ./deploy_jenkins/deploy_jenkins.sh
#   - 被主脚本调用: source deploy_jenkins/deploy_jenkins.sh
#
# 端口配置 (新规划):
#   - Jenkins Web: 18081
#   - Jenkins Agent: 50000
#   - Nginx Jenkins: 18440
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
DEPLOY_LOG="${PROJECT_DIR}/deploy.log"
DOCKER_COMPOSE_CMD=""

source "$LIB_DIR/common.sh"

JENKINS_PORT_WEB="${JENKINS_PORT_WEB:-18081}"
JENKINS_PORT_AGENT="${JENKINS_PORT_AGENT:-50000}"
JENKINS_BIND="${JENKINS_BIND:-127.0.0.1}"
JENKINS_IMAGE="${JENKINS_IMAGE:-jenkins/jenkins:2.541.3-lts-jdk21}"
JENKINS_CONTAINER_NAME="${JENKINS_CONTAINER_NAME:-devopsclaw-jenkins}"
JENKINS_DATA_DIR="${JENKINS_DATA_DIR:-$PROJECT_DIR/data/jenkins}"
JENKINS_JAVA_OPTS="${JENKINS_JAVA_OPTS:--Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true -Dhudson.model.DirectoryBrowserSupport.CSP=\"\"}"
JENKINS_OPTS="${JENKINS_OPTS:---prefix=/jenkins}"
JENKINS_PASSWORD_FILE="/var/jenkins_home/secrets/initialAdminPassword"

deploy_jenkins() {
    log_step "部署 Jenkins 服务"
    
    if [[ ! -d "$JENKINS_DATA_DIR" ]]; then
        log_info "创建 Jenkins 数据目录: $JENKINS_DATA_DIR"
        mkdir -p "$JENKINS_DATA_DIR"
    fi
    
    log_info "修改 Jenkins 数据目录权限 (UID 1000)..."
    chown -R 1000:1000 "$JENKINS_DATA_DIR" 2>/dev/null || {
        log_warn "权限修改失败，尝试创建修复脚本..."
        cat > /tmp/fix_jenkins_perms.sh << 'EOFPERMS'
#!/bin/bash
JENKINS_DATA_DIR="$1"
if [[ -n "$JENKINS_DATA_DIR" && -d "$JENKINS_DATA_DIR" ]]; then
    mkdir -p "$JENKINS_DATA_DIR"
    chown -R 1000:1000 "$JENKINS_DATA_DIR"
    echo "权限已修复"
fi
EOFPERMS
        chmod +x /tmp/fix_jenkins_perms.sh
    }
    
    if docker ps -q --filter "name=$JENKINS_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "Jenkins 容器已在运行，停止并删除..."
        docker stop "$JENKINS_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$JENKINS_CONTAINER_NAME" 2>/dev/null || true
    elif docker ps -aq --filter "name=$JENKINS_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "删除已停止的 Jenkins 容器..."
        docker rm "$JENKINS_CONTAINER_NAME" 2>/dev/null || true
    fi
    
    log_info "创建 Jenkins 容器..."
    echo "  - 端口: $JENKINS_BIND:$JENKINS_PORT_WEB -> 8080"
    echo "  - 端口: $JENKINS_BIND:$JENKINS_PORT_AGENT -> 50000"
    echo "  - 数据目录: $JENKINS_DATA_DIR"
    echo "  - 上下文路径: $JENKINS_OPTS"
    
    docker run -d \
        --name "$JENKINS_CONTAINER_NAME" \
        --network devopsclaw-network \
        --restart unless-stopped \
        -p "$JENKINS_BIND:$JENKINS_PORT_WEB:8080" \
        -p "$JENKINS_BIND:$JENKINS_PORT_AGENT:50000" \
        -v "$JENKINS_DATA_DIR:/var/jenkins_home" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e JAVA_OPTS="$JENKINS_JAVA_OPTS" \
        -e JENKINS_OPTS="$JENKINS_OPTS" \
        "$JENKINS_IMAGE"
    
    sleep 5
    
    if docker ps -q --filter "name=$JENKINS_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "✓ Jenkins 容器已启动"
        return 0
    else
        log_error "Jenkins 容器启动失败"
        log_warn "检查日志: docker logs $JENKINS_CONTAINER_NAME"
        return 1
    fi
}

get_jenkins_password() {
    local container_name="${1:-$JENKINS_CONTAINER_NAME}"
    
    log_step "获取 Jenkins 初始密码"
    
    if ! docker ps -q --filter "name=$container_name" 2>/dev/null | grep -q .; then
        log_warn "Jenkins 容器未运行，正在启动..."
        docker start "$container_name" 2>/dev/null
        sleep 10
    fi
    
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker exec "$container_name" test -f "$JENKINS_PASSWORD_FILE" 2>/dev/null; then
            local password
            password=$(docker exec "$container_name" cat "$JENKINS_PASSWORD_FILE" 2>/dev/null)
            if [[ -n "$password" ]]; then
                echo
                echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
                echo -e "${BOLD}${GREEN}                           Jenkins 登录信息                                    ${NC}"
                echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
                echo
                echo -e "  ${CYAN}登录地址:${NC}"
                echo -e "    - 通过 Nginx: ${YELLOW}https://127.0.0.1:18440/jenkins/${NC}"
                echo -e "    - 直接访问: ${YELLOW}http://127.0.0.1:$JENKINS_PORT_WEB/jenkins/${NC}"
                echo
                echo -e "  ${CYAN}解锁密码:${NC}   ${YELLOW}$password${NC}"
                echo
                echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
                echo
                log_warn "此密码用于解锁 Jenkins 安装向导，请尽快创建管理员账户"
                echo
                
                echo -e "${CYAN}【首次登录步骤】${NC}"
                echo
                echo -e "步骤 1：解锁 Jenkins"
                echo -e "  1. 打开浏览器访问上面的登录地址"
                echo -e "  2. 在 \"解锁 Jenkins\" 页面，将上面的密码粘贴到 \"管理员密码\" 输入框"
                echo -e "  3. 点击 \"继续\""
                echo
                echo -e "步骤 2：安装插件"
                echo -e "  1. 选择 \"安装推荐的插件\" 或 \"选择插件\""
                echo -e "  2. 等待插件安装完成"
                echo
                echo -e "步骤 3：创建管理员账户"
                echo -e "  1. 输入用户名 (如: admin)"
                echo -e "  2. 输入密码"
                echo -e "  3. 输入全名和邮箱"
                echo -e "  4. 点击 \"保存并完成\""
                echo
                
                echo -e "${CYAN}【如何修改密码】${NC}"
                echo
                echo -e "方法 1：登录后修改（推荐）"
                echo -e "  1. 使用管理员账户登录 Jenkins"
                echo -e "  2. 点击右上角用户名 → 选择 \"设置\""
                echo -e "  3. 点击左侧菜单 \"密码\""
                echo -e "  4. 输入当前密码，然后输入新密码并确认"
                echo -e "  5. 点击 \"保存\""
                echo
                
                echo -e "方法 2：忘记密码重置"
                echo -e "  如果忘记密码，可以删除 Jenkins 数据目录中的密码文件："
                echo -e "  docker exec $container_name rm -rf /var/jenkins_home/secrets/initialAdminPassword"
                echo -e "  然后重启 Jenkins 容器，会重新生成初始密码"
                echo
                
                echo -e "${CYAN}【注意事项】${NC}"
                echo -e "  - 初始密码仅用于解锁 Jenkins"
                echo -e "  - 首次登录后需要创建管理员账户"
                echo -e "  - 建议使用强密码，包含大小写字母、数字和特殊字符"
                echo
                
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
    log_info "请手动执行: docker exec $container_name cat $JENKINS_PASSWORD_FILE"
    return 1
}

get_jenkins_password_simple() {
    local container_name="${1:-$JENKINS_CONTAINER_NAME}"
    
    if docker ps -q --filter "name=$container_name" 2>/dev/null | grep -q .; then
        if docker exec "$container_name" test -f "$JENKINS_PASSWORD_FILE" 2>/dev/null; then
            local password
            password=$(docker exec "$container_name" cat "$JENKINS_PASSWORD_FILE" 2>/dev/null)
            if [[ -n "$password" ]]; then
                echo "$password"
                return 0
            fi
        fi
    fi
    
    log_warn "无法获取 Jenkins 密码"
    return 1
}

print_jenkins_summary() {
    local mode="${1:-standalone}"
    
    echo
    echo -e "${BOLD}${GREEN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${GREEN}│                      Jenkins 服务状态                            │${NC}"
    echo -e "${BOLD}${GREEN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo
    
    if docker ps -q --filter "name=$JENKINS_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "容器: $JENKINS_CONTAINER_NAME - 运行中 ✓"
    else
        log_warn "容器: $JENKINS_CONTAINER_NAME - 未运行"
    fi
    
    if [[ "$mode" == "without_nginx" ]]; then
        echo
        echo -e "${BOLD}Jenkins 访问地址:${NC}"
        echo -e "  - 本地访问: ${CYAN}http://127.0.0.1:$JENKINS_PORT_WEB/jenkins/${NC}"
        echo -e "  - 网络访问: ${YELLOW}http://<主机IP>:$JENKINS_PORT_WEB/jenkins/${NC}"
    elif [[ "$mode" == "with_nginx" ]]; then
        echo
        echo -e "${BOLD}Jenkins 访问地址:${NC}"
        echo -e "  - Nginx (推荐): ${CYAN}http://127.0.0.1:18440/jenkins/${NC}"
        echo -e "  - 直连: http://127.0.0.1:$JENKINS_PORT_WEB/jenkins/"
    fi
    
    echo
}

show_help() {
    echo
    echo -e "${BOLD}DevOpsClaw Jenkins 部署脚本${NC}"
    echo
    echo -e "用法: $0 [选项]"
    echo
    echo -e "选项:"
    echo -e "  ${CYAN}-h, --help${NC}              显示此帮助信息"
    echo -e "  ${CYAN}--deploy${NC}                部署 Jenkins 服务 (默认)"
    echo -e "  ${CYAN}--standalone${NC}             独立部署 Jenkins（含 Nginx 访问地址摘要）"
    echo -e "  ${CYAN}--get-password${NC}          获取 Jenkins 初始密码"
    echo -e "  ${CYAN}--status${NC}                查看 Jenkins 服务状态"
    echo -e "  ${CYAN}--stop${NC}                  停止 Jenkins 服务"
    echo -e "  ${CYAN}--start${NC}                 启动 Jenkins 服务"
    echo -e "  ${CYAN}--restart${NC}               重启 Jenkins 服务"
    echo
    echo -e "环境变量:"
    echo -e "  JENKINS_PORT_WEB=${JENKINS_PORT_WEB}     Jenkins Web 端口"
    echo -e "  JENKINS_PORT_AGENT=${JENKINS_PORT_AGENT}   Jenkins Agent 端口"
    echo -e "  JENKINS_BIND=${JENKINS_BIND}         Jenkins 绑定地址"
    echo -e "  JENKINS_CONTAINER_NAME=${JENKINS_CONTAINER_NAME}"
    echo
    echo -e "示例:"
    echo -e "  $0                              部署 Jenkins"
    echo -e "  $0 --get-password               获取密码"
    echo -e "  $0 --status                     查看状态"
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
            deploy_jenkins
            print_jenkins_summary "without_nginx"
            log_info "Jenkins 部署完成!"
            ;;
        get_password)
            check_root
            check_docker
            get_jenkins_password
            ;;
        status)
            print_jenkins_summary "standalone"
            ;;
        stop)
            check_root
            log_step "停止 Jenkins 服务"
            docker stop "$JENKINS_CONTAINER_NAME" 2>/dev/null || true
            log_info "Jenkins 已停止"
            ;;
        start)
            check_root
            log_step "启动 Jenkins 服务"
            docker start "$JENKINS_CONTAINER_NAME" 2>/dev/null
            log_info "Jenkins 已启动"
            ;;
        restart)
            check_root
            log_step "重启 Jenkins 服务"
            docker restart "$JENKINS_CONTAINER_NAME" 2>/dev/null
            log_info "Jenkins 已重启"
            ;;
        standalone)
            check_root
            check_docker
            if [[ -f "$PROJECT_DIR/.env" ]]; then
                load_env "$PROJECT_DIR/.env"
            fi
            deploy_jenkins
            print_jenkins_summary "with_nginx"
            log_info "Jenkins 独立部署完成"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
