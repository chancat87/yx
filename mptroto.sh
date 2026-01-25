#!/bin/bash

# ============================================
# 简单MTProto代理安装脚本
# 支持自定义端口
# ============================================

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_color() {
    echo -e "${2}${1}${NC}"
}

# 检查root
if [[ $EUID -ne 0 ]]; then
    echo_color "请使用root权限运行: sudo bash $0" "$RED"
    exit 1
fi

echo ""
echo_color "=== MTProto代理安装脚本 ===" "$GREEN"
echo ""

# 获取用户输入
read -p "请输入MTProto端口 (推荐443): " PORT
PORT=${PORT:-443}

read -p "是否自动生成密钥? (y/n) [默认y]: " AUTO_KEY
AUTO_KEY=${AUTO_KEY:-y}

if [[ $AUTO_KEY =~ ^[Yy]$ ]]; then
    SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    echo_color "生成密钥: $SECRET" "$BLUE"
else
    while true; do
        read -p "请输入32位十六进制密钥: " SECRET
        if [[ $SECRET =~ ^[0-9a-fA-F]{32}$ ]]; then
            break
        else
            echo_color "密钥格式错误！必须是32位十六进制" "$RED"
        fi
    done
fi

read -p "代理标签 (可选): " TAG
TAG=${TAG:-"My MTProxy"}

# 显示配置
echo ""
echo_color "配置信息:" "$YELLOW"
echo "端口: $PORT"
echo "密钥: $SECRET"
echo "标签: $TAG"
echo ""

read -p "确认安装? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo_color "安装取消" "$RED"
    exit 0
fi

# 安装依赖
echo_color "安装依赖..." "$BLUE"
apt update
apt install -y docker.io curl wget

# 下载官方配置文件
echo_color "下载配置文件..." "$BLUE"
mkdir -p /etc/mtproto
cd /etc/mtproto
curl -sL https://core.telegram.org/getProxySecret -o proxy-secret
curl -sL https://core.telegram.org/getProxyConfig -o proxy-multi.conf

# 创建Docker Compose文件
cat > docker-compose.yml << EOF
version: '3'
services:
  mtproto:
    image: telegrammessenger/proxy:latest
    container_name: mtproto-proxy
    restart: always
    network_mode: host
    environment:
      - SECRET=${SECRET}
      - PORT=${PORT}
      - PROXY_TAG=${TAG}
    volumes:
      - ./proxy-secret:/proxy-secret
      - ./proxy-multi.conf:/proxy-multi.conf
EOF

# 启动服务
echo_color "启动MTProto服务..." "$BLUE"
docker-compose up -d

# 配置防火墙
echo_color "配置防火墙..." "$BLUE"
if command -v ufw >/dev/null; then
    ufw allow $PORT/tcp
    ufw allow $PORT/udp
    echo "y" | ufw enable >/dev/null 2>&1
elif command -v firewall-cmd >/dev/null; then
    firewall-cmd --permanent --add-port=$PORT/tcp
    firewall-cmd --permanent --add-port=$PORT/udp
    firewall-cmd --reload
fi

# 等待服务启动
sleep 3

# 检查服务状态
if docker ps | grep -q mtproto-proxy; then
    echo_color "✓ MTProto安装成功！" "$GREEN"
else
    echo_color "✗ MTProto启动失败，请检查日志" "$RED"
    docker logs mtproto-proxy
    exit 1
fi

# 显示结果
PUBLIC_IP=$(curl -s ifconfig.me)
echo ""
echo_color "=== 安装完成 ===" "$GREEN"
echo ""
echo_color "服务器: $PUBLIC_IP" "$BLUE"
echo_color "端口: $PORT" "$BLUE"
echo_color "密钥: $SECRET" "$BLUE"
echo ""
echo_color "Telegram配置:" "$YELLOW"
echo "1. 设置 → 高级 → 连接类型"
echo "2. 使用自定义代理"
echo "3. 类型: MTProto"
echo "4. 服务器: $PUBLIC_IP"
echo "5. 端口: $PORT"
echo "6. 密钥: $SECRET"
echo ""
echo_color "分享链接:" "$YELLOW"
echo "tg://proxy?server=$PUBLIC_IP&port=$PORT&secret=$SECRET"
echo ""
echo_color "管理命令:" "$YELLOW"
echo "启动: docker start mtproto-proxy"
echo "停止: docker stop mtproto-proxy"
echo "重启: docker restart mtproto-proxy"
echo "日志: docker logs mtproto-proxy"
echo ""
