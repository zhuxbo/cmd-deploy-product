#!/bin/bash

# 证书管理系统运行环境依赖安装脚本
# 功能：检测并安装PHP 8.3+及必要的扩展，支持多系统和宝塔面板

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# 检测宝塔面板
check_bt_panel() {
    # 多种方式检测宝塔面板
    if [ -f "/www/server/panel/BT-Panel" ] || \
       [ -f "/www/server/panel/class/panelPlugin.py" ] || \
       [ -d "/www/server/panel" ] && [ -f "/www/server/panel/data/port.pl" ]; then
        return 0  # 是宝塔环境
    fi
    return 1  # 非宝塔环境
}

# 检测系统类型
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
        OS_NAME=$NAME
        OS_LIKE=$ID_LIKE
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
        VER=$(cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+' | head -1)
        OS_NAME="CentOS"
    else
        log_error "无法检测系统类型"
        exit 1
    fi
    
    # 确定包管理器和PHP包前缀
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt-get update"
        PKG_INSTALL="apt-get install -y"
        PHP_VERSION="8.3"
        PHP_PKG_PREFIX="php${PHP_VERSION}"
        SERVICE_NAME="php${PHP_VERSION}-fpm"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        PKG_UPDATE="yum makecache"
        PKG_INSTALL="yum install -y"
        PHP_VERSION=""  # CentOS使用模块流
        PHP_PKG_PREFIX="php"
        SERVICE_NAME="php-fpm"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf makecache"
        PKG_INSTALL="dnf install -y"
        PHP_VERSION=""
        PHP_PKG_PREFIX="php"
        SERVICE_NAME="php-fpm"
    elif command -v zypper &> /dev/null; then
        PKG_MANAGER="zypper"
        PKG_UPDATE="zypper refresh"
        PKG_INSTALL="zypper install -y"
        PHP_VERSION=""
        PHP_PKG_PREFIX="php8"
        SERVICE_NAME="php-fpm"
    else
        log_error "不支持的包管理器"
        exit 1
    fi
    
    log_info "检测到系统: $OS_NAME $VER"
    log_info "包管理器: $PKG_MANAGER"
}

# 检测PHP版本
check_php_version() {
    log_info "检测 PHP 版本..."
    
    # 尝试多个可能的PHP命令位置
    PHP_CMD=""
    for cmd in php php8.3 php83 php8; do
        if command -v $cmd &> /dev/null; then
            PHP_CMD=$cmd
            break
        fi
    done
    
    if [ -z "$PHP_CMD" ]; then
        # 宝塔环境特殊处理
        if check_bt_panel; then
            for php_path in /www/server/php/83/bin/php /www/server/php/82/bin/php /www/server/php/81/bin/php; do
                if [ -x "$php_path" ]; then
                    PHP_CMD=$php_path
                    break
                fi
            done
        fi
    fi
    
    if [ -z "$PHP_CMD" ]; then
        log_warning "PHP 未安装"
        return 1
    fi
    
    PHP_VERSION_STR=$($PHP_CMD -r "echo PHP_VERSION;")
    PHP_MAJOR=$(echo $PHP_VERSION_STR | cut -d. -f1)
    PHP_MINOR=$(echo $PHP_VERSION_STR | cut -d. -f2)
    
    log_info "当前 PHP 版本: $PHP_VERSION_STR (命令: $PHP_CMD)"
    
    # 检查是否满足 8.3+
    if [ "$PHP_MAJOR" -gt 8 ] || ([ "$PHP_MAJOR" -eq 8 ] && [ "$PHP_MINOR" -ge 3 ]); then
        log_success "PHP 版本满足要求 (>= 8.3)"
        return 0
    else
        log_warning "PHP 版本不满足要求，需要 >= 8.3"
        return 1
    fi
}

# 检测PHP扩展
check_php_extensions() {
    log_info "检测 PHP 扩展..."
    
    REQUIRED_EXTENSIONS=(
        "bcmath"
        "ctype"
        "curl"
        "dom"
        "fileinfo"
        "json"
        "mbstring"
        "openssl"
        "pcre"
        "pdo"
        "pdo_mysql"
        "tokenizer"
        "xml"
        "zip"
        "gd"
        "intl"
        "redis"
    )
    
    MISSING_EXTENSIONS=()
    
    # 使用找到的PHP命令检测扩展
    PHP_CMD=${PHP_CMD:-php}
    for ext in "${REQUIRED_EXTENSIONS[@]}"; do
        if ! $PHP_CMD -m 2>/dev/null | grep -qi "^$ext$"; then
            MISSING_EXTENSIONS+=("$ext")
        fi
    done
    
    if [ ${#MISSING_EXTENSIONS[@]} -eq 0 ]; then
        log_success "所有必需的 PHP 扩展已安装"
        return 0
    else
        log_warning "缺少以下 PHP 扩展: ${MISSING_EXTENSIONS[*]}"
        return 1
    fi
}

# 安装PHP (Ubuntu/Debian)
install_php_ubuntu() {
    log_info "在 Ubuntu/Debian 上安装 PHP 8.3..."
    
    # 添加 PHP PPA
    sudo $PKG_UPDATE
    sudo $PKG_INSTALL software-properties-common ca-certificates lsb-release
    
    # 添加 Ondrej PHP 仓库
    if ! grep -q "ondrej/php" /etc/apt/sources.list.d/*.list 2>/dev/null; then
        sudo add-apt-repository -y ppa:ondrej/php || {
            # 备用方法：手动添加仓库
            log_info "使用备用方法添加 PHP 仓库..."
            sudo sh -c 'echo "deb https://ppa.launchpadcontent.net/ondrej/php/ubuntu $(lsb_release -cs) main" > /etc/apt/sources.list.d/ondrej-php.list'
            sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 4F4EA0AAE5267A6C
        }
    fi
    
    sudo $PKG_UPDATE
    
    # 安装 PHP 8.3 和扩展
    sudo $PKG_INSTALL \
        ${PHP_PKG_PREFIX}-cli \
        ${PHP_PKG_PREFIX}-fpm \
        ${PHP_PKG_PREFIX}-bcmath \
        ${PHP_PKG_PREFIX}-curl \
        ${PHP_PKG_PREFIX}-dom \
        ${PHP_PKG_PREFIX}-mbstring \
        ${PHP_PKG_PREFIX}-mysql \
        ${PHP_PKG_PREFIX}-xml \
        ${PHP_PKG_PREFIX}-zip \
        ${PHP_PKG_PREFIX}-gd \
        ${PHP_PKG_PREFIX}-intl \
        ${PHP_PKG_PREFIX}-redis \
        ${PHP_PKG_PREFIX}-opcache
    
    # 启用 PHP-FPM
    sudo systemctl enable $SERVICE_NAME
    sudo systemctl start $SERVICE_NAME
    
    log_success "PHP 8.3 安装完成"
}

# 安装PHP (CentOS/RHEL/Rocky/AlmaLinux)
install_php_centos() {
    log_info "在 CentOS/RHEL 系统上安装 PHP 8.3..."
    
    OS_VERSION=$(echo $VER | cut -d. -f1)
    
    # 安装 EPEL
    sudo $PKG_INSTALL epel-release
    
    # 根据系统版本选择合适的仓库
    if [ "$OS_VERSION" -eq 7 ]; then
        # CentOS 7
        sudo $PKG_INSTALL https://rpms.remirepo.net/enterprise/remi-release-7.rpm || true
        sudo yum-config-manager --enable remi-php83 || true
    elif [ "$OS_VERSION" -eq 8 ] || [ "$OS_VERSION" -eq 9 ]; then
        # CentOS/Rocky/AlmaLinux 8/9
        sudo $PKG_INSTALL https://rpms.remirepo.net/enterprise/remi-release-${OS_VERSION}.rpm || true
        sudo dnf module reset php -y || true
        sudo dnf module enable php:remi-8.3 -y || true
    fi
    
    # 安装 PHP 8.3 和扩展
    sudo $PKG_INSTALL \
        php \
        php-cli \
        php-fpm \
        php-bcmath \
        php-common \
        php-curl \
        php-mbstring \
        php-mysqlnd \
        php-xml \
        php-zip \
        php-gd \
        php-intl \
        php-pecl-redis \
        php-opcache \
        php-json
    
    # 启用 PHP-FPM
    sudo systemctl enable php-fpm
    sudo systemctl start php-fpm
    
    log_success "PHP 8.3 安装完成"
}

# 安装PHP (Fedora)
install_php_fedora() {
    log_info "在 Fedora 上安装 PHP 8.3..."
    
    # Fedora 通常有较新的 PHP 版本
    sudo $PKG_UPDATE
    
    # 安装 PHP 8.3 和扩展
    sudo $PKG_INSTALL \
        php \
        php-cli \
        php-fpm \
        php-bcmath \
        php-common \
        php-curl \
        php-mbstring \
        php-mysqlnd \
        php-xml \
        php-zip \
        php-gd \
        php-intl \
        php-pecl-redis \
        php-opcache \
        php-json
    
    # 启用 PHP-FPM
    sudo systemctl enable php-fpm
    sudo systemctl start php-fpm
    
    log_success "PHP 8.3 安装完成"
}

# 安装PHP (openSUSE)
install_php_suse() {
    log_info "在 openSUSE 上安装 PHP 8..."
    
    sudo $PKG_UPDATE
    
    # 安装 PHP 8 和扩展
    sudo $PKG_INSTALL \
        php8 \
        php8-cli \
        php8-fpm \
        php8-bcmath \
        php8-curl \
        php8-mbstring \
        php8-mysql \
        php8-xml \
        php8-zip \
        php8-gd \
        php8-intl \
        php8-redis \
        php8-opcache
    
    # 启用 PHP-FPM
    sudo systemctl enable php-fpm
    sudo systemctl start php-fpm
    
    log_success "PHP 8 安装完成"
}

# 根据系统安装PHP
install_php_for_system() {
    case "$PKG_MANAGER" in
        apt)
            install_php_ubuntu
            ;;
        yum|dnf)
            if [[ "$OS" == "fedora" ]]; then
                install_php_fedora
            else
                install_php_centos
            fi
            ;;
        zypper)
            install_php_suse
            ;;
        *)
            log_error "不支持的系统: $PKG_MANAGER"
            exit 1
            ;;
    esac
}

# 宝塔面板环境处理
handle_bt_panel() {
    log_warning "=== 宝塔面板环境检测到 ==="
    log_info "正在检查宝塔面板中的 PHP 安装情况..."
    
    # 检查宝塔PHP安装
    BT_PHP_VERSIONS=()
    for ver in 83 82 81 80 74 73; do
        if [ -d "/www/server/php/$ver" ]; then
            BT_PHP_VERSIONS+=("$ver")
        fi
    done
    
    if [ ${#BT_PHP_VERSIONS[@]} -gt 0 ]; then
        log_info "已安装的 PHP 版本: ${BT_PHP_VERSIONS[*]}"
        
        # 检查是否有8.3+
        if [[ " ${BT_PHP_VERSIONS[@]} " =~ " 83 " ]]; then
            log_success "检测到 PHP 8.3，设置为默认版本..."
            PHP_CMD="/www/server/php/83/bin/php"
            
            # 检查扩展
            if check_php_extensions; then
                log_success "PHP 环境满足要求"
                return 0
            else
                log_warning "部分扩展缺失，请在宝塔面板中安装"
            fi
        else
            log_warning "未检测到 PHP 8.3+"
        fi
    fi
    
    log_warning ""
    log_warning "请按以下步骤在宝塔面板中配置 PHP："
    log_warning "1. 登录宝塔面板"
    log_warning "2. 进入【软件商店】->【运行环境】"
    log_warning "3. 安装 PHP 8.3"
    log_warning "4. 点击 PHP 8.3 的【设置】"
    log_warning "5. 在【安装扩展】中安装以下扩展："
    log_warning "   - fileinfo（必需）"
    log_warning "   - redis（必需）"
    log_warning "   - opcache（推荐）"
    log_warning "   - intl（推荐）"
    log_warning "6. 在网站设置中选择 PHP 8.3"
    log_warning ""
    log_warning "提示：其他常用扩展通常已默认安装"
    log_warning "============================="
    
    read -p "是否已完成上述配置？(y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # 重新检测
        PHP_CMD="/www/server/php/83/bin/php"
        if [ -x "$PHP_CMD" ] && check_php_extensions; then
            log_success "PHP 环境配置完成"
            return 0
        else
            log_error "PHP 环境仍不满足要求，请检查配置"
            exit 1
        fi
    else
        log_info "请完成配置后重新运行此脚本"
        exit 0
    fi
}

# 配置PHP
configure_php() {
    log_info "优化 PHP 配置..."
    
    # 查找 php.ini 位置
    PHP_INI=""
    if [ -n "$PHP_CMD" ]; then
        PHP_INI=$($PHP_CMD -i 2>/dev/null | grep "Loaded Configuration File" | cut -d' ' -f5)
    fi
    
    if [ -z "$PHP_INI" ] || [ ! -f "$PHP_INI" ]; then
        # 尝试常见位置
        for ini_path in \
            "/etc/php/8.3/cli/php.ini" \
            "/etc/php/8.3/fpm/php.ini" \
            "/etc/php.ini" \
            "/www/server/php/83/etc/php.ini"; do
            if [ -f "$ini_path" ]; then
                PHP_INI=$ini_path
                break
            fi
        done
    fi
    
    if [ -f "$PHP_INI" ]; then
        log_info "PHP 配置文件: $PHP_INI"
        
        # 备份原配置
        sudo cp "$PHP_INI" "$PHP_INI.bak.$(date +%Y%m%d%H%M%S)"
        
        # 优化配置
        sudo sed -i 's/^upload_max_filesize.*/upload_max_filesize = 50M/' "$PHP_INI"
        sudo sed -i 's/^post_max_size.*/post_max_size = 50M/' "$PHP_INI"
        sudo sed -i 's/^memory_limit.*/memory_limit = 256M/' "$PHP_INI"
        sudo sed -i 's/^max_execution_time.*/max_execution_time = 300/' "$PHP_INI"
        sudo sed -i 's/^;date.timezone.*/date.timezone = Asia\/Shanghai/' "$PHP_INI"
        
        # 启用 OPcache
        sudo sed -i 's/^;opcache.enable=.*/opcache.enable=1/' "$PHP_INI"
        sudo sed -i 's/^;opcache.enable_cli=.*/opcache.enable_cli=1/' "$PHP_INI"
        
        log_success "PHP 配置优化完成"
        
        # 重启 PHP-FPM（如果存在）
        if systemctl list-units --type=service | grep -q php.*fpm; then
            sudo systemctl restart php*fpm
        fi
    else
        log_warning "未找到 php.ini 文件，跳过配置优化"
    fi
}

# 安装其他依赖
install_other_deps() {
    log_info "安装其他必要依赖..."
    
    case "$PKG_MANAGER" in
        apt)
            sudo $PKG_INSTALL \
                curl \
                git \
                unzip \
                supervisor \
                redis-server \
                nginx
            
            # Ubuntu/Debian 服务名
            REDIS_SERVICE="redis-server"
            ;;
        yum|dnf)
            sudo $PKG_INSTALL \
                curl \
                git \
                unzip \
                supervisor \
                redis \
                nginx
            
            # CentOS/RHEL 服务名
            REDIS_SERVICE="redis"
            ;;
        zypper)
            sudo $PKG_INSTALL \
                curl \
                git \
                unzip \
                supervisor \
                redis \
                nginx
            
            REDIS_SERVICE="redis"
            ;;
        *)
            log_error "不支持的包管理器: $PKG_MANAGER"
            return 1
            ;;
    esac
    
    # 启动 Redis（非宝塔环境）
    if ! check_bt_panel; then
        sudo systemctl enable $REDIS_SERVICE
        sudo systemctl start $REDIS_SERVICE
        log_success "Redis 服务已启动"
    else
        log_info "宝塔环境，请在面板中管理 Redis 服务"
    fi
    
    log_success "其他依赖安装完成"
}

# 显示安装摘要
show_summary() {
    log_success "============================================"
    log_success "依赖安装完成！"
    log_success "============================================"
    
    if [ -n "$PHP_CMD" ]; then
        log_info "PHP 版本: $($PHP_CMD -v | head -n1)"
        log_info "PHP 命令: $PHP_CMD"
    else
        log_info "PHP 版本: $(php -v | head -n1)"
    fi
    
    if check_bt_panel; then
        log_info "环境类型: 宝塔面板"
        log_warning "请确保在宝塔面板中："
        log_warning "- 为网站配置 PHP 8.3"
        log_warning "- 安装必要的 PHP 扩展"
        log_warning "- 配置 Redis 服务"
        log_warning "- 配置定时任务和守护进程"
    else
        log_info "环境类型: 标准 Linux"
        
        # 检查服务状态
        if systemctl is-active --quiet nginx; then
            log_success "Nginx: 运行中"
        else
            log_warning "Nginx: 未运行"
        fi
        
        if systemctl is-active --quiet redis || systemctl is-active --quiet redis-server; then
            log_success "Redis: 运行中"
        else
            log_warning "Redis: 未运行"
        fi
        
        if systemctl is-active --quiet php*fpm; then
            log_success "PHP-FPM: 运行中"
        else
            log_warning "PHP-FPM: 未运行"
        fi
    fi
}

# 主函数
main() {
    log_info "============================================"
    log_info "证书管理系统运行环境依赖安装"
    log_info "============================================"
    
    # 检测系统
    detect_system
    
    # 检测宝塔环境
    if check_bt_panel; then
        log_info "检测到宝塔面板环境"
        handle_bt_panel
    else
        log_info "标准 Linux 环境"
        
        # 检查PHP
        if ! check_php_version || ! check_php_extensions; then
            log_info "开始安装 PHP 8.3..."
            install_php_for_system
            
            # 重新检查
            if ! check_php_version; then
                log_error "PHP 安装失败"
                exit 1
            fi
        fi
        
        # 配置 PHP
        configure_php
        
        # 安装其他依赖
        install_other_deps
    fi
    
    # 最终检查
    log_info "执行最终检查..."
    if check_php_version && check_php_extensions; then
        show_summary
    else
        log_error "环境检查未通过，请查看上述错误信息"
        exit 1
    fi
}

# 执行主函数
main "$@"