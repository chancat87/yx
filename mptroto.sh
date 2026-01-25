#!/bin/bash

# ============================================
# MTProto Proxy 安装脚本 for VPS
# 作者: hc990275
# 仓库: https://github.com/hc990275/yx
# ============================================

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 输出颜色信息
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "${CYAN}➜${NC} $1"; }
question() { echo -e "${PURPLE}[?]${NC} $1"; }

# 打印横幅
print_banner() {
    clear
    echo -e "${BOLD}${GREEN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║                                                      ║"
    echo "║              MTProto Proxy 安装脚本                  ║"
    echo "║            (支持自定义端口和配置)                    ║"
    echo "║                                                      ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以root权限运行!"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

# 检查系统
check_system() {
    if [[ -f /etc/redhat-release ]]; then
        OS="centos"
    elif grep -Eqi "debian" /etc/issue; then
        OS="debian"
    elif grep -Eqi "ubuntu" /etc/issue; then
        OS="ubuntu"
    elif grep -Eqi "centos|red hat|redhat" /etc/issue; then
        OS="centos"
    elif grep -Eqi "debian" /proc/version; then
        OS="debian"
    elif grep -Eqi "ubuntu" /proc/version; then
        OS="ubuntu"
    elif grep -Eqi "centos|red hat|redhat" /proc/version; then
        OS="centos"
    else
        error "不支持的操作系统！"
        exit 1
    fi
    info "检测到操作系统: $OS"
}

# 安装依赖
install_dependencies() {
    step "安装系统依赖..."
    
    if [[ $OS == "centos" ]]; then
        yum install -y epel-release
        yum install -y wget curl git docker docker-compose firewalld jq xxd
        systemctl start docker
        systemctl enable docker
        systemctl start firewalld
        systemctl enable firewalld
    else
        apt-get update
        apt-get install -y wget curl git docker.io docker-compose jq ufw xxd
        systemctl start docker
        systemctl enable docker
    fi
    success "依赖安装完成！"
}

# 获取用户输入
get_user_input() {
    echo ""
    question "请输入MTProto代理端口 (推荐使用443，或输入其他端口): "
    read -p "端口 [默认: 443]: " PORT
    PORT=${PORT:-443}
    
    # 检查端口是否被占用
    if netstat -tuln | grep ":$PORT " > /dev/null; then
        warning "端口 $PORT 已被占用！"
        question "是否强制使用此端口？(y/n): "
        read -p "[默认: n]: " FORCE_PORT
        if [[ ! $FORCE_PORT =~ ^[Yy]$ ]]; then
            get_user_input
            return
        fi
    fi
    
    question "是否自动生成密钥？(y/n) [默认: y]: "
    read -p "自动生成密钥: " AUTO_SECRET
    AUTO_SECRET=${AUTO_SECRET:-y}
    
    if [[ $AUTO_SECRET =~ ^[Yy]$ ]]; then
        SECRET=$(head -c 16 /dev/urandom | xxd -ps)
        info "已生成密钥: $SECRET"
    else
        question "请输入自定义密钥（32位十六进制）: "
        read -p "密钥: " SECRET
        # 验证密钥格式
        if [[ ! $SECRET =~ ^[0-9a-fA-F]{32}$ ]]; then
            error "密钥格式错误！必须是32位十六进制字符"
            exit 1
        fi
    fi
    
    question "请输入标签（用于识别代理，可选）: "
    read -p "标签: " PROXY_TAG
    PROXY_TAG=${PROXY_TAG:-"My MTProto Proxy"}
    
    question "设置最大连接数 [默认: 10000]: "
    read -p "最大连接数: " MAX_CONNECTIONS
    MAX_CONNECTIONS=${MAX_CONNECTIONS:-10000}
    
    question "设置Worker数量 (CPU核心数 * 2) [默认: 4]: "
    read -p "Worker数量: " WORKERS
    WORKERS=${WORKERS:-4}
}

# 配置防火墙
setup_firewall() {
    step "配置防火墙..."
    
    if [[ $OS == "centos" ]]; then
        firewall-cmd --permanent --add-port=$PORT/tcp
        firewall-cmd --permanent --add-port=$PORT/udp
        firewall-cmd --reload
        success "CentOS防火墙已配置"
    else
        ufw allow $PORT/tcp
        ufw allow $PORT/udp
        echo "y" | ufw enable
        success "UFW防火墙已配置"
    fi
}

# 方法1: 使用官方Docker安装
install_method_docker() {
    step "使用Docker安装MTProto代理..."
    
    # 创建配置目录
    mkdir -p /etc/mtproto-proxy
    
    # 下载官方配置文件
    if [[ ! -f /etc/mtproto-proxy/proxy-secret ]]; then
        curl -sL https://core.telegram.org/getProxySecret -o /etc/mtproto-proxy/proxy-secret
    fi
    
    if [[ ! -f /etc/mtproto-proxy/proxy-multi.conf ]]; then
        curl -sL https://core.telegram.org/getProxyConfig -o /etc/mtproto-proxy/proxy-multi.conf
    fi
    
    # 创建自定义配置
    cat > /etc/mtproto-proxy/config.env << EOF
PORT=$PORT
SECRET=$SECRET
PROXY_TAG=$PROXY_TAG
MAX_CONNECTIONS=$MAX_CONNECTIONS
WORKERS=$WORKERS
EOF
    
    # 创建docker-compose文件
    cat > /etc/mtproto-proxy/docker-compose.yml << EOF
version: '3.8'
services:
  mtproto-proxy:
    image: telegrammessenger/proxy:latest
    container_name: mtproto-proxy
    restart: always
    network_mode: host
    environment:
      - SECRET=${SECRET}
      - PROXY_TAG=${PROXY_TAG}
      - WORKERS=${WORKERS}
      - MAX_CONNECTIONS=${MAX_CONNECTIONS}
    volumes:
      - ./proxy-secret:/proxy-secret
      - ./proxy-multi.conf:/proxy-multi.conf
EOF
    
    # 启动服务
    cd /etc/mtproto-proxy
    docker-compose up -d
    
    # 等待服务启动
    sleep 3
    if docker ps | grep -q mtproto-proxy; then
        success "MTProto代理启动成功！"
    else
        error "MTProto代理启动失败！"
        docker-compose logs
        exit 1
    fi
}

# 方法2: 使用原生安装
install_method_native() {
    step "使用原生方式安装MTProto代理..."
    
    # 克隆源码
    cd /tmp
    if [[ ! -d MTProxy ]]; then
        git clone https://github.com/TelegramMessenger/MTProxy.git
    fi
    
    cd MTProxy
    make -j$(nproc)
    
    # 创建服务目录
    mkdir -p /opt/mtproto-proxy
    cp objs/bin/mtproto-proxy /opt/mtproto-proxy/
    
    # 创建配置文件
    cat > /opt/mtproto-proxy/config.conf << EOF
port = $PORT;
secret = "$SECRET";
workers = $WORKERS;
max-connections = $MAX_CONNECTIONS;
proxy_tag = "$PROXY_TAG";
EOF
    
    # 下载官方配置文件
    cd /opt/mtproto-proxy
    curl -sL https://core.telegram.org/getProxySecret -o proxy-secret
    curl -sL https://core.telegram.org/getProxyConfig -o proxy-multi.conf
    
    # 创建systemd服务
    cat > /etc/systemd/system/mtproto-proxy.service << EOF
[Unit]
Description=MTProto Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
WorkingDirectory=/opt/mtproto-proxy
ExecStart=/opt/mtproto-proxy/mtproto-proxy -u nobody -p $PORT -H $PORT -S $SECRET --aes-pwd proxy-secret proxy-multi.conf -M $WORKERS
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    
    # 启动服务
    systemctl daemon-reload
    systemctl enable mtproto-proxy
    systemctl start mtproto-proxy
    
    sleep 2
    if systemctl is-active --quiet mtproto-proxy; then
        success "MTProto代理启动成功！"
    else
        error "MTProto代理启动失败！"
        systemctl status mtproto-proxy
        exit 1
    fi
}

# 安装选择
choose_install_method() {
    echo ""
    question "请选择安装方式:"
    echo "  1) Docker安装 (推荐，简单稳定)"
    echo "  2) 原生安装 (性能更好)"
    read -p "请选择 [1/2, 默认: 1]: " INSTALL_METHOD
    INSTALL_METHOD=${INSTALL_METHOD:-1}
    
    case $INSTALL_METHOD in
        1)
            install_method_docker
            ;;
        2)
            install_method_native
            ;;
        *)
            install_method_docker
            ;;
    esac
}

# 显示安装信息
show_installation_info() {
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║               安装完成！配置信息如下                ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}代理配置信息:${NC}"
    echo -e "  ${BOLD}服务器地址:${NC} $(curl -s ifconfig.me)"
    echo -e "  ${BOLD}端口:${NC} $PORT"
    echo -e "  ${BOLD}密钥:${NC} $SECRET"
    echo -e "  ${BOLD}标签:${NC} $PROXY_TAG"
    echo ""
    echo -e "${CYAN}Telegram客户端配置:${NC}"
    echo "  1. 打开 Telegram → 设置 → 高级 → 连接类型"
    echo "  2. 选择 '使用自定义代理'"
    echo "  3. 代理类型: MTProto"
    echo "  4. 服务器: $(curl -s ifconfig.me)"
    echo "  5. 端口: $PORT"
    echo "  6. 密钥: $SECRET"
    echo ""
    
    # 生成分享链接
    IP=$(curl -s ifconfig.me)
    SHARE_LINK="tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
    echo -e "${CYAN}一键分享链接:${NC}"
    echo -e "  ${BOLD}$SHARE_LINK${NC}"
    echo ""
    echo -e "${YELLOW}将此链接发送给朋友，他们可以直接点击连接代理${NC}"
    echo ""
    
    # 生成QR码链接
    QR_URL="https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$SHARE_LINK"
    echo -e "${CYAN}QR码链接:${NC}"
    echo -e "  $QR_URL"
    echo ""
    
    # 显示服务状态
    if [[ $INSTALL_METHOD -eq 1 ]]; then
        echo -e "${CYAN}服务状态:${NC}"
        docker ps | grep mtproto-proxy
    else
        echo -e "${CYAN}服务状态:${NC}"
        systemctl status mtproto-proxy --no-pager -l
    fi
}

# 生成管理脚本
generate_management_script() {
    cat > /usr/local/bin/mtproto-manage << 'EOF'
#!/bin/bash

# MTProto 管理脚本

case "$1" in
    start)
        if [[ -f /etc/systemd/system/mtproto-proxy.service ]]; then
            systemctl start mtproto-proxy
        else
            docker start mtproto-proxy
        fi
        echo "MTProto代理已启动"
        ;;
    stop)
        if [[ -f /etc/systemd/system/mtproto-proxy.service ]]; then
            systemctl stop mtproto-proxy
        else
            docker stop mtproto-proxy
        fi
        echo "MTProto代理已停止"
        ;;
    restart)
        if [[ -f /etc/systemd/system/mtproto-proxy.service ]]; then
            systemctl restart mtproto-proxy
        else
            docker restart mtproto-proxy
        fi
        echo "MTProto代理已重启"
        ;;
    status)
        if [[ -f /etc/systemd/system/mtproto-proxy.service ]]; then
            systemctl status mtproto-proxy --no-pager -l
        else
            docker ps | grep mtproto-proxy
        fi
        ;;
    logs)
        if [[ -f /etc/systemd/system/mtproto-proxy.service ]]; then
            journalctl -u mtproto-proxy -f
        else
            docker logs -f mtproto-proxy
        fi
        ;;
    update)
        if [[ -f /etc/systemd/system/mtproto-proxy.service ]]; then
            cd /tmp/MTProxy && git pull && make
            systemctl restart mtproto-proxy
        else
            docker pull telegrammessenger/proxy:latest
            docker restart mtproto-proxy
        fi
        echo "MTProto代理已更新"
        ;;
    *)
        echo "使用方法: $0 {start|stop|restart|status|logs|update}"
        exit 1
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/mtproto-manage
    info "管理脚本已安装，使用命令: mtproto-manage {start|stop|restart|status|logs|update}"
}

# 安装监控
install_monitoring() {
    question "是否安装监控和日志？(y/n) [默认: y]: "
    read -p "安装监控: " INSTALL_MONITOR
    INSTALL_MONITOR=${INSTALL_MONITOR:-y}
    
    if [[ $INSTALL_MONITOR =~ ^[Yy]$ ]]; then
        step "安装监控工具..."
        
        # 安装iftop用于流量监控
        if [[ $OS == "centos" ]]; then
            yum install -y iftop
        else
            apt-get install -y iftop
        fi
        
        # 创建监控脚本
        cat > /usr/local/bin/mtproto-monitor << 'EOF'
#!/bin/bash

echo "=== MTProto 代理监控 ==="
echo ""

# 显示连接数
if [[ -f /etc/systemd/system/mtproto-proxy.service ]]; then
    CONNECTIONS=$(ss -tunap | grep mtproto-proxy | wc -l)
else
    CONTAINER_ID=$(docker ps -q --filter "name=mtproto-proxy")
    if [[ ! -z $CONTAINER_ID ]]; then
        CONNECTIONS=$(docker exec $CONTAINER_ID ss -tunap | grep -c LISTEN)
    else
        CONNECTIONS="0"
    fi
fi

echo "当前连接数: $CONNECTIONS"
echo ""

# 显示内存使用
echo "内存使用情况:"
if [[ -f /etc/systemd/system/mtproto-proxy.service ]]; then
    ps aux | grep mtproto-proxy | grep -v grep
else
    docker stats mtproto-proxy --no-stream
fi
echo ""

# 显示日志最后10行
echo "最近日志:"
if [[ -f /etc/systemd/system/mtproto-proxy.service ]]; then
    journalctl -u mtproto-proxy -n 10 --no-pager
else
    docker logs --tail 10 mtproto-proxy
fi
EOF
        
        chmod +x /usr/local/bin/mtproto-monitor
        success "监控脚本已安装，使用命令: mtproto-monitor"
    fi
}

# 备份配置
backup_config() {
    step "备份配置..."
    
    BACKUP_DIR="/root/mtproto-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p $BACKUP_DIR
    
    if [[ $INSTALL_METHOD -eq 1 ]]; then
        cp -r /etc/mtproto-proxy $BACKUP_DIR/
    else
        cp -r /opt/mtproto-proxy $BACKUP_DIR/
        cp /etc/systemd/system/mtproto-proxy.service $BACKUP_DIR/
    fi
    
    # 保存配置信息
    cat > $BACKUP_DIR/config.info << EOF
安装时间: $(date)
安装方式: $([ $INSTALL_METHOD -eq 1 ] && echo "Docker" || echo "Native")
服务器IP: $(curl -s ifconfig.me)
端口: $PORT
密钥: $SECRET
标签: $PROXY_TAG
最大连接数: $MAX_CONNECTIONS
Worker数量: $WORKERS
EOF
    
    info "配置已备份到: $BACKUP_DIR"
}

# 主函数
main() {
    print_banner
    check_root
    check_system
    install_dependencies
    get_user_input
    setup_firewall
    choose_install_method
    generate_management_script
    install_monitoring
    backup_config
    show_installation_info
    
    echo ""
    success "MTProto代理安装完成！"
    echo ""
    info "后续管理命令:"
    echo "  查看状态: mtproto-manage status"
    echo "  查看日志: mtproto-manage logs"
    echo "  重启服务: mtproto-manage restart"
    echo "  监控状态: mtproto-monitor"
    echo ""
    info "如果遇到问题，请检查防火墙设置和端口占用"
}

# 执行主函数
main
