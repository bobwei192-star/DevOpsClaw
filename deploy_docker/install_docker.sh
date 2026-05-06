#!/bin/bash
# =============================================================================
# Docker 安装脚本
# =============================================================================
# 支持: Ubuntu 22.04 / 24.04 (WSL & 原生)
# 功能:
#   - 自动检测系统版本
#   - 安装 Docker CE + Docker Compose Plugin
#   - 配置镜像加速器
#   - 添加当前用户到 docker 组
#
# 使用方法:
#   chmod +x install_docker.sh
#   sudo ./install_docker.sh
#
# =============================================================================

set -euo pipefail

# =============================================================================
# 配置变量
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Docker 镜像加速器列表
MIRRORS=(
    "https://docker.1ms.run"
    "https://docker.xuanyuan.me"
    "https://docker.xuanyuan.us.kg"
    "https://docker.chenby.cn"
)

# =============================================================================
# 颜色定义
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
    echo -e "${CYAN}"
    cat << 'EOF'
   ____             _             _           
  |  _ \  ___   ___| |_ __ _ _ __| |_ ___ _ __ 
  | | | |/ _ \ / __| __/ _` | '__| __/ _ \ '__|
  | |_| | (_) | (__| || (_| | |  | ||  __/ |   
  |____/ \___/ \___|\__\__,_|_|   \__\___|_|   
                                                 
EOF
    echo -e "${NC}"
    echo -e "${CYAN}Docker 安装脚本${NC}"
    echo -e "${CYAN}================${NC}"
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

detect_os() {
    log_step "检测系统信息"
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="$VERSION_CODENAME"
    else
        log_error "无法检测系统版本"
        exit 1
    fi
    
    log_info "操作系统: $PRETTY_NAME"
    log_info "版本代号: $OS_CODENAME"
    
    # 检查是否为 Ubuntu
    if [[ "$OS_NAME" != "ubuntu" ]]; then
        log_warn "此脚本主要针对 Ubuntu 优化，其他系统可能不兼容"
        read -p "是否继续? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "用户取消安装"
            exit 0
        fi
    fi
    
    # 检查版本
    if [[ "$OS_VERSION" != "22.04" && "$OS_VERSION" != "24.04" ]]; then
        log_warn "建议使用 Ubuntu 22.04 或 24.04"
        read -p "是否继续? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 0
        fi
    fi
}

check_existing_docker() {
    log_step "检查现有 Docker 安装"
    
    if command -v docker &>/dev/null; then
        local docker_version=$(docker --version 2>/dev/null)
        log_warn "检测到已安装 Docker: $docker_version"
        echo
        echo "选项:"
        echo "  [1] 重新安装 Docker（会删除现有容器和镜像）"
        echo "  [2] 仅配置镜像加速器"
        echo "  [3] 跳过，退出"
        echo
        read -p "请选择 (1-3): " choice
        
        case $choice in
            1)
                log_info "准备重新安装 Docker..."
                uninstall_existing_docker
                ;;
            2)
                log_info "仅配置镜像加速器..."
                configure_mirrors
                verify_installation
                exit 0
                ;;
            3)
                log_info "退出安装"
                exit 0
                ;;
            *)
                log_error "无效选项"
                exit 1
                ;;
        esac
    else
        log_info "未检测到 Docker，开始全新安装"
    fi
}

uninstall_existing_docker() {
    log_step "卸载现有 Docker"
    
    log_info "停止 Docker 服务..."
    systemctl stop docker.service docker.socket 2>/dev/null || true
    
    log_info "移除 Docker 包..."
    apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
    apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    
    log_warn "注意: /var/lib/docker 目录（容器、镜像、卷）未删除"
    read -p "是否删除 /var/lib/docker 目录? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "删除 /var/lib/docker 目录..."
        rm -rf /var/lib/docker
        rm -rf /var/lib/containerd
        log_info "已删除"
    fi
}

# =============================================================================
# 安装函数
# =============================================================================

install_dependencies() {
    log_step "安装依赖包"
    
    log_info "更新 apt 包索引..."
    apt-get update -qq
    
    log_info "安装必要的依赖..."
    apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common \
        apt-transport-https
    
    log_info "依赖安装完成 ✓"
}

add_docker_repo() {
    log_step "添加 Docker 官方源"
    
    # 创建 keyrings 目录
    install -m 0755 -d /etc/apt/keyrings
    
    # 添加 Docker GPG 密钥
    log_info "添加 Docker GPG 密钥..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # 添加 Docker 仓库
    log_info "添加 Docker 官方仓库..."
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    log_info "更新 apt 包索引..."
    apt-get update -qq
    
    log_info "Docker 仓库添加完成 ✓"
}

install_docker_packages() {
    log_step "安装 Docker 包"
    
    log_info "安装 Docker CE, CLI, Containerd, Docker Compose..."
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    
    # 启动 Docker 服务
    log_info "启动 Docker 服务..."
    systemctl enable docker.service
    systemctl enable containerd.service
    systemctl start docker.service
    systemctl start containerd.service
    
    log_info "Docker 包安装完成 ✓"
}

configure_mirrors() {
    log_step "配置 Docker 镜像加速器"
    
    # 备份现有配置
    if [[ -f /etc/docker/daemon.json ]]; then
        log_info "备份现有 daemon.json..."
        cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
    fi
    
    # 创建 Docker 配置目录
    mkdir -p /etc/docker
    
    # 生成镜像加速器 JSON
    log_info "配置镜像加速器..."
    
    # 构建 JSON 数组
    local mirrors_json="["
    local first=true
    for mirror in "${MIRRORS[@]}"; do
        if [[ "$first" == true ]]; then
            first=false
        else
            mirrors_json+=","
        fi
        mirrors_json+="\"$mirror\""
    done
    mirrors_json+="]"
    
    # 写入配置文件
    cat > /etc/docker/daemon.json << EOF
{
  "registry-mirrors": $mirrors_json
}
EOF
    
    log_info "已写入 /etc/docker/daemon.json"
    cat /etc/docker/daemon.json
    
    # 重启 Docker
    log_info "重启 Docker 服务..."
    systemctl daemon-reload
    systemctl restart docker
    
    log_info "镜像加速器配置完成 ✓"
}

configure_user_permissions() {
    log_step "配置用户权限"
    
    # 获取当前用户（即使使用 sudo）
    local current_user="${SUDO_USER:-$USER}"
    
    if [[ -n "$current_user" && "$current_user" != "root" ]]; then
        log_info "将用户 '$current_user' 添加到 docker 组..."
        
        # 创建 docker 组（如果不存在）
        getent group docker >/dev/null || groupadd docker
        
        # 添加用户到 docker 组
        usermod -aG docker "$current_user"
        
        log_info "用户权限配置完成 ✓"
        log_warn "⚠️  重要: 请注销并重新登录以使用户组变更生效"
        log_info "    或运行: newgrp docker（当前会话临时生效）"
    else
        log_warn "无法检测到当前用户，请手动添加用户到 docker 组:"
        log_info "  sudo usermod -aG docker your_username"
    fi
}

# =============================================================================
# 验证函数
# =============================================================================

verify_installation() {
    log_step "验证安装"
    
    echo
    
    # 检查 Docker 版本
    log_info "1. Docker 版本:"
    docker version
    
    echo
    
    # 检查 Docker Compose
    log_info "2. Docker Compose 版本:"
    docker compose version
    
    echo
    
    # 检查镜像加速器
    log_info "3. 镜像加速器配置:"
    docker info | grep -A 10 "Registry Mirrors" || echo "    未检测到"
    
    echo
    
    # 运行测试容器
    log_info "4. 运行测试容器 (hello-world)..."
    docker run --rm hello-world
    
    echo
    log_info "✓ Docker 安装和配置完成!"
}

# =============================================================================
# 输出函数
# =============================================================================

print_summary() {
    log_step "安装完成"
    
    echo
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    Docker 安装完成                                ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    echo -e "${CYAN}【已安装组件】${NC}"
    local docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "最新版")
    local compose_ver=$(docker compose version --short 2>/dev/null || echo "最新版")
    echo "  Docker CE:         $docker_ver"
    echo "  Docker CLI:        $docker_ver"
    echo "  Containerd:        已安装"
    echo "  Docker Compose:    $compose_ver"
    echo "  Buildx Plugin:     已安装"
    echo
    
    echo -e "${CYAN}【镜像加速器】${NC}"
    for mirror in "${MIRRORS[@]}"; do
        echo "  - $mirror"
    done
    echo
    
    echo -e "${CYAN}【常用命令】${NC}"
    echo "  查看版本:  docker version"
    echo "  查看信息:  docker info"
    echo "  运行测试:  docker run hello-world"
    echo "  查看镜像:  docker images"
    echo "  查看容器:  docker ps -a"
    echo "  重启服务:  sudo systemctl restart docker"
    echo
    
    echo -e "${YELLOW}【重要提示】${NC}"
    echo "  ⚠️  如果当前用户需要非 root 使用 Docker，请:"
    echo "     1. 注销并重新登录"
    echo "     2. 或运行: newgrp docker（临时生效）"
    echo
    echo "  ⚠️  如果在 WSL 中使用 Docker Desktop，请确保:"
    echo "     1. 打开 Docker Desktop Settings"
    echo "     2. Resources → WSL Integration → 启用你的发行版"
    echo
    
    log_info "Docker 安装完成!"
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    log_banner
    
    # 检查
    check_root
    detect_os
    check_existing_docker
    
    # 安装
    install_dependencies
    add_docker_repo
    install_docker_packages
    configure_mirrors
    configure_user_permissions
    
    # 验证
    verify_installation
    
    # 输出
    print_summary
}

# =============================================================================
# 信号处理
# =============================================================================

trap 'log_warn "脚本被用户中断"; exit 1' INT TERM

# 执行主函数
main "$@"
