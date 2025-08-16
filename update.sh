#!/bin/bash

# 证书管理系统更新脚本
# 功能：从 production-code 仓库更新系统

# 注意：使用了 set -e，任何返回非零的命令都会导致脚本退出
# 如果函数使用非零返回值表示状态，需要在 if 语句中调用或使用 || true
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

# 检测服务器是否在中国大陆（快速版）
is_china_server() {
    # 如果环境变量已设置，直接使用
    if [ -n "$FORCE_CHINA_MIRROR" ]; then
        [ "$FORCE_CHINA_MIRROR" = "1" ] && return 0 || return 1
    fi
    
    # 方法1: 快速检查云服务商元数据（1秒超时）
    # 阿里云 - 只有 cn- 开头的是中国区域
    local aliyun_region=$(timeout 1 curl -s "http://100.100.100.200/latest/meta-data/region-id" 2>/dev/null || echo "")
    if [ -n "$aliyun_region" ] && [[ "$aliyun_region" =~ ^cn- ]]; then
        return 0
    fi
    
    # 腾讯云 - 明确指定中国大陆区域
    local tencent_region=$(timeout 1 curl -s "http://metadata.tencentyun.com/latest/meta-data/region" 2>/dev/null || echo "")
    if [ -n "$tencent_region" ]; then
        # 腾讯云中国大陆区域：ap-beijing, ap-shanghai, ap-guangzhou, ap-chengdu, ap-chongqing, ap-nanjing
        if [[ "$tencent_region" =~ ^(ap-beijing|ap-shanghai|ap-guangzhou|ap-chengdu|ap-chongqing|ap-nanjing) ]]; then
            return 0
        fi
        # 如果能获取到区域但不是中国大陆，说明是海外腾讯云，直接返回非中国
        return 1
    fi
    
    # 华为云 - 只有 cn- 开头的是中国区域
    local huawei_region=$(timeout 1 curl -s "http://169.254.169.254/latest/meta-data/region-id" 2>/dev/null || echo "")
    if [ -n "$huawei_region" ] && [[ "$huawei_region" =~ ^cn- ]]; then
        return 0
    fi
    
    # 方法2: 检测能否快速连接到中国镜像（使用 timeout 命令限制时间）
    # 只测试一个镜像站，超时1秒
    if timeout 1 bash -c "echo -n '' > /dev/tcp/mirrors.aliyun.com/443" 2>/dev/null; then
        # 能快速连接，可能在中国
        return 0
    fi
    
    # 默认不使用中国镜像
    return 1
}

# 获取脚本所在目录（deploy目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 获取站点根目录（site目录）
SITE_ROOT="$(dirname "$SCRIPT_DIR")"
# 源码目录
SOURCE_DIR="$SCRIPT_DIR/source"
# 备份目录
BACKUP_DIR="$SITE_ROOT/backup/update"
# 配置文件
CONFIG_FILE="$SCRIPT_DIR/update-config.json"

# 生产代码仓库（使用HTTPS地址，避免SSH密钥问题）
PRODUCTION_REPO_GITEE="https://gitee.com/zhuxbo/production-code.git"
PRODUCTION_REPO_GITHUB="https://github.com/zhuxbo/production-code.git"

# 临时保留目录
TEMP_PRESERVE_DIR=""

# 清理函数
cleanup() {
    if [ -n "$TEMP_PRESERVE_DIR" ] && [ -d "$TEMP_PRESERVE_DIR" ]; then
        rm -rf "$TEMP_PRESERVE_DIR"
    fi
}

# 设置退出陷阱
trap cleanup EXIT INT TERM

# 显示使用帮助
show_usage() {
    echo "证书管理系统更新工具"
    echo ""
    echo "用法:"
    echo "  $0 [操作] [选项]"
    echo ""
    echo "操作:"
    echo "  update [模块]    更新系统（默认）"
    echo "  list             列出所有备份"
    echo "  restore <备份>   恢复指定备份"
    echo "  help             显示此帮助"
    echo ""
    echo "更新模块:"
    echo "  all              更新所有模块（默认）"
    echo "  api              仅更新后端"
    echo "  admin            仅更新管理端"
    echo "  user             仅更新用户端"
    echo "  easy             仅更新简易端"
    echo "  nginx            仅更新Nginx配置"
    echo ""
    echo "示例:"
    echo "  $0                               # 更新所有模块"
    echo "  $0 update api                    # 仅更新后端"
    echo "  $0 list                          # 列出备份"
    echo "  $0 restore update_20250809_1234  # 恢复备份"
    echo ""
    echo "兼容旧版调用:"
    echo "  $0 api                           # 等同于 $0 update api"
}

# 操作模式和模块
ACTION="${1:-update}"
UPDATE_MODULE="${2:-all}"

# 如果第一个参数是模块名，则兼容旧版本调用方式
VALID_MODULES=("api" "admin" "user" "easy" "nginx" "all")
if [[ " ${VALID_MODULES[@]} " =~ " ${ACTION} " ]]; then
    # 旧版本调用方式：./update.sh [module]
    UPDATE_MODULE="$ACTION"
    ACTION="update"
fi

# 验证操作模式
VALID_ACTIONS=("update" "list" "restore" "help")
if [[ ! " ${VALID_ACTIONS[@]} " =~ " ${ACTION} " ]]; then
    log_error "无效的操作: $ACTION"
    log_info "有效的操作: ${VALID_ACTIONS[*]}"
    show_usage
    exit 1
fi

# 验证更新模块（仅在更新模式下）
if [ "$ACTION" = "update" ]; then
    if [[ ! " ${VALID_MODULES[@]} " =~ " ${UPDATE_MODULE} " ]]; then
        log_error "无效的更新模块: $UPDATE_MODULE"
        log_info "有效的模块: ${VALID_MODULES[*]}"
        show_usage
        exit 1
    fi
fi

# 检查必要的命令
check_dependencies() {
    # 检查 jq 命令
    if ! command -v jq >/dev/null 2>&1; then
        log_warning "jq 命令未安装，正在自动安装..."
        
        # 尝试自动安装 jq
        local install_success=false
        
        # Ubuntu/Debian 系统
        if command -v apt-get >/dev/null 2>&1; then
            # 只有在中国大陆服务器上才配置中国镜像源
            if is_china_server; then
                if [ -f /etc/apt/sources.list ] && ! grep -q "mirrors.aliyun.com\|mirrors.tuna" /etc/apt/sources.list; then
                    log_info "检测到中国大陆服务器，配置 APT 中国镜像源..."
                    sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
                    # Ubuntu 镜像源配置
                    sudo sed -i 's|http://[a-z][a-z].archive.ubuntu.com|http://mirrors.aliyun.com|g' /etc/apt/sources.list
                    sudo sed -i 's|http://archive.ubuntu.com|http://mirrors.aliyun.com|g' /etc/apt/sources.list
                    sudo sed -i 's|http://security.ubuntu.com|http://mirrors.aliyun.com|g' /etc/apt/sources.list
                    # Debian 镜像源配置（更完整的处理）
                    sudo sed -i 's|http://deb.debian.org/debian|http://mirrors.aliyun.com/debian|g' /etc/apt/sources.list
                    sudo sed -i 's|http://security.debian.org/debian-security|http://mirrors.aliyun.com/debian-security|g' /etc/apt/sources.list
                    sudo sed -i 's|http://security.debian.org|http://mirrors.aliyun.com/debian-security|g' /etc/apt/sources.list
                    # 处理 HTTPS 源
                    sudo sed -i 's|https://deb.debian.org/debian|http://mirrors.aliyun.com/debian|g' /etc/apt/sources.list
                    sudo sed -i 's|https://security.debian.org/debian-security|http://mirrors.aliyun.com/debian-security|g' /etc/apt/sources.list
                fi
            fi
            log_info "检测到 Ubuntu/Debian 系统，使用 apt 安装 jq..."
            # 先尝试更新包列表，如果失败则显示错误信息
            if ! sudo apt-get update 2>/dev/null; then
                log_warning "apt-get update 失败，尝试使用现有包列表安装 jq..."
            fi
            # 尝试安装 jq，显示更详细的错误信息
            if sudo apt-get install -y jq 2>/dev/null; then
                install_success=true
            else
                log_warning "使用 apt-get 安装 jq 失败，可能的原因："
                log_warning "  1. 网络连接问题"
                log_warning "  2. 软件源配置问题"
                log_warning "  3. 权限问题"
                # 尝试使用 apt 而不是 apt-get
                if command -v apt >/dev/null 2>&1; then
                    log_info "尝试使用 apt 命令安装..."
                    if sudo apt install -y jq 2>/dev/null; then
                        install_success=true
                    fi
                fi
            fi
        # CentOS/RHEL/Fedora 系统
        elif command -v yum >/dev/null 2>&1; then
            # 只有在中国大陆服务器上才配置中国镜像源
            if is_china_server; then
                if [ -f /etc/yum.repos.d/CentOS-Base.repo ] && ! grep -q "mirrors.aliyun.com\|mirrors.tuna" /etc/yum.repos.d/CentOS-Base.repo; then
                    log_info "检测到中国大陆服务器，配置 YUM 中国镜像源..."
                    sudo cp /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.bak
                    sudo sed -i 's|mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/CentOS-Base.repo
                    sudo sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' /etc/yum.repos.d/CentOS-Base.repo
                fi
            fi
            log_info "检测到 CentOS/RHEL 系统，使用 yum 安装 jq..."
            if sudo yum install -y jq >/dev/null 2>&1; then
                install_success=true
            fi
        elif command -v dnf >/dev/null 2>&1; then
            # 只有在中国大陆服务器上才配置中国镜像源
            if is_china_server; then
                if [ -f /etc/yum.repos.d/fedora.repo ] && ! grep -q "mirrors.aliyun.com\|mirrors.tuna" /etc/yum.repos.d/fedora.repo; then
                    log_info "检测到中国大陆服务器，配置 DNF 中国镜像源..."
                    sudo cp /etc/yum.repos.d/fedora.repo /etc/yum.repos.d/fedora.repo.bak
                    sudo sed -i 's|metalink=|#metalink=|g' /etc/yum.repos.d/fedora.repo
                    sudo sed -i 's|#baseurl=http://download.example/pub/fedora/linux|baseurl=https://mirrors.aliyun.com/fedora|g' /etc/yum.repos.d/fedora.repo
                fi
            fi
            log_info "检测到 Fedora 系统，使用 dnf 安装 jq..."
            if sudo dnf install -y jq >/dev/null 2>&1; then
                install_success=true
            fi
        # Arch Linux
        elif command -v pacman >/dev/null 2>&1; then
            # 只有在中国大陆服务器上才配置中国镜像源
            if is_china_server; then
                if [ -f /etc/pacman.d/mirrorlist ] && ! grep -q "mirrors.aliyun.com\|mirrors.tuna" /etc/pacman.d/mirrorlist; then
                    log_info "检测到中国大陆服务器，配置 Pacman 中国镜像源..."
                    sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
                    echo 'Server = https://mirrors.aliyun.com/archlinux/$repo/os/$arch' | sudo tee /etc/pacman.d/mirrorlist.china
                    echo 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch' | sudo tee -a /etc/pacman.d/mirrorlist.china
                    sudo cat /etc/pacman.d/mirrorlist >> /etc/pacman.d/mirrorlist.china
                    sudo mv /etc/pacman.d/mirrorlist.china /etc/pacman.d/mirrorlist
                fi
            fi
            log_info "检测到 Arch Linux 系统，使用 pacman 安装 jq..."
            if sudo pacman -Sy --noconfirm jq >/dev/null 2>&1; then
                install_success=true
            fi
        # openSUSE
        elif command -v zypper >/dev/null 2>&1; then
            log_info "检测到 openSUSE 系统，使用 zypper 安装 jq..."
            if sudo zypper install -y jq >/dev/null 2>&1; then
                install_success=true
            fi
        else
            log_warning "未能识别系统包管理器"
        fi
        
        # 验证安装结果
        if command -v jq >/dev/null 2>&1; then
            install_success=true
            log_success "jq 已成功安装"
        fi
        
        # 如果自动安装失败，提供手动安装指引
        if [ "$install_success" = false ]; then
            log_error "自动安装 jq 失败，请手动安装："
            log_info "  Ubuntu/Debian: sudo apt-get install jq"
            log_info "  CentOS/RHEL: sudo yum install jq"
            log_info "  Fedora: sudo dnf install jq"
            log_info "  Arch: sudo pacman -Sy jq"
            log_info "  openSUSE: sudo zypper install jq"
            log_info "  其他系统: 请参考 https://stedolan.github.io/jq/download/"
            exit 1
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

# 加载配置
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        log_info "请确保 update-config.json 文件存在"
        exit 1
    fi
    
    # 验证配置文件格式
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        log_error "配置文件格式错误，请检查 JSON 格式"
        exit 1
    fi
    
    log_success "配置文件加载成功"
}

# 拉取最新代码
pull_latest_code() {
    log_info "拉取最新生产代码..."
    
    mkdir -p "$SOURCE_DIR" "$BACKUP_DIR"
    cd "$SOURCE_DIR"
    
    if [ -d "production-code" ]; then
        cd production-code
        
        # 尝试从当前 origin 拉取
        if ! git fetch origin 2>/dev/null; then
            log_warning "从当前仓库拉取失败，尝试切换仓库..."
            # 获取当前 origin URL
            local current_url=$(git remote get-url origin 2>/dev/null || echo "")
            
            # 尝试切换到备用仓库
            if [[ "$current_url" == *"gitee.com"* ]]; then
                log_info "切换到 GitHub 仓库..."
                git remote set-url origin "$PRODUCTION_REPO_GITHUB"
            else
                log_info "切换到 Gitee 仓库..."
                git remote set-url origin "$PRODUCTION_REPO_GITEE"
            fi
            
            # 再次尝试拉取
            if ! git fetch origin 2>/dev/null; then
                log_error "无法从任何仓库拉取代码"
                exit 1
            fi
            log_success "从备用仓库拉取成功"
        fi
        
        # 检查是否有更新
        LOCAL_COMMIT=$(git rev-parse HEAD)
        REMOTE_COMMIT=$(git rev-parse origin/main)
        
        if [ "$LOCAL_COMMIT" = "$REMOTE_COMMIT" ]; then
            log_info "已是最新版本"
            
            # 检查是否强制更新
            if [ "${FORCE_UPDATE:-0}" != "1" ]; then
                read -p "没有新版本，是否继续更新？(y/n): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    log_info "更新已取消"
                    exit 0
                fi
            fi
        fi
        
        git reset --hard origin/main
    else
        # 首次克隆，尝试多个仓库
        local clone_success=false
        
        # 优先尝试 Gitee（国内通常更快）
        log_info "尝试从 Gitee 克隆..."
        if git clone "$PRODUCTION_REPO_GITEE" production-code 2>/dev/null; then
            clone_success=true
            log_success "从 Gitee 克隆成功"
        else
            log_warning "Gitee 克隆失败，尝试 GitHub..."
            if git clone "$PRODUCTION_REPO_GITHUB" production-code 2>/dev/null; then
                clone_success=true
                log_success "从 GitHub 克隆成功"
            fi
        fi
        
        if [ "$clone_success" = false ]; then
            log_error "无法从任何仓库克隆代码"
            exit 1
        fi
        
        cd production-code
    fi
    
    # 读取版本信息
    NEW_VERSION=$(jq -r '.version' config.json 2>/dev/null || echo "unknown")
    log_success "新版本: $NEW_VERSION"
    
    cd "$SCRIPT_DIR"
}

# 备份当前版本
backup_current() {
    log_info "备份当前版本..."
    
    BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="$BACKUP_DIR/update_$BACKUP_TIMESTAMP"
    mkdir -p "$BACKUP_PATH"
    
    # 记录当前版本
    if [ -f "$SITE_ROOT/config.json" ]; then
        CURRENT_VERSION=$(jq -r '.version' "$SITE_ROOT/config.json" 2>/dev/null || echo "unknown")
        echo "原版本: $CURRENT_VERSION" > "$BACKUP_PATH/backup_info.txt"
    fi
    
    echo "备份时间: $(date)" >> "$BACKUP_PATH/backup_info.txt"
    echo "更新模块: $UPDATE_MODULE" >> "$BACKUP_PATH/backup_info.txt"
    echo "新版本: $NEW_VERSION" >> "$BACKUP_PATH/backup_info.txt"
    
    # 根据更新模块备份
    case "$UPDATE_MODULE" in
        all)
            for dir in backend frontend nginx; do
                if [ -d "$SITE_ROOT/$dir" ]; then
                    cp -r "$SITE_ROOT/$dir" "$BACKUP_PATH/"
                fi
            done
            ;;
        api)
            if [ -d "$SITE_ROOT/backend" ]; then
                cp -r "$SITE_ROOT/backend" "$BACKUP_PATH/"
            fi
            ;;
        nginx)
            if [ -d "$SITE_ROOT/nginx" ]; then
                cp -r "$SITE_ROOT/nginx" "$BACKUP_PATH/"
            fi
            ;;
        admin|user|easy)
            if [ -d "$SITE_ROOT/frontend/$UPDATE_MODULE" ]; then
                mkdir -p "$BACKUP_PATH/frontend"
                cp -r "$SITE_ROOT/frontend/$UPDATE_MODULE" "$BACKUP_PATH/frontend/"
            fi
            ;;
    esac
    
    log_success "备份完成: $BACKUP_PATH"
}

# 保存需要保留的文件
save_preserve_files() {
    log_info "保存需要保留的文件..."
    
    TEMP_PRESERVE_DIR="/tmp/cert_manager_preserve_$$"
    mkdir -p "$TEMP_PRESERVE_DIR"
    
    local saved_count=0
    local failed_count=0
    
    # 保存后端文件
    if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
        if [ -d "$SITE_ROOT/backend" ]; then
            log_info "检查后端需要保护的文件..."
            # 读取需要保留的后端文件
            BACKEND_FILES=$(jq -r '.preserve_files.backend[]' "$CONFIG_FILE" 2>/dev/null)
            if [ -n "$BACKEND_FILES" ]; then
                while IFS= read -r file; do
                    if [ -e "$SITE_ROOT/backend/$file" ]; then
                        # 创建目标目录
                        TARGET_DIR="$TEMP_PRESERVE_DIR/backend/$(dirname "$file")"
                        mkdir -p "$TARGET_DIR"
                        # 使用cp -a保持权限和属性
                        if cp -a "$SITE_ROOT/backend/$file" "$TARGET_DIR/"; then
                            log_success "  ✓ 保存: backend/$file"
                            saved_count=$((saved_count + 1))
                        else
                            log_error "  ✗ 保存失败: backend/$file"
                            failed_count=$((failed_count + 1))
                        fi
                    else
                        log_warning "  ! 不存在: backend/$file"
                    fi
                done <<< "$BACKEND_FILES"
            fi
        fi
    fi
    
    # 保存前端配置文件
    for component in admin user easy; do
        if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "$component" ]; then
            if [ -d "$SITE_ROOT/frontend/$component" ]; then
                log_info "检查 $component 前端需要保护的文件..."
                PRESERVE_FILES=$(jq -r ".preserve_files.frontend.$component[]" "$CONFIG_FILE" 2>/dev/null)
                if [ -n "$PRESERVE_FILES" ]; then
                    mkdir -p "$TEMP_PRESERVE_DIR/frontend/$component"
                    while IFS= read -r file; do
                        if [ -e "$SITE_ROOT/frontend/$component/$file" ]; then
                            if cp -a "$SITE_ROOT/frontend/$component/$file" "$TEMP_PRESERVE_DIR/frontend/$component/"; then
                                log_success "  ✓ 保存: frontend/$component/$file"
                                saved_count=$((saved_count + 1))
                            else
                                log_error "  ✗ 保存失败: frontend/$component/$file"
                                failed_count=$((failed_count + 1))
                            fi
                        else
                            log_warning "  ! 不存在: frontend/$component/$file"
                        fi
                    done <<< "$PRESERVE_FILES"
                fi
            fi
        fi
    done
    
    if [ $failed_count -eq 0 ]; then
        log_success "文件保存完成（共保存 $saved_count 个文件/目录）"
    else
        log_warning "文件保存完成（成功: $saved_count, 失败: $failed_count）"
    fi
}

# 恢复保留的文件
restore_preserve_files() {
    log_info "恢复保留的文件..."
    
    if [ ! -d "$TEMP_PRESERVE_DIR" ]; then
        log_warning "没有需要恢复的文件"
        return
    fi
    
    local restored_count=0
    local failed_count=0
    
    # 恢复后端文件
    if [ -d "$TEMP_PRESERVE_DIR/backend" ]; then
        log_info "恢复后端保护文件..."
        # 使用rsync或cp -a保持目录结构和权限
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "$TEMP_PRESERVE_DIR/backend/" "$SITE_ROOT/backend/"
        else
            cp -a "$TEMP_PRESERVE_DIR/backend/." "$SITE_ROOT/backend/" 2>/dev/null || true
        fi
        
        # 验证关键文件恢复情况
        BACKEND_FILES=$(jq -r '.preserve_files.backend[]' "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$BACKEND_FILES" ]; then
            while IFS= read -r file; do
                if [ -e "$SITE_ROOT/backend/$file" ]; then
                    log_success "  ✓ 已恢复: backend/$file"
                    restored_count=$((restored_count + 1))
                else
                    log_error "  ✗ 恢复失败: backend/$file"
                    failed_count=$((failed_count + 1))
                fi
            done <<< "$BACKEND_FILES"
        fi
    fi
    
    # 恢复前端文件
    if [ -d "$TEMP_PRESERVE_DIR/frontend" ]; then
        for component in admin user easy; do
            if [ -d "$TEMP_PRESERVE_DIR/frontend/$component" ]; then
                log_info "恢复 $component 前端保护文件..."
                if command -v rsync >/dev/null 2>&1; then
                    rsync -a "$TEMP_PRESERVE_DIR/frontend/$component/" "$SITE_ROOT/frontend/$component/"
                else
                    cp -a "$TEMP_PRESERVE_DIR/frontend/$component/." "$SITE_ROOT/frontend/$component/" 2>/dev/null || true
                fi
                
                # 验证文件恢复情况
                PRESERVE_FILES=$(jq -r ".preserve_files.frontend.$component[]" "$CONFIG_FILE" 2>/dev/null)
                if [ -n "$PRESERVE_FILES" ]; then
                    while IFS= read -r file; do
                        if [ -e "$SITE_ROOT/frontend/$component/$file" ]; then
                            log_success "  ✓ 已恢复: frontend/$component/$file"
                            restored_count=$((restored_count + 1))
                        else
                            log_error "  ✗ 恢复失败: frontend/$component/$file"
                            failed_count=$((failed_count + 1))
                        fi
                    done <<< "$PRESERVE_FILES"
                fi
            fi
        done
    fi
    
    # 显示恢复结果统计
    if [ $failed_count -eq 0 ]; then
        log_success "文件恢复完成（共恢复 $restored_count 个文件/目录）"
    else
        log_error "文件恢复有错误（成功: $restored_count, 失败: $failed_count）"
        log_error "请检查上述失败的文件，可能需要手动恢复"
    fi
    
    log_info "临时文件将在脚本结束时自动清理"
}

# 部署新文件
deploy_new_files() {
    log_info "部署新文件..."
    
    SOURCE_PATH="$SOURCE_DIR/production-code"
    
    case "$UPDATE_MODULE" in
        all)
            # 删除并更新所有模块
            for dir in backend frontend nginx; do
                if [ -d "$SOURCE_PATH/$dir" ]; then
                    log_info "更新 $dir..."
                    rm -rf "$SITE_ROOT/$dir"
                    # 使用cp -a保持文件属性
                    cp -a "$SOURCE_PATH/$dir" "$SITE_ROOT/"
                fi
            done
            
            # 复制构建信息文件
            if [ -f "$SOURCE_PATH/config.json" ]; then
                cp "$SOURCE_PATH/config.json" "$SITE_ROOT/"
            fi
            ;;
            
        api)
            # 仅更新后端
            if [ -d "$SOURCE_PATH/backend" ]; then
                log_info "更新后端..."
                rm -rf "$SITE_ROOT/backend"
                cp -a "$SOURCE_PATH/backend" "$SITE_ROOT/"
            fi
            ;;
            
        nginx)
            # 仅更新 Nginx 配置
            if [ -d "$SOURCE_PATH/nginx" ]; then
                log_info "更新 Nginx 配置..."
                rm -rf "$SITE_ROOT/nginx"
                cp -a "$SOURCE_PATH/nginx" "$SITE_ROOT/"
            fi
            ;;
            
        admin|user|easy)
            # 更新特定前端
            if [ -d "$SOURCE_PATH/frontend/$UPDATE_MODULE" ]; then
                log_info "更新 $UPDATE_MODULE 前端..."
                rm -rf "$SITE_ROOT/frontend/$UPDATE_MODULE"
                mkdir -p "$SITE_ROOT/frontend"
                cp -a "$SOURCE_PATH/frontend/$UPDATE_MODULE" "$SITE_ROOT/frontend/"
            fi
            ;;
    esac
    
    log_success "文件部署完成"
}

# 执行后端优化
optimize_backend() {
    if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
        log_info "执行后端优化..."
        
        cd "$SITE_ROOT/backend"
        
        # 检查PHP命令
        PHP_CMD="php"
        if check_bt_panel; then
            # 检查可用的宝塔PHP版本（83, 84, 85等）
            for ver in 85 84 83; do
                if [ -x "/www/server/php/$ver/bin/php" ]; then
                    PHP_CMD="/www/server/php/$ver/bin/php"
                    break
                fi
            done
        fi
        
        # 优化 Composer 自动加载（使用正确的站点所有者执行）
        if command -v composer &> /dev/null; then
            log_info "优化 Composer 自动加载..."
            
            # 根据地理位置配置镜像源
            if is_china_server; then
                log_info "配置 Composer 中国镜像源..."
                # 设置环境变量避免交互式提示
                export COMPOSER_NO_INTERACTION=1
                export COMPOSER_PROCESS_TIMEOUT=30
                # 使用 timeout 限制执行时间
                timeout 10s composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/ 2>/dev/null || {
                    log_warning "Composer 镜像源配置超时，跳过"
                }
            else
                log_info "使用 Composer 官方源..."
                # 确保使用官方源
                export COMPOSER_NO_INTERACTION=1
                timeout 10s composer config -g --unset repos.packagist 2>/dev/null || true
            fi
            
            # 获取正确的站点所有者
            if check_bt_panel; then
                COMPOSER_USER="www"
            else
                COMPOSER_USER=$(stat -c "%U" "$SITE_ROOT")
            fi
            
            # 确保backend目录权限正确后再执行composer
            if [ "$EUID" -eq 0 ]; then
                # 以root运行时，使用sudo切换到正确用户
                # 使用 timeout 避免卡住，设置环境变量
                if timeout 30s sudo -u "$COMPOSER_USER" env COMPOSER_NO_INTERACTION=1 COMPOSER_PROCESS_TIMEOUT=30 composer dump-autoload --optimize --no-dev 2>/dev/null; then
                    log_success "自动加载优化完成（包发现已自动执行）"
                else
                    log_warning "自动加载优化失败，但不影响应用运行"
                    log_info "Laravel 将使用基础自动加载器，性能可能稍有影响"
                    echo
                    log_info "如需手动尝试优化，请执行以下命令："
                    log_info "cd $SITE_ROOT/backend"
                    log_info "sudo -u $COMPOSER_USER composer dump-autoload --optimize --no-dev"
                    echo
                fi
            else
                # 非root用户直接执行
                # 使用 timeout 避免卡住
                if timeout 30s env COMPOSER_NO_INTERACTION=1 COMPOSER_PROCESS_TIMEOUT=30 composer dump-autoload --optimize --no-dev 2>/dev/null; then
                    log_success "自动加载优化完成（包发现已自动执行）"
                else
                    log_warning "自动加载优化失败，但不影响应用运行"
                    log_info "Laravel 将使用基础自动加载器"
                fi
            fi
        else
            log_warning "Composer 未安装，跳过自动加载优化"
            log_info "Laravel 将使用基础自动加载器"
        fi
        
        # 清理并优化 Laravel 缓存
        log_info "清理并优化 Laravel 缓存..."
        $PHP_CMD artisan cache:clear
        $PHP_CMD artisan config:clear
        $PHP_CMD artisan route:clear
        $PHP_CMD artisan optimize
        
        # 删除安装文件和目录（如果存在）
        if [ -f "public/install.php" ]; then
            rm -f "public/install.php"
            log_info "已删除 install.php"
        fi
        
        if [ -d "public/install-assets" ]; then
            rm -rf "public/install-assets"
            log_info "已删除 install-assets 目录"
        fi
        
        cd "$SCRIPT_DIR"
        
        log_success "后端优化完成"
    fi
}

# 更新 Nginx 配置路径
update_nginx_config() {
    if ([ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "nginx" ]) && [ -f "$SITE_ROOT/nginx/manager.conf" ]; then
        log_info "更新 Nginx 配置路径..."
        sed -i "s|__PROJECT_ROOT__|$SITE_ROOT|g" "$SITE_ROOT/nginx/manager.conf"
        log_success "Nginx 配置路径已更新"
    fi
}

# 设置文件权限
set_permissions() {
    log_info "设置文件权限..."
    
    # 检测宝塔环境，确定正确的Web用户
    if check_bt_panel; then
        # 宝塔环境固定使用www用户
        SITE_OWNER="www"
        SITE_GROUP="www"
        log_info "检测到宝塔环境，使用 www:www 作为文件所有者"
    else
        # 非宝塔环境，使用站点目录的当前所有者
        SITE_OWNER=$(stat -c "%U" "$SITE_ROOT")
        SITE_GROUP=$(stat -c "%G" "$SITE_ROOT")
        log_info "使用站点目录所有者: $SITE_OWNER:$SITE_GROUP"
    fi
    
    # 设置后端权限
    if [ -d "$SITE_ROOT/backend" ] && ([ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]); then
        log_info "设置后端目录权限..."
        
        # 整体设置所有者（显示错误信息）
        if ! sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend"; then
            log_error "设置后端目录所有者失败"
            log_info "尝试分步设置权限..."
            # 先设置目录
            find "$SITE_ROOT/backend" -type d -exec sudo chown "$SITE_OWNER:$SITE_GROUP" {} \;
            # 再设置文件
            find "$SITE_ROOT/backend" -type f -exec sudo chown "$SITE_OWNER:$SITE_GROUP" {} \;
        else
            log_success "后端目录所有者设置成功: $SITE_OWNER:$SITE_GROUP"
        fi
        
        # 设置基础目录权限为755
        sudo chmod 755 "$SITE_ROOT/backend" 2>/dev/null
        
        # 代码文件设置为644（只读）- 简化版本
        find "$SITE_ROOT/backend" -type f \( \
            -name "*.php" -o -name "*.js" -o -name "*.css" -o -name "*.xml" -o \
            -name "*.yml" -o -name "*.yaml" -o -name "*.md" -o -name "*.txt" -o \
            -name ".env*" -o -name "*.json" \
        \) -not -path "$SITE_ROOT/backend/storage/*" -not -path "$SITE_ROOT/backend/bootstrap/cache/*" \
        -exec sudo chmod 644 {} + 2>/dev/null
        
        # Laravel 特殊文件处理
        [ -f "$SITE_ROOT/backend/artisan" ] && sudo chmod 755 "$SITE_ROOT/backend/artisan" 2>/dev/null
        
        # Laravel 需要写入权限的目录
        if [ -d "$SITE_ROOT/backend/storage" ]; then
            sudo chmod -R 775 "$SITE_ROOT/backend/storage" 2>/dev/null
            find "$SITE_ROOT/backend/storage" -type f -exec sudo chmod 664 {} + 2>/dev/null
        fi
        
        [ -d "$SITE_ROOT/backend/bootstrap/cache" ] && sudo chmod -R 775 "$SITE_ROOT/backend/bootstrap/cache" 2>/dev/null
        
        # 其他目录设置为755
        find "$SITE_ROOT/backend" -type d -not -path "$SITE_ROOT/backend/storage*" -not -path "$SITE_ROOT/backend/bootstrap/cache*" -exec sudo chmod 755 {} + 2>/dev/null
        
        log_info "后端权限设置完成"
    fi
    
    # 设置前端权限（简化版）
    if [ -d "$SITE_ROOT/frontend" ] && [ "$UPDATE_MODULE" != "api" ] && [ "$UPDATE_MODULE" != "nginx" ]; then
        if [ "$UPDATE_MODULE" = "all" ]; then
            # 批量处理所有前端
            log_info "设置前端权限..."
            if ! sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/frontend"; then
                log_error "设置前端目录所有者失败"
            else
                log_success "前端目录所有者设置成功: $SITE_OWNER:$SITE_GROUP"
            fi
            find "$SITE_ROOT/frontend" -type d -exec sudo chmod 755 {} + 2>/dev/null
            find "$SITE_ROOT/frontend" -type f -exec sudo chmod 644 {} + 2>/dev/null
        else
            # 单个前端组件
            if [ -d "$SITE_ROOT/frontend/$UPDATE_MODULE" ]; then
                log_info "设置 $UPDATE_MODULE 前端权限..."
                if ! sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/frontend/$UPDATE_MODULE"; then
                    log_error "设置 $UPDATE_MODULE 前端目录所有者失败"
                else
                    log_success "$UPDATE_MODULE 前端目录所有者设置成功: $SITE_OWNER:$SITE_GROUP"
                fi
                find "$SITE_ROOT/frontend/$UPDATE_MODULE" -type d -exec sudo chmod 755 {} + 2>/dev/null
                find "$SITE_ROOT/frontend/$UPDATE_MODULE" -type f -exec sudo chmod 644 {} + 2>/dev/null
            fi
        fi
    fi
    
    # 设置nginx目录权限
    if ([ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "nginx" ]) && [ -d "$SITE_ROOT/nginx" ]; then
        log_info "设置nginx目录权限..."
        if ! sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/nginx"; then
            log_error "设置nginx目录所有者失败"
        else
            log_success "nginx目录所有者设置成功: $SITE_OWNER:$SITE_GROUP"
        fi
        sudo chmod -R 755 "$SITE_ROOT/nginx" 2>/dev/null
        find "$SITE_ROOT/nginx" -type f -exec sudo chmod 644 {} + 2>/dev/null
    fi
    
    # 验证权限设置结果
    log_info "验证权限设置结果..."
    VERIFY_FAILED=0
    
    if [ -d "$SITE_ROOT/backend" ] && ([ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]); then
        ACTUAL_OWNER=$(stat -c "%U" "$SITE_ROOT/backend")
        ACTUAL_GROUP=$(stat -c "%G" "$SITE_ROOT/backend")
        if [ "$ACTUAL_OWNER" = "$SITE_OWNER" ] && [ "$ACTUAL_GROUP" = "$SITE_GROUP" ]; then
            log_success "✓ 后端目录权限验证通过: $ACTUAL_OWNER:$ACTUAL_GROUP"
        else
            log_error "✗ 后端目录权限验证失败: 实际 $ACTUAL_OWNER:$ACTUAL_GROUP, 期望 $SITE_OWNER:$SITE_GROUP"
            VERIFY_FAILED=1
        fi
        
        # 检查重要文件的权限
        if [ -f "$SITE_ROOT/backend/.env" ]; then
            ENV_OWNER=$(stat -c "%U" "$SITE_ROOT/backend/.env")
            if [ "$ENV_OWNER" = "$SITE_OWNER" ]; then
                log_success "✓ .env文件权限正确: $ENV_OWNER"
            else
                log_error "✗ .env文件权限错误: $ENV_OWNER (期望 $SITE_OWNER)"
                VERIFY_FAILED=1
            fi
        fi
    fi
    
    if [ $VERIFY_FAILED -eq 0 ]; then
        log_success "权限设置完成并验证通过（所有者: $SITE_OWNER:$SITE_GROUP）"
    else
        log_warning "权限设置完成但验证有错误（目标所有者: $SITE_OWNER:$SITE_GROUP）"
        log_warning "请手动检查文件权限或使用以下命令修复："
        log_warning "sudo chown -R $SITE_OWNER:$SITE_GROUP $SITE_ROOT"
    fi
}

# 重载服务
reload_services() {
    log_info "重载服务..."
    
    if check_bt_panel; then
        log_warning "宝塔环境，请在面板中重载服务"
        log_warning "- 重载 Nginx"
        log_warning "- 重启 PHP-FPM"
        log_warning "- 重启队列守护进程"
    else
        # 重载 Nginx（只在更新后端API或Nginx配置时）
        if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ] || [ "$UPDATE_MODULE" = "nginx" ]; then
            NGINX_RELOAD=$(jq -r '.services.nginx.reload_command' "$CONFIG_FILE")
            if eval "$NGINX_RELOAD" 2>/dev/null; then
                log_success "Nginx 已重载"
            else
                log_warning "Nginx 重载失败"
            fi
        fi
        
        # 重启 PHP-FPM（仅在更新后端时）
        if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
            PHP_RESTART=$(jq -r '.services."php-fpm".restart_command' "$CONFIG_FILE")
            if eval "$PHP_RESTART" 2>/dev/null; then
                log_success "PHP-FPM 已重启"
            else
                log_warning "PHP-FPM 重启失败"
            fi
        fi
        
        # 重启队列（仅在更新后端时）
        if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
            if command -v supervisorctl &> /dev/null; then
                SITE_NAME=$(basename "$SITE_ROOT")
                QUEUE_RESTART=$(jq -r '.services.queue.restart_command' "$CONFIG_FILE" | sed "s/{SITE_NAME}/$SITE_NAME/g")
                if eval "$QUEUE_RESTART" 2>/dev/null; then
                    log_success "队列已重启"
                else
                    log_warning "队列重启失败"
                fi
            fi
        fi
    fi
}

# 检查服务状态
check_services_status() {
    log_info "检查服务状态..."
    
    if check_bt_panel; then
        log_info "宝塔环境，请在面板中检查服务状态"
    else
        # 检查 Nginx
        NGINX_STATUS=$(jq -r '.services.nginx.status_command' "$CONFIG_FILE")
        if eval "$NGINX_STATUS" &>/dev/null; then
            log_success "Nginx: 运行中"
        else
            log_error "Nginx: 未运行"
        fi
        
        # 检查 PHP-FPM
        PHP_STATUS=$(jq -r '.services."php-fpm".status_command' "$CONFIG_FILE")
        if eval "$PHP_STATUS" &>/dev/null; then
            log_success "PHP-FPM: 运行中"
        else
            log_error "PHP-FPM: 未运行"
        fi
        
        # 检查队列
        if command -v supervisorctl &> /dev/null; then
            SITE_NAME=$(basename "$SITE_ROOT")
            QUEUE_STATUS=$(jq -r '.services.queue.status_command' "$CONFIG_FILE" | sed "s/{SITE_NAME}/$SITE_NAME/g")
            QUEUE_OUTPUT=$(eval "$QUEUE_STATUS" 2>/dev/null || echo "")
            if echo "$QUEUE_OUTPUT" | grep -q "RUNNING"; then
                log_success "队列进程: 运行中"
                echo "$QUEUE_OUTPUT"
            else
                log_warning "队列进程: 状态异常"
                echo "$QUEUE_OUTPUT"
            fi
        else
            log_info "队列: Supervisor 未安装"
        fi
    fi
}

# 列出备份
list_backups() {
    log_info "备份列表:"
    echo
    
    if [ ! -d "$BACKUP_DIR" ]; then
        log_warning "备份目录不存在"
        return
    fi
    
    # 查找备份目录
    BACKUP_DIRS=$(find "$BACKUP_DIR" -maxdepth 1 -name "update_*" -type d | sort -r)
    
    if [ -z "$BACKUP_DIRS" ]; then
        log_warning "没有找到备份"
        return
    fi
    
    echo "备份名称                    版本        模块      备份时间"
    echo "--------------------------------------------------------------------"
    
    while IFS= read -r dir; do
        if [ -d "$dir" ]; then
            BACKUP_NAME=$(basename "$dir")
            
            # 读取备份信息
            if [ -f "$dir/backup_info.txt" ]; then
                # 提取信息
                OLD_VERSION=$(grep "原版本:" "$dir/backup_info.txt" 2>/dev/null | cut -d':' -f2 | xargs || echo "unknown")
                MODULE=$(grep "更新模块:" "$dir/backup_info.txt" 2>/dev/null | cut -d':' -f2 | xargs || echo "unknown")
                BACKUP_TIME=$(grep "备份时间:" "$dir/backup_info.txt" 2>/dev/null | cut -d':' -f2- | xargs || echo "unknown")
                
                printf "%-28s %-11s %-9s %s\n" "$BACKUP_NAME" "$OLD_VERSION" "$MODULE" "$BACKUP_TIME"
            else
                # 从目录名提取时间戳
                TIMESTAMP=$(echo "$BACKUP_NAME" | sed 's/update_//')
                DATE_PART=$(echo "$TIMESTAMP" | cut -d'_' -f1)
                TIME_PART=$(echo "$TIMESTAMP" | cut -d'_' -f2)
                
                if [ ${#DATE_PART} -eq 8 ] && [ ${#TIME_PART} -eq 6 ]; then
                    FORMATTED_DATE="${DATE_PART:0:4}-${DATE_PART:4:2}-${DATE_PART:6:2}"
                    FORMATTED_TIME="${TIME_PART:0:2}:${TIME_PART:2:2}:${TIME_PART:4:2}"
                    printf "%-28s %-11s %-9s %s %s\n" "$BACKUP_NAME" "unknown" "unknown" "$FORMATTED_DATE" "$FORMATTED_TIME"
                else
                    printf "%-28s %-11s %-9s %s\n" "$BACKUP_NAME" "unknown" "unknown" "unknown"
                fi
            fi
        fi
    done <<< "$BACKUP_DIRS"
    echo
}

# 恢复备份
restore_backup() {
    local backup_name="$1"
    
    if [ -z "$backup_name" ]; then
        log_error "请指定要恢复的备份"
        log_info "用法: $0 restore <备份名称>"
        log_info "使用 '$0 list' 查看可用的备份"
        exit 1
    fi
    
    # 构建备份路径
    local backup_path="$BACKUP_DIR/$backup_name"
    
    if [ ! -d "$backup_path" ]; then
        log_error "备份不存在: $backup_name"
        log_info "使用 '$0 list' 查看可用的备份"
        exit 1
    fi
    
    log_warning "============================================"
    log_warning "警告：恢复备份将覆盖当前的系统文件！"
    log_warning "备份: $backup_name"
    
    # 显示备份信息
    if [ -f "$backup_path/backup_info.txt" ]; then
        echo
        log_info "备份信息:"
        cat "$backup_path/backup_info.txt"
        echo
    fi
    
    log_warning "============================================"
    
    read -p "确定要恢复此备份吗？(y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "恢复已取消"
        exit 0
    fi
    
    log_info "开始恢复备份..."
    
    # 创建当前状态的紧急备份
    EMERGENCY_BACKUP="$BACKUP_DIR/emergency_$(date +%Y%m%d_%H%M%S)"
    log_info "创建紧急备份: $(basename "$EMERGENCY_BACKUP")"
    mkdir -p "$EMERGENCY_BACKUP"
    
    # 备份当前文件
    for dir in backend frontend nginx; do
        if [ -d "$backup_path/$dir" ] && [ -d "$SITE_ROOT/$dir" ]; then
            cp -a "$SITE_ROOT/$dir" "$EMERGENCY_BACKUP/" 2>/dev/null
        fi
    done
    
    # 记录紧急备份信息
    cat > "$EMERGENCY_BACKUP/backup_info.txt" <<EOF
备份时间: $(date)
备份类型: 紧急备份（恢复前自动创建）
恢复来源: $backup_name
EOF
    
    # 恢复备份文件
    log_info "恢复系统文件..."
    local restore_success=true
    
    # 恢复各个目录
    for dir in backend frontend nginx; do
        if [ -d "$backup_path/$dir" ]; then
            log_info "恢复 $dir..."
            if [ -d "$SITE_ROOT/$dir" ]; then
                rm -rf "$SITE_ROOT/$dir"
            fi
            if cp -a "$backup_path/$dir" "$SITE_ROOT/"; then
                log_success "$dir 恢复成功"
            else
                log_error "$dir 恢复失败"
                restore_success=false
            fi
        fi
    done
    
    if [ "$restore_success" = false ]; then
        log_error "恢复过程中出现错误"
        log_info "可以从紧急备份恢复: $0 restore $(basename "$EMERGENCY_BACKUP")"
        exit 1
    fi
    
    # 恢复后设置权限
    log_info "设置文件权限..."
    set_permissions
    
    # 如果恢复了后端，执行必要的Laravel命令
    if [ -d "$backup_path/backend" ]; then
        log_info "执行Laravel恢复命令..."
        cd "$SITE_ROOT/backend"
        
        # 检查PHP命令
        PHP_CMD="php"
        if check_bt_panel; then
            for ver in 85 84 83; do
                if [ -x "/www/server/php/$ver/bin/php" ]; then
                    PHP_CMD="/www/server/php/$ver/bin/php"
                    break
                fi
            done
        fi
        
        # 清理缓存
        $PHP_CMD artisan cache:clear 2>/dev/null || true
        $PHP_CMD artisan config:clear 2>/dev/null || true
        $PHP_CMD artisan route:clear 2>/dev/null || true
        
        cd "$SCRIPT_DIR"
    fi
    
    # 重载服务
    log_info "重载服务..."
    reload_services
    
    log_success "============================================"
    log_success "恢复完成！"
    log_success "恢复备份: $backup_name"
    log_success "紧急备份: $(basename "$EMERGENCY_BACKUP")"
    log_success "============================================"
    echo
    log_info "如果系统出现问题，可以恢复紧急备份:"
    log_info "$0 restore $(basename "$EMERGENCY_BACKUP")"
}

# 主函数
main() {
    log_info "============================================"
    log_info "证书管理系统更新"
    log_info "更新模块: $UPDATE_MODULE"
    log_info "站点目录: $SITE_ROOT"
    log_info "============================================"
    
    # 检查依赖命令
    check_dependencies
    
    # 加载配置
    load_config
    
    # 拉取最新代码
    pull_latest_code
    
    # 备份当前版本
    backup_current
    
    # 保存需要保留的文件
    save_preserve_files
    
    # 部署新文件
    deploy_new_files
    
    # 恢复保留的文件
    restore_preserve_files
    
    # 更新 Nginx 配置路径
    update_nginx_config
    
    # 设置权限（必须在后端优化之前）
    set_permissions
    
    # 执行后端优化（在权限设置之后）
    optimize_backend
    
    # 重载服务
    reload_services
    
    # 检查服务状态
    check_services_status
    
    log_success "============================================"
    log_success "更新完成！"
    log_success "新版本: $NEW_VERSION"
    log_success "============================================"
    
    # 显示更新摘要
    echo
    log_info "更新摘要："
    log_info "- 更新模块: $UPDATE_MODULE"
    log_info "- 备份位置: $BACKUP_DIR"
    log_info "- 保留文件: 已按配置恢复"
    
    if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
        log_info "- Laravel 缓存: 已清理并优化"
    fi
}

# 根据操作模式执行
case "$ACTION" in
    update)
        # 执行更新流程
        main
        ;;
    list)
        # 列出备份
        list_backups
        ;;
    restore)
        # 恢复备份
        restore_backup "$UPDATE_MODULE"
        ;;
    help)
        # 显示帮助
        show_usage
        ;;
    *)
        log_error "未知操作: $ACTION"
        show_usage
        exit 1
        ;;
esac
