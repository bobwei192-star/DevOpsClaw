#!/bin/bash
# =============================================================================
# DevOpsClaw 一键部署脚本 v5.0.0
# =============================================================================
# 功能:
#   - 交互式选择部署模式
#   - 配置环境变量
#   - 调用各子脚本执行具体部署任务
#   - 统一输出部署结果
#
# 使用方法:
#   chmod +x deploy_all.sh
#   sudo ./deploy_all.sh
#
# 命令行选项:
#   --help, -h              显示帮助信息
#   --get-jenkins-password  获取 Jenkins 初始密码
#   --get-gitlab-password   获取 GitLab 初始密码
#   --reset-openclaw-device 重置 OpenClaw 设备
#   --list-openclaw-devices 列出 OpenClaw 待配对设备
#   --approve-openclaw-device 批准 OpenClaw 设备配对
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
#
# 架构:
#   deploy_all.sh (主控制脚本)
#   ├── deploy_docker/install_docker.sh   (Docker 安装)
#   ├── deploy_jenkins/deploy_jenkins.sh  (Jenkins 部署)
#   ├── deploy_gitlab/deploy_gitlab.sh    (GitLab 部署)
#   ├── deploy_openclaw/deploy_openclaw.sh (OpenClaw 部署)
#   └── deploy_nginx/deploy_nginx.sh      (Nginx 部署)
#
# =============================================================================

set -euo pipefail

# =============================================================================
# 配置变量
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
ENV_FILE="$PROJECT_ROOT/.env"
ENV_EXAMPLE="$PROJECT_ROOT/.env.example"
DOCKER_COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"
DEPLOY_LOG="$PROJECT_ROOT/deploy.log"

# 子脚本路径
DOCKER_INSTALL_SCRIPT="$PROJECT_ROOT/deploy_docker/install_docker.sh"
JENKINS_DEPLOY_SCRIPT="$PROJECT_ROOT/deploy_jenkins/deploy_jenkins.sh"
GITLAB_DEPLOY_SCRIPT="$PROJECT_ROOT/deploy_gitlab/deploy_gitlab.sh"
OPENCLAW_DEPLOY_SCRIPT="$PROJECT_ROOT/deploy_openclaw/deploy_openclaw.sh"
NGINX_DEPLOY_SCRIPT="$PROJECT_ROOT/deploy_nginx/deploy_nginx.sh"

# 端口配置
PORTS=(
    "OpenClaw:18789"
    "Jenkins Web:18081"
    "Jenkins Agent:50000"
    "GitLab HTTP:19092"
    "GitLab HTTPS:19443"
    "GitLab SSH:2222"
)

# Nginx 端口配置
NGINX_PORTS=(
    "Nginx Jenkins:18440"
    "Nginx GitLab:18441"
    "Nginx OpenClaw:18442"
    "Nginx Registry:18444"
    "Nginx Harbor:18445"
    "Nginx SonarQube:18446"
)

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
    echo -e "${CYAN}DevOpsClaw 一键部署脚本 v5.0.0${NC}" | tee -a "$DEPLOY_LOG"
    echo -e "${CYAN}========================================${NC}" | tee -a "$DEPLOY_LOG"
}

# =============================================================================
# 帮助函数
# =============================================================================
show_help() {
    echo -e "${CYAN}DevOpsClaw 一键部署脚本 v5.0.0${NC}"
    echo
    echo -e "${BLUE}用法:${NC}"
    echo "  sudo ./deploy_all.sh [选项]"
    echo
    echo -e "${BLUE}选项:${NC}"
    echo "  -h, --help                    显示此帮助信息"
    echo "  --get-jenkins-password        获取 Jenkins 初始密码"
    echo "  --get-gitlab-password         获取 GitLab 初始密码"
    echo "  --reset-openclaw-device       重置 OpenClaw 设备（解决 device signature expired 问题）"
    echo "  --list-openclaw-devices       列出 OpenClaw 待配对设备"
    echo "  --approve-openclaw-device     批准 OpenClaw 设备配对（需要 UUID 参数）"
    echo
    echo -e "${BLUE}示例:${NC}"
    echo "  sudo ./deploy_all.sh                              # 交互式部署"
    echo "  sudo ./deploy_all.sh --get-jenkins-password      # 获取 Jenkins 密码"
    echo "  sudo ./deploy_all.sh --get-gitlab-password       # 获取 GitLab 密码"
    echo "  sudo ./deploy_all.sh --reset-openclaw-device     # 重置 OpenClaw 设备"
    echo "  sudo ./deploy_all.sh --list-openclaw-devices     # 列出待配对设备"
    echo "  sudo ./deploy_all.sh --approve-openclaw-device <UUID>  # 批准设备配对"
    echo
    echo -e "${YELLOW}注意:${NC}"
    echo "  - 获取密码需要服务已启动"
    echo "  - Jenkins 密码文件: /var/jenkins_home/secrets/initialAdminPassword"
    echo "  - GitLab 密码文件: /etc/gitlab/initial_root_password (24小时后自动删除)"
    echo "  - OpenClaw device signature expired 问题: 使用 --reset-openclaw-device 重置"
    echo
}

# =============================================================================
# 命令行选项处理函数（调用子脚本）
# =============================================================================
get_jenkins_password_simple() {
    if [[ -x "$JENKINS_DEPLOY_SCRIPT" ]]; then
        log_info "调用 Jenkins 部署脚本获取密码..."
        "$JENKINS_DEPLOY_SCRIPT" --get-password
    else
        log_error "Jenkins 部署脚本不存在或不可执行: $JENKINS_DEPLOY_SCRIPT"
        exit 1
    fi
}

get_gitlab_password_simple() {
    if [[ -x "$GITLAB_DEPLOY_SCRIPT" ]]; then
        log_info "调用 GitLab 部署脚本获取密码..."
        "$GITLAB_DEPLOY_SCRIPT" --get-password
    else
        log_error "GitLab 部署脚本不存在或不可执行: $GITLAB_DEPLOY_SCRIPT"
        exit 1
    fi
}

reset_openclaw_device() {
    if [[ -x "$OPENCLAW_DEPLOY_SCRIPT" ]]; then
        log_info "调用 OpenClaw 部署脚本重置设备..."
        "$OPENCLAW_DEPLOY_SCRIPT" --reset-device
    else
        log_error "OpenClaw 部署脚本不存在或不可执行: $OPENCLAW_DEPLOY_SCRIPT"
        exit 1
    fi
}

list_openclaw_devices() {
    if [[ -x "$OPENCLAW_DEPLOY_SCRIPT" ]]; then
        log_info "调用 OpenClaw 部署脚本列出设备..."
        "$OPENCLAW_DEPLOY_SCRIPT" --list-devices
    else
        log_error "OpenClaw 部署脚本不存在或不可执行: $OPENCLAW_DEPLOY_SCRIPT"
        exit 1
    fi
}

approve_openclaw_device() {
    local device_uuid="$1"
    
    if [[ -z "$device_uuid" ]]; then
        log_error "请提供设备 UUID"
        log_info "用法: sudo ./deploy_all.sh --approve-openclaw-device <UUID>"
        log_info "使用 --list-openclaw-devices 查看待配对设备"
        exit 1
    fi
    
    if [[ -x "$OPENCLAW_DEPLOY_SCRIPT" ]]; then
        log_info "调用 OpenClaw 部署脚本批准设备..."
        "$OPENCLAW_DEPLOY_SCRIPT" --approve-device "$device_uuid"
    else
        log_error "OpenClaw 部署脚本不存在或不可执行: $OPENCLAW_DEPLOY_SCRIPT"
        exit 1
    fi
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
    
    if [[ -x "$DOCKER_INSTALL_SCRIPT" ]]; then
        log_info "调用 Docker 安装脚本检查环境..."
        "$DOCKER_INSTALL_SCRIPT" --check
    else
        log_warn "Docker 安装脚本不存在，尝试直接检查..."
        
        if ! command -v docker &>/dev/null; then
            log_error "Docker 未安装"
            log_info "请先运行: $DOCKER_INSTALL_SCRIPT"
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
    fi
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
# 部署模式选择
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
    read -p "请输入选项 (1-8): " choice
    
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
# 部署执行函数
# =============================================================================
deploy_services() {
    log_step "执行部署"
    
    local services=($DEPLOY_SERVICES)
    
    for service in "${services[@]}"; do
        case $service in
            openclaw)
                log_step "部署 OpenClaw"
                if [[ -x "$OPENCLAW_DEPLOY_SCRIPT" ]]; then
                    "$OPENCLAW_DEPLOY_SCRIPT" --deploy
                else
                    log_error "OpenClaw 部署脚本不存在: $OPENCLAW_DEPLOY_SCRIPT"
                    exit 1
                fi
                ;;
            jenkins)
                log_step "部署 Jenkins"
                if [[ -x "$JENKINS_DEPLOY_SCRIPT" ]]; then
                    "$JENKINS_DEPLOY_SCRIPT" --deploy
                else
                    log_error "Jenkins 部署脚本不存在: $JENKINS_DEPLOY_SCRIPT"
                    exit 1
                fi
                ;;
            gitlab)
                log_step "部署 GitLab"
                if [[ -x "$GITLAB_DEPLOY_SCRIPT" ]]; then
                    "$GITLAB_DEPLOY_SCRIPT" --deploy
                else
                    log_error "GitLab 部署脚本不存在: $GITLAB_DEPLOY_SCRIPT"
                    exit 1
                fi
                ;;
            nginx)
                log_step "部署 Nginx"
                if [[ -x "$NGINX_DEPLOY_SCRIPT" ]]; then
                    "$NGINX_DEPLOY_SCRIPT" --deploy
                else
                    log_error "Nginx 部署脚本不存在: $NGINX_DEPLOY_SCRIPT"
                    exit 1
                fi
                ;;
        esac
    done
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
    echo -e "${BOLD}部署服务:${NC} ${DEPLOY_SERVICES:-无}"
    if [[ "$USE_NGINX" == true ]]; then
        echo -e "${BOLD}反向代理:${NC} Nginx (HTTPS)"
    fi
    echo
    
    if [[ "$USE_NGINX" == true ]]; then
        echo -e "${CYAN}【Nginx 反向代理访问地址 (HTTPS)】${NC}"
        echo
        if [[ " $DEPLOY_SERVICES " =~ " jenkins " ]]; then
            echo "  Jenkins:   https://127.0.0.1:18440/jenkins/"
        fi
        if [[ " $DEPLOY_SERVICES " =~ " openclaw " ]]; then
            echo "  OpenClaw:  https://127.0.0.1:18442"
        fi
        if [[ " $DEPLOY_SERVICES " =~ " gitlab " ]]; then
            echo "  GitLab:    https://127.0.0.1:18441"
        fi
        echo
        echo -e "${YELLOW}【提示】${NC} 由于使用自签名证书，浏览器会显示 '不安全' 警告"
        echo "       请点击 '高级' -> '继续访问' 即可继续使用"
        echo
    else
        echo -e "${CYAN}【直接访问地址】${NC}"
        echo
        if [[ " $DEPLOY_SERVICES " =~ " jenkins " ]]; then
            echo "  Jenkins:   http://127.0.0.1:18081/jenkins/"
        fi
        if [[ " $DEPLOY_SERVICES " =~ " openclaw " ]]; then
            echo "  OpenClaw:  http://127.0.0.1:18789"
        fi
        if [[ " $DEPLOY_SERVICES " =~ " gitlab " ]]; then
            echo "  GitLab:    http://127.0.0.1:19092"
        fi
        echo
    fi
    
    echo -e "${CYAN}【各服务独立管理脚本】${NC}"
    echo
    echo "  Docker:    $DOCKER_INSTALL_SCRIPT"
    echo "  Jenkins:   $JENKINS_DEPLOY_SCRIPT"
    echo "  GitLab:    $GITLAB_DEPLOY_SCRIPT"
    echo "  OpenClaw:  $OPENCLAW_DEPLOY_SCRIPT"
    echo "  Nginx:     $NGINX_DEPLOY_SCRIPT"
    echo
    
    echo -e "${YELLOW}【重要提示】${NC}"
    echo "  - 请妥善保存初始密码和 Token"
    echo "  - 部署日志已保存到: $DEPLOY_LOG"
    echo "  - 可使用各独立脚本进行单独管理"
    echo
    
    echo -e "${CYAN}【常用命令】${NC}"
    echo
    echo "  查看 Docker 状态:     docker ps"
    echo "  查看 Docker 日志:     docker logs -f <容器名>"
    echo "  获取 Jenkins 密码:   sudo $0 --get-jenkins-password"
    echo "  获取 GitLab 密码:    sudo $0 --get-gitlab-password"
    echo "  重置 OpenClaw 设备:  sudo $0 --reset-openclaw-device"
    echo
    
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
}

# =============================================================================
# 部署测试函数
# =============================================================================
run_deployment_tests() {
    log_step "运行部署后测试"
    
    local TEST_SCRIPT="$PROJECT_ROOT/tests/test_deployment.py"
    local REPORT_FILE="$PROJECT_ROOT/tests/deployment_test_report.txt"
    
    if [[ ! -f "$TEST_SCRIPT" ]]; then
        log_warn "测试脚本不存在: $TEST_SCRIPT"
        log_info "跳过测试"
        return 0
    fi
    
    if ! command -v python3 &>/dev/null; then
        log_warn "Python3 未安装，跳过测试"
        return 0
    fi
    
    if ! python3 -c "import pytest" &>/dev/null 2>&1; then
        log_warn "pytest 未安装，跳过测试"
        log_info "可运行: pip install pytest"
        return 0
    fi
    
    echo
    echo -e "${CYAN}【部署后测试】${NC}"
    echo "  正在运行测试脚本: $TEST_SCRIPT"
    echo "  测试报告将保存到: $REPORT_FILE"
    echo
    
    # 运行测试（不使用 set -e，允许测试失败）
    set +e
    python3 "$TEST_SCRIPT" --quick 2>&1 | tee -a "$DEPLOY_LOG"
    local TEST_EXIT_CODE=$?
    set -e
    
    echo
    if [[ $TEST_EXIT_CODE -eq 0 ]]; then
        log_info "✓ 部署后测试完成"
    else
        log_warn "部分测试可能失败，请查看报告: $REPORT_FILE"
        log_info "注意: 某些服务（如 GitLab）可能需要几分钟才能完全启动"
        log_info "      建议稍后手动运行: pytest tests/test_deployment.py -v"
    fi
    
    echo
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
    check_ports
    setup_env
    
    # 部署
    deploy_services
    
    # 输出结果
    print_summary
    
    # 运行部署后测试
    run_deployment_tests
    
    log_info "部署流程完成!"
}

# =============================================================================
# 信号处理
# =============================================================================
trap 'log_warn "脚本被用户中断"; exit 1' INT TERM

# =============================================================================
# 命令行参数解析
# =============================================================================
if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --get-jenkins-password)
            if [[ $EUID -ne 0 ]]; then
                log_warn "建议使用 sudo 运行以确保权限"
            fi
            get_jenkins_password_simple
            exit 0
            ;;
        --get-gitlab-password)
            if [[ $EUID -ne 0 ]]; then
                log_warn "建议使用 sudo 运行以确保权限"
            fi
            get_gitlab_password_simple
            exit 0
            ;;
        --reset-openclaw-device)
            if [[ $EUID -ne 0 ]]; then
                log_warn "建议使用 sudo 运行以确保权限"
            fi
            reset_openclaw_device
            exit 0
            ;;
        --list-openclaw-devices)
            if [[ $EUID -ne 0 ]]; then
                log_warn "建议使用 sudo 运行以确保权限"
            fi
            list_openclaw_devices
            exit 0
            ;;
        --approve-openclaw-device)
            if [[ $EUID -ne 0 ]]; then
                log_warn "建议使用 sudo 运行以确保权限"
            fi
            approve_openclaw_device "${2:-}"
            exit 0
            ;;
        *)
            log_error "未知选项: $1"
            echo
            show_help
            exit 1
            ;;
    esac
fi

# 执行主函数
main "$@"
