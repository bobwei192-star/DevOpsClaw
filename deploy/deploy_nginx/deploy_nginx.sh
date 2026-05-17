#!/bin/bash
# =============================================================================
# DevOpsAgent Nginx 部署脚本
# =============================================================================
# 功能：
#   - 部署 Nginx 反向代理服务
#   - 配置 SSL 证书
#   - 配置各服务的反向代理
#   - ensure_nginx_proxy() 共享核心函数（供 deploy_all.sh 调用）
#
# 使用方法：
#   - 独立运行: sudo ./deploy_nginx/deploy_nginx.sh
#   - 被主脚本调用: source deploy_nginx/deploy_nginx.sh
#
# 端口配置 (新规划):
#   - 注意: 使用 18440-18449 范围，避免与 GitLab 内置 HTTPS 端口 8443 冲突！
#   - Nginx Jenkins: 18440
#   - Nginx GitLab: 18441
#   - Nginx Agent: 18442
#   - Nginx Registry: 18444
#   - Nginx Harbor: 18445
#   - Nginx SonarQube: 18446
#
# =============================================================================

if [[ -z "${_NGINX_SH_SOURCED:-}" ]]; then
    _NGINX_SH_SOURCED=true
    set -e

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
    LIB_DIR="$PROJECT_DIR/lib"
    DEPLOY_LOG="${PROJECT_DIR}/deploy.log"
    DOCKER_COMPOSE_CMD=""

    source "$LIB_DIR/common.sh"
fi

NGINX_PORT_JENKINS="${NGINX_PORT_JENKINS:-18440}"
NGINX_PORT_GITLAB="${NGINX_PORT_GITLAB:-18441}"
NGINX_PORT_AGENT="${NGINX_PORT_AGENT:-18442}"
NGINX_PORT_REGISTRY="${NGINX_PORT_REGISTRY:-18444}"
NGINX_PORT_HARBOR="${NGINX_PORT_HARBOR:-18445}"
NGINX_PORT_SONARQUBE="${NGINX_PORT_SONARQUBE:-18446}"
NGINX_BIND="${NGINX_BIND:-$(detect_local_ip)}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:alpine}"
NGINX_CONTAINER_NAME="${NGINX_CONTAINER_NAME:-devopsagent-nginx}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-${PROJECT_ROOT:-$PROJECT_DIR}/deploy_nginx/nginx}"
NGINX_SSL_DIR="${NGINX_SSL_DIR:-${PROJECT_ROOT:-$PROJECT_DIR}/deploy_nginx/nginx/ssl}"

# =============================================================================
# ensure_nginx_proxy() — Nginx 共享核心函数
# 供 deploy_all.sh 的 standalone 函数调用，也可由本脚本 standalone 模式使用
# 职责: 清理→证书→检测服务→创建conf→启动Nginx→验证
# =============================================================================
ensure_nginx_proxy() {
    local PROJECT_ROOT="${PROJECT_ROOT:-$PROJECT_DIR}"
    local NGINX_CONF_DIR="$PROJECT_ROOT/deploy_nginx/nginx"
    local NGINX_SSL_DIR="$NGINX_CONF_DIR/ssl"
    local NGINX_CONF_D="$NGINX_CONF_DIR/conf.d"
    local NGINX_CONF="$NGINX_CONF_DIR/nginx.conf"
    local NGINX_IMAGE="${NGINX_IMAGE:-nginx:alpine}"

    local NGINX_PORT_JENKINS="${NGINX_PORT_JENKINS:-18440}"
    local NGINX_PORT_GITLAB="${NGINX_PORT_GITLAB:-18441}"
    local NGINX_PORT_AGENT="${NGINX_PORT_AGENT:-18442}"
    local NGINX_BIND="${NGINX_BIND:-$(detect_local_ip)}"

    local NGINX_CONTAINER_NAME="${NGINX_CONTAINER_NAME:-devopsagent-nginx}"

    log_info "Nginx 监听地址: $NGINX_BIND"

    # 清理旧容器
    log_info "清理旧 Nginx 容器（如存在）..."
    if docker ps -q --filter "name=$NGINX_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        docker stop "$NGINX_CONTAINER_NAME" 2>/dev/null || true
    fi
    if docker ps -aq --filter "name=$NGINX_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        docker rm -f "$NGINX_CONTAINER_NAME" 2>/dev/null || true
    fi

    # SSL 证书
    if [[ ! -d "$NGINX_SSL_DIR" ]]; then
        mkdir -p "$NGINX_SSL_DIR"
    fi

    local cert_names=("devopsagent" "jenkins" "gitlab" "agent" "registry" "harbor" "sonarqube")
    local need_generate=false

    for name in "${cert_names[@]}"; do
        if [[ ! -f "$NGINX_SSL_DIR/$name.crt" || ! -f "$NGINX_SSL_DIR/$name.key" ]]; then
            need_generate=true
            break
        fi
    done

    if [[ "$need_generate" == true ]]; then
        if ! command -v openssl &>/dev/null; then
            log_error "openssl 未安装，无法生成证书"
            exit 1
        fi
        log_info "部分 SSL 证书缺失，正在生成自签名证书..."
        for name in "${cert_names[@]}"; do
            if [[ -f "$NGINX_SSL_DIR/$name.crt" && -f "$NGINX_SSL_DIR/$name.key" ]]; then
                continue
            fi
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "$NGINX_SSL_DIR/$name.key" \
                -out "$NGINX_SSL_DIR/$name.crt" \
                -subj "/C=CN/ST=Beijing/L=Beijing/O=DevOpsAgent/OU=DevOps/CN=$name.local" 2>/dev/null
            chmod 600 "$NGINX_SSL_DIR/$name.key"
            chmod 644 "$NGINX_SSL_DIR/$name.crt"
            log_info "✓ 证书已生成: $name"
        done
    else
        log_info "✓ 所有 SSL 证书已存在"
    fi

    # 检测后端服务并确保配置文件存在
    if [[ ! -d "$NGINX_CONF_D" ]]; then
        mkdir -p "$NGINX_CONF_D"
    fi

    local detected_services=()
    local port_map_args=""

    # 检测 Jenkins
    if docker ps --filter "name=devopsagent-jenkins" --format "{{.Names}}" 2>/dev/null | grep -q .; then
        log_info "✓ 检测到 Jenkins 容器"
        detected_services+=("jenkins")
        port_map_args="$port_map_args -p ${NGINX_BIND}:${NGINX_PORT_JENKINS}:8440"

        log_info "创建/更新 jenkins.conf..."
        cat > "$NGINX_CONF_D/jenkins.conf" << 'NGINXEOF'
server {
    listen 8440 ssl;
    listen [::]:8440 ssl;

    server_name _;

    ssl_certificate /etc/nginx/ssl/devopsagent.crt;
    ssl_certificate_key /etc/nginx/ssl/devopsagent.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    client_max_body_size 100m;

    location = / {
        return 301 /jenkins/;
    }

    location = /jenkins {
        return 301 /jenkins/;
    }

    location /jenkins/ {
        proxy_pass http://devopsagent-jenkins:8080/jenkins/;

        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 300;
        proxy_connect_timeout 5;
        proxy_send_timeout 90;

        proxy_redirect default;
        proxy_redirect http:// https://;
    }
}
NGINXEOF
    else
        log_info "- Jenkins 容器未运行，跳过"
    fi

    # 检测 GitLab
    if docker ps --filter "name=devopsagent-gitlab" --format "{{.Names}}" 2>/dev/null | grep -q .; then
        log_info "✓ 检测到 GitLab 容器"
        detected_services+=("gitlab")
        port_map_args="$port_map_args -p ${NGINX_BIND}:${NGINX_PORT_GITLAB}:8441"

        log_info "创建/更新 gitlab.conf..."
        cat > "$NGINX_CONF_D/gitlab.conf" << 'NGINXEOF'
server {
    listen 8441 ssl;
    listen [::]:8441 ssl;

    server_name _;

    ssl_certificate /etc/nginx/ssl/devopsagent.crt;
    ssl_certificate_key /etc/nginx/ssl/devopsagent.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    client_max_body_size 100m;

    location / {
        proxy_pass http://devopsagent-gitlab:80;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 300;
        proxy_connect_timeout 5;
        proxy_send_timeout 90;

        proxy_set_header X-Forwarded-Ssl on;
        proxy_set_header X-Forwarded-Port 8441;
    }
}
NGINXEOF
    else
        log_info "- GitLab 容器未运行，跳过"
    fi

    # 检测 Agent（始终覆盖 agent.conf，确保 proxy_pass 指向容器名）
    if docker ps --filter "name=devopsagent-agent" --format "{{.Names}}" 2>/dev/null | grep -q .; then
        log_info "✓ 检测到 Agent 容器"
        detected_services+=("agent")
        port_map_args="$port_map_args -p ${NGINX_BIND}:${NGINX_PORT_AGENT}:8442"

        log_info "创建/更新 agent.conf..."
        cat > "$NGINX_CONF_D/agent.conf" << 'NGINXEOF'
server {
    listen 8442 ssl;
    listen [::]:8442 ssl;

    server_name _;

    ssl_certificate /etc/nginx/ssl/devopsagent.crt;
    ssl_certificate_key /etc/nginx/ssl/devopsagent.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location / {
        proxy_pass http://devopsagent-agent:18789;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 90;
        proxy_connect_timeout 5;
        proxy_send_timeout 90;
    }
}
NGINXEOF
    else
        log_info "- Agent 容器未运行，跳过"
    fi

    if [[ ${#detected_services[@]} -eq 0 ]]; then
        log_error "未检测到任何后端服务容器"
        log_info "请确保至少有一个后端服务正在运行（Jenkins / GitLab / Agent / MantisBT）"
        log_info "运行中的容器列表:"
        docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || true
        exit 1
    fi

    # 保存到全局变量
    NGINX_DETECTED_SERVICES=("${detected_services[@]}")

    # 启动 Nginx 容器
    local VOLUME_ARGS="-v $NGINX_CONF:/etc/nginx/nginx.conf:ro -v $NGINX_CONF_D:/etc/nginx/conf.d:ro -v $NGINX_SSL_DIR:/etc/nginx/ssl:ro"

    echo "  检测到的服务: ${detected_services[*]}"
    echo ""

    docker run -d \
        --name "$NGINX_CONTAINER_NAME" \
        --network devopsagent-network \
        --restart unless-stopped \
        $VOLUME_ARGS \
        $port_map_args \
        "$NGINX_IMAGE" 2>/dev/null

    sleep 3

    if ! docker ps -q --filter "name=$NGINX_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_error "Nginx 容器启动失败"
        log_info "查看日志: docker logs $NGINX_CONTAINER_NAME"
        exit 1
    fi

    log_info "✓ Nginx 容器已启动"

    # 验证配置
    if docker exec "$NGINX_CONTAINER_NAME" nginx -t 2>/dev/null; then
        log_info "✓ Nginx 配置语法正确"
        docker exec "$NGINX_CONTAINER_NAME" nginx -s reload 2>/dev/null
        log_info "✓ Nginx 配置已重载"
    else
        log_warn "Nginx 配置语法错误，请检查日志"
        log_info "查看错误详情: docker logs $NGINX_CONTAINER_NAME"
    fi
}

check_nginx_ssl_certificates() {
    log_step "检查 Nginx SSL 证书"
    
    local cert_files=(
        "jenkins.crt"
        "gitlab.crt"
        "agent.crt"
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
        "agent"
        "registry"
        "harbor"
        "sonarqube"
    )
    
    local country="CN"
    local state="Beijing"
    local locality="Beijing"
    local organization="DevOpsAgent"
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
    echo "  - 端口 Agent: $NGINX_BIND:$NGINX_PORT_AGENT -> 8442"
    echo "  - 端口 Registry: $NGINX_BIND:$NGINX_PORT_REGISTRY -> 8444"
    echo "  - 端口 Harbor: $NGINX_BIND:$NGINX_PORT_HARBOR -> 8445"
    echo "  - 端口 SonarQube: $NGINX_BIND:$NGINX_PORT_SONARQUBE -> 8446"
    echo "  - 配置目录: $NGINX_CONF_DIR"
    
    docker run -d \
        --name "$NGINX_CONTAINER_NAME" \
        --network devopsagent-network \
        --restart unless-stopped \
        -p "$NGINX_BIND:$NGINX_PORT_JENKINS:8440" \
        -p "$NGINX_BIND:$NGINX_PORT_GITLAB:8441" \
        -p "$NGINX_BIND:$NGINX_PORT_AGENT:8442" \
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
    local bind_display="${NGINX_BIND:-$(detect_local_ip)}"
    echo -e "  - Jenkins: ${CYAN}https://${bind_display}:$NGINX_PORT_JENKINS/jenkins/${NC}"
    echo -e "  - GitLab: ${CYAN}https://${bind_display}:$NGINX_PORT_GITLAB${NC}"
    echo -e "  - Agent: ${CYAN}https://${bind_display}:$NGINX_PORT_AGENT${NC}"
    if [[ "$NGINX_PORT_REGISTRY" != "" ]]; then
        echo -e "  - Registry: ${CYAN}https://${bind_display}:$NGINX_PORT_REGISTRY${NC}"
        echo -e "    注意: Registry 服务需要单独部署才能访问${NC}"
    fi
    if [[ "$NGINX_PORT_HARBOR" != "" ]]; then
        echo -e "  - Harbor: ${CYAN}https://${bind_display}:$NGINX_PORT_HARBOR${NC}"
        echo -e "    注意: Harbor 服务需要单独部署才能访问${NC}"
    fi
    if [[ "$NGINX_PORT_SONARQUBE" != "" ]]; then
        echo -e "  - SonarQube: ${CYAN}https://${bind_display}:$NGINX_PORT_SONARQUBE${NC}"
        echo -e "    注意: SonarQube 服务需要单独部署才能访问${NC}"
    fi
    
    echo
    log_info "配置目录: $NGINX_CONF_DIR"
    log_info "SSL 证书目录: $NGINX_SSL_DIR"
    echo
}

show_help() {
    echo
    echo -e "${BOLD}DevOpsAgent Nginx 部署脚本${NC}"
    echo
    echo -e "用法: $0 [选项]"
    echo
    echo -e "选项:"
    echo -e "  ${CYAN}-h, --help${NC}              显示此帮助信息"
    echo -e "  ${CYAN}--standalone${NC}             独立部署 Nginx（自动检测后端服务+配置反向代理）"
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
    echo -e "  NGINX_PORT_AGENT=${NGINX_PORT_AGENT}   Nginx Agent 端口"
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
        standalone)
            check_root
            check_docker
            if [[ -f "$PROJECT_DIR/.env" ]]; then
                load_env "$PROJECT_DIR/.env"
            fi
            log_banner
            log_step "Nginx 一键部署/修复"
            ensure_nginx_proxy
            print_nginx_summary
            log_info "Nginx 独立部署完成"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
