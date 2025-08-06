#!/bin/bash

# 证书管理系统运行环境依赖安装脚本
# 功能：检测并安装PHP 8.3+及必要的扩展

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

# 检测系统类型
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        log_error "无法检测系统类型"
        exit 1
    fi
    
    log_info "检测到系统: $OS $VER"
}

# 检测是否为宝塔环境
check_bt_panel() {
    if [ -f "/www/server/panel/BT-Panel" ]; then
        log_warning "检测到宝塔面板环境"
        return 0
    fi
    return 1
}

# 检测PHP版本
check_php_version() {
    log_info "检测 PHP 版本..."
    
    if ! command -v php &> /dev/null; then
        log_warning "PHP 未安装"
        return 1
    fi
    
    PHP_VERSION=$(php -r "echo PHP_VERSION;")
    PHP_MAJOR=$(echo $PHP_VERSION | cut -d. -f1)
    PHP_MINOR=$(echo $PHP_VERSION | cut -d. -f2)
    
    log_info "当前 PHP 版本: $PHP_VERSION"
    
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
    
    for ext in "${REQUIRED_EXTENSIONS[@]}"; do
        if ! php -m | grep -q "^$ext$"; then
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
    sudo apt-get update
    sudo apt-get install -y software-properties-common
    sudo add-apt-repository -y ppa:ondrej/php
    sudo apt-get update
    
    # 安装 PHP 8.3 和扩展
    sudo apt-get install -y \
        php8.3-cli \
        php8.3-fpm \
        php8.3-bcmath \
        php8.3-curl \
        php8.3-dom \
        php8.3-fileinfo \
        php8.3-mbstring \
        php8.3-mysql \
        php8.3-tokenizer \
        php8.3-xml \
        php8.3-zip \
        php8.3-gd \
        php8.3-intl \
        php8.3-redis \
        php8.3-opcache
    
    # 启用 PHP-FPM
    sudo systemctl enable php8.3-fpm
    sudo systemctl start php8.3-fpm
    
    log_success "PHP 8.3 安装完成"
}

# 安装PHP (CentOS/RHEL)
install_php_centos() {
    log_info "在 CentOS/RHEL 上安装 PHP 8.3..."
    
    # 安装 EPEL 和 Remi 仓库
    sudo yum install -y epel-release
    sudo yum install -y https://rpms.remirepo.net/enterprise/remi-release-${VER}.rpm
    
    # 启用 PHP 8.3 模块
    sudo yum module reset php -y
    sudo yum module enable php:remi-8.3 -y
    
    # 安装 PHP 8.3 和扩展
    sudo yum install -y \
        php \
        php-cli \
        php-fpm \
        php-bcmath \
        php-common \
        php-curl \
        php-dom \
        php-fileinfo \
        php-mbstring \
        php-mysqlnd \
        php-tokenizer \
        php-xml \
        php-zip \
        php-gd \
        php-intl \
        php-redis \
        php-opcache
    
    # 启用 PHP-FPM
    sudo systemctl enable php-fpm
    sudo systemctl start php-fpm
    
    log_success "PHP 8.3 安装完成"
}

# 宝塔环境处理
handle_bt_panel() {
    log_warning "=== 宝塔面板环境说明 ==="
    log_warning "在宝塔面板中，建议通过面板界面安装和管理 PHP"
    log_warning ""
    log_warning "请按以下步骤操作："
    log_warning "1. 登录宝塔面板"
    log_warning "2. 进入【软件商店】"
    log_warning "3. 搜索并安装 PHP 8.3"
    log_warning "4. 在 PHP 8.3 设置中安装以下扩展："
    log_warning "   - fileinfo"
    log_warning "   - redis"
    log_warning "   - opcache"
    log_warning "   - imagemagick (可选)"
    log_warning "5. 在网站设置中选择 PHP 8.3"
    log_warning ""
    log_warning "其他必需的扩展通常已默认安装"
    log_warning "==========================="
    
    read -p "是否已在宝塔面板中完成 PHP 8.3 的安装？(y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # 重新检测
        if check_php_version && check_php_extensions; then
            log_success "PHP 环境检测通过"
        else
            log_error "PHP 环境仍不满足要求，请检查宝塔面板中的设置"
            exit 1
        fi
    else
        log_info "请先在宝塔面板中完成 PHP 安装，然后重新运行此脚本"
        exit 0
    fi
}

# 配置PHP
configure_php() {
    log_info "配置 PHP..."
    
    # 查找 php.ini 位置
    PHP_INI=$(php -i | grep "Loaded Configuration File" | cut -d' ' -f5)
    
    if [ -f "$PHP_INI" ]; then
        log_info "PHP 配置文件: $PHP_INI"
        
        # 备份原配置
        sudo cp "$PHP_INI" "$PHP_INI.bak.$(date +%Y%m%d%H%M%S)"
        
        # 优化配置
        log_info "优化 PHP 配置..."
        
        # 使用 sed 修改配置
        sudo sed -i 's/^upload_max_filesize.*/upload_max_filesize = 50M/' "$PHP_INI"
        sudo sed -i 's/^post_max_size.*/post_max_size = 50M/' "$PHP_INI"
        sudo sed -i 's/^memory_limit.*/memory_limit = 256M/' "$PHP_INI"
        sudo sed -i 's/^max_execution_time.*/max_execution_time = 300/' "$PHP_INI"
        sudo sed -i 's/^;date.timezone.*/date.timezone = Asia\/Shanghai/' "$PHP_INI"
        
        # 启用 OPcache
        sudo sed -i 's/^;opcache.enable=.*/opcache.enable=1/' "$PHP_INI"
        sudo sed -i 's/^;opcache.enable_cli=.*/opcache.enable_cli=1/' "$PHP_INI"
        
        log_success "PHP 配置优化完成"
        
        # 重启 PHP-FPM
        if systemctl is-active --quiet php8.3-fpm; then
            sudo systemctl restart php8.3-fpm
        elif systemctl is-active --quiet php-fpm; then
            sudo systemctl restart php-fpm
        fi
    else
        log_warning "未找到 php.ini 文件"
    fi
}

# 安装其他依赖
install_other_deps() {
    log_info "安装其他必要依赖..."
    
    if [ "$OS" == "ubuntu" ] || [ "$OS" == "debian" ]; then
        sudo apt-get install -y \
            curl \
            git \
            unzip \
            supervisor \
            redis-server
    elif [ "$OS" == "centos" ] || [ "$OS" == "rhel" ]; then
        sudo yum install -y \
            curl \
            git \
            unzip \
            supervisor \
            redis
    fi
    
    # 启动 Redis
    sudo systemctl enable redis
    sudo systemctl start redis
    
    log_success "其他依赖安装完成"
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
        handle_bt_panel
    else
        # 非宝塔环境，自动安装
        if ! check_php_version || ! check_php_extensions; then
            log_info "开始安装 PHP 8.3..."
            
            case "$OS" in
                ubuntu|debian)
                    install_php_ubuntu
                    ;;
                centos|rhel)
                    install_php_centos
                    ;;
                *)
                    log_error "不支持的系统: $OS"
                    exit 1
                    ;;
            esac
            
            # 配置 PHP
            configure_php
        fi
        
        # 安装其他依赖
        install_other_deps
    fi
    
    # 最终检查
    log_info "执行最终检查..."
    if check_php_version && check_php_extensions; then
        log_success "============================================"
        log_success "所有依赖安装完成！"
        log_success "PHP 版本: $(php -v | head -n1)"
        log_success "============================================"
    else
        log_error "依赖检查失败，请检查安装日志"
        exit 1
    fi
}

# 执行主函数
main "$@"