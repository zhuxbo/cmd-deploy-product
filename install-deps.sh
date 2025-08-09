#!/bin/bash

# 证书管理系统运行环境依赖安装脚本（标准Linux环境）
# 功能：检测并安装PHP 8.3+及必要的扩展，支持多种Linux发行版

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

# 显示帮助信息
show_help() {
    echo "证书管理系统依赖安装脚本（标准Linux环境）"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help       显示此帮助信息"
    echo ""
    echo "说明:"
    echo "  本脚本仅适用于标准Linux环境"
    echo "  如果是宝塔面板环境，请使用 install-deps-bt.sh 脚本"
    echo ""
    echo "示例:"
    echo "  $0               # 检查和安装运行环境依赖"
    echo ""
}

version_compare() {
    local version1="$1"
    local version2="$2"
    
    # 移除 v 前缀和后缀信息
    version1=$(echo "$version1" | sed 's/^v//' | sed 's/-.*//')
    version2=$(echo "$version2" | sed 's/^v//' | sed 's/-.*//')
    
    # 使用 sort -V 进行版本比较
    if command -v sort >/dev/null 2>&1; then
        # 如果 version1 在排序后是最高版本，则 version1 >= version2
        local sorted_versions=$(printf '%s\n%s' "$version1" "$version2" | sort -V)
        local lowest=$(echo "$sorted_versions" | head -n1)
        [ "$lowest" = "$version2" ] && return 0 || return 1
    else
        # 降级到简单的数字比较
        local v1_major=$(echo "$version1" | cut -d. -f1)
        local v1_minor=$(echo "$version1" | cut -d. -f2)
        local v1_patch=$(echo "$version1" | cut -d. -f3)
        
        local v2_major=$(echo "$version2" | cut -d. -f1)
        local v2_minor=$(echo "$version2" | cut -d. -f2)
        local v2_patch=$(echo "$version2" | cut -d. -f3)
        
        # 比较主版本号
        if [ "$v1_major" -gt "$v2_major" ]; then
            return 0
        elif [ "$v1_major" -lt "$v2_major" ]; then
            return 1
        fi
        
        # 比较次版本号
        if [ "$v1_minor" -gt "$v2_minor" ]; then
            return 0
        elif [ "$v1_minor" -lt "$v2_minor" ]; then
            return 1
        fi
        
        # 比较补丁版本号
        if [ "$v1_patch" -ge "$v2_patch" ]; then
            return 0
        else
            return 1
        fi
    fi
}

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
    
    # PHP命令未找到时的处理
    if [ -z "$PHP_CMD" ]; then
        log_warning "未找到标准PHP命令"
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

# 检查PHP函数
check_php_functions() {
    local required_functions=("exec" "putenv" "pcntl_signal" "pcntl_alarm")
    local optional_functions=("proc_open")
    local disabled_functions=()
    
    PHP_CMD=${PHP_CMD:-php}
    
    # 检查必需函数
    for func in "${required_functions[@]}"; do
        if ! $PHP_CMD -r "echo function_exists('$func') && !in_array('$func', array_map('trim', explode(',', ini_get('disable_functions')))) ? 'yes' : 'no';" 2>/dev/null | grep -q "yes"; then
            disabled_functions+=("$func")
        fi
    done
    
    # 检查可选函数
    for func in "${optional_functions[@]}"; do
        if ! $PHP_CMD -r "echo function_exists('$func') && !in_array('$func', array_map('trim', explode(',', ini_get('disable_functions')))) ? 'yes' : 'no';" 2>/dev/null | grep -q "yes"; then
            log_warning "可选PHP函数 $func 被禁用"
        fi
    done
    
    # 如果有必需函数被禁用，返回失败
    if [ ${#disabled_functions[@]} -gt 0 ]; then
        log_error "以下必需的PHP函数被禁用: ${disabled_functions[*]}"
        log_info "请在php.ini中的disable_functions配置中移除这些函数"
        return 1
    fi
    
    return 0
}

# 检测PHP扩展
check_php_extensions() {
    log_info "检测 PHP 扩展..."
    
    local required_extensions=(
        "bcmath" "calendar" "ctype" "curl" "dom" "fileinfo"
        "gd" "iconv" "intl" "json" "mbstring" "openssl"
        "pcntl" "pcre" "pdo" "pdo_mysql" "redis" "tokenizer" 
        "xml" "zip"
    )
    
    local missing_extensions=()
    local php_cmd="${PHP_CMD:-php}"
    
    # 检查扩展
    for ext in "${required_extensions[@]}"; do
        if ! $php_cmd -m 2>/dev/null | grep -qi "^$ext$"; then
            missing_extensions+=("$ext")
        fi
    done
    
    # 如果有扩展缺失，显示信息并返回失败
    if [ ${#missing_extensions[@]} -gt 0 ]; then
        log_error "缺少以下PHP扩展: ${missing_extensions[*]}"
        return 1
    fi
    
    log_success "所有必需的PHP扩展都已安装"
    return 0
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
        ${PHP_PKG_PREFIX}-calendar \
        ${PHP_PKG_PREFIX}-curl \
        ${PHP_PKG_PREFIX}-dom \
        ${PHP_PKG_PREFIX}-fileinfo \
        ${PHP_PKG_PREFIX}-gd \
        ${PHP_PKG_PREFIX}-iconv \
        ${PHP_PKG_PREFIX}-intl \
        ${PHP_PKG_PREFIX}-mbstring \
        ${PHP_PKG_PREFIX}-mysql \
        ${PHP_PKG_PREFIX}-pcntl \
        ${PHP_PKG_PREFIX}-redis \
        ${PHP_PKG_PREFIX}-xml \
        ${PHP_PKG_PREFIX}-zip \
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
        php-calendar \
        php-common \
        php-curl \
        php-fileinfo \
        php-gd \
        php-iconv \
        php-intl \
        php-json \
        php-mbstring \
        php-mysqlnd \
        php-opcache \
        php-pcntl \
        php-pecl-redis \
        php-process \
        php-xml \
        php-zip
    
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
        php-calendar \
        php-common \
        php-curl \
        php-fileinfo \
        php-gd \
        php-iconv \
        php-intl \
        php-json \
        php-mbstring \
        php-mysqlnd \
        php-opcache \
        php-pcntl \
        php-pecl-redis \
        php-process \
        php-xml \
        php-zip
    
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
        php8-calendar \
        php8-curl \
        php8-fileinfo \
        php8-gd \
        php8-iconv \
        php8-intl \
        php8-mbstring \
        php8-mysql \
        php8-opcache \
        php8-pcntl \
        php8-redis \
        php8-xml \
        php8-zip
    
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

# 检查Composer版本和可用性
check_composer() {
    log_info "检查Composer..."
    
    # 首先检查 timeout 命令是否可用
    if ! command -v timeout >/dev/null 2>&1; then
        log_warning "timeout 命令不可用，尝试安装 coreutils..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y coreutils || true
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y coreutils || true
        fi
    fi
    
    if command -v composer >/dev/null 2>&1; then
        # 设置临时环境变量避免交互式提示
        export COMPOSER_NO_INTERACTION=1
        export COMPOSER_ALLOW_SUPERUSER=1
        
        # 使用更短的超时时间，并添加kill信号
        local composer_output=$(timeout -k 3s 10s composer --version 2>&1 | grep -v "Deprecated\|Warning" | head -1)
        local exit_code=$?
        
        # 检查是否超时（timeout 返回码为 124）
        if [ $exit_code -eq 124 ]; then
            log_warning "Composer 执行超时，可能存在网络问题"
            log_info "尝试使用离线模式..."
            # 尝试离线模式
            composer_output=$(timeout -k 3s 10s composer --version --no-plugins 2>&1 | grep -v "Deprecated\|Warning" | head -1)
            if [ -n "$composer_output" ]; then
                local composer_version=$(echo "$composer_output" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
                log_success "Composer (离线模式): $composer_version"
                return 0
            else
                log_warning "Composer 可能需要重新安装"
                return 1
            fi
        elif [ -n "$composer_output" ]; then
            local composer_version=$(echo "$composer_output" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
            if [ -n "$composer_version" ]; then
                log_success "Composer $composer_version 已安装"
                
                # 检查版本是否低于 2.8
                if ! version_compare "$composer_version" "2.8.0"; then
                    log_warning "Composer 版本 $composer_version 低于推荐版本 2.8.0"
                    log_info "尝试更新Composer..."
                    install_or_update_composer
                fi
                return 0
            else
                log_warning "Composer 已安装但版本信息异常"
                return 0  # 仍然认为可用
            fi
        else
            # 尝试获取任何输出，即使有警告
            local full_output=$(timeout -k 3s 10s composer --version 2>&1 | head -5)
            if [ -n "$full_output" ]; then
                log_warning "Composer 已安装但输出包含警告"
                log_info "建议稍后手动更新 Composer: composer self-update"
                return 0  # 仍然认为可用
            else
                log_error "Composer 安装但无法执行"
                return 1
            fi
        fi
    else
        log_warning "Composer未安装"
        return 1
    fi
}

# 安装或更新Composer
install_or_update_composer() {
    log_info "安装或更新Composer..."
    
    # 检查是否已安装
    if command -v composer >/dev/null 2>&1; then
        log_info "检测到已安装的Composer，尝试更新..."
        update_composer_robust
    else
        log_info "Composer未安装，开始安装..."
        install_composer_new
    fi
}

# 强健的Composer更新函数  
update_composer_robust() {
    log_info "开始更新 Composer..."
    
    # 检查必需的 PHP 函数
    local required_functions=("proc_open" "proc_close" "proc_terminate" "proc_get_status")
    local missing_functions=()
    
    PHP_CMD=${PHP_CMD:-php}
    for func in "${required_functions[@]}"; do
        if ! $PHP_CMD -r "echo function_exists('$func') && !in_array('$func', array_map('trim', explode(',', ini_get('disable_functions')))) ? 'yes' : 'no';" 2>/dev/null | grep -q "yes"; then
            missing_functions+=("$func")
        fi
    done
    
    if [ ${#missing_functions[@]} -gt 0 ]; then
        log_warning "以下 PHP 函数被禁用，无法使用 self-update: ${missing_functions[*]}"
        log_info "尝试重新安装 Composer..."
        reinstall_composer
        return
    fi
    
    # 设置环境变量
    export COMPOSER_HOME="${COMPOSER_HOME:-$HOME/.composer}"
    export COMPOSER_CACHE_DIR="${COMPOSER_CACHE_DIR:-$COMPOSER_HOME/cache}"
    export COMPOSER_NO_INTERACTION=1
    export COMPOSER_ALLOW_SUPERUSER=1
    export COMPOSER_PROCESS_TIMEOUT=300
    
    # 尝试创建缓存目录
    mkdir -p "$COMPOSER_CACHE_DIR" 2>/dev/null || true
    
    # 先配置中国镜像源以加速下载
    log_info "配置 Composer 使用中国镜像源..."
    composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/ 2>/dev/null || true
    # 设置 GitHub 镜像
    composer config -g github-protocols https 2>/dev/null || true
    
    # 清理可能的缓存问题
    log_info "清理 Composer 缓存..."
    composer clear-cache 2>/dev/null || true
    
    # 检查 Composer 位置
    local composer_path=$(which composer)
    local use_sudo=true
    
    if [ -n "$composer_path" ]; then
        log_info "Composer 位于 $composer_path"
        if [ -w "$composer_path" ] && [ "$EUID" -eq 0 ]; then
            log_info "以 root 用户运行，不需要 sudo"
            use_sudo=false
        else
            log_info "使用 sudo 确保权限"
        fi
    fi
    
    # 构建更新命令
    local update_cmd="composer self-update --no-interaction"
    if [ "$use_sudo" = true ]; then
        update_cmd="sudo -E $update_cmd"
    fi
    
    # 尝试使用阿里云镜像进行快速更新
    log_info "尝试使用阿里云镜像快速更新..."
    local fast_update_success=false
    
    # 先尝试从阿里云直接下载最新版本
    if timeout 60s curl -sL https://mirrors.aliyun.com/composer/composer.phar -o /tmp/composer_new.phar 2>/dev/null; then
        if $PHP_CMD /tmp/composer_new.phar --version >/dev/null 2>&1; then
            local new_version=$($PHP_CMD /tmp/composer_new.phar --version 2>&1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
            log_info "从阿里云下载的版本: $new_version"
            
            # 替换现有的composer
            if [ "$use_sudo" = true ]; then
                if sudo mv /tmp/composer_new.phar "$composer_path" && sudo chmod +x "$composer_path"; then
                    log_success "Composer 快速更新成功 (阿里云镜像)"
                    log_success "新版本: $new_version"
                    fast_update_success=true
                fi
            else
                if mv /tmp/composer_new.phar "$composer_path" && chmod +x "$composer_path"; then
                    log_success "Composer 快速更新成功 (阿里云镜像)"
                    log_success "新版本: $new_version"
                    fast_update_success=true
                fi
            fi
        fi
        rm -f /tmp/composer_new.phar 2>/dev/null || true
    fi
    
    # 如果快速更新成功，跳过常规更新
    if [ "$fast_update_success" = true ]; then
        return 0
    fi
    
    # 常规self-update方式
    log_info "阿里云快速更新失败，使用常规更新方式..."
    log_info "执行命令: $update_cmd"
    log_info "这可能需要几分钟，请耐心等待..."
    
    # 使用较长的超时时间（5分钟）
    if timeout -k 30s 300s $update_cmd 2>&1 | tee /tmp/composer_update.log; then
        if grep -q "successfully\|Success\|Updated\|Nothing to install\|update\|already at the latest" /tmp/composer_update.log; then
            log_success "Composer 更新成功"
            local new_version=$(timeout -k 3s 10s composer --version 2>&1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
            log_success "新版本: $new_version"
            rm -f /tmp/composer_update.log
            return 0
        fi
    fi
    
    log_warning "self-update 可能失败，尝试重新安装..."
    reinstall_composer
}

# 重新安装Composer
reinstall_composer() {
    log_info "重新安装 Composer..."
    
    cd /tmp
    rm -f composer-setup.php composer.phar
    
    # 尝试使用国内镜像下载最新版（优先级：速度最快的在前）
    local installer_urls=(
        "https://mirrors.aliyun.com/composer/composer.phar"
        "https://mirrors.tencent.com/composer/composer.phar"
        "https://install.phpcomposer.com/installer"
        "https://mirrors.huaweicloud.com/composer/composer.phar"
        "https://getcomposer.org/installer"
    )
    
    local download_success=false
    
    for url in "${installer_urls[@]}"; do
        log_info "尝试从 $url 下载..."
        
        if [[ "$url" == *".phar" ]]; then
            # 直接下载 phar 文件
            if timeout 30s curl -sS "$url" -o composer.phar; then
                PHP_CMD=${PHP_CMD:-php}
                if $PHP_CMD composer.phar --version >/dev/null 2>&1; then
                    log_success "下载 composer.phar 成功"
                    download_success=true
                    break
                fi
            fi
        else
            # 下载安装脚本
            if timeout 30s curl -sS "$url" -o composer-setup.php; then
                PHP_CMD=${PHP_CMD:-php}
                if $PHP_CMD composer-setup.php --quiet; then
                    rm -f composer-setup.php
                    log_success "安装脚本执行成功"
                    download_success=true
                    break
                fi
            fi
        fi
    done
    
    if [ "$download_success" = false ]; then
        log_error "所有下载源都失败了"
        log_error "请手动下载安装 Composer:"
        log_error "  wget https://getcomposer.org/download/latest-stable/composer.phar"
        log_error "  sudo mv composer.phar /usr/local/bin/composer"
        log_error "  sudo chmod +x /usr/local/bin/composer"
        return 1
    fi
    
    # 移动到系统目录
    local target_paths=("/usr/local/bin/composer" "/usr/bin/composer")
    local install_success=false
    
    for target in "${target_paths[@]}"; do
        if sudo mv composer.phar "$target" 2>/dev/null && sudo chmod +x "$target" 2>/dev/null; then
            log_success "Composer 安装到 $target"
            install_success=true
            break
        fi
    done
    
    if [ "$install_success" = false ]; then
        log_error "无法安装 Composer 到任何位置"
        return 1
    fi
    
    # 配置中国镜像源（优先阿里云）
    log_info "配置 Composer 中国镜像源..."
    # 主镜像源（阿里云）
    composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/ 2>/dev/null || true
    # 其他优化配置
    composer config -g github-protocols https 2>/dev/null || true
    composer config -g process-timeout 300 2>/dev/null || true
    composer config -g use-parent-dir true 2>/dev/null || true
    # 如果阿里云不可用，可以手动切换到腾讯云镜像
    log_info "如需切换镜像源，可使用: composer config -g repo.packagist composer https://mirrors.tencent.com/composer/"
    
    # 验证安装
    local final_version=$(timeout -k 3s 10s composer --version 2>&1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
    if [ -n "$final_version" ]; then
        log_success "Composer $final_version 安装成功"
        
        if version_compare "$final_version" "2.8.0"; then
            log_success "版本满足要求"
        else
            log_warning "安装的版本仍然低于 2.8.0，但这是能获取到的最新版本"
            log_info "项目可能仍能正常工作，请继续安装"
        fi
    fi
}

# 新的Composer安装函数
install_composer_new() {
    log_info "安装Composer..."
    
    if ! check_composer; then
        reinstall_composer
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
    
    # 启动 Redis 服务
    sudo systemctl enable $REDIS_SERVICE
    sudo systemctl start $REDIS_SERVICE
    log_success "Redis 服务已启动"
    
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
}

# 主函数
main() {
    # 参数解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 检测宝塔环境，如果是宝塔环境则提示并退出
    if check_bt_panel; then
        echo
        log_warning "检测到宝塔面板环境！"
        log_info "宝塔环境请使用专用安装脚本："
        log_info "  ./install-deps-bt.sh"
        echo
        log_info "本脚本仅适用于标准Linux环境"
        exit 0
    fi
    
    # 检测系统
    echo
    detect_system
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
    
    # 检查PHP函数
    echo
    log_info "检查PHP函数..."
    check_php_functions || log_warning "请检查并修复PHP函数禁用问题"
    
    # 检查和安装Composer
    echo
    log_info "检查Composer..."
    if ! check_composer; then
        log_info "安装Composer..."
        install_or_update_composer
    fi
    
    # 给出最终提示
    echo
    log_success "环境检查完成"
}

# 执行主函数
main "$@"
