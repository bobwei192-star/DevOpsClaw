#!/bin/bash
# =============================================================================
# DevOpsAgent Docker 安装脚本
# =============================================================================
# 功能：
#   - 安装 Docker CE
#   - 安装 Docker Compose
#   - 配置 Docker 镜像加速器
#   - 多源镜像拉取函数
#
# 使用方法：
#   - 独立运行: sudo ./deploy_docker/install_docker.sh
#   - 被主脚本调用: source deploy_docker/install_docker.sh
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
        log_info "请先安装 Docker 或运行: $0"
        exit 1
    fi
    
    log_info "Docker 已安装: $(docker --version)"
    
    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
        log_info "Docker Compose (plugin) 已安装: $(docker compose version --short 2>/dev/null || echo "可用")"
    elif command -v docker-compose &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
        log_info "Docker Compose (standalone) 已安装: $(docker-compose version --short 2>/dev/null || echo "可用")"
    else
        log_error "Docker Compose 未安装"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION_ID="$VERSION_ID"
        OS_NAME="$PRETTY_NAME"
    elif [[ -f /etc/centos-release ]]; then
        OS_ID="centos"
        OS_VERSION_ID=$(cat /etc/centos-release | grep -oP '\d+\.\d+')
        OS_NAME=$(cat /etc/centos-release)
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="rhel"
        OS_VERSION_ID=$(cat /etc/redhat-release | grep -oP '\d+\.\d+')
        OS_NAME=$(cat /etc/redhat-release)
    else
        log_error "无法检测操作系统版本"
        exit 1
    fi
    
    log_info "检测到操作系统: $OS_NAME"
}

install_docker_ubuntu() {
    log_step "在 Ubuntu/Debian 上安装 Docker"
    
    log_info "更新软件包列表..."
    apt-get update -y
    
    log_info "安装依赖包..."
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    log_info "添加 Docker GPG 密钥..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg 2>/dev/null || {
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    }
    
    log_info "设置 Docker 仓库..."
    if [[ -d /usr/share/keyrings ]]; then
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
            $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    else
        add-apt-repository \
            "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu \
            $(lsb_release -cs) stable"
    fi
    
    log_info "更新软件包列表并安装 Docker CE..."
    apt-get update -y
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
}

install_docker_centos() {
    log_step "在 CentOS/RHEL 上安装 Docker"
    
    log_info "安装依赖包..."
    yum install -y yum-utils device-mapper-persistent-data lvm2
    
    log_info "设置 Docker 仓库..."
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    
    log_info "启用 nightly 仓库（可选）..."
    yum-config-manager --enable docker-ce-nightly 2>/dev/null || true
    
    log_info "安装 Docker CE..."
    yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    log_info "启动 Docker 服务..."
    systemctl start docker
    systemctl enable docker
}

install_docker() {
    detect_os
    
    if command -v docker &>/dev/null; then
        log_info "Docker 已安装: $(docker --version)"
        
        local docker_version=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        local major_version=$(echo "$docker_version" | cut -d. -f1)
        local minor_version=$(echo "$docker_version" | cut -d. -f2)
        
        if [[ $major_version -lt 20 || ($major_version -eq 20 && $minor_version -lt 10) ]]; then
            log_warn "Docker 版本较旧 ($docker_version)，建议升级到 20.10+"
        fi
        
        if ! docker info &>/dev/null; then
            log_warn "Docker 已安装但无法运行，尝试启动..."
            if command -v systemctl &>/dev/null; then
                systemctl start docker
            elif command -v service &>/dev/null; then
                service docker start
            fi
        fi
        
        return 0
    fi
    
    log_step "安装 Docker CE"
    
    case "$OS_ID" in
        ubuntu|debian|linuxmint)
            install_docker_ubuntu
            ;;
        centos|rhel|fedora)
            install_docker_centos
            ;;
        *)
            log_error "不支持的操作系统: $OS_ID"
            log_info "请手动安装 Docker: https://docs.docker.com/engine/install/"
            exit 1
            ;;
    esac
    
    log_info "验证 Docker 安装..."
    docker run hello-world
    
    log_info "Docker 安装完成: $(docker --version)"
}

install_docker_compose() {
    log_step "安装 Docker Compose"
    
    if docker compose version &>/dev/null; then
        log_info "Docker Compose (plugin) 已安装: $(docker compose version --short 2>/dev/null || echo "可用")"
        return 0
    fi
    
    if command -v docker-compose &>/dev/null; then
        log_info "Docker Compose (standalone) 已安装: $(docker-compose version --short 2>/dev/null || echo "可用")"
        return 0
    fi
    
    log_warn "Docker Compose 未安装，正在安装..."
    
    local COMPOSE_VERSION="2.23.3"
    local COMPOSE_URL="https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)"
    
    log_info "下载 Docker Compose $COMPOSE_VERSION..."
    if curl -SL "$COMPOSE_URL" -o /usr/local/bin/docker-compose; then
        chmod +x /usr/local/bin/docker-compose
        log_info "Docker Compose 安装完成: $(docker-compose --version)"
    else
        log_error "Docker Compose 下载失败"
        log_info "请手动安装: https://docs.docker.com/compose/install/"
        exit 1
    fi
}

configure_docker_mirrors() {
    log_step "配置 Docker 镜像加速器"
    
    local daemon_json="/etc/docker/daemon.json"
    local daemon_dir="/etc/docker"
    
    if [[ ! -d "$daemon_dir" ]]; then
        mkdir -p "$daemon_dir"
    fi
    
    local existing_mirrors=()
    if [[ -f "$daemon_json" ]]; then
        log_info "现有的 daemon.json 配置:"
        cat "$daemon_json"
        
        if command -v jq &>/dev/null; then
            while IFS= read -r mirror; do
                existing_mirrors+=("$mirror")
            done < <(jq -r '.["registry-mirrors"] // [] | .[]' "$daemon_json" 2>/dev/null)
        fi
    fi
    
    local new_mirrors=(
        "https://docker.xuanyuan.me"
        "https://docker.1ms.run"
        "https://xuanyuan.cloud"
        "https://docker.m.daocloud.io"
        "https://dockerproxy.com"
        "https://atomhub.openatom.cn"
        "https://docker.nju.edu.cn"
    )
    
    local all_mirrors=()
    for mirror in "${existing_mirrors[@]}"; do
        if [[ -n "$mirror" ]]; then
            all_mirrors+=("$mirror")
        fi
    done
    for mirror in "${new_mirrors[@]}"; do
        local exists=false
        for existing in "${all_mirrors[@]}"; do
            if [[ "$existing" == "$mirror" ]]; then
                exists=true
                break
            fi
        done
        if [[ "$exists" == false ]]; then
            all_mirrors+=("$mirror")
        fi
    done
    
    local mirrors_json=""
    if [[ ${#all_mirrors[@]} -gt 0 ]]; then
        mirrors_json=$(printf '%s\n' "${all_mirrors[@]}" | sed 's/^/        "/; s/$/"/' | tr '\n' ',' | sed 's/,$//')
    fi
    
    log_info "准备应用以下镜像加速器配置:"
    cat > "/tmp/daemon.json.tmp" << EOF
{
    "registry-mirrors": [
${mirrors_json}
    ],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "5"
    }
}
EOF
    cat "/tmp/daemon.json.tmp"
    echo
    
    log_info "正在应用配置..."
    mv "/tmp/daemon.json.tmp" "$daemon_json"
    
    log_info "重启 Docker 服务以应用配置..."
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload
        systemctl restart docker
    elif command -v service &>/dev/null; then
        service docker restart
    fi
    
    sleep 3
    
    if docker info &>/dev/null; then
        log_info "✓ Docker 配置已生效"
    else
        log_warn "Docker 重启后可能需要手动验证配置"
    fi
    
    echo
    echo -e "${GREEN}镜像加速器配置完成${NC}"
    echo
    
    log_info "镜像源说明:"
    log_info "  - docker.1ms.run      (国内高速镜像)"
    log_info "  - docker.xuanyuan.me   (轩辕镜像)"
    log_info "  - docker.chenby.cn     (陈冰宇镜像)"
    log_info "  - hub.rat.dev          (Rat 镜像)"
    echo
    log_info "如果仍然无法拉取镜像，请考虑:"
    log_info "  1. 检查网络连接"
    log_info "  2. 尝试使用代理: export HTTP_PROXY=http://127.0.0.1:7890"
    log_info "  3. 手动拉取镜像: docker pull <镜像名>"
}

pull_image_with_fallback() {
    local service="$1"
    local target_tag="${2:-}"
    
    local -a sources=()
    local -a source_names=()
    
    case "$service" in
        agent)
            sources=(
                "ghcr.io/agent/agent:latest"
                "docker.io/agent/agent:latest"
            )
            source_names=(
                "github-ghcr"
                "dockerhub"
            )
            ;;
        jenkins)
            sources=(
                "docker.io/jenkins/jenkins:lts-jdk21"
                "registry.cn-hangzhou.aliyuncs.com/library/jenkins:lts-jdk21"
                "docker.mirrors.sjtug.sjtu.edu.cn/library/jenkins:lts-jdk21"
            )
            source_names=(
                "dockerhub"
                "aliyun"
                "sjtug"
            )
            ;;
        gitlab)
            sources=(
                "docker.io/gitlab/gitlab-ce:latest"
                "registry.cn-hangzhou.aliyuncs.com/gitlab/gitlab-ce:latest"
                "docker.mirrors.sjtug.sjtu.edu.cn/gitlab/gitlab-ce:latest"
            )
            source_names=(
                "dockerhub"
                "aliyun"
                "sjtug"
            )
            ;;
        nginx)
            sources=(
                "docker.io/library/nginx:alpine"
                "registry.cn-hangzhou.aliyuncs.com/library/nginx:alpine"
                "docker.mirrors.sjtug.sjtu.edu.cn/library/nginx:alpine"
            )
            source_names=(
                "dockerhub"
                "aliyun"
                "sjtug"
            )
            ;;
        *)
            log_error "未知服务: $service"
            return 1
            ;;
    esac
    
    local max_retries=2
    local pull_timeout=120
    local success=false
    local pulled_image=""
    
    log_info "尝试拉取 $service 镜像（支持多源重试，每个源最多 $max_retries 次，超时 $pull_timeout 秒）..."
    
    local idx=0
    for image in "${sources[@]}"; do
        local source_name="${source_names[$idx]:-$idx}"
        idx=$((idx + 1))
        
        if [[ -z "$image" ]]; then
            continue
        fi
        
        log_info "尝试源 [$source_name]: $image"
        
        for ((i=1; i<=max_retries; i++)); do
            log_info "  第 $i 次尝试拉取... (超时: ${pull_timeout}秒)"
            
            if command -v timeout &>/dev/null; then
                if timeout $pull_timeout docker pull "$image" 2>&1; then
                    log_info "  ✓ 镜像拉取成功: $image"
                    pulled_image="$image"
                    success=true
                    break 2
                else
                    local exit_code=$?
                    if [[ $exit_code -eq 124 ]]; then
                        log_warn "  第 $i 次尝试超时 (${pull_timeout}秒)"
                    else
                        log_warn "  第 $i 次尝试失败 (退出码: $exit_code)"
                    fi
                fi
            else
                if docker pull "$image"; then
                    log_info "  ✓ 镜像拉取成功: $image"
                    pulled_image="$image"
                    success=true
                    break 2
                else
                    log_warn "  第 $i 次尝试失败"
                fi
            fi
            
            if [[ $i -lt $max_retries ]]; then
                log_info "  等待 3 秒后重试..."
                sleep 3
            fi
        done
        
        if [[ "$success" != true ]]; then
            log_warn "源 [$source_name] 失败，尝试下一个源..."
        fi
    done
    
    if [[ "$success" != true ]]; then
        log_error "所有镜像源都尝试过了，仍然失败"
        log_warn "可能的解决方案:"
        echo
        
        echo -e "${CYAN}【方案 1】配置 Docker 镜像加速器${NC}"
        echo "  本脚本已自动配置，如已运行请跳过。手动配置方法:"
        echo
        echo '  创建或编辑 /etc/docker/daemon.json:'
        echo
        echo '  {'
        echo '    "registry-mirrors": ['
        echo '      "https://docker.1ms.run",'
        echo '      "https://docker.xuanyuan.me",'
        echo '      "https://docker.xuanyuan.us.kg",'
        echo '      "https://docker.chenby.cn",'
        echo '      "https://hub.rat.dev",'
        echo '      "https://docker.1panel.top"'
        echo '    ]'
        echo '  }'
        echo
        echo "  然后执行:"
        echo "    sudo systemctl daemon-reload"
        echo "    sudo systemctl restart docker"
        echo
        
        echo -e "${CYAN}【方案 2】配置代理访问 GHCR${NC}"
        echo "  export HTTP_PROXY=http://127.0.0.1:7890"
        echo "  export HTTPS_PROXY=http://127.0.0.1:7890"
        echo "  sudo -E docker pull ghcr.io/agent/agent:latest"
        echo
        
        return 1
    fi
    
    if [[ -n "$target_tag" && "$pulled_image" != "$target_tag" ]]; then
        log_info "重命名镜像: $pulled_image -> $target_tag"
        if docker tag "$pulled_image" "$target_tag"; then
            log_info "  ✓ 镜像重命名成功"
        else
            log_warn "  镜像重命名失败，但拉取已成功"
        fi
    fi
    
    return 0
}

show_help() {
    echo
    echo -e "${BOLD}DevOpsAgent Docker 安装脚本${NC}"
    echo
    echo -e "用法: $0 [选项]"
    echo
    echo -e "选项:"
    echo -e "  ${CYAN}-h, --help${NC}              显示此帮助信息"
    echo -e "  ${CYAN}--install${NC}               安装 Docker 和 Docker Compose (默认)"
    echo -e "  ${CYAN}--configure-mirrors${NC}     只配置镜像加速器"
    echo -e "  ${CYAN}--pull <service>${NC}        拉取指定服务的镜像"
    echo -e "  ${CYAN}--check${NC}                 检查 Docker 环境"
    echo
    echo -e "服务列表:"
    echo -e "  ${GREEN}agent${NC}                Agent 镜像"
    echo -e "  ${GREEN}jenkins${NC}                 Jenkins 镜像"
    echo -e "  ${GREEN}gitlab${NC}                  GitLab 镜像"
    echo -e "  ${GREEN}nginx${NC}                   Nginx 镜像"
    echo
    echo -e "示例:"
    echo -e "  $0                              安装 Docker 并配置镜像"
    echo -e "  $0 --configure-mirrors         只配置镜像加速器"
    echo -e "  $0 --pull jenkins              拉取 Jenkins 镜像"
    echo -e "  $0 --check                     检查 Docker 环境"
    echo
}

main() {
    local action="install"
    local pull_service=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --install)
                action="install"
                shift
                ;;
            --configure-mirrors)
                action="configure_mirrors"
                shift
                ;;
            --pull)
                action="pull"
                pull_service="$2"
                shift 2
                ;;
            --check)
                action="check"
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
        install)
            check_root
            install_docker
            install_docker_compose
            configure_docker_mirrors
            log_info "Docker 安装和配置完成!"
            ;;
        configure_mirrors)
            check_root
            configure_docker_mirrors
            log_info "镜像加速器配置完成!"
            ;;
        pull)
            check_docker
            if [[ -z "$pull_service" ]]; then
                log_error "请指定要拉取的服务"
                show_help
                exit 1
            fi
            pull_image_with_fallback "$pull_service"
            ;;
        check)
            check_docker
            log_info "Docker 环境检查通过!"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
