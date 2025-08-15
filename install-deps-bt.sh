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

# 检测服务器是否在中国大陆（简化版）
is_china_server() {
    # 方法1: 检测到中国镜像站的延迟
    local china_hosts=("mirrors.aliyun.com" "mirrors.tencent.com")
    local low_latency_count=0
    
    for host in "${china_hosts[@]}"; do
        if ping -c 1 -W 1 "$host" >/dev/null 2>&1; then
            local avg_time=$(ping -c 2 -W 1 "$host" 2>/dev/null | grep "avg" | awk -F'/' '{print $5}')
            if [ -n "$avg_time" ]; then
                local avg_ms=${avg_time%.*}
                # 延迟小于50ms，很可能在中国大陆
                [ "$avg_ms" -lt 50 ] && low_latency_count=$((low_latency_count + 1))
            fi
        fi
    done
    
    # 方法2: 检查云服务商元数据
    # 阿里云
    if curl -s -m 1 "http://100.100.100.200/latest/meta-data/region-id" 2>/dev/null | grep -qE "^cn-"; then
        return 0
    fi
    # 腾讯云
    if curl -s -m 1 "http://metadata.tencentyun.com/latest/meta-data/region" 2>/dev/null | grep -qE "^ap-beijing|^ap-shanghai|^ap-guangzhou"; then
        return 0
    fi
    
    # 如果至少一个中国镜像站延迟很低，认为在中国
    [ $low_latency_count -ge 1 ] && return 0
    
    return 1
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
        
        # 重新下载安装（优先使用国内镜像）
        local temp_file="/tmp/composer_installer_$$.php"
        if curl -sS https://install.phpcomposer.com/installer -o "$temp_file" || curl -sS https://getcomposer.org/installer -o "$temp_file"; then
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
            printf "  - %s\n" "${conflicting_packages[@]}"
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
                    
                    # 验证卸载结果
                    local remaining_conflicts=0
                    for cmd in "${php_commands[@]}"; do
                        if [ -x "$cmd" ]; then
                            log_warning "  残留命令: $cmd"
                            remaining_conflicts=$((remaining_conflicts + 1))
                        fi
                    done
                    
                    if [ $remaining_conflicts -eq 0 ]; then
                        log_success "验证通过：冲突的系统PHP命令已移除"
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

# 检测JDK版本
check_jdk_version() {
    log_info "检测 JDK 版本..."
    
    # 检查 java 命令是否存在
    if ! command -v java >/dev/null 2>&1; then
        log_warning "未检测到 Java"
        return 1
    fi
    
    # 获取Java版本信息
    local java_version_output=$(java -version 2>&1)
    
    # 提取版本号（支持不同格式：1.8.0_xxx, 11.0.x, 17.0.x等）
    local java_version=""
    
    # 尝试匹配新版本格式（9+）: "17.0.1" 或 "11.0.2"
    if echo "$java_version_output" | grep -q '"[0-9]\+\.[0-9]\+\.[0-9]\+"'; then
        java_version=$(echo "$java_version_output" | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | tr -d '"' | cut -d. -f1)
    # 尝试匹配旧版本格式（8及以下）: "1.8.0_xxx"
    elif echo "$java_version_output" | grep -q '"1\.[0-9]\+\.[0-9]\+'; then
        java_version=$(echo "$java_version_output" | grep -oE '"1\.[0-9]+\.[0-9]+' | head -1 | tr -d '"' | cut -d. -f2)
    fi
    
    if [ -z "$java_version" ]; then
        log_warning "无法解析 Java 版本"
        return 1
    fi
    
    log_info "当前 Java 版本: $java_version"
    
    # 检查版本是否满足要求（>= 17）
    if [ "$java_version" -ge 17 ]; then
        log_success "Java 版本满足要求 (>= 17)"
        return 0
    else
        log_warning "Java 版本过低: $java_version，需要 >= 17"
        return 1
    fi
}

# 安装 JDK 17
install_jdk17() {
    log_info "开始安装 JDK 17..."
    
    # 检测系统类型
    local install_success=false
    
    # 宝塔环境特殊处理
    if check_bt_panel; then
        log_info "宝塔环境，尝试通过系统包管理器安装..."
    fi
    
    # Ubuntu/Debian 系统
    if command -v apt-get >/dev/null 2>&1; then
        # 只有在中国大陆服务器上才配置中国镜像源
        if is_china_server; then
            if [ -f /etc/apt/sources.list ] && ! grep -q "mirrors.aliyun.com\|mirrors.tuna" /etc/apt/sources.list; then
                log_info "检测到中国大陆服务器，配置 APT 中国镜像源..."
                sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
                sudo sed -i 's|http://[a-z][a-z].archive.ubuntu.com|http://mirrors.aliyun.com|g' /etc/apt/sources.list
                sudo sed -i 's|http://archive.ubuntu.com|http://mirrors.aliyun.com|g' /etc/apt/sources.list
                sudo sed -i 's|http://security.ubuntu.com|http://mirrors.aliyun.com|g' /etc/apt/sources.list
                sudo sed -i 's|http://deb.debian.org|http://mirrors.aliyun.com|g' /etc/apt/sources.list
            fi
        else
            log_info "检测到海外服务器，使用默认 APT 源..."
        fi
        log_info "使用 apt 安装 OpenJDK 17..."
        if sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y openjdk-17-jdk >/dev/null 2>&1; then
            install_success=true
        else
            # 尝试添加PPA仓库
            log_info "尝试添加 OpenJDK PPA 仓库..."
            sudo add-apt-repository -y ppa:openjdk-r/ppa >/dev/null 2>&1
            sudo apt-get update >/dev/null 2>&1
            if sudo apt-get install -y openjdk-17-jdk >/dev/null 2>&1; then
                install_success=true
            fi
        fi
    # CentOS/RHEL 系统
    elif command -v yum >/dev/null 2>&1; then
        # 只有在中国大陆服务器上才配置中国镜像源
        if is_china_server; then
            if [ -f /etc/yum.repos.d/CentOS-Base.repo ] && ! grep -q "mirrors.aliyun.com\|mirrors.tuna" /etc/yum.repos.d/CentOS-Base.repo; then
                log_info "检测到中国大陆服务器，配置 YUM 中国镜像源..."
                sudo cp /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.bak
                sudo sed -i 's|mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/CentOS-Base.repo
                sudo sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' /etc/yum.repos.d/CentOS-Base.repo
            fi
        else
            log_info "检测到海外服务器，使用默认 YUM 源..."
        fi
        log_info "使用 yum 安装 OpenJDK 17..."
        # CentOS 8+ / RHEL 8+
        if sudo yum install -y java-17-openjdk java-17-openjdk-devel >/dev/null 2>&1; then
            install_success=true
        else
            # CentOS 7 可能需要额外的仓库
            log_info "尝试启用额外仓库..."
            sudo yum install -y epel-release >/dev/null 2>&1
            if sudo yum install -y java-17-openjdk java-17-openjdk-devel >/dev/null 2>&1; then
                install_success=true
            fi
        fi
    # Fedora 系统
    elif command -v dnf >/dev/null 2>&1; then
        # 只有在中国大陆服务器上才配置中国镜像源
        if is_china_server; then
            if [ -f /etc/yum.repos.d/fedora.repo ] && ! grep -q "mirrors.aliyun.com\|mirrors.tuna" /etc/yum.repos.d/fedora.repo; then
                log_info "检测到中国大陆服务器，配置 DNF 中国镜像源..."
                sudo cp /etc/yum.repos.d/fedora.repo /etc/yum.repos.d/fedora.repo.bak
                sudo sed -i 's|metalink=|#metalink=|g' /etc/yum.repos.d/fedora.repo
                sudo sed -i 's|#baseurl=http://download.example/pub/fedora/linux|baseurl=https://mirrors.aliyun.com/fedora|g' /etc/yum.repos.d/fedora.repo
            fi
        else
            log_info "检测到海外服务器，使用默认 DNF 源..."
        fi
        log_info "使用 dnf 安装 OpenJDK 17..."
        if sudo dnf install -y java-17-openjdk java-17-openjdk-devel >/dev/null 2>&1; then
            install_success=true
        fi
    # openSUSE 系统
    elif command -v zypper >/dev/null 2>&1; then
        log_info "使用 zypper 安装 OpenJDK 17..."
        if sudo zypper install -y java-17-openjdk java-17-openjdk-devel >/dev/null 2>&1; then
            install_success=true
        fi
    # Arch Linux
    elif command -v pacman >/dev/null 2>&1; then
        log_info "使用 pacman 安装 OpenJDK 17..."
        if sudo pacman -Sy --noconfirm jdk17-openjdk >/dev/null 2>&1; then
            install_success=true
        fi
    fi
    
    # 如果系统包管理器安装失败，尝试手动下载安装
    if [ "$install_success" = false ]; then
        log_info "尝试手动下载安装 OpenJDK 17..."
        
        # 确定系统架构
        local arch=$(uname -m)
        local jdk_arch=""
        
        case "$arch" in
            x86_64|amd64)
                jdk_arch="x64"
                ;;
            aarch64|arm64)
                jdk_arch="aarch64"
                ;;
            *)
                log_error "不支持的系统架构: $arch"
                return 1
                ;;
        esac
        
        # 下载 OpenJDK 17
        local jdk_file="/tmp/openjdk-17.tar.gz"
        local jdk_url=""
        
        if is_china_server; then
            # 中国大陆使用清华镜像
            jdk_url="https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/linux/OpenJDK17U-jdk_${jdk_arch}_linux_hotspot_17.0.9_9.tar.gz"
            log_info "从清华镜像下载 OpenJDK 17..."
        else
            # 海外使用官方源
            jdk_url="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.9%2B9/OpenJDK17U-jdk_${jdk_arch}_linux_hotspot_17.0.9_9.tar.gz"
            log_info "从官方源下载 OpenJDK 17..."
        fi
        
        if curl -L -o "$jdk_file" "$jdk_url" >/dev/null 2>&1 || wget -O "$jdk_file" "$jdk_url" >/dev/null 2>&1; then
            # 解压到 /opt/java
            sudo mkdir -p /opt/java
            if sudo tar -xzf "$jdk_file" -C /opt/java; then
                # 查找解压后的目录
                local jdk_dir=$(ls -d /opt/java/jdk-17* 2>/dev/null | head -1)
                
                if [ -n "$jdk_dir" ] && [ -d "$jdk_dir" ]; then
                    # 创建符号链接
                    sudo ln -sf "$jdk_dir/bin/java" /usr/bin/java
                    sudo ln -sf "$jdk_dir/bin/javac" /usr/bin/javac
                    sudo ln -sf "$jdk_dir/bin/jar" /usr/bin/jar
                    
                    # 设置 JAVA_HOME
                    echo "export JAVA_HOME=$jdk_dir" | sudo tee /etc/profile.d/java.sh >/dev/null
                    echo "export PATH=\$JAVA_HOME/bin:\$PATH" | sudo tee -a /etc/profile.d/java.sh >/dev/null
                    
                    install_success=true
                    log_success "OpenJDK 17 手动安装成功"
                fi
            fi
            rm -f "$jdk_file"
        fi
    fi
    
    # 验证安装
    if [ "$install_success" = true ]; then
        # 刷新环境变量
        if [ -f /etc/profile.d/java.sh ]; then
            source /etc/profile.d/java.sh
        fi
        
        # 再次检查版本
        if check_jdk_version; then
            log_success "JDK 17 安装并验证成功"
            return 0
        else
            log_warning "JDK 安装后验证失败，请检查环境变量"
            return 1
        fi
    else
        log_error "JDK 17 安装失败"
        log_info "请手动安装 JDK 17 或更高版本："
        log_info "  Ubuntu/Debian: sudo apt-get install openjdk-17-jdk"
        log_info "  CentOS/RHEL: sudo yum install java-17-openjdk"
        log_info "  Fedora: sudo dnf install java-17-openjdk"
        log_info "  或访问: https://adoptium.net/"
        return 1
    fi
}

# 检查Composer
# 返回值：0=版本满足要求，1=未安装，2=需要升级
check_composer() {
    log_info "检查Composer..."
    
    if command -v composer >/dev/null 2>&1; then
        local full_output=""
        local exit_code=0
        
        # 优先使用 www 用户执行（如果当前是 root）
        if [ "$EUID" -eq 0 ] && id -u www >/dev/null 2>&1; then
            log_info "[DEBUG] 使用 www 用户执行 composer --version"
            full_output=$(sudo -u www composer --version 2>&1)
            exit_code=$?
        else
            # 非 root 用户或 www 用户不存在时
            export COMPOSER_NO_INTERACTION=1
            export COMPOSER_ALLOW_SUPERUSER=1
            
            # 尝试使用 --no-interaction 参数
            full_output=$(timeout -k 3s 10s composer --version --no-interaction 2>&1)
            exit_code=$?
            
            # 如果还是失败，尝试用 yes 响应
            if [[ "$full_output" == *"Continue as root"* ]]; then
                log_info "[DEBUG] 检测到root提示，使用yes响应"
                full_output=$(echo 'yes' | timeout -k 3s 10s composer --version 2>&1)
                exit_code=$?
            fi
        fi
        
        # 尝试提取版本行（可能在Deprecated警告之后）
        local composer_output=$(echo "$full_output" | grep "Composer version" | head -1)
        
        # 如果没找到，尝试获取第一行非警告内容
        if [ -z "$composer_output" ]; then
            composer_output=$(echo "$full_output" | grep -v "^PHP Deprecated\|^Deprecated\|^Warning" | head -1)
        fi
        
        log_info "[DEBUG] Composer版本行: $composer_output"
        
        if [ $exit_code -eq 124 ]; then
            log_warning "Composer 执行超时，可能存在网络问题"
            return 1
        elif [ -n "$composer_output" ]; then
            local composer_version=$(echo "$composer_output" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
            if [ -n "$composer_version" ]; then
                log_success "Composer $composer_version 已安装"
                # 检查版本是否满足要求（>= 2.8.0）
                log_info "[DEBUG] 准备比较版本: $composer_version vs 2.8.0"
                if version_compare "$composer_version" "2.8.0"; then
                    # 版本 >= 2.8.0，满足要求
                    log_info "[DEBUG] 版本满足要求，返回 0"
                    return 0
                else
                    # 版本 < 2.8.0，需要升级
                    log_warning "Composer 版本 $composer_version 低于推荐版本 2.8.0，需要升级"
                    log_info "[DEBUG] 版本过低，返回 2"
                    return 2  # 返回2表示需要升级
                fi
            else
                log_warning "[DEBUG] 无法从输出中提取版本号"
                return 1
            fi
        else
            log_warning "[DEBUG] Composer命令无输出"
            return 1
        fi
    else
        log_warning "Composer未安装"
        return 1  # 返回1表示未安装
    fi
}

# 安装或更新Composer
install_or_update_composer() {
    log_info "安装或更新 Composer..."
    
    cd /tmp
    rm -f composer-setup.php composer.phar
    
    # 根据地理位置选择下载源
    local installer_urls=()
    
    if is_china_server; then
        # 中国大陆优先使用国内镜像
        installer_urls=(
            "https://mirrors.aliyun.com/composer/composer.phar"
            "https://mirrors.cloud.tencent.com/composer/composer.phar"
            "https://install.phpcomposer.com/installer"
            "https://getcomposer.org/installer"
        )
    else
        # 海外优先使用官方源
        installer_urls=(
            "https://getcomposer.org/installer"
            "https://github.com/composer/composer/releases/latest/download/composer.phar"
        )
    fi
    
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
    
    # 根据地理位置配置镜像源
    if is_china_server; then
        log_info "配置 Composer 中国镜像源..."
        composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/ 2>/dev/null || true
        # 为www用户也配置镜像源
        if [ "$EUID" -eq 0 ]; then
            sudo -u www composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/ 2>/dev/null || true
        fi
    else
        log_info "使用 Composer 官方源..."
        # 确保使用官方源（移除可能存在的中国镜像配置）
        composer config -g --unset repos.packagist 2>/dev/null || true
        if [ "$EUID" -eq 0 ]; then
            sudo -u www composer config -g --unset repos.packagist 2>/dev/null || true
        fi
    fi
    
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
        log_info "提示：Composer命令将使用www用户执行"
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
    
    local minimum_php_version="8.3"
    local has_issue=false
    local php_link_issue=false
    local system_php_issue=false
    local composer_wrapper_issue=false
    local composer_missing=false
    local composer_version_issue=false
    
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
                log_success "  [OK] /usr/bin/php 配置正确 (宝塔PHP >= $minimum_php_version)"
            else
                log_warning "  ! PHP版本过低: $php_version，需要 >= $minimum_php_version"
                php_link_issue=true
                has_issue=true
            fi
        else
            log_error "  [FAIL] /usr/bin/php 不是宝塔PHP"
            php_link_issue=true
            has_issue=true
        fi
    else
        log_warning "  ! /usr/bin/php 不存在，需要创建链接"
        php_link_issue=true
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
        log_success "  [OK] 未发现系统PHP包"
    else
        log_warning "  ! 发现 ${#system_phps[@]} 个系统PHP包，建议卸载"
        system_php_issue=true
        has_issue=true
    fi
    
    echo
    log_info "=== 步骤3: 检查Composer配置 ==="
    
    if ! command -v composer >/dev/null 2>&1; then
        log_error "  [FAIL] 未找到Composer命令"
        log_info "  建议安装: curl -sS https://install.phpcomposer.com/installer | php"
        log_info "  然后移动: sudo mv composer.phar /usr/local/bin/composer"
        composer_missing=true
        has_issue=true
    else
        local composer_path=$(which composer)
        log_info "  Composer路径: $composer_path"
        
        # 检测composer是否是wrapper脚本
        if [ -f "$composer_path" ]; then
            local file_type=$(file -b "$composer_path" 2>/dev/null)
            if [[ "$file_type" == *"shell script"* ]] || [[ "$file_type" == *"bash"* ]] || [[ "$file_type" == *"text"* ]]; then
                # 检查内容是否包含wrapper特征
                if grep -q "BaoTa\|wrapper\|exec.*php.*composer" "$composer_path" 2>/dev/null; then
                    log_error "  [FAIL] 检测到Composer是宝塔wrapper脚本"
                    composer_wrapper_issue=true
                    
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
                log_success "  [OK] Composer是PHP/PHAR文件（正常）"
            fi
        fi
        
        # 测试composer执行
        if [ -e "/usr/bin/php" ]; then
            log_info "  测试Composer执行..."
            
            local composer_cmd="/usr/bin/php $(which composer) --version"
            local composer_version=""
            local composer_error=""
            
            if [ "$EUID" -eq 0 ]; then
                # root权限时，切换到www用户执行
                log_info "    使用www用户执行composer..."
                local full_output=$(sudo -u www bash -c "$composer_cmd" 2>&1)
                composer_error=$?
                composer_version=$(echo "$full_output" | grep "Composer version" | head -1)
                if [ -z "$composer_version" ]; then
                    composer_version=$(echo "$full_output" | grep -v "^PHP Deprecated\|^Deprecated\|^Warning" | head -1)
                fi
            else
                # 非root直接执行
                local full_output=$(timeout 5s $composer_cmd 2>&1)
                composer_error=$?
                composer_version=$(echo "$full_output" | grep "Composer version" | head -1)
                if [ -z "$composer_version" ]; then
                    composer_version=$(echo "$full_output" | grep -v "^PHP Deprecated\|^Deprecated\|^Warning" | head -1)
                fi
            fi
            
            if [ $composer_error -eq 0 ] && [[ "$composer_version" == *"Composer version"* ]]; then
                log_success "  [OK] Composer可以正常执行"
                log_info "    $composer_version"
                
                # 检查版本是否需要升级
                local current_version=$(echo "$composer_version" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
                if [ -n "$current_version" ]; then
                    if ! version_compare "$current_version" "2.8.0"; then
                        log_warning "  ! Composer 版本 $current_version 低于推荐版本 2.8.0，需要升级"
                        composer_version_issue=true
                        has_issue=true
                    fi
                fi
            elif [ $composer_error -eq 124 ]; then
                log_error "  [FAIL] Composer执行超时"
                has_issue=true
            elif [[ "$composer_version" == *"Deprecated"* ]] || [[ "$composer_version" == *"PHP Deprecated"* ]]; then
                # 如果只是 Deprecated 警告，尝试从后续行获取版本
                local clean_version=$(timeout 5s $composer_cmd 2>&1 | grep "Composer version" | head -1)
                if [ -n "$clean_version" ]; then
                    log_warning "  [WARN] Composer有Deprecated警告，但可以执行"
                    log_info "    $clean_version"
                    # 检查版本
                    local current_version=$(echo "$clean_version" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
                    if [ -n "$current_version" ] && ! version_compare "$current_version" "2.8.0"; then
                        log_warning "  ! Composer 版本 $current_version 低于推荐版本 2.8.0，需要升级"
                        composer_version_issue=true
                        has_issue=true
                    fi
                else
                    log_error "  [FAIL] Composer执行失败"
                    log_info "    输出: $composer_version"
                    has_issue=true
                fi
            else
                log_error "  [FAIL] Composer执行失败"
                log_info "    输出: $composer_version"
                log_info "    返回码: $composer_error"
                has_issue=true
            fi
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
            # 根据具体问题运行对应的修复函数
            
            # 1. 卸载系统PHP（如果有）
            if [ "$system_php_issue" = true ] && [ ${#system_phps[@]} -gt 0 ]; then
                log_info "正在卸载系统PHP包..."
                remove_system_php
            fi
            
            # 2. 修复 /usr/bin/php（如果需要）
            if [ "$php_link_issue" = true ]; then
                log_info "正在修复 /usr/bin/php..."
                fix_bt_composer_php
            fi
            
            # 3. 修复Composer wrapper（如果检测到）
            if [ "$composer_wrapper_issue" = true ]; then
                log_info "正在修复Composer wrapper..."
                fix_composer_wrapper
            fi
            
            # 4. 安装或更新Composer（如果缺失或版本过低）
            if [ "$composer_missing" = true ] || [ "$composer_version_issue" = true ]; then
                log_info "正在安装或更新Composer..."
                install_or_update_composer
            fi
            
            log_success "修复完成，请重新运行诊断验证"
        else
            log_info "跳过自动修复"
        fi
    else
        log_success "[OK] PHP和Composer配置正确，无需修复"
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
    
    # 1. 处理 PHP 和扩展
    handle_bt_panel
    
    # 2. 检查 Composer
    echo
    log_info "检查 Composer..."
    
    # 先修复PHP链接
    if select_bt_php_version; then
        fix_bt_composer_php
    fi
    
    # 检查Composer状态
    log_info "[DEBUG] 开始检查Composer状态..."
    check_composer
    local composer_status=$?
    log_info "[DEBUG] check_composer返回值: $composer_status"
    
    if [ $composer_status -eq 1 ]; then
        log_info "Composer未安装，自动安装..."
        install_or_update_composer
    elif [ $composer_status -eq 2 ]; then
        log_info "Composer版本过低，自动升级到最新版本..."
        install_or_update_composer
    else
        log_success "Composer版本满足要求（>= 2.8.0），无需更新"
    fi
    
    # 3. 检查 JDK
    echo
    log_info "检查 JDK 环境..."
    if ! check_jdk_version; then
        log_info "需要安装 JDK 17 或更高版本"
        install_jdk17
    fi
    
    # 最终提示
    echo
    log_success "环境检查完成"
    
    if [ -n "$PHP_VERSION" ]; then
        log_info "PHP 版本: PHP 8.${PHP_VERSION: -1}"
        log_info "PHP 路径: /www/server/php/$PHP_VERSION/bin/php"
    fi
    
    # 显示 JDK 版本
    if command -v java >/dev/null 2>&1; then
        local java_ver=$(java -version 2>&1 | head -1)
        log_info "Java 版本: $java_ver"
    fi
    
    echo
    log_info "如果composer install报错，可运行深度诊断："
    log_info "  $0 --diagnose"
}

# 执行主函数
main "$@"