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

# 显示帮助信息
show_help() {
    echo "证书管理系统依赖安装脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help       显示此帮助信息"
    echo "  -d, --diagnose   运行PHP扩展深度诊断（用于排查composer install扩展报错）"
    echo ""
    echo "示例:"
    echo "  $0               # 正常运行依赖检查和安装"
    echo "  $0 --diagnose    # 仅运行深度诊断"
    echo "  $0 -d            # 简写形式的深度诊断"
    echo ""
}

# 深度诊断PHP扩展问题（简化版）
diagnose_php_extension_issues() {
    log_info "运行PHP扩展深度诊断模式..."
    
    # 检测运行环境
    if [ "$EUID" -eq 0 ]; then
        log_info "以root权限运行（正常）"
        log_info "提示：Composer命令将使用www用户执行"
    else
        log_warning "非root权限运行，某些检测可能失败"
    fi
    
    if ! check_bt_panel; then
        log_error "未检测到宝塔环境，诊断功能需要宝塔环境"
        return 1
    fi
    
    local minimum_php_version="8.3"
    local has_issue=false
    
    echo
    log_info "=== 步骤1: 检查 /usr/bin/php 配置 ==="
    
    # 检查 /usr/bin/php 是否存在且正确
    if [ -e "/usr/bin/php" ]; then
        local php_version=$(timeout 3s /usr/bin/php -r "echo PHP_VERSION;" 2>/dev/null || echo "unknown")
        local real_path=$(readlink -f "/usr/bin/php" 2>/dev/null || echo "/usr/bin/php")
        
        log_info "  当前PHP: /usr/bin/php -> $real_path"
        log_info "  PHP版本: $php_version"
        
        if [[ "$real_path" == *"/www/server/php"* ]]; then
            if [ "$php_version" != "unknown" ] && version_compare "$php_version" "$minimum_php_version"; then
                log_success "  ✓ /usr/bin/php 配置正确 (宝塔PHP >= $minimum_php_version)"
            else
                log_warning "  ! PHP版本过低: $php_version，需要 >= $minimum_php_version"
                has_issue=true
            fi
        else
            log_error "  ✗ /usr/bin/php 不是宝塔PHP"
            has_issue=true
        fi
    else
        log_warning "  ! /usr/bin/php 不存在，需要创建链接"
        has_issue=true
    fi
    
    # 检测系统PHP包
    echo
    log_info "=== 步骤2: 检测系统PHP包 ==="
    local system_php_paths=(
        "/usr/bin/php8.4"
        "/usr/bin/php8.3"
        "/usr/bin/php8.2"
        "/usr/bin/php8.1"
        "/usr/bin/php8.0"
        "/usr/bin/php7.4"
    )
    
    local system_phps=()
    for php_path in "${system_php_paths[@]}"; do
        if [ -x "$php_path" ]; then
            local version=$(timeout 3s "$php_path" -r "echo PHP_VERSION;" 2>/dev/null || echo "unknown")
            system_phps+=("$php_path")
            log_warning "  ! 发现系统PHP: $php_path ($version)"
        fi
    done
    
    if [ ${#system_phps[@]} -eq 0 ]; then
        log_success "  ✓ 未发现系统PHP包"
    else
        log_warning "  ! 发现 ${#system_phps[@]} 个系统PHP包，建议卸载"
        has_issue=true
    fi
    
    echo
    log_info "=== 步骤3: 检查Composer配置 ==="
    
    if ! command -v composer >/dev/null 2>&1; then
        log_error "  ✗ 未找到Composer命令"
        log_info "  建议安装: curl -sS https://getcomposer.org/installer | php"
        log_info "  然后移动: sudo mv composer.phar /usr/local/bin/composer"
        return 1
    fi
    
    local composer_path=$(which composer)
    local composer_is_wrapper=false
    
    log_info "  Composer路径: $composer_path"
    
    # 检测composer是否是wrapper脚本
    if [ -f "$composer_path" ]; then
        local file_type=$(file -b "$composer_path" 2>/dev/null)
        if [[ "$file_type" == *"shell script"* ]] || [[ "$file_type" == *"bash"* ]] || [[ "$file_type" == *"text"* ]]; then
            # 检查内容是否包含wrapper特征
            if grep -q "BaoTa\|wrapper\|exec.*php.*composer" "$composer_path" 2>/dev/null; then
                composer_is_wrapper=true
                log_error "  ✗ 检测到Composer是宝塔wrapper脚本"
                
                # 查找原始composer
                if [ -f "/usr/bin/composer.original" ]; then
                    log_info "  找到原始Composer: /usr/bin/composer.original"
                elif [ -f "/usr/local/bin/composer.original" ]; then
                    log_info "  找到原始Composer: /usr/local/bin/composer.original"
                elif [ -f "${composer_path}.original" ]; then
                    log_info "  找到原始Composer: ${composer_path}.original"
                fi
                has_issue=true
            else
                log_info "  Composer是脚本文件，但不是wrapper"
            fi
        elif [[ "$file_type" == *"PHP script"* ]] || [[ "$file_type" == *"phar"* ]]; then
            log_success "  ✓ Composer是PHP/PHAR文件（正常）"
        fi
    fi
    
    # 测试composer执行
    if [ -e "/usr/bin/php" ]; then
        log_info "  测试Composer执行..."
        
        # 根据权限选择执行方式
        local composer_cmd="/usr/bin/php $(which composer) --version"
        local composer_version=""
        local composer_error=""
        
        if [ "$EUID" -eq 0 ]; then
            # root权限时，切换到www用户执行
            log_info "    使用www用户执行composer..."
            composer_version=$(sudo -u www bash -c "$composer_cmd" 2>&1 | head -1)
            composer_error=$?
        else
            # 非root直接执行
            composer_version=$(timeout 5s $composer_cmd 2>&1 | head -1)
            composer_error=$?
        fi
        
        if [ $composer_error -eq 0 ] && [[ "$composer_version" == *"Composer version"* ]]; then
            log_success "  ✓ Composer可以正常执行"
            log_info "    $composer_version"
        else
            log_error "  ✗ Composer执行失败"
            log_info "    输出: $composer_version"
            log_info "    返回码: $composer_error"
            if [ "$EUID" -eq 0 ]; then
                log_info "    尝试检查www用户权限和composer文件权限"
            fi
            has_issue=true
        fi
    fi
    
    echo
    log_info "=== 步骤4: 使用Composer检测扩展 ==="
    
    if [ -e "/usr/bin/php" ] && command -v composer >/dev/null 2>&1; then
        log_info "  执行: composer show --platform"
        
        local platform_output=""
        local platform_cmd="/usr/bin/php $(which composer) show --platform"
        
        # 根据权限选择执行方式
        if [ "$EUID" -eq 0 ]; then
            log_info "  使用www用户执行扩展检测..."
            platform_output=$(sudo -u www bash -c "$platform_cmd" 2>&1)
        else
            platform_output=$(timeout 30s $platform_cmd 2>&1)
        fi
        
        if [ $? -eq 0 ] && [ -n "$platform_output" ]; then
            local ext_count=$(echo "$platform_output" | grep -c "^ext-" || echo "0")
            log_success "  ✓ 检测到 $ext_count 个PHP扩展"
            
            # 检查必需扩展
            local required_extensions=(
                "bcmath" "calendar" "ctype" "curl" "dom" "fileinfo"
                "gd" "iconv" "intl" "json" "mbstring" "openssl"
                "pcntl" "pcre" "pdo" "pdo_mysql" "redis" "tokenizer" 
                "xml" "zip"
            )
            
            local missing=()
            for ext in "${required_extensions[@]}"; do
                if ! echo "$platform_output" | grep -q "^ext-$ext"; then
                    missing+=("$ext")
                fi
            done
            
            if [ ${#missing[@]} -eq 0 ]; then
                log_success "  ✓ 所有必需扩展都已安装"
            else
                log_error "  ✗ 缺少 ${#missing[@]} 个扩展: ${missing[*]}"
                has_issue=true
            fi
        else
            log_error "  ✗ Composer平台检测失败"
            if [ -n "$platform_output" ]; then
                log_info "    错误信息: $(echo "$platform_output" | head -1)"
            fi
            if [ "$EUID" -eq 0 ]; then
                log_info "    请检查www用户是否有权限访问composer和PHP"
            fi
            has_issue=true
        fi
    else
        log_warning "  跳过扩展检测（PHP或Composer未就绪）"
    fi
    
    echo
    log_info "=== 诊断总结 ==="
    
    if [ "$has_issue" = true ]; then
        log_error "发现问题，需要修复："
        
        # 提供修复选项
        echo
        read -p "是否自动修复这些问题？(y/n): " -n 1 -r choice < /dev/tty
        echo
        
        if [[ $choice =~ ^[Yy]$ ]]; then
            # 1. 卸载系统PHP
            if [ ${#system_phps[@]} -gt 0 ]; then
                log_info "正在卸载系统PHP包..."
                remove_system_php
            fi
            
            # 2. 修复 /usr/bin/php
            log_info "正在修复 /usr/bin/php..."
            fix_bt_composer_php
            
            # 3. 修复Composer wrapper
            if [ "$composer_is_wrapper" = true ]; then
                log_info "正在修复Composer wrapper..."
                fix_composer_wrapper
            fi
            
            log_success "修复完成，请重新运行诊断验证"
        else
            log_info "跳过自动修复"
        fi
    else
        log_success "✓ PHP和Composer配置正确，无需修复"
    fi
}

# 修复Composer wrapper问题
fix_composer_wrapper() {
    local composer_path=$(which composer)
    
    if [ ! -f "$composer_path" ]; then
        log_error "找不到composer路径"
        return 1
    fi
    
    # 查找原始composer
    local original_composer=""
    if [ -f "/usr/bin/composer.original" ]; then
        original_composer="/usr/bin/composer.original"
    elif [ -f "/usr/local/bin/composer.original" ]; then
        original_composer="/usr/local/bin/composer.original"
    elif [ -f "${composer_path}.original" ]; then
        original_composer="${composer_path}.original"
    fi
    
    if [ -n "$original_composer" ] && [ -f "$original_composer" ]; then
        log_info "恢复原始Composer: $original_composer -> $composer_path"
        sudo rm -f "$composer_path"
        sudo mv "$original_composer" "$composer_path"
        sudo chmod +x "$composer_path"
        log_success "Composer已恢复为原始版本"
        return 0
    else
        log_info "未找到原始Composer，重新安装..."
        
        # 备份现有composer
        if [ -f "$composer_path" ]; then
            sudo mv "$composer_path" "${composer_path}.bak"
        fi
        
        # 重新下载安装
        local temp_file="/tmp/composer_installer_$$.php"
        if curl -sS https://getcomposer.org/installer -o "$temp_file"; then
            if /usr/bin/php "$temp_file" --install-dir=/usr/local/bin --filename=composer 2>/dev/null; then
                rm -f "$temp_file"
                log_success "Composer重新安装成功"
                return 0
            fi
        fi
        
        rm -f "$temp_file"
        log_error "Composer重新安装失败"
        return 1
    fi
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

check_bt_panel() {
    # 多种方式检测宝塔面板
    if [ -f "/www/server/panel/BT-Panel" ] || \
       [ -f "/www/server/panel/class/panelPlugin.py" ] || \
       [ -d "/www/server/panel" ] && [ -f "/www/server/panel/data/port.pl" ]; then
        return 0  # 是宝塔环境
    fi
    return 1  # 非宝塔环境
}

# 版本比较函数
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

# 检查PHP函数（宝塔环境特殊处理）
check_php_functions() {
    local required_functions=("exec" "putenv" "pcntl_signal" "pcntl_alarm")
    local optional_functions=("proc_open")
    local cli_disabled_required=()
    local fpm_disabled_required=()
    local cli_disabled_optional=()
    local fpm_disabled_optional=()
    
    if check_bt_panel && [ -n "$PHP_VERSION" ]; then
        # 宝塔环境：分别检查CLI和FPM配置文件
        local fpm_ini="/www/server/php/$PHP_VERSION/etc/php.ini"
        local cli_ini="/www/server/php/$PHP_VERSION/etc/php-cli.ini"
        local php_cmd="/www/server/php/$PHP_VERSION/bin/php"
        
        # 检查FPM配置（Web模式，php.ini）
        if [ -f "$fpm_ini" ]; then
            local disabled_funcs=$(grep "^disable_functions" "$fpm_ini" 2>/dev/null | sed 's/disable_functions = //' | tr ',' ' ')
            for func in "${required_functions[@]}"; do
                if echo "$disabled_funcs" | grep -q "\\b$func\\b"; then
                    fpm_disabled_required+=("$func")
                fi
            done
            for func in "${optional_functions[@]}"; do
                if echo "$disabled_funcs" | grep -q "\\b$func\\b"; then
                    fpm_disabled_optional+=("$func")
                fi
            done
        fi
        
        # 检查CLI配置（命令行模式，php-cli.ini）
        if [ -f "$cli_ini" ]; then
            local disabled_funcs=$(grep "^disable_functions" "$cli_ini" 2>/dev/null | sed 's/disable_functions = //' | tr ',' ' ')
            for func in "${required_functions[@]}"; do
                if echo "$disabled_funcs" | grep -q "\\b$func\\b"; then
                    cli_disabled_required+=("$func")
                fi
            done
            for func in "${optional_functions[@]}"; do
                if echo "$disabled_funcs" | grep -q "\\b$func\\b"; then
                    cli_disabled_optional+=("$func")
                fi
            done
        fi
        
        # 如果配置文件没有禁用，再通过实际执行验证
        if [ ${#cli_disabled_required[@]} -eq 0 ]; then
            for func in "${required_functions[@]}"; do
                if ! $php_cmd -r "echo function_exists('$func') && !in_array('$func', array_map('trim', explode(',', ini_get('disable_functions')))) ? 'yes' : 'no';" 2>/dev/null | grep -q "yes"; then
                    cli_disabled_required+=("$func")
                fi
            done
        fi
        
    else
        # 标准环境：通过PHP命令检查（通常CLI和FPM配置相同）
        PHP_CMD=${PHP_CMD:-php}
        
        for func in "${required_functions[@]}"; do
            if ! $PHP_CMD -r "echo function_exists('$func') && !in_array('$func', array_map('trim', explode(',', ini_get('disable_functions')))) ? 'yes' : 'no';" 2>/dev/null | grep -q "yes"; then
                cli_disabled_required+=("$func")
                fpm_disabled_required+=("$func")  # 标准环境通常配置相同
            fi
        done
        
        for func in "${optional_functions[@]}"; do
            if ! $PHP_CMD -r "echo function_exists('$func') && !in_array('$func', array_map('trim', explode(',', ini_get('disable_functions')))) ? 'yes' : 'no';" 2>/dev/null | grep -q "yes"; then
                cli_disabled_optional+=("$func")
                fpm_disabled_optional+=("$func")
            fi
        done
    fi
    
    # 导出检测结果供其他函数使用
    export PHP_CLI_DISABLED_REQUIRED="${cli_disabled_required[*]}"
    export PHP_FMP_DISABLED_REQUIRED="${fpm_disabled_required[*]}"
    export PHP_CLI_DISABLED_OPTIONAL="${cli_disabled_optional[*]}"
    export PHP_FMP_DISABLED_OPTIONAL="${fpm_disabled_optional[*]}"
    
    # 返回失败条件：CLI或FMP任一模式有必需函数被禁用
    if [ ${#cli_disabled_required[@]} -gt 0 ] || [ ${#fpm_disabled_required[@]} -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# 检测PHP扩展（CLI和FPM模式分别检测）
check_php_extensions() {
    log_info "检测 PHP 扩展..."
    
    local required_extensions=(
        "bcmath" "calendar" "ctype" "curl" "dom" "fileinfo"
        "gd" "iconv" "intl" "json" "mbstring" "openssl"
        "pcntl" "pcre" "pdo" "pdo_mysql" "redis" "tokenizer" 
        "xml" "zip"
    )
    
    local cli_missing=()
    local fpm_missing=()
    
    if check_bt_panel && [ -n "$PHP_VERSION" ]; then
        # 宝塔环境：分别检查CLI和FPM
        local php_cli="/www/server/php/$PHP_VERSION/bin/php"
        local php_fpm="/www/server/php/$PHP_VERSION/bin/php"  # FPM使用同一个可执行文件但不同配置
        
        # 检查CLI模式扩展
        for ext in "${required_extensions[@]}"; do
            # CLI模式：使用 php-cli.ini 配置
            if ! PHPRC="/www/server/php/$PHP_VERSION/etc/php-cli.ini" $php_cli -m 2>/dev/null | grep -qi "^$ext$"; then
                cli_missing+=("$ext")
            fi
        done
        
        # 检查FPM模式扩展
        for ext in "${required_extensions[@]}"; do
            # FPM模式：使用 php.ini 配置  
            if ! PHPRC="/www/server/php/$PHP_VERSION/etc/php.ini" $php_fpm -m 2>/dev/null | grep -qi "^$ext$"; then
                fpm_missing+=("$ext")
            fi
        done
        
    else
        # 标准环境：通常CLI和FPM共享扩展配置
        local php_cmd="${PHP_CMD:-php}"
        
        for ext in "${required_extensions[@]}"; do
            if ! $php_cmd -m 2>/dev/null | grep -qi "^$ext$"; then
                cli_missing+=("$ext")
                fpm_missing+=("$ext")  # 标准环境通常配置相同
            fi
        done
    fi
    
    # 导出检测结果供其他函数使用
    export PHP_CLI_MISSING_EXTENSIONS="${cli_missing[*]}"
    export PHP_FMP_MISSING_EXTENSIONS="${fpm_missing[*]}"
    export REQUIRED_EXTENSIONS="${required_extensions[*]}"
    
    # 返回失败条件：CLI或FMP任一模式有扩展缺失
    if [ ${#cli_missing[@]} -gt 0 ] || [ ${#fpm_missing[@]} -gt 0 ]; then
        return 1
    fi
    
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

# 选择宝塔PHP版本
select_bt_php_version() {
    # 检查可用的 PHP 8.3+ 版本
    BT_PHP_VERSIONS=()
    for ver in 85 84 83; do
        if [ -d "/www/server/php/$ver" ] && [ -x "/www/server/php/$ver/bin/php" ]; then
            BT_PHP_VERSIONS+=("$ver")
        fi
    done
    
    if [ ${#BT_PHP_VERSIONS[@]} -eq 0 ]; then
        PHP_CMD=""
        PHP_VERSION=""
        return 1
    elif [ ${#BT_PHP_VERSIONS[@]} -eq 1 ]; then
        # 只有一个版本，直接使用
        PHP_VERSION="${BT_PHP_VERSIONS[0]}"
        PHP_CMD="/www/server/php/$PHP_VERSION/bin/php"
        return 0
    else
        # 多个版本，让用户选择
        log_info "检测到多个可用的 PHP 版本："
        echo
        for i in "${!BT_PHP_VERSIONS[@]}"; do
            local ver="${BT_PHP_VERSIONS[i]}"
            echo "  $((i+1)). PHP 8.${ver: -1} (/www/server/php/$ver/bin/php)"
        done
        echo
        
        while true; do
            read -p "请选择要使用的 PHP 版本 (1-${#BT_PHP_VERSIONS[@]}): " -r choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#BT_PHP_VERSIONS[@]} ]; then
                PHP_VERSION="${BT_PHP_VERSIONS[$((choice-1))]}"
                PHP_CMD="/www/server/php/$PHP_VERSION/bin/php"
                return 0
            else
                log_error "无效选择，请输入 1-${#BT_PHP_VERSIONS[@]} 之间的数字"
            fi
        done
    fi
}

# 安装宝塔环境下可自动处理的扩展
install_bt_auto_extensions() {
    if ! check_bt_panel || [ -z "$PHP_VERSION" ]; then
        return 1
    fi
    
    # 除了4个必须手工安装的扩展外，其他都尝试自动安装
    local manual_extensions=("calendar" "fileinfo" "mbstring" "redis")
    local auto_extensions=(
        "bcmath" "ctype" "curl" "dom" "gd" "iconv" 
        "intl" "json" "openssl" "pcntl" "pcre" 
        "pdo" "pdo_mysql" "tokenizer" "xml" "zip"
    )
    
    local missing_auto=()
    local installed_any=false
    
    # 检查哪些可自动安装的扩展缺失（CLI/FPM分别检测）
    local php_cli="/www/server/php/$PHP_VERSION/bin/php"
    local cli_ini="/www/server/php/$PHP_VERSION/etc/php-cli.ini"
    local fpm_ini="/www/server/php/$PHP_VERSION/etc/php.ini"
    
    for ext in "${auto_extensions[@]}"; do
        local cli_missing=false
        local fpm_missing=false
        
        # 检查CLI模式
        if ! PHPRC="$cli_ini" $php_cli -m 2>/dev/null | grep -qi "^$ext$"; then
            cli_missing=true
        fi
        
        # 检查FPM模式  
        if ! PHPRC="$fpm_ini" $php_cli -m 2>/dev/null | grep -qi "^$ext$"; then
            fpm_missing=true
        fi
        
        # 如果任一模式缺失，加入待安装列表
        if [ "$cli_missing" = true ] || [ "$fpm_missing" = true ]; then
            missing_auto+=("$ext")
        fi
    done
    
    if [ ${#missing_auto[@]} -gt 0 ]; then
        log_info "尝试自动安装PHP扩展: ${missing_auto[*]}"
        
        # 根据系统类型使用对应的包管理器
        local php_version_short=""
        if [[ "$PHP_VERSION" =~ ^[0-9]{2}$ ]]; then
            # 宝塔格式：83 -> 8.3
            php_version_short="${PHP_VERSION:0:1}.${PHP_VERSION:1:1}"
        else
            # 标准格式：8.3 -> 8.3
            php_version_short="$PHP_VERSION"
        fi
        
        local install_success=()
        local install_failed=()
        
        for ext in "${missing_auto[@]}"; do
            local installed=false
            local pkg_name=""
            
            # Ubuntu/Debian系统
            if command -v apt-get >/dev/null 2>&1; then
                # 扩展名映射
                case "$ext" in
                    "pdo_mysql") pkg_name="php${php_version_short}-mysql" ;;
                    *) pkg_name="php${php_version_short}-${ext}" ;;
                esac
                
                if sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y "$pkg_name" >/dev/null 2>&1; then
                    installed=true
                fi
            # CentOS/RHEL系统  
            elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
                local installer="yum"
                command -v dnf >/dev/null 2>&1 && installer="dnf"
                
                # 扩展名映射
                case "$ext" in
                    "pdo_mysql") pkg_name="php-mysqlnd" ;;
                    *) pkg_name="php-${ext}" ;;
                esac
                
                if sudo $installer install -y "$pkg_name" >/dev/null 2>&1; then
                    installed=true
                fi
            fi
            
            if [ "$installed" = true ]; then
                install_success+=("$ext")
                installed_any=true
            else
                install_failed+=("$ext")
            fi
        done
        
        # 如果有扩展安装成功，重启PHP服务
        if [ "$installed_any" = true ]; then
            log_success "已安装扩展: ${install_success[*]}"
            
            # 重启PHP服务
            local php_service_name=""
            if [[ "$PHP_VERSION" =~ ^[0-9]{2}$ ]]; then
                # 宝塔格式：83 -> php83-fpm
                php_service_name="php${PHP_VERSION: -2}-fpm"
            else
                # 标准格式：8.3 -> php8.3-fpm
                php_service_name="php${PHP_VERSION}-fpm"
            fi
            
            # 尝试多种服务重启方法
            if systemctl list-units --type=service | grep -q "$php_service_name"; then
                sudo systemctl restart "$php_service_name" >/dev/null 2>&1
            elif systemctl list-units --type=service | grep -q "php.*fpm"; then
                # 通用PHP-FPM服务重启
                sudo systemctl restart php*fpm >/dev/null 2>&1
            elif [ -f "/etc/init.d/php-fpm-${PHP_VERSION}" ]; then
                sudo /etc/init.d/php-fpm-${PHP_VERSION} restart >/dev/null 2>&1
            fi
        fi
        
        if [ ${#install_failed[@]} -gt 0 ]; then
            log_warning "以下扩展需要在宝塔面板中手动安装: ${install_failed[*]}"
        fi
    fi
    
    return 0
}

# 宝塔面板环境处理
handle_bt_panel() {
    # 选择PHP版本
    if select_bt_php_version; then
        echo
        log_success "检测到 PHP 8.${PHP_VERSION: -1}"
        
        # 1. 处理PHP函数
        local functions_ok=true
        if ! check_php_functions; then
            # 尝试自动启用
            if enable_bt_php_functions && check_php_functions; then
                log_success "PHP函数已自动启用"
            else
                functions_ok=false
            fi
        fi
        
        # 2. 尝试安装可自动处理的扩展
        install_bt_auto_extensions
        
        # 3. 安装后重新检测所有函数和扩展状态（分模式校验）
        echo
        log_info "校验PHP函数和扩展安装结果 (CLI/FPM分别检查)..."
        echo
        
        # 重新检测函数和扩展状态
        check_php_functions >/dev/null 2>&1 || true
        check_php_extensions >/dev/null 2>&1 || true
        
        # 校验PHP函数
        log_info "PHP函数检查 (CLI vs FPM):"
        local required_functions=("exec" "putenv" "pcntl_signal" "pcntl_alarm")
        local optional_functions=("proc_open")
        local functions_all_ok=true
        
        # 解析导出的环境变量
        local cli_disabled_required=($PHP_CLI_DISABLED_REQUIRED)
        local fpm_disabled_required=($PHP_FMP_DISABLED_REQUIRED)
        local cli_disabled_optional=($PHP_CLI_DISABLED_OPTIONAL)
        local fpm_disabled_optional=($PHP_FMP_DISABLED_OPTIONAL)
        
        # 检查必需函数
        for func in "${required_functions[@]}"; do
            local cli_status="[OK]"
            local fpm_status="[OK]"
            
            # 检查CLI状态
            if [[ " ${cli_disabled_required[*]} " =~ " ${func} " ]]; then
                cli_status="[DISABLED]"
                functions_all_ok=false
            fi
            
            # 检查FPM状态
            if [[ " ${fpm_disabled_required[*]} " =~ " ${func} " ]]; then
                fpm_status="[DISABLED]"
                functions_all_ok=false
            fi
            
            if [ "$cli_status" = "[OK]" ] && [ "$fpm_status" = "[OK]" ]; then
                log_success "  $(printf '%-15s' "$func"): CLI $cli_status, FPM $fpm_status"
            else
                log_warning "  $(printf '%-15s' "$func"): CLI $cli_status, FPM $fpm_status (必需)"
            fi
        done
        
        # 检查可选函数
        for func in "${optional_functions[@]}"; do
            local cli_status="[OK]"
            local fpm_status="[OK]"
            
            if [[ " ${cli_disabled_optional[*]} " =~ " ${func} " ]]; then
                cli_status="[DISABLED]"
            fi
            
            if [[ " ${fpm_disabled_optional[*]} " =~ " ${func} " ]]; then
                fpm_status="[DISABLED]"
            fi
            
            if [ "$cli_status" = "[OK]" ] && [ "$fpm_status" = "[OK]" ]; then
                log_success "  $(printf '%-15s' "$func"): CLI $cli_status, FPM $fpm_status (可选)"
            else
                log_info "  $(printf '%-15s' "$func"): CLI $cli_status, FPM $fpm_status (可选)"
            fi
        done
        
        echo
        log_info "PHP扩展检查 (CLI vs FPM):"
        
        # 解析扩展检测结果
        local cli_missing_extensions=($PHP_CLI_MISSING_EXTENSIONS)
        local fpm_missing_extensions=($PHP_FMP_MISSING_EXTENSIONS)
        local required_extensions_array=($REQUIRED_EXTENSIONS)
        
        # 分类扩展
        local auto_extensions=(
            "bcmath" "ctype" "curl" "dom" "gd" "iconv" 
            "intl" "json" "openssl" "pcntl" "pcre" 
            "pdo" "pdo_mysql" "tokenizer" "xml" "zip"
        )
        local manual_extensions=("calendar" "fileinfo" "mbstring" "redis")
        
        local extensions_all_ok=true
        local total_extensions=${#required_extensions_array[@]}
        local cli_missing_count=0
        local fpm_missing_count=0
        
        # 检查自动安装的扩展
        for ext in "${auto_extensions[@]}"; do
            local cli_status="[OK]"
            local fpm_status="[OK]"
            
            if [[ " ${cli_missing_extensions[*]} " =~ " ${ext} " ]]; then
                cli_status="[MISSING]"
                extensions_all_ok=false
                cli_missing_count=$((cli_missing_count + 1))
            fi
            
            if [[ " ${fpm_missing_extensions[*]} " =~ " ${ext} " ]]; then
                fpm_status="[MISSING]"
                extensions_all_ok=false
                fpm_missing_count=$((fpm_missing_count + 1))
            fi
            
            if [ "$cli_status" = "[OK]" ] && [ "$fpm_status" = "[OK]" ]; then
                log_success "  $(printf '%-12s' "$ext"): CLI $cli_status, FPM $fpm_status"
            else
                log_error "  $(printf '%-12s' "$ext"): CLI $cli_status, FPM $fpm_status (自动安装失败)"
            fi
        done
        
        # 检查需要手动安装的扩展
        echo
        log_info "手动安装扩展检查 (CLI vs FPM):"
        for ext in "${manual_extensions[@]}"; do
            local cli_status="[OK]"
            local fpm_status="[OK]"
            
            if [[ " ${cli_missing_extensions[*]} " =~ " ${ext} " ]]; then
                cli_status="[MISSING]"
                cli_missing_count=$((cli_missing_count + 1))
            fi
            
            if [[ " ${fpm_missing_extensions[*]} " =~ " ${ext} " ]]; then
                fpm_status="[MISSING]"
                fpm_missing_count=$((fpm_missing_count + 1))
            fi
            
            if [ "$cli_status" = "[OK]" ] && [ "$fpm_status" = "[OK]" ]; then
                log_success "  $(printf '%-12s' "$ext"): CLI $cli_status, FPM $fpm_status"
            else
                log_warning "  $(printf '%-12s' "$ext"): CLI $cli_status, FPM $fpm_status (需手动安装)"
            fi
        done
        
        echo
        log_info "扩展统计:"
        log_info "  CLI: $((total_extensions - cli_missing_count))/$total_extensions 已安装"
        log_info "  FPM: $((total_extensions - fpm_missing_count))/$total_extensions 已安装"
        
        # 4. 输出结果摘要
        local extensions_ok=true
        if [ $cli_missing_count -gt 0 ] || [ $fpm_missing_count -gt 0 ]; then
            extensions_ok=false
        fi
        
        echo
        if [ "$functions_all_ok" = true ] && [ "$extensions_ok" = true ]; then
            log_success "PHP环境完全就绪 (CLI和FPM模式)！"
            return 0
        fi
        
        # 显示需要处理的问题摘要
        if [ "$functions_all_ok" = false ]; then
            log_warning "检测到PHP函数被禁用"
            log_info "   需要在宝塔面板启用: PHP设置 -> 禁用函数 -> 移除禁用的函数"
            if [ ${#cli_disabled_required[@]} -gt 0 ]; then
                log_info "   CLI模式禁用的必需函数: ${cli_disabled_required[*]}"
            fi
            if [ ${#fpm_disabled_required[@]} -gt 0 ]; then
                log_info "   FPM模式禁用的必需函数: ${fpm_disabled_required[*]}"
            fi
        fi
        
        if [ $extensions_ok = false ]; then
            log_warning "检测到PHP扩展缺失"
            if [ ${#cli_missing_extensions[@]} -gt 0 ]; then
                log_info "   CLI模式缺失的扩展: ${cli_missing_extensions[*]}"
            fi
            if [ ${#fpm_missing_extensions[@]} -gt 0 ]; then
                log_info "   FPM模式缺失的扩展: ${fpm_missing_extensions[*]}"
            fi
            log_info "   安装路径: 软件商店 -> PHP -> 安装扩展"
        fi
        
    else
        log_warning "未检测到 PHP 8.3 或更高版本"
        
        echo
        log_warning "=== 需要在宝塔面板中完成的安装 ==="
        log_warning "1. 【安装PHP】"
        log_warning "   - 登录宝塔面板"
        log_warning "   - 进入【软件商店】->【运行环境】"
        log_warning "   - 安装 PHP 8.3 或更高版本"
        log_warning "2. 【配置函数和扩展】"
        log_warning "   - 安装完PHP后，按上述步骤配置函数和扩展"
        log_warning "====================================="
    fi
}

# 宝塔环境自动启用PHP函数
enable_bt_php_functions() {
    if ! check_bt_panel || [ -z "$PHP_VERSION" ]; then
        return 1
    fi
    
    local fpm_ini="/www/server/php/$PHP_VERSION/etc/php.ini"
    local cli_ini="/www/server/php/$PHP_VERSION/etc/php-cli.ini"
    local required_functions=("exec" "putenv" "pcntl_signal" "pcntl_alarm")
    local optional_functions=("proc_open")
    local all_functions=("${required_functions[@]}" "${optional_functions[@]}")
    local modified=false
    
    # 静默处理FPM配置文件
    if [ -f "$fpm_ini" ]; then
        # 备份配置文件
        sudo cp "$fpm_ini" "${fpm_ini}.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null
        
        # 获取当前禁用的函数列表
        local current_disabled=$(grep "^disable_functions" "$fpm_ini" | sed 's/disable_functions = //')
        
        if [ -n "$current_disabled" ]; then
            # 构建新的禁用函数列表（移除我们需要的函数）
            local new_disabled=""
            IFS=',' read -ra DISABLED_ARRAY <<< "$current_disabled"
            
            for func in "${DISABLED_ARRAY[@]}"; do
                func=$(echo "$func" | xargs)  # 去除空格
                local keep=true
                for needed_func in "${all_functions[@]}"; do
                    if [ "$func" = "$needed_func" ]; then
                        keep=false
                        modified=true
                        break
                    fi
                done
                if [ "$keep" = true ] && [ -n "$func" ]; then
                    if [ -n "$new_disabled" ]; then
                        new_disabled="$new_disabled,$func"
                    else
                        new_disabled="$func"
                    fi
                fi
            done
            
            # 更新配置文件
            sudo sed -i "s/^disable_functions = .*/disable_functions = $new_disabled/" "$fpm_ini" 2>/dev/null
        fi
    fi
    
    # 静默处理CLI配置文件
    if [ -f "$cli_ini" ]; then
        # 备份配置文件
        sudo cp "$cli_ini" "${cli_ini}.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null
        
        # 获取当前禁用的函数列表
        local current_disabled=$(grep "^disable_functions" "$cli_ini" | sed 's/disable_functions = //')
        
        if [ -n "$current_disabled" ]; then
            # 构建新的禁用函数列表（移除我们需要的函数）
            local new_disabled=""
            IFS=',' read -ra DISABLED_ARRAY <<< "$current_disabled"
            
            for func in "${DISABLED_ARRAY[@]}"; do
                func=$(echo "$func" | xargs)  # 去除空格
                local keep=true
                for needed_func in "${all_functions[@]}"; do
                    if [ "$func" = "$needed_func" ]; then
                        keep=false
                        modified=true
                        break
                    fi
                done
                if [ "$keep" = true ] && [ -n "$func" ]; then
                    if [ -n "$new_disabled" ]; then
                        new_disabled="$new_disabled,$func"
                    else
                        new_disabled="$func"
                    fi
                fi
            done
            
            # 更新配置文件
            sudo sed -i "s/^disable_functions = .*/disable_functions = $new_disabled/" "$cli_ini" 2>/dev/null
        fi
    fi
    
    if [ "$modified" = true ]; then
        # 静默重启PHP服务
        sudo systemctl restart php${PHP_VERSION: -2}-fpm 2>/dev/null || \
        sudo /etc/init.d/php-fpm-${PHP_VERSION} restart 2>/dev/null || \
        sudo pkill -f "php-fpm.*php/$PHP_VERSION" 2>/dev/null && sudo /www/server/php/$PHP_VERSION/sbin/php-fpm 2>/dev/null
        
        return 0
    else
        return 1
    fi
}

# 卸载冲突的系统PHP
remove_system_php() {
    log_info "分析冲突的系统PHP包..."
    
    # 检测系统包管理器
    if command -v apt-get >/dev/null 2>&1; then
        # Ubuntu/Debian系统
        
        # 检查哪些包提供了冲突的PHP命令
        local conflicting_packages=()
        local php_commands=("/usr/bin/php8.4" "/usr/bin/php8.3" "/usr/bin/php8.2" "/usr/bin/php8.1" "/usr/bin/php8.0" "/usr/bin/php7.4")
        
        for cmd in "${php_commands[@]}"; do
            if [ -x "$cmd" ]; then
                # 查找哪个包提供了这个命令
                local package=""
                package=$(dpkg -S "$cmd" 2>/dev/null | cut -d: -f1 | head -1)
                if [ -n "$package" ] && [[ ! " ${conflicting_packages[*]} " =~ " $package " ]]; then
                    conflicting_packages+=("$package")
                    log_info "  冲突命令 $cmd 由包 $package 提供"
                fi
            fi
        done
        
        # 也检查一些常见的PHP核心包
        local common_php_packages=("php" "php-cli" "php-common" "php-fpm")
        for pkg in "${common_php_packages[@]}"; do
            if dpkg -l | grep -q "^ii.*$pkg[[:space:]]"; then
                conflicting_packages+=("$pkg")
                log_info "  发现系统PHP包: $pkg"
            fi
        done
        
        if [ ${#conflicting_packages[@]} -gt 0 ]; then
            echo
            log_warning "发现 ${#conflicting_packages[@]} 个冲突的系统PHP包："
            printf "  - %s\\n" "${conflicting_packages[@]}"
            echo
            
            log_warning "注意：卸载这些包可能影响依赖它们的其他软件！"
            log_info "这些包会与宝塔PHP产生冲突，影响Composer正常工作。"
            echo
            read -p "确定要卸载这些冲突的PHP包吗？(y/N): " -n 1 -r confirm < /dev/tty
            echo
            
            if [[ $confirm =~ ^[Yy]$ ]]; then
                log_info "开始卸载冲突的系统PHP包..."
                if sudo apt-get remove --autoremove -y "${conflicting_packages[@]}" >/dev/null 2>&1; then
                    log_success "系统PHP包已成功卸载"
                    
                    # 清理残留配置
                    sudo apt-get autoremove -y >/dev/null 2>&1
                    sudo apt-get autoclean >/dev/null 2>&1
                    
                    # 验证卸载结果 - 检查具体的冲突命令是否已移除
                    local remaining_conflicts=0
                    for cmd in "${php_commands[@]}"; do
                        if [ -x "$cmd" ]; then
                            log_warning "  残留命令: $cmd"
                            remaining_conflicts=$((remaining_conflicts + 1))
                        fi
                    done
                    
                    if [ $remaining_conflicts -eq 0 ]; then
                        log_success "验证通过：冲突的系统PHP命令已移除"
                        log_info "注意：/usr/bin/php 将通过软链接指向宝塔PHP"
                        return 0
                    else
                        log_warning "仍有 $remaining_conflicts 个冲突命令残留，但主要问题应已解决"
                        return 0
                    fi
                else
                    log_error "卸载过程中出现错误"
                    return 1
                fi
            else
                log_info "用户取消卸载操作"
                return 1
            fi
        else
            log_info "未发现系统PHP包（可能是手动安装的）"
            return 1
        fi
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        # CentOS/RHEL/Fedora系统
        log_warning "检测到RedHat系系统，请手动卸载PHP包："
        log_info "  yum remove php php-* 或 dnf remove php php-*"
        return 1
    else
        log_warning "未知的包管理器，无法自动卸载"
        return 1
    fi
}

# 修复宝塔环境Composer PHP版本问题
fix_bt_composer_php() {
    if ! check_bt_panel || [ -z "$PHP_VERSION" ]; then
        return 0
    fi
    
    local bt_php="/www/server/php/$PHP_VERSION/bin/php"
    local minimum_php_version="8.3"
    
    log_info "检查PHP命令行配置..."
    
    # 检查 /usr/bin/php 是否存在且可用
    if [ ! -e "/usr/bin/php" ]; then
        log_info "/usr/bin/php 不存在，创建指向宝塔PHP的链接"
    else
        # 检查当前PHP是否可用
        if php_version=$(timeout 3s /usr/bin/php -r "echo PHP_VERSION;" 2>/dev/null); then
            # 检查是否指向宝塔PHP
            if [ -L "/usr/bin/php" ]; then
                local link_target=$(readlink -f "/usr/bin/php")
                if [[ "$link_target" == *"/www/server/php"* ]]; then
                    # 检查版本是否满足要求
                    if version_compare "$php_version" "$minimum_php_version"; then
                        log_success "✓ /usr/bin/php 配置正确，版本: $php_version (>= $minimum_php_version)"
                        return 0
                    else
                        log_warning "! /usr/bin/php 版本过低: $php_version，需要升级"
                    fi
                else
                    log_warning "! /usr/bin/php 指向系统PHP: $link_target"
                fi
            else
                log_warning "! /usr/bin/php 是系统安装的PHP: $php_version"
            fi
        else
            log_warning "! /usr/bin/php 存在但无法执行"
        fi
    fi
    
    # 需要修复时，创建指向当前宝塔PHP的链接
    log_info "设置 /usr/bin/php 指向宝塔PHP $PHP_VERSION..."
    
    # 备份原文件（如果存在且不是软链接）
    if [ -f "/usr/bin/php" ] && [ ! -L "/usr/bin/php" ]; then
        sudo mv /usr/bin/php /usr/bin/php.system.bak 2>/dev/null || true
        log_info "已备份系统PHP到 /usr/bin/php.system.bak"
    fi
    
    # 删除现有的链接或文件
    sudo rm -f /usr/bin/php
    
    # 创建新的软链接
    if sudo ln -s "$bt_php" /usr/bin/php; then
        log_success "✓ 已创建软链接: /usr/bin/php -> $bt_php"
        
        # 验证
        if php_version=$(timeout 3s /usr/bin/php -r "echo PHP_VERSION;" 2>/dev/null); then
            log_success "✓ 设置成功，PHP版本: $php_version"
            
            # 同时处理php-config和phpize
            sudo rm -f /usr/bin/php-config /usr/bin/phpize
            sudo ln -s "/www/server/php/$PHP_VERSION/bin/php-config" /usr/bin/php-config 2>/dev/null || true
            sudo ln -s "/www/server/php/$PHP_VERSION/bin/phpize" /usr/bin/phpize 2>/dev/null || true
            
            return 0
        else
            log_error "设置后验证失败"
            return 1
        fi
    else
        log_error "创建软链接失败"
        return 1
    fi
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
                    if ! check_bt_panel; then
                        log_info "尝试更新Composer..."
                        install_or_update_composer
                    else
                        log_info "宝塔环境，请手动更新Composer或使用系统自带版本"
                    fi
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
    local final_version=$(composer --version 2>&1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
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
    # 参数解析
    local run_diagnose=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--diagnose)
                run_diagnose=true
                shift
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 如果是诊断模式，只运行诊断
    if [ "$run_diagnose" = true ]; then
        # 直接运行诊断，不需要选择PHP版本
        if diagnose_php_extension_issues; then
            log_success "诊断完成"
        else
            log_error "诊断失败"
        fi
        return 0
    fi
    
    # 检测系统
    echo
    detect_system

    echo
    # 检测宝塔环境
    if check_bt_panel; then
        log_info "检测到宝塔面板环境"
        handle_bt_panel
        
        # 宝塔环境自动处理Composer
        echo
        log_info "检查 Composer..."
        
        # 先修复宝塔环境Composer PHP版本问题
        fix_bt_composer_php
        echo
        
        if ! check_composer; then
            log_info "自动安装 Composer..."
            install_or_update_composer
        else
            # 检查版本是否需要更新
            local current_version=$(timeout -k 3s 10s composer --version 2>&1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
            if [ -n "$current_version" ] && ! version_compare "$current_version" "2.8.0"; then
                log_warning "Composer 版本 $current_version 低于推荐版本 2.8.0"
                log_info "自动更新 Composer..."
                install_or_update_composer
            fi
        fi
        
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
    fi
    
    # 给出最终提示
    echo
    log_success "环境检查完成"
    
    # 如果用户需要，提供深度诊断选项
    echo
    log_info "如果composer install报错缺少扩展，可运行深度诊断："
    log_info "  ./install-deps.sh --diagnose"
    log_info "  或简写: ./install-deps.sh -d"
}

# 执行主函数
main "$@"
