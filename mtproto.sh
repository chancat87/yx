#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印彩色消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要以root权限运行"
        print_info "请使用: sudo bash $0"
        exit 1
    fi
}

# 检查系统并安装依赖
install_dependencies() {
    print_info "检测系统并安装必要依赖..."
    
    if command -v apt &> /dev/null; then
        # Debian/Ubuntu
        apt update -y
        apt install -y wget curl net-tools ufw build-essential
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL
        yum install -y wget curl net-tools
    elif command -v dnf &> /dev/null; then
        # Fedora
        dnf install -y wget curl net-tools
    else
        print_warning "无法识别的包管理器，请手动安装依赖"
        return 1
    fi
    
    print_success "依赖安装完成"
    return 0
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if netstat -tuln | grep ":$port " > /dev/null; then
        print_error "端口 $port 已被占用"
        return 1
    fi
    return 0
}

# 安装SOCKS5代理 (使用Dante)
install_socks5() {
    local port=$1
    
    print_info "开始安装SOCKS5代理 (端口: $port)..."
    
    if command -v apt &> /dev/null; then
        apt install -y dante-server
    elif command -v yum &> /dev/null; then
        yum install -y dante-server
    else
        print_error "不支持的包管理器"
        return 1
    fi
    
    # 配置Dante
    cat > /etc/danted.conf << EOF
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = $port
external: eth0
method: username none
user.privileged: root
user.unprivileged: nobody
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect
}
pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: connect disconnect
}
pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: bindreply udpreply
    log: connect disconnect
}
EOF
    
    # 创建日志文件
    touch /var/log/danted.log
    chown nobody:nogroup /var/log/danted.log
    
    # 启动服务
    systemctl restart danted
    systemctl enable danted
    
    if systemctl is-active --quiet danted; then
        print_success "SOCKS5代理安装完成，运行在端口: $port"
        return 0
    else
        print_error "SOCKS5代理启动失败"
        return 1
    fi
}

# 安装HTTP代理 (使用TinyProxy)
install_http_proxy() {
    local port=$1
    
    print_info "开始安装HTTP代理 (端口: $port)..."
    
    if command -v apt &> /dev/null; then
        apt install -y tinyproxy
    elif command -v yum &> /dev/null; then
        yum install -y tinyproxy
    else
        print_error "不支持的包管理器"
        return 1
    fi
    
    # 备份原配置
    cp /etc/tinyproxy/tinyproxy.conf /etc/tinyproxy/tinyproxy.conf.backup
    
    # 生成新配置
    cat > /etc/tinyproxy/tinyproxy.conf << EOF
User tinyproxy
Group tinyproxy
Port $port
Timeout 600
DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"
Logfile "/var/log/tinyproxy/tinyproxy.log"
LogLevel Info
PidFile "/run/tinyproxy/tinyproxy.pid"
MaxClients 100
MinSpareServers 5
MaxSpareServers 20
StartServers 10
MaxRequestsPerChild 0
Allow 0.0.0.0/0
ViaProxyName "tinyproxy"
ConnectPort 443
ConnectPort 563
EOF
    
    # 重启服务
    systemctl restart tinyproxy
    systemctl enable tinyproxy
    
    if systemctl is-active --quiet tinyproxy; then
        print_success "HTTP代理安装完成，运行在端口: $port"
        return 0
    else
        print_error "HTTP代理启动失败"
        return 1
    fi
}

# 安装多功能代理 (使用Gost)
install_gost() {
    local socks_port=$1
    local http_port=$2
    
    print_info "开始安装Gost多功能代理..."
    
    # 下载Gost
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        ARCH="amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        ARCH="arm64"
    fi
    
    GOST_VERSION="3.0.0-rc8"
    GOST_URL="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost-linux-${ARCH}-${GOST_VERSION}.gz"
    
    wget -O gost.gz $GOST_URL
    gunzip gost.gz
    chmod +x gost
    mv gost /usr/local/bin/
    
    # 创建配置文件
    cat > /etc/gost.yaml << EOF
services:
- name: service-socks5
  addr: :$socks_port
  handler:
    type: socks5
  listener:
    type: tcp
- name: service-http
  addr: :$http_port
  handler:
    type: http
  listener:
    type: tcp
EOF
    
    # 创建systemd服务
    cat > /etc/systemd/system/gost.service << EOF
[Unit]
Description=GO Simple Tunnel
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/gost -C /etc/gost.yaml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # 启动服务
    systemctl daemon-reload
    systemctl start gost
    systemctl enable gost
    
    if systemctl is-active --quiet gost; then
        print_success "Gost安装完成"
        print_info "SOCKS5代理端口: $socks_port"
        print_info "HTTP代理端口: $http_port"
        return 0
    else
        print_error "Gost启动失败"
        return 1
    fi
}

# 配置防火墙
configure_firewall() {
    local socks_port=$1
    local http_port=$2
    
    print_info "配置防火墙..."
    
    # 检查UFW是否安装
    if command -v ufw &> /dev/null; then
        ufw allow $socks_port/tcp
        ufw allow $http_port/tcp
        ufw reload
        print_success "防火墙规则已添加"
    elif command -v firewall-cmd &> /dev/null; then
        # CentOS Firewalld
        firewall-cmd --permanent --add-port=$socks_port/tcp
        firewall-cmd --permanent --add-port=$http_port/tcp
        firewall-cmd --reload
        print_success "防火墙规则已添加"
    else
        print_warning "未找到UFW或Firewalld，请手动配置防火墙"
    fi
}

# 显示使用信息
show_usage() {
    local socks_port=$1
    local http_port=$2
    
    clear
    echo "=============================================="
    echo "        代理服务器安装完成"
    echo "=============================================="
    echo ""
    echo "${GREEN}代理服务器信息:${NC}"
    echo "服务器IP: $(curl -s ifconfig.me)"
    echo "SOCKS5代理端口: $socks_port"
    echo "HTTP代理端口: $http_port"
    echo ""
    echo "${YELLOW}Telegram设置方法:${NC}"
    echo "1. Telegram设置 → 数据和存储 → 代理设置"
    echo "2. 添加代理 → 选择类型 (SOCKS5 或 HTTP)"
    echo "3. 填写信息:"
    echo "   - 服务器: 你的VPS IP"
    echo "   - 端口: $socks_port (SOCKS5) 或 $http_port (HTTP)"
    echo "4. 点击保存并启用"
    echo ""
    echo "${BLUE}测试命令:${NC}"
    echo "测试SOCKS5: curl --socks5 127.0.0.1:$socks_port http://ifconfig.me"
    echo "测试HTTP: curl --proxy http://127.0.0.1:$http_port http://ifconfig.me"
    echo ""
    echo "防火墙已开放端口: $socks_port/tcp, $http_port/tcp"
    echo "=============================================="
}

# 主函数
main() {
    clear
    echo "=============================================="
    echo "     SOCKS5 & HTTP 代理服务器一键安装脚本"
    echo "=============================================="
    echo ""
    
    # 检查root权限
    check_root
    
    # 安装依赖
    install_dependencies
    
    # 获取端口输入
    echo ""
    print_info "请输入代理端口 (默认使用1080和8080):"
    
    read -p "SOCKS5代理端口 [1080]: " SOCKS_PORT
    SOCKS_PORT=${SOCKS_PORT:-1080}
    
    read -p "HTTP代理端口 [8080]: " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-8080}
    
    # 检查端口
    check_port $SOCKS_PORT || {
        read -p "端口 $SOCKS_PORT 被占用，是否继续？ (y/N): " choice
        if [[ ! $choice =~ ^[Yy]$ ]]; then
            exit 1
        fi
    }
    
    check_port $HTTP_PORT || {
        read -p "端口 $HTTP_PORT 被占用，是否继续？ (y/N): " choice
        if [[ ! $choice =~ ^[Yy]$ ]]; then
            exit 1
        fi
    }
    
    echo ""
    print_info "请选择安装类型:"
    echo "1) 安装Gost (同时支持SOCKS5和HTTP，推荐)"
    echo "2) 分别安装Dante(SOCKS5)和TinyProxy(HTTP)"
    echo "3) 只安装SOCKS5代理"
    echo "4) 只安装HTTP代理"
    read -p "请选择 [1-4]: " choice
    
    case $choice in
        1)
            install_gost $SOCKS_PORT $HTTP_PORT
            ;;
        2)
            install_socks5 $SOCKS_PORT
            install_http_proxy $HTTP_PORT
            ;;
        3)
            install_socks5 $SOCKS_PORT
            ;;
        4)
            install_http_proxy $HTTP_PORT
            ;;
        *)
            print_error "无效选择，退出"
            exit 1
            ;;
    esac
    
    # 配置防火墙
    configure_firewall $SOCKS_PORT $HTTP_PORT
    
    # 显示使用信息
    show_usage $SOCKS_PORT $HTTP_PORT
}

# 运行主函数
main "$@"