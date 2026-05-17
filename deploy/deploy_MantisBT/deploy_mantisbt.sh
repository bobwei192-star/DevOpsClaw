#!/bin/bash
# =============================================================================
# DevOpsAgent MantisBT 部署脚本
# =============================================================================
# 功能：
#   - 部署 MantisBT Bug 追踪系统 + MariaDB 数据库
#   - 自动初始化数据库
#   - 获取初始管理员密码
#
# 使用方法：
#   - 独立运行: sudo ./deploy_MantisBT/deploy_mantisbt.sh
#   - 被主脚本调用: source deploy_MantisBT/deploy_mantisbt.sh
#
# 端口配置:
#   - MantisBT Web: 19093
#   - MariaDB: 3307
#   - Nginx MantisBT: 18443
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"
DEPLOY_LOG="${PROJECT_DIR}/deploy.log"
DOCKER_COMPOSE_CMD=""

source "$LIB_DIR/common.sh"

MANTISBT_PORT_WEB="${MANTISBT_PORT_WEB:-19093}"
MANTISBT_BIND="${MANTISBT_BIND:-127.0.0.1}"
MANTISBT_IMAGE="${MANTISBT_IMAGE:-mantisbt/mantisbt:latest}"
MANTISBT_CONTAINER_NAME="${MANTISBT_CONTAINER_NAME:-devopsagent-mantisbt}"
MANTISBT_DATA_DIR="${MANTISBT_DATA_DIR:-$PROJECT_DIR/data/mantisbt}"

MARIADB_PORT="${MARIADB_PORT:-3307}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:10.11}"
MARIADB_CONTAINER_NAME="${MARIADB_CONTAINER_NAME:-devopsagent-mantisbt-db}"
MARIADB_DATA_DIR="${MARIADB_DATA_DIR:-$PROJECT_DIR/data/mantisbt-db}"

MANTISBT_DB_NAME="${MANTISBT_DB_NAME:-mantisbt}"
MANTISBT_DB_USER="${MANTISBT_DB_USER:-mantisbt}"
MANTISBT_DB_PASSWORD="${MANTISBT_DB_PASSWORD:-mantisbt_secret}"
MANTISBT_ADMIN_USER="${MANTISBT_ADMIN_USER:-administrator}"
MANTISBT_ADMIN_PASSWORD="${MANTISBT_ADMIN_PASSWORD:-root}"
MANTISBT_USE_NAMED_VOLUMES="${MANTISBT_USE_NAMED_VOLUMES:-true}"

MANTISBT_USE_HTTPS_PROXY="${MANTISBT_USE_HTTPS_PROXY:-false}"
MANTISBT_NGINX_PORT="${MANTISBT_NGINX_PORT:-18443}"
MANTISBT_HOSTNAME="${MANTISBT_HOSTNAME:-127.0.0.1}"

if [[ "$MANTISBT_USE_HTTPS_PROXY" == "true" ]]; then
    MANTISBT_EXTERNAL_URL="${MANTISBT_EXTERNAL_URL:-https://$MANTISBT_HOSTNAME:$MANTISBT_NGINX_PORT}"
else
    MANTISBT_EXTERNAL_URL="${MANTISBT_EXTERNAL_URL:-http://$MANTISBT_HOSTNAME:$MANTISBT_PORT_WEB}"
fi

MANTISBT_VOLUME_WEB="${MANTISBT_VOLUME_WEB:-mantisbt-web}"
MARIADB_VOLUME_DATA="${MARIADB_VOLUME_DATA:-mantisbt-db-data}"

deploy_mantisbt_db() {
    log_step "部署 MantisBT MariaDB 数据库"

    if [[ "$MANTISBT_USE_NAMED_VOLUMES" == "true" ]]; then
        log_info "使用 Docker 命名卷存储 (推荐用于 WSL/Windows)"
    else
        if [[ ! -d "$MARIADB_DATA_DIR" ]]; then
            log_info "创建 MariaDB 数据目录: $MARIADB_DATA_DIR"
            mkdir -p "$MARIADB_DATA_DIR"
        fi
    fi

    if docker ps -q --filter "name=$MARIADB_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "MantisBT DB 容器已在运行，停止并删除..."
        docker stop "$MARIADB_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$MARIADB_CONTAINER_NAME" 2>/dev/null || true
    elif docker ps -aq --filter "name=$MARIADB_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "删除已停止的 MantisBT DB 容器..."
        docker rm "$MARIADB_CONTAINER_NAME" 2>/dev/null || true
    fi

    log_info "创建 MariaDB 容器..."
    echo "  - 端口: $MANTISBT_BIND:$MARIADB_PORT -> 3306"
    echo "  - 数据库: $MANTISBT_DB_NAME"
    echo "  - 用户: $MANTISBT_DB_USER"

    local volume_args=""
    if [[ "$MANTISBT_USE_NAMED_VOLUMES" == "true" ]]; then
        volume_args="-v $MARIADB_VOLUME_DATA:/var/lib/mysql"
    else
        volume_args="-v $MARIADB_DATA_DIR:/var/lib/mysql"
    fi

    docker run -d \
        --name "$MARIADB_CONTAINER_NAME" \
        --network devopsagent-network \
        --restart unless-stopped \
        -p "$MANTISBT_BIND:$MARIADB_PORT:3306" \
        $volume_args \
        -e MYSQL_ROOT_PASSWORD="$MANTISBT_DB_PASSWORD" \
        -e MYSQL_DATABASE="$MANTISBT_DB_NAME" \
        -e MYSQL_USER="$MANTISBT_DB_USER" \
        -e MYSQL_PASSWORD="$MANTISBT_DB_PASSWORD" \
        -e TZ=Asia/Shanghai \
        "$MARIADB_IMAGE"

    sleep 5

    if docker ps -q --filter "name=$MARIADB_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "✓ MariaDB 容器已启动"

        log_info "等待 MariaDB 就绪..."
        local max_attempts=30
        local attempt=0
        while [[ $attempt -lt $max_attempts ]]; do
            if docker exec "$MARIADB_CONTAINER_NAME" mysqladmin ping -h localhost -u root -p"$MANTISBT_DB_PASSWORD" --silent 2>/dev/null; then
                log_info "✓ MariaDB 已就绪"
                return 0
            fi
            attempt=$((attempt + 1))
            sleep 2
        done
        log_warn "MariaDB 可能未完全就绪，继续部署..."
        return 0
    else
        log_error "MariaDB 容器启动失败"
        return 1
    fi
}

deploy_mantisbt() {
    log_step "部署 MantisBT Bug 追踪系统"

    deploy_mantisbt_db

    if [[ -z "$MANTISBT_DB_PASSWORD" ]]; then
        log_warn "MANTISBT_DB_PASSWORD 未设置，使用默认密码: mantisbt_secret"
    fi

    if [[ "$MANTISBT_USE_NAMED_VOLUMES" == "true" ]]; then
        log_info "使用 Docker 命名卷存储"
    else
        if [[ ! -d "$MANTISBT_DATA_DIR" ]]; then
            log_info "创建 MantisBT 数据目录: $MANTISBT_DATA_DIR"
            mkdir -p "$MANTISBT_DATA_DIR"
        fi
    fi

    if docker ps -q --filter "name=$MANTISBT_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "MantisBT 容器已在运行，停止并删除..."
        docker stop "$MANTISBT_CONTAINER_NAME" 2>/dev/null || true
        docker rm "$MANTISBT_CONTAINER_NAME" 2>/dev/null || true
    elif docker ps -aq --filter "name=$MANTISBT_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "删除已停止的 MantisBT 容器..."
        docker rm "$MANTISBT_CONTAINER_NAME" 2>/dev/null || true
    fi

    log_info "创建 MantisBT 容器..."
    echo "  - 端口: $MANTISBT_BIND:$MANTISBT_PORT_WEB -> 80"
    echo "  - 数据库主机: $MARIADB_CONTAINER_NAME"
    echo "  - 数据库端口: 3306"
    echo "  - 数据库名: $MANTISBT_DB_NAME"

    local volume_args=""
    if [[ "$MANTISBT_USE_NAMED_VOLUMES" == "true" ]]; then
        volume_args="-v $MANTISBT_VOLUME_WEB:/var/www/html"
    else
        volume_args="-v $MANTISBT_DATA_DIR:/var/www/html"
    fi

    docker run -d \
        --name "$MANTISBT_CONTAINER_NAME" \
        --network devopsagent-network \
        --restart unless-stopped \
        -p "$MANTISBT_BIND:$MANTISBT_PORT_WEB:80" \
        $volume_args \
        -e MANTISBT_DB_HOST="$MARIADB_CONTAINER_NAME" \
        -e MANTISBT_DB_PORT=3306 \
        -e MANTISBT_DB_NAME="$MANTISBT_DB_NAME" \
        -e MANTISBT_DB_USER="root" \
        -e MANTISBT_DB_PASSWORD="$MANTISBT_DB_PASSWORD" \
        -e MANTISBT_ADMIN_USER="$MANTISBT_ADMIN_USER" \
        -e MANTISBT_ADMIN_PASSWORD="$MANTISBT_ADMIN_PASSWORD" \
        -e TZ=Asia/Shanghai \
        "$MANTISBT_IMAGE"

    sleep 10

    if docker ps -q --filter "name=$MANTISBT_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        log_info "✓ MantisBT 容器已启动"
    else
        log_error "MantisBT 容器启动失败"
        log_warn "检查日志: docker logs $MANTISBT_CONTAINER_NAME"
        return 1
    fi

    log_info "等待 MantisBT 初始化 (安装数据库表)..."
    local max_attempts=60
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$MANTISBT_PORT_WEB/login_page.php" 2>/dev/null | grep -q "200\|302"; then
            log_info "✓ MantisBT 已就绪"
            break
        fi
        attempt=$((attempt + 1))
        sleep 3
    done

    log_info ""
    log_info "MantisBT 部署完成"
    log_info "===================="
    echo -e "  ${CYAN}访问地址:${NC}"
    echo -e "    - 直连: ${YELLOW}http://127.0.0.1:$MANTISBT_PORT_WEB${NC}"
    echo -e "    - Nginx: ${YELLOW}https://127.0.0.1:$MANTISBT_NGINX_PORT${NC}"
    echo
    echo -e "  ${CYAN}管理员登录:${NC}"
    echo -e "    - 用户名: ${YELLOW}$MANTISBT_ADMIN_USER${NC}"
    echo -e "    - 密码:   ${YELLOW}$MANTISBT_ADMIN_PASSWORD${NC}"
    echo
    echo -e "  ${CYAN}数据库信息:${NC}"
    echo -e "    - 主机: ${YELLOW}$MARIADB_CONTAINER_NAME:3306${NC}"
    echo -e "    - 数据库: ${YELLOW}$MANTISBT_DB_NAME${NC}"

    return 0
}

deploy_mantisbt_standalone() {
    log_banner
    log_step "MantisBT 一键部署/修复"
    deploy_mantisbt
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --deploy)
            deploy_mantisbt
            ;;
        --standalone)
            source "$PROJECT_DIR/lib/common.sh" 2>/dev/null || true
            deploy_mantisbt_standalone
            ;;
        *)
            echo "用法: $0 [--deploy|--standalone]"
            echo "  --deploy      部署 MantisBT"
            echo "  --standalone  独立部署（含 Nginx 集成检测）"
            exit 1
            ;;
    esac
fi
