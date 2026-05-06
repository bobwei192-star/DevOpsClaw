#!/bin/bash
# =============================================================================
# 生成自签名 SSL 证书脚本
# =============================================================================
# 用于 Nginx 反向代理的 HTTPS 配置
#
# 使用方法:
#   chmod +x generate_certs.sh
#   ./generate_certs.sh
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSL_DIR="$SCRIPT_DIR/nginx/ssl"
OPENSSL_CONF="$SSL_DIR/openssl.cnf"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# 检查 openssl 是否可用
check_openssl() {
    if ! command -v openssl &>/dev/null; then
        log_error "openssl 命令未找到，请先安装 openssl"
        exit 1
    fi
    log_info "OpenSSL 版本: $(openssl version)"
}

# 创建 SSL 目录
create_ssl_dir() {
    log_step "创建 SSL 目录"
    
    mkdir -p "$SSL_DIR"
    log_info "SSL 目录: $SSL_DIR"
}

# 生成自签名证书
generate_certificates() {
    log_step "生成自签名 SSL 证书"
    
    local cert_file="$SSL_DIR/devopsclaw.crt"
    local key_file="$SSL_DIR/devopsclaw.key"
    local days=3650
    
    # 检查配置文件是否存在
    if [[ ! -f "$OPENSSL_CONF" ]]; then
        log_error "OpenSSL 配置文件不存在: $OPENSSL_CONF"
        exit 1
    fi
    
    log_info "证书有效期: $days 天"
    log_info "证书文件: $cert_file"
    log_info "私钥文件: $key_file"
    
    # 生成自签名证书
    openssl req -x509 -nodes -days "$days" \
        -newkey rsa:2048 \
        -keyout "$key_file" \
        -out "$cert_file" \
        -config "$OPENSSL_CONF"
    
    if [[ $? -eq 0 ]]; then
        log_info "证书生成成功 ✓"
    else
        log_error "证书生成失败"
        exit 1
    fi
    
    # 设置权限
    chmod 600 "$key_file"
    chmod 644 "$cert_file"
    
    log_info "私钥权限已设置为 600"
}

# 显示证书信息
show_cert_info() {
    log_step "证书信息"
    
    local cert_file="$SSL_DIR/devopsclaw.crt"
    
    echo
    openssl x509 -in "$cert_file" -noout -subject -dates -ext subjectAltName
    echo
}

# 输出使用说明
print_instructions() {
    log_step "使用说明"
    
    echo
    echo -e "${CYAN}【证书文件位置】${NC}"
    echo "  证书: $SSL_DIR/devopsclaw.crt"
    echo "  私钥: $SSL_DIR/devopsclaw.key"
    echo
    echo -e "${CYAN}【Docker Compose 配置】${NC}"
    echo "  证书会自动挂载到 Nginx 容器的 /etc/nginx/ssl/ 目录"
    echo
    echo -e "${CYAN}【客户端配置】${NC}"
    echo "  由于是自签名证书，客户端需要进行以下配置:"
    echo
    echo "  1. 浏览器访问时:"
    echo "     - 点击 '高级' -> '继续前往'"
    echo "     - 或导入证书到系统信任根证书"
    echo
    echo "  2. Docker 配置（如使用 Harbor）:"
    echo "     - 将证书复制到 /etc/docker/certs.d/<registry>/ca.crt"
    echo "     - 或配置 /etc/docker/daemon.json 中的 insecure-registries"
    echo
    echo "  3. Git 配置:"
    echo "     - export GIT_SSL_NO_VERIFY=true"
    echo "     - 或 git config --global http.sslVerify false"
    echo
    echo -e "${YELLOW}【重要提示】${NC}"
    echo "  - 自签名证书仅用于开发/测试环境"
    echo "  - 生产环境请使用可信 CA 签发的证书"
    echo "  - 证书有效期 10 年，请定期更新"
    echo
}

# 主函数
main() {
    echo -e "${BLUE}"
    cat << 'EOF'
   ______           _   _      ______          _     
  |  ____|         | | (_)    |  ____|        | |    
  | |__   _ __ __ _| |_ _  ___| |__ ___  _ __ | |_   
  |  __| | '__/ _` | __| |/ __|  __/ _ \| '_ \| __|  
  | |____| | | (_| | |_| | (__| | | (_) | | | | |_   
  |______|_|  \__,_|\__|_|\___|_|  \___/|_| |_|\__|  
                                                       
EOF
    echo -e "${NC}"
    echo -e "${CYAN}SSL 证书生成脚本${NC}"
    echo -e "${CYAN}=================${NC}"
    
    check_openssl
    create_ssl_dir
    generate_certificates
    show_cert_info
    print_instructions
    
    log_info "SSL 证书生成完成!"
}

# 执行主函数
main "$@"
