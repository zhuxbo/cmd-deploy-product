#!/bin/bash

# 证书管理系统宝塔面板专用依赖检查脚本
# 功能：检测并配置宝塔面板PHP 8.3+及必要的扩展

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
    echo "证书管理系统宝塔面板依赖检查脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help       显示此帮助信息"
    echo "  -d, --diagnose   运行PHP扩展深度诊断"
    echo ""
    echo "示例:"
    echo "  $0               # 正常运行依赖检查"
    echo "  $0 --diagnose    # 运行深度诊断"
    echo ""
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
        local sorted_versions=$(printf '%s\n%s' "$version1" "$version2" | sort -V)
        local lowest=$(echo "$sorted_versions" | head -n1)
        [ "$lowest" = "$version2" ] && return 0 || return 1
    else
        # 降级到简单的数字比较
        local v1_major=$(echo "$version1" | cut -d. -f1)
        local v1_minor=$(echo "$version1" | cut -d. -f2)
        
        local v2_major=$(echo "$version2" | cut -d. -f1)
        local v2_minor=$(echo "$version2" | cut -d. -f2)
        
        if [ "$v1_major" -gt "$v2_major" ]; then
            return 0
        elif [ "$v1_major" -lt "$v2_major" ]; then
            return 1
        fi
        
        if [ "$v1_minor" -ge "$v2_minor" ]; then
            return 0
        else
            return 1
        fi
    fi
}

# 检测宝塔面板
check_bt_panel() {
    if [ -f "/www/server/panel/BT-Panel" ] || \
       [ -f "/www/server/panel/class/panelPlugin.py" ] || \
       [ -d "/www/server/panel" ] && [ -f "/www/server/panel/data/port.pl" ]; then
        return 0  # 是宝塔环境
    fi
    return 1  # 非宝塔环境
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

# 检查PHP函数
check_php_functions() {
    local required_functions=("exec" "putenv" "pcntl_signal" "pcntl_alarm")
    local optional_functions=("proc_open")
    local cli_disabled_required=()
    local fpm_disabled_required=()
    local cli_disabled_optional=()
    local fpm_disabled_optional=()
    
    if [ -n "$PHP_VERSION" ]; then
        local fpm_ini="/www/server/php/$PHP_VERSION/etc/php.ini"
        local cli_ini="/www/server/php/$PHP_VERSION/etc/php-cli.ini"
        local php_cmd="/www/server/php/$PHP_VERSION/bin/php"
        
        # 检查FPM配置
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
        
        # 检查CLI配置
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
    fi
    
    # 导出检测结果
    export PHP_CLI_DISABLED_REQUIRED="${cli_disabled_required[*]}"
    export PHP_FPM_DISABLED_REQUIRED="${fpm_disabled_required[*]}"
    export PHP_CLI_DISABLED_OPTIONAL="${cli_disabled_optional[*]}"
    export PHP_FPM_DISABLED_OPTIONAL="${fpm_disabled_optional[*]}"
    
    # 返回失败条件：任一模式有必需函数被禁用
    if [ ${#cli_disabled_required[@]} -gt 0 ] || [ ${#fpm_disabled_required[@]} -gt 0 ]; then
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
    
    local cli_missing=()
    local fpm_missing=()
    
    if [ -n "$PHP_VERSION" ]; then
        local php_cli="/www/server/php/$PHP_VERSION/bin/php"
        
        # 检查CLI模式扩展
        for ext in "${required_extensions[@]}"; do
            if ! PHPRC="/www/server/php/$PHP_VERSION/etc/php-cli.ini" $php_cli -m 2>/dev/null | grep -qi "^$ext$"; then
                cli_missing+=("$ext")
            fi
        done
        
        # 检查FPM模式扩展
        for ext in "${required_extensions[@]}"; do
            if ! PHPRC="/www/server/php/$PHP_VERSION/etc/php.ini" $php_cli -m 2>/dev/null | grep -qi "^$ext$"; then
                fpm_missing+=("$ext")
            fi
        done
    fi
    
    # 导出检测结果
    export PHP_CLI_MISSING_EXTENSIONS="${cli_missing[*]}"
    export PHP_FPM_MISSING_EXTENSIONS="${fpm_missing[*]}"
    export REQUIRED_EXTENSIONS="${required_extensions[*]}"
    
    # 返回失败条件
    if [ ${#cli_missing[@]} -gt 0 ] || [ ${#fpm_missing[@]} -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# 自动启用PHP函数
enable_bt_php_functions() {
    if [ -z "$PHP_VERSION" ]; then
        return 1
    fi
    
    local fpm_ini="/www/server/php/$PHP_VERSION/etc/php.ini"
    local cli_ini="/www/server/php/$PHP_VERSION/etc/php-cli.ini"
    local required_functions=("exec" "putenv" "pcntl_signal" "pcntl_alarm")
    local optional_functions=("proc_open")
    local all_functions=("${required_functions[@]}" "${optional_functions[@]}")
    local modified=false
    
    # 处理FPM配置文件
    if [ -f "$fpm_ini" ]; then
        sudo cp "$fpm_ini" "${fpm_ini}.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null
        
        local current_disabled=$(grep "^disable_functions" "$fpm_ini" | sed 's/disable_functions = //')
        
        if [ -n "$current_disabled" ]; then
            local new_disabled=""
            IFS=',' read -ra DISABLED_ARRAY <<< "$current_disabled"
            
            for func in "${DISABLED_ARRAY[@]}"; do
                func=$(echo "$func" | xargs)
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
            
            sudo sed -i "s/^disable_functions = .*/disable_functions = $new_disabled/" "$fpm_ini" 2>/dev/null
        fi
    fi
    
    # 处理CLI配置文件
    if [ -f "$cli_ini" ]; then
        sudo cp "$cli_ini" "${cli_ini}.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null
        
        local current_disabled=$(grep "^disable_functions" "$cli_ini" | sed 's/disable_functions = //')
        
        if [ -n "$current_disabled" ]; then
            local new_disabled=""
            IFS=',' read -ra DISABLED_ARRAY <<< "$current_disabled"
            
            for func in "${DISABLED_ARRAY[@]}"; do
                func=$(echo "$func" | xargs)
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
            
            sudo sed -i "s/^disable_functions = .*/disable_functions = $new_disabled/" "$cli_ini" 2>/dev/null
        fi
    fi
    
    if [ "$modified" = true ]; then
        # 重启PHP服务
        sudo systemctl restart php${PHP_VERSION: -2}-fpm 2>/dev/null || \
        sudo /etc/init.d/php-fpm-${PHP_VERSION} restart 2>/dev/null || \
        sudo pkill -f "php-fpm.*php/$PHP_VERSION" 2>/dev/null && sudo /www/server/php/$PHP_VERSION/sbin/php-fpm 2>/dev/null
        
        return 0
    else
        return 1
    fi
}

# 修复 /usr/bin/php 链接
fix_bt_composer_php() {
    if [ -z "$PHP_VERSION" ]; then
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
                    if version_compare "$php_version" "$minimum_php_version"; then
                        log_success "[OK] /usr/bin/php 配置正确，版本: $php_version (>= $minimum_php_version)"
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
    
    # 修复链接
    log_info "设置 /usr/bin/php 指向宝塔PHP $PHP_VERSION..."
    
    # 备份原文件
    if [ -f "/usr/bin/php" ] && [ ! -L "/usr/bin/php" ]; then
        sudo mv /usr/bin/php /usr/bin/php.system.bak 2>/dev/null || true
        log_info "已备份系统PHP到 /usr/bin/php.system.bak"
    fi
    
    # 删除现有的链接或文件
    sudo rm -f /usr/bin/php
    
    # 创建新的软链接
    if sudo ln -s "$bt_php" /usr/bin/php; then
        log_success "[OK] 已创建软链接: /usr/bin/php -> $bt_php"
        
        # 验证
        if php_version=$(timeout 3s /usr/bin/php -r "echo PHP_VERSION;" 2>/dev/null); then
            log_success "[OK] 设置成功，PHP版本: $php_version"
            
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

# 检查Composer
check_composer() {
    log_info "检查Composer..."
    
    if command -v composer >/dev/null 2>&1; then
        export COMPOSER_NO_INTERACTION=1
        export COMPOSER_ALLOW_SUPERUSER=1
        
        local composer_output=$(timeout -k 3s 10s composer --version 2>&1 | grep -v "Deprecated\|Warning" | head -1)
        local exit_code=$?
        
        if [ $exit_code -eq 124 ]; then
            log_warning "Composer 执行超时，可能存在网络问题"
            return 1
        elif [ -n "$composer_output" ]; then
            local composer_version=$(echo "$composer_output" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
            if [ -n "$composer_version" ]; then
                log_success "Composer $composer_version 已安装"
                
                if ! version_compare "$composer_version" "2.8.0"; then
                    log_warning "Composer 版本 $composer_version 低于推荐版本 2.8.0"
                    return 1
                fi
                return 0
            fi
        fi
    else
        log_warning "Composer未安装"
        return 1
    fi
}

# 安装或更新Composer
install_or_update_composer() {
    log_info "安装或更新 Composer..."
    
    cd /tmp
    rm -f composer-setup.php composer.phar
    
    # 使用国内镜像下载
    local installer_urls=(
        "https://mirrors.aliyun.com/composer/composer.phar"
        "https://mirrors.tencent.com/composer/composer.phar"
        "https://getcomposer.org/installer"
    )
    
    local download_success=false
    
    for url in "${installer_urls[@]}"; do
        log_info "尝试从 $url 下载..."
        
        if [[ "$url" == *".phar" ]]; then
            if timeout 30s curl -sS "$url" -o composer.phar; then
                if /usr/bin/php composer.phar --version >/dev/null 2>&1; then
                    log_success "下载 composer.phar 成功"
                    download_success=true
                    break
                fi
            fi
        else
            if timeout 30s curl -sS "$url" -o composer-setup.php; then
                if /usr/bin/php composer-setup.php --quiet; then
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
        return 1
    fi
    
    # 移动到系统目录
    if sudo mv composer.phar /usr/local/bin/composer 2>/dev/null && sudo chmod +x /usr/local/bin/composer 2>/dev/null; then
        log_success "Composer 安装到 /usr/local/bin/composer"
    else
        log_error "无法安装 Composer"
        return 1
    fi
    
    # 配置中国镜像源
    log_info "配置 Composer 中国镜像源..."
    composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/ 2>/dev/null || true
    
    # 验证安装
    local final_version=$(composer --version 2>&1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
    if [ -n "$final_version" ]; then
        log_success "Composer $final_version 安装成功"
    fi
}

# 深度诊断
diagnose_php_extension_issues() {
    log_info "运行PHP扩展深度诊断模式..."
    
    if [ "$EUID" -eq 0 ]; then
        log_info "以root权限运行（正常）"
    else
        log_warning "非root权限运行，某些检测可能失败"
    fi
    
    if ! check_bt_panel; then
        log_error "未检测到宝塔环境，此脚本专用于宝塔面板"
        return 1
    fi
    
    if ! select_bt_php_version; then
        log_error "未找到PHP 8.3+版本"
        return 1
    fi
    
    local has_issue=false
    
    echo
    log_info "=== 步骤1: 检查 /usr/bin/php 配置 ==="
    
    if [ -e "/usr/bin/php" ]; then
        local php_version=$(timeout 3s /usr/bin/php -r "echo PHP_VERSION;" 2>/dev/null || echo "unknown")
        local real_path=$(readlink -f "/usr/bin/php" 2>/dev/null || echo "/usr/bin/php")
        
        log_info "  当前PHP: /usr/bin/php -> $real_path"
        log_info "  PHP版本: $php_version"
        
        if [[ "$real_path" == *"/www/server/php"* ]]; then
            if [ "$php_version" != "unknown" ] && version_compare "$php_version" "8.3"; then
                log_success "  [OK] /usr/bin/php 配置正确"
            else
                log_warning "  ! PHP版本过低: $php_version"
                has_issue=true
            fi
        else
            log_error "  [FAIL] /usr/bin/php 不是宝塔PHP"
            has_issue=true
        fi
    else
        log_warning "  ! /usr/bin/php 不存在"
        has_issue=true
    fi
    
    echo
    log_info "=== 步骤2: 检查Composer配置 ==="
    
    if ! command -v composer >/dev/null 2>&1; then
        log_error "  [FAIL] 未找到Composer命令"
        has_issue=true
    else
        local composer_path=$(which composer)
        log_info "  Composer路径: $composer_path"
        
        local composer_version=$(timeout 5s /usr/bin/php $(which composer) --version 2>&1 | head -1)
        if [ $? -eq 0 ] && [[ "$composer_version" == *"Composer version"* ]]; then
            log_success "  [OK] Composer可以正常执行"
            log_info "    $composer_version"
        else
            log_error "  [FAIL] Composer执行失败"
            has_issue=true
        fi
    fi
    
    echo
    log_info "=== 诊断总结 ==="
    
    if [ "$has_issue" = true ]; then
        log_error "发现问题，需要修复："
        
        echo
        read -p "是否自动修复这些问题？(y/n): " -n 1 -r choice < /dev/tty
        echo
        
        if [[ $choice =~ ^[Yy]$ ]]; then
            fix_bt_composer_php
            install_or_update_composer
            log_success "修复完成"
        else
            log_info "跳过自动修复"
        fi
    else
        log_success "[OK] PHP和Composer配置正确"
    fi
}

# 处理宝塔面板环境
handle_bt_panel() {
    if select_bt_php_version; then
        echo
        log_success "检测到 PHP 8.${PHP_VERSION: -1}"
        
        # 1. 处理PHP函数
        local functions_ok=true
        if ! check_php_functions; then
            if enable_bt_php_functions && check_php_functions; then
                log_success "PHP函数已自动启用"
            else
                functions_ok=false
            fi
        fi
        
        # 2. 检测所有函数和扩展状态
        echo
        log_info "校验PHP函数和扩展..."
        echo
        
        check_php_functions >/dev/null 2>&1 || true
        check_php_extensions >/dev/null 2>&1 || true
        
        # 校验PHP函数
        log_info "PHP函数检查:"
        local required_functions=("exec" "putenv" "pcntl_signal" "pcntl_alarm")
        local optional_functions=("proc_open")
        
        local cli_disabled_required=($PHP_CLI_DISABLED_REQUIRED)
        local fpm_disabled_required=($PHP_FPM_DISABLED_REQUIRED)
        local cli_disabled_optional=($PHP_CLI_DISABLED_OPTIONAL)
        local fpm_disabled_optional=($PHP_FPM_DISABLED_OPTIONAL)
        
        for func in "${required_functions[@]}"; do
            local cli_status="[OK]"
            local fpm_status="[OK]"
            
            if [[ " ${cli_disabled_required[*]} " =~ " ${func} " ]]; then
                cli_status="[DISABLED]"
            fi
            
            if [[ " ${fpm_disabled_required[*]} " =~ " ${func} " ]]; then
                fpm_status="[DISABLED]"
            fi
            
            if [ "$cli_status" = "[OK]" ] && [ "$fpm_status" = "[OK]" ]; then
                log_success "  $(printf '%-15s' "$func"): CLI $cli_status, FPM $fpm_status"
            else
                log_warning "  $(printf '%-15s' "$func"): CLI $cli_status, FPM $fpm_status (必需)"
            fi
        done
        
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
        log_info "PHP扩展检查:"
        
        local cli_missing_extensions=($PHP_CLI_MISSING_EXTENSIONS)
        local fpm_missing_extensions=($PHP_FPM_MISSING_EXTENSIONS)
        local required_extensions_array=($REQUIRED_EXTENSIONS)
        
        # 需要手动安装的扩展
        local manual_extensions=("calendar" "fileinfo" "mbstring" "redis")
        
        for ext in "${required_extensions_array[@]}"; do
            local cli_status="[OK]"
            local fpm_status="[OK]"
            local is_manual=false
            
            # 检查是否是手动安装扩展
            for manual_ext in "${manual_extensions[@]}"; do
                if [ "$ext" = "$manual_ext" ]; then
                    is_manual=true
                    break
                fi
            done
            
            if [[ " ${cli_missing_extensions[*]} " =~ " ${ext} " ]]; then
                cli_status="[MISSING]"
            fi
            
            if [[ " ${fpm_missing_extensions[*]} " =~ " ${ext} " ]]; then
                fpm_status="[MISSING]"
            fi
            
            if [ "$cli_status" = "[OK]" ] && [ "$fpm_status" = "[OK]" ]; then
                log_success "  $(printf '%-12s' "$ext"): CLI $cli_status, FPM $fpm_status"
            else
                if [ "$is_manual" = true ]; then
                    log_warning "  $(printf '%-12s' "$ext"): CLI $cli_status, FPM $fpm_status (需在宝塔面板手动安装)"
                else
                    log_error "  $(printf '%-12s' "$ext"): CLI $cli_status, FPM $fpm_status"
                fi
            fi
        done
        
        # 显示安装指引
        if [ ${#cli_missing_extensions[@]} -gt 0 ] || [ ${#fpm_missing_extensions[@]} -gt 0 ]; then
            echo
            log_warning "=== 需要在宝塔面板中安装扩展 ==="
            log_warning "1. 登录宝塔面板"
            log_warning "2. 进入【软件商店】->【已安装】"
            log_warning "3. 找到 PHP-${PHP_VERSION: -1}.${PHP_VERSION: -1}"
            log_warning "4. 点击【设置】->【安装扩展】"
            log_warning "5. 安装缺失的扩展"
        fi
        
    else
        log_warning "未检测到 PHP 8.3 或更高版本"
        
        echo
        log_warning "=== 需要在宝塔面板中安装PHP ==="
        log_warning "1. 登录宝塔面板"
        log_warning "2. 进入【软件商店】->【运行环境】"
        log_warning "3. 安装 PHP 8.3 或更高版本"
        log_warning "4. 安装完成后重新运行此脚本"
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
    
    # 检测宝塔环境
    if ! check_bt_panel; then
        log_error "未检测到宝塔面板环境"
        log_info "此脚本专用于宝塔面板，请使用 install-deps.sh 进行通用安装"
        exit 1
    fi
    
    log_info "检测到宝塔面板环境"
    
    # 如果是诊断模式
    if [ "$run_diagnose" = true ]; then
        if diagnose_php_extension_issues; then
            log_success "诊断完成"
        else
            log_error "诊断失败"
        fi
        return 0
    fi
    
    # 正常模式
    handle_bt_panel
    
    # 检查 Composer
    echo
    log_info "检查 Composer..."
    
    # 先修复PHP链接
    if select_bt_php_version; then
        fix_bt_composer_php
    fi
    
    if ! check_composer; then
        log_info "自动安装 Composer..."
        install_or_update_composer
    fi
    
    # 最终提示
    echo
    log_success "环境检查完成"
    
    if [ -n "$PHP_VERSION" ]; then
        log_info "PHP 版本: PHP 8.${PHP_VERSION: -1}"
        log_info "PHP 路径: /www/server/php/$PHP_VERSION/bin/php"
    fi
    
    echo
    log_info "如果composer install报错，可运行深度诊断："
    log_info "  $0 --diagnose"
}

# 执行主函数
main "$@"