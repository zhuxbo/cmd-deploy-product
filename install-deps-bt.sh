#!/bin/bash

# 证书管理系统宝塔环境依赖安装脚本
# 功能：专门处理宝塔面板环境下的PHP依赖安装和配置

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

# 显示帮助信息
show_help() {
    echo "证书管理系统宝塔环境依赖安装脚本"
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

# 版本比较函数
version_compare() {
    local version1="$1"
    local version2="$2"
    
    # 将版本号转换为数字进行比较
    local ver1_major="${version1%%.*}"
    local ver1_minor="${version1#*.}"
    ver1_minor="${ver1_minor%%.*}"
    
    local ver2_major="${version2%%.*}"
    local ver2_minor="${version2#*.}"
    ver2_minor="${ver2_minor%%.*}"
    
    if [ "$ver1_major" -gt "$ver2_major" ]; then
        return 0
    elif [ "$ver1_major" -eq "$ver2_major" ] && [ "$ver1_minor" -ge "$ver2_minor" ]; then
        return 0
    else
        return 1
    fi
}

# 深度诊断PHP扩展问题
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
        log_error "未检测到宝塔环境，此脚本专用于宝塔环境"
        log_info "请使用 install-deps.sh 处理普通环境"
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
            platform_output=$(timeout 10s $platform_cmd 2>&1)
        fi
        
        if [ $? -eq 0 ]; then
            log_success "  ✓ Composer扩展检测成功"
            
            # 检查必需的扩展
            local required_extensions=(
                "bcmath" "ctype" "curl" "dom" "fileinfo"
                "json" "mbstring" "openssl" "pcre" "pdo"
                "pdo_mysql" "tokenizer" "xml" "zip"
                "gd" "intl" "redis" "opcache" "iconv" "pcntl"
            )
            
            echo
            log_info "  必需扩展检测结果:"
            local missing_extensions=()
            for ext in "${required_extensions[@]}"; do
                if echo "$platform_output" | grep -qi "ext-$ext"; then
                    log_success "    ✓ $ext"
                else
                    log_error "    ✗ $ext (缺失)"
                    missing_extensions+=("$ext")
                    has_issue=true
                fi
            done
            
            if [ ${#missing_extensions[@]} -gt 0 ]; then
                echo
                log_error "  缺少 ${#missing_extensions[@]} 个扩展: ${missing_extensions[*]}"
                log_info "  请在宝塔面板中安装缺失的扩展"
            fi
        else
            log_error "  ✗ Composer扩展检测失败"
            has_issue=true
        fi
    fi
    
    echo
    log_info "=== 诊断结果汇总 ==="
    if [ "$has_issue" = true ]; then
        log_warning "发现一些问题需要处理："
        
        # 提供解决方案
        if [ ! -e "/usr/bin/php" ] || [[ "$(readlink -f "/usr/bin/php")" != *"/www/server/php"* ]]; then
            echo
            log_info "解决方案1: 设置正确的PHP链接"
            log_info "  请选择一个宝塔PHP版本创建链接："
            for ver in 85 84 83; do
                if [ -x "/www/server/php/$ver/bin/php" ]; then
                    log_info "  sudo ln -sf /www/server/php/$ver/bin/php /usr/bin/php"
                fi
            done
        fi
        
        if [ ${#system_phps[@]} -gt 0 ]; then
            echo
            log_info "解决方案2: 卸载系统PHP包"
            log_info "  建议使用主脚本卸载：sudo $0"
            log_info "  或选择诊断模式中的卸载选项"
        fi
        
        if [ "$composer_is_wrapper" = true ]; then
            echo
            log_info "解决方案3: 恢复原始Composer"
            if [ -f "/usr/bin/composer.original" ]; then
                log_info "  sudo mv /usr/bin/composer.original /usr/bin/composer"
            else
                log_info "  重新安装Composer:"
                log_info "  curl -sS https://getcomposer.org/installer | php"
                log_info "  sudo mv composer.phar /usr/local/bin/composer"
            fi
        fi
        
        return 1
    else
        log_success "所有检查通过，PHP环境配置正确！"
        return 0
    fi
}

# 检测宝塔PHP版本
detect_bt_php() {
    log_info "检测宝塔PHP版本..."
    
    # 检查可用的PHP版本（只检查8.3及以上版本）
    BT_PHP_VERSIONS=()
    for ver in 85 84 83; do
        if [ -d "/www/server/php/$ver" ] && [ -x "/www/server/php/$ver/bin/php" ]; then
            BT_PHP_VERSIONS+=("$ver")
        fi
    done
    
    if [ ${#BT_PHP_VERSIONS[@]} -eq 0 ]; then
        log_error "未找到宝塔PHP 8.3+版本"
        log_error "请先在宝塔面板中安装PHP 8.3或更高版本"
        return 1
    fi
    
    # 如果找到多个版本，让用户选择
    if [ ${#BT_PHP_VERSIONS[@]} -gt 1 ]; then
        log_info "检测到多个可用的PHP版本："
        echo
        for i in "${!BT_PHP_VERSIONS[@]}"; do
            local ver="${BT_PHP_VERSIONS[i]}"
            echo "  $((i+1)). PHP 8.${ver: -1} (/www/server/php/$ver/bin/php)"
        done
        echo
        
        while true; do
            read -p "请选择要使用的PHP版本 (1-${#BT_PHP_VERSIONS[@]}): " -r choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#BT_PHP_VERSIONS[@]} ]; then
                PHP_VERSION="${BT_PHP_VERSIONS[$((choice-1))]}"
                PHP_CMD="/www/server/php/$PHP_VERSION/bin/php"
                log_success "选择了 PHP 8.${PHP_VERSION: -1}"
                return 0
            else
                log_error "无效选择，请输入 1-${#BT_PHP_VERSIONS[@]} 之间的数字"
            fi
        done
    else
        # 只有一个版本，直接使用
        PHP_VERSION="${BT_PHP_VERSIONS[0]}"
        PHP_CMD="/www/server/php/$PHP_VERSION/bin/php"
        log_success "使用 PHP 8.${PHP_VERSION: -1}"
        return 0
    fi
}

# 检查PHP扩展
check_php_extensions() {
    log_info "检查PHP扩展..."
    
    # 必需的扩展列表
    local required_extensions=(
        "bcmath" "ctype" "curl" "dom" "fileinfo"
        "json" "mbstring" "openssl" "pcre" "pdo"
        "pdo_mysql" "tokenizer" "xml" "zip"
    )
    
    # 可选但推荐的扩展
    local optional_extensions=(
        "gd" "intl" "redis" "opcache"
    )
    
    local missing_required=()
    local missing_optional=()
    
    # 检查必需扩展
    for ext in "${required_extensions[@]}"; do
        if ! $PHP_CMD -m 2>/dev/null | grep -qi "^$ext$"; then
            missing_required+=("$ext")
        fi
    done
    
    # 检查可选扩展
    for ext in "${optional_extensions[@]}"; do
        if ! $PHP_CMD -m 2>/dev/null | grep -qi "^$ext$"; then
            missing_optional+=("$ext")
        fi
    done
    
    # 显示结果
    if [ ${#missing_required[@]} -eq 0 ]; then
        log_success "所有必需的PHP扩展已安装"
    else
        log_error "缺少必需的PHP扩展: ${missing_required[*]}"
        log_info "请在宝塔面板中为PHP ${PHP_VERSION} 安装这些扩展"
        return 1
    fi
    
    if [ ${#missing_optional[@]} -gt 0 ]; then
        log_warning "缺少可选扩展: ${missing_optional[*]}"
        log_info "建议安装这些扩展以获得更好的性能"
    fi
    
    return 0
}

# 检查PHP函数
check_php_functions() {
    log_info "检查PHP函数..."
    
    # 必需的函数列表
    local required_functions=(
        "putenv" "getenv" "proc_open" "proc_get_status"
        "proc_terminate" "proc_close" "shell_exec" "exec"
    )
    
    local disabled_functions=()
    
    # 获取被禁用的函数列表
    local disabled_list=$($PHP_CMD -r "echo ini_get('disable_functions');" 2>/dev/null)
    
    if [ -n "$disabled_list" ]; then
        # 检查哪些必需的函数被禁用了
        for func in "${required_functions[@]}"; do
            if echo "$disabled_list" | grep -q "$func"; then
                disabled_functions+=("$func")
            fi
        done
    fi
    
    if [ ${#disabled_functions[@]} -eq 0 ]; then
        log_success "所有必需的PHP函数已启用"
    else
        log_warning "以下PHP函数被禁用: ${disabled_functions[*]}"
        log_info "系统将尝试自动启用这些函数..."
        
        # 尝试自动修改配置
        if enable_php_functions; then
            log_success "PHP函数已自动启用"
        else
            log_warning "自动启用失败，请手动在宝塔面板中启用这些函数"
        fi
    fi
    
    return 0
}

# 启用PHP函数
enable_php_functions() {
    local fpm_ini="/www/server/php/$PHP_VERSION/etc/php.ini"
    local cli_ini="/www/server/php/$PHP_VERSION/etc/php-cli.ini"
    
    # 必需的函数列表
    local required_functions=(
        "putenv" "getenv" "proc_open" "proc_get_status"
        "proc_terminate" "proc_close" "shell_exec" "exec"
    )
    
    local modified=false
    
    # 处理FPM配置文件
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
                for needed_func in "${required_functions[@]}"; do
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
    
    # 处理CLI配置文件
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
                for needed_func in "${required_functions[@]}"; do
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
        # 重启PHP服务
        log_info "重启PHP服务..."
        sudo systemctl restart php${PHP_VERSION: -2}-fpm 2>/dev/null || \
        sudo /etc/init.d/php-fpm-${PHP_VERSION} restart 2>/dev/null || \
        sudo pkill -f "php-fpm.*php/$PHP_VERSION" 2>/dev/null && sudo /www/server/php/$PHP_VERSION/sbin/php-fpm 2>/dev/null
        
        return 0
    else
        return 1
    fi
}

# 安装或重新安装Composer
install_composer() {
    log_info "安装Composer..."
    
    # 使用国内镜像源（阿里云）
    local COMPOSER_INSTALL_URL="https://mirrors.aliyun.com/composer/composer.phar"
    local COMPOSER_INSTALL_BACKUP="https://install.phpcomposer.com/installer"
    
    # 先尝试直接下载 composer.phar
    log_info "从阿里云镜像下载 Composer..."
    if curl --connect-timeout 10 --max-time 60 -sL "$COMPOSER_INSTALL_URL" -o composer.phar; then
        if [ -f composer.phar ] && [ -s composer.phar ]; then
            # 验证下载的文件
            if $PHP_CMD composer.phar --version >/dev/null 2>&1; then
                sudo mv composer.phar /usr/local/bin/composer
                sudo chmod +x /usr/local/bin/composer
                log_success "Composer 安装成功（阿里云镜像）"
                return 0
            else
                log_warning "下载的 composer.phar 无效"
                rm -f composer.phar
            fi
        fi
    fi
    
    # 如果阿里云失败，尝试备用源
    log_info "尝试备用安装源..."
    if curl --connect-timeout 10 --max-time 60 -sS "$COMPOSER_INSTALL_BACKUP" | $PHP_CMD; then
        if [ -f composer.phar ]; then
            sudo mv composer.phar /usr/local/bin/composer
            sudo chmod +x /usr/local/bin/composer
            log_success "Composer 安装成功（备用源）"
            return 0
        fi
    fi
    
    # 最后尝试官方源
    log_info "尝试官方源（可能较慢）..."
    if curl --connect-timeout 10 --max-time 60 -sS https://getcomposer.org/installer | $PHP_CMD; then
        if [ -f composer.phar ]; then
            sudo mv composer.phar /usr/local/bin/composer
            sudo chmod +x /usr/local/bin/composer
            log_success "Composer 安装成功（官方源）"
            return 0
        fi
    fi
    
    log_error "Composer 安装失败，请检查网络连接"
    return 1
}

# 检查并修复Composer
check_composer() {
    log_info "检查Composer..."
    
    # 确保PHP_CMD已设置
    if [ -z "$PHP_CMD" ]; then
        log_warning "PHP_CMD未设置，尝试使用默认PHP"
        if [ -x "/usr/bin/php" ]; then
            PHP_CMD="/usr/bin/php"
        else
            log_error "无法找到可用的PHP命令"
            return 1
        fi
    fi
    
    local need_reinstall=false
    
    if command -v composer >/dev/null 2>&1; then
        local composer_path=$(which composer)
        
        # 检查是否是wrapper脚本
        if [ -f "$composer_path" ]; then
            # 检查文件类型
            local file_type=$(file -b "$composer_path" 2>/dev/null)
            
            # 如果是脚本文件，检查内容
            if [[ "$file_type" == *"shell script"* ]] || [[ "$file_type" == *"bash"* ]] || [[ "$file_type" == *"text"* ]]; then
                # 检查是否包含wrapper特征
                if grep -q "BaoTa\|wrapper\|/www/server/php" "$composer_path" 2>/dev/null; then
                    log_warning "检测到Composer是宝塔wrapper脚本"
                    
                    # 查找原始composer
                    local original_found=false
                    for orig in "/usr/bin/composer.original" "/usr/local/bin/composer.original" "${composer_path}.original"; do
                        if [ -f "$orig" ]; then
                            log_info "找到原始Composer: $orig"
                            log_info "恢复原始Composer..."
                            sudo mv "$orig" "$composer_path"
                            original_found=true
                            break
                        fi
                    done
                    
                    if [ "$original_found" = false ]; then
                        log_warning "未找到原始Composer，需要重新安装"
                        need_reinstall=true
                        # 删除wrapper
                        sudo rm -f "$composer_path"
                    fi
                fi
            fi
        fi
        
        # 如果不需要重新安装，验证版本
        if [ "$need_reinstall" = false ]; then
            # 使用PHP_CMD明确执行composer，避免wrapper问题
            local composer_version=""
            if [ -f "$composer_path" ]; then
                # 处理权限问题：如果是root用户，使用sudo -u www执行
                if [ "$EUID" -eq 0 ]; then
                    # 使用www用户执行，避免权限问题
                    composer_version=$(timeout 5s sudo -u www $PHP_CMD "$composer_path" --version 2>/dev/null | head -1)
                else
                    # 非root直接执行
                    composer_version=$(timeout 5s $PHP_CMD "$composer_path" --version 2>/dev/null | head -1)
                fi
            fi
            
            if [ -n "$composer_version" ]; then
                log_success "Composer已安装: $composer_version"
                
                # 配置中国镜像源（处理权限问题）
                log_info "配置Composer中国镜像源..."
                
                # 检查并修复composer配置目录权限
                local composer_home="${COMPOSER_HOME:-$HOME/.config/composer}"
                if [ ! -d "$composer_home" ]; then
                    composer_home="$HOME/.composer"
                fi
                
                # 如果配置目录存在且是root权限，修复权限
                if [ -d "$composer_home" ] && [ "$(stat -c %U "$composer_home")" = "root" ]; then
                    log_info "修复Composer配置目录权限..."
                    sudo chown -R "$USER:$USER" "$composer_home" 2>/dev/null || true
                fi
                
                # 使用sudo -u避免权限问题
                if [ "$EUID" -eq 0 ]; then
                    # root用户执行，切换到www用户
                    sudo -u www $PHP_CMD "$composer_path" config -g repo.packagist composer https://mirrors.aliyun.com/composer/ 2>/dev/null || true
                    sudo -u www $PHP_CMD "$composer_path" config -g use-parent-dir true 2>/dev/null || true
                else
                    # 普通用户直接执行
                    $PHP_CMD "$composer_path" config -g repo.packagist composer https://mirrors.aliyun.com/composer/ 2>/dev/null || true
                    $PHP_CMD "$composer_path" config -g use-parent-dir true 2>/dev/null || true
                fi
                log_success "已配置阿里云Composer镜像"
                
                return 0
            else
                log_warning "Composer命令存在但无法执行"
                need_reinstall=true
            fi
        fi
    else
        log_warning "Composer未安装"
        need_reinstall=true
    fi
    
    # 如果需要重新安装
    if [ "$need_reinstall" = true ]; then
        if install_composer; then
            # 配置中国镜像源（处理权限问题）
            log_info "配置Composer中国镜像源..."
            local new_composer_path="/usr/local/bin/composer"
            if [ -f "$new_composer_path" ]; then
                # 检查并修复composer配置目录权限
                local composer_home="${COMPOSER_HOME:-$HOME/.config/composer}"
                if [ ! -d "$composer_home" ]; then
                    composer_home="$HOME/.composer"
                fi
                
                # 如果配置目录存在且是root权限，修复权限
                if [ -d "$composer_home" ] && [ "$(stat -c %U "$composer_home")" = "root" ]; then
                    log_info "修复Composer配置目录权限..."
                    sudo chown -R "$USER:$USER" "$composer_home" 2>/dev/null || true
                fi
                
                # 使用sudo -u避免权限问题
                if [ "$EUID" -eq 0 ]; then
                    # root用户执行，切换到www用户
                    sudo -u www $PHP_CMD "$new_composer_path" config -g repo.packagist composer https://mirrors.aliyun.com/composer/ 2>/dev/null || true
                    sudo -u www $PHP_CMD "$new_composer_path" config -g use-parent-dir true 2>/dev/null || true
                else
                    # 普通用户直接执行
                    $PHP_CMD "$new_composer_path" config -g repo.packagist composer https://mirrors.aliyun.com/composer/ 2>/dev/null || true
                    $PHP_CMD "$new_composer_path" config -g use-parent-dir true 2>/dev/null || true
                fi
                log_success "已配置阿里云Composer镜像"
            fi
            return 0
        else
            return 1
        fi
    fi
    
    return 0
}

# 设置默认PHP版本
set_default_php() {
    log_info "设置默认PHP版本..."
    
    # 创建/更新软链接
    if [ -e "/usr/bin/php" ]; then
        sudo rm -f /usr/bin/php
    fi
    
    sudo ln -sf "/www/server/php/$PHP_VERSION/bin/php" /usr/bin/php
    
    # 验证
    local current_version=$(/usr/bin/php -v 2>/dev/null | head -1)
    log_success "默认PHP已设置: $current_version"
    
    return 0
}

# 卸载系统PHP
remove_system_php() {
    log_info "检查系统PHP包..."
    
    local system_php_paths=(
        "/usr/bin/php8.4"
        "/usr/bin/php8.3"
        "/usr/bin/php8.2"
        "/usr/bin/php8.1"
        "/usr/bin/php8.0"
        "/usr/bin/php7.4"
    )
    
    local found_system_php=false
    for php_path in "${system_php_paths[@]}"; do
        if [ -x "$php_path" ] && [[ "$(readlink -f "$php_path")" != *"/www/server/php"* ]]; then
            found_system_php=true
            log_warning "发现系统PHP: $php_path"
        fi
    done
    
    if [ "$found_system_php" = false ]; then
        log_success "未发现系统PHP包"
        return 0
    fi
    
    echo
    log_warning "发现系统PHP包，可能会与宝塔PHP冲突"
    read -p "是否卸载系统PHP包？(y/n): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # 根据系统类型卸载
        if command -v apt-get >/dev/null 2>&1; then
            # Ubuntu/Debian
            log_info "卸载系统PHP包..."
            sudo apt-get remove -y php* --purge 2>/dev/null || true
            sudo apt-get autoremove -y 2>/dev/null || true
        elif command -v yum >/dev/null 2>&1; then
            # CentOS/RHEL
            log_info "卸载系统PHP包..."
            sudo yum remove -y php* 2>/dev/null || true
        fi
        
        log_success "系统PHP包已卸载"
    fi
    
    return 0
}

# 主函数
main() {
    # 检查是否为宝塔环境
    if ! check_bt_panel; then
        log_error "未检测到宝塔环境"
        log_info "此脚本专用于宝塔面板环境"
        log_info "如果您使用的是普通Linux环境，请使用: ./install-deps.sh"
        exit 1
    fi
    
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
        if diagnose_php_extension_issues; then
            log_success "诊断完成"
        else
            log_error "诊断失败"
        fi
        exit 0
    fi
    
    log_info "============================================"
    log_info "证书管理系统宝塔环境依赖检查"
    log_info "============================================"
    echo
    
    # 检测PHP版本
    if ! detect_bt_php; then
        exit 1
    fi
    
    # 检查并卸载系统PHP
    remove_system_php
    
    # 设置默认PHP版本
    set_default_php
    
    # 检查PHP扩展
    check_php_extensions
    
    # 检查PHP函数
    check_php_functions
    
    # 检查Composer
    check_composer
    
    echo
    log_success "============================================"
    log_success "宝塔环境依赖检查完成"
    log_success "============================================"
    echo
    log_info "如果还有问题，可以运行诊断模式："
    log_info "  sudo $0 --diagnose"
    echo
}

# 执行主函数
main "$@"