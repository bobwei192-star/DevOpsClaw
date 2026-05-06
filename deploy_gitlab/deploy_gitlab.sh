#!/bin/bash
# GitLab CE Docker安装脚本
# 使用Docker安装，更快更简单

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=== GitLab CE Docker安装 ==="
echo "使用Docker安装，避免复杂的系统安装"

# 检查是否以 root 运行
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}此脚本需要 root 权限运行，请使用 sudo${NC}"
    exit 1
fi

# 检查 Docker 是否已安装
if ! command -v docker &>/dev/null; then
    echo -e "${YELLOW}Docker 未安装，正在安装...${NC}"
    apt-get update -qq
    apt-get install -y -qq docker.io
    systemctl enable --now docker
    echo -e "${GREEN}Docker 安装完成${NC}"
fi

# 配置国内 Docker 镜像加速（防止超时）
echo -e "${BLUE}配置国内 Docker 镜像加速...${NC}"
if [ ! -f /etc/docker/daemon.json ]; then
    cat > /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me",
    "https://registry.docker-cn.com",
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com"
  ]
}
EOF
    systemctl restart docker
    sleep 10
fi

echo -e "${BLUE}1. 创建必要的目录...${NC}"
mkdir -p /srv/gitlab/config
mkdir -p /srv/gitlab/logs
mkdir -p /srv/gitlab/data

echo -e "${BLUE}2. 拉取GitLab Docker镜像...${NC}"
echo -e "${YELLOW}注意: 镜像约2GB，但下载通常比deb包快${NC}"

pull_success=0

# 尝试多个镜像源
echo -e "${YELLOW}尝试镜像: gitlab/gitlab-ce:latest${NC}"
if docker pull gitlab/gitlab-ce:latest; then
    echo -e "${GREEN}✅ GitLab镜像拉取成功${NC}"
    pull_success=1
fi

if [ $pull_success -eq 0 ]; then
    echo -e "${YELLOW}尝试镜像: docker.1ms.run/gitlab/gitlab-ce:latest${NC}"
    if docker pull docker.1ms.run/gitlab/gitlab-ce:latest; then
        echo -e "${GREEN}✅ GitLab镜像拉取成功${NC}"
        docker tag docker.1ms.run/gitlab/gitlab-ce:latest gitlab/gitlab-ce:latest
        docker rmi docker.1ms.run/gitlab/gitlab-ce:latest
        pull_success=1
    fi
fi

if [ $pull_success -eq 0 ]; then
    echo -e "${YELLOW}尝试镜像: docker.xuanyuan.me/gitlab/gitlab-ce:latest${NC}"
    if docker pull docker.xuanyuan.me/gitlab/gitlab-ce:latest; then
        echo -e "${GREEN}✅ GitLab镜像拉取成功${NC}"
        docker tag docker.xuanyuan.me/gitlab/gitlab-ce:latest gitlab/gitlab-ce:latest
        docker rmi docker.xuanyuan.me/gitlab/gitlab-ce:latest
        pull_success=1
    fi
fi

if [ $pull_success -eq 0 ]; then
    echo -e "${RED}❌ 所有镜像都拉取失败，请检查网络连接${NC}"
    exit 1
fi

echo -e "${BLUE}3. 停止并删除现有容器（如果有）...${NC}"
docker stop gitlab 2>/dev/null || true
docker rm gitlab 2>/dev/null || true

echo -e "${BLUE}4. 启动GitLab容器...${NC}"
echo -e "${YELLOW}使用端口: 8080 (HTTP), 2222 (SSH), 8443 (HTTPS)${NC}"

docker run --detach \
    --hostname localhost \
    --publish 8080:80 \
    --publish 2222:22 \
    --publish 8443:443 \
    --name gitlab \
    --restart always \
    --volume /srv/gitlab/config:/etc/gitlab \
    --volume /srv/gitlab/logs:/var/log/gitlab \
    --volume /srv/gitlab/data:/var/opt/gitlab \
    --shm-size 512m \
    gitlab/gitlab-ce:latest

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ GitLab容器启动成功${NC}"
    
    echo -e "${BLUE}5. 等待GitLab启动...${NC}"
    echo -e "${YELLOW}这可能需要2-5分钟，请耐心等待...${NC}"
    
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if docker logs gitlab 2>&1 | grep -q "gitlab Reconfigured!"; then
            echo -e "${GREEN}✅ GitLab已配置完成${NC}"
            break
        fi
        echo "等待GitLab启动... ($i/10)"
        sleep 30
    done
    
    echo -e "${BLUE}6. 获取初始密码...${NC}"
    echo "从容器中获取root初始密码..."
    
    # 等待密码文件生成
    echo -e "${YELLOW}等待密码文件生成...${NC}"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if docker exec gitlab test -f /etc/gitlab/initial_root_password 2>/dev/null; then
            break
        fi
        sleep 10
    done
    
    if docker exec gitlab grep -q "Password:" /etc/gitlab/initial_root_password 2>/dev/null; then
        echo -e "\n${GREEN}初始root密码:${NC}"
        docker exec gitlab grep "Password:" /etc/gitlab/initial_root_password
        echo ""
        echo -e "${RED}⚠️  此密码文件会在24小时后自动删除${NC}"
    else
        echo -e "${YELLOW}密码文件尚未生成，稍后运行以下命令获取:${NC}"
        echo "sudo docker exec gitlab cat /etc/gitlab/initial_root_password"
    fi
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}🎉 GitLab CE Docker安装完成！${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BLUE}访问地址:${NC}"
    echo "  HTTP:  http://localhost:8080"
    echo "  HTTPS: https://localhost:8443 (自签名证书)"
    echo "  SSH:   localhost:2222"
    echo ""
    echo -e "${BLUE}管理员账户:${NC}"
    echo "  用户名: root"
    echo "  密码: 见上方或 /etc/gitlab/initial_root_password (容器内)"
    echo ""
    echo -e "${BLUE}容器状态:${NC}"
    docker ps | grep gitlab
    
    echo ""
    echo -e "${BLUE}常用命令:${NC}"
    echo "  查看日志: sudo docker logs -f gitlab"
    echo "  进入容器: sudo docker exec -it gitlab bash"
    echo "  停止容器: sudo docker stop gitlab"
    echo "  启动容器: sudo docker start gitlab"
    echo "  重启容器: sudo docker restart gitlab"
    echo "  重新配置: sudo docker exec -it gitlab gitlab-ctl reconfigure"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    
else
    echo -e "${RED}❌ GitLab容器启动失败${NC}"
    echo -e "${YELLOW}检查Docker日志: sudo docker logs gitlab${NC}"
    exit 1
fi
