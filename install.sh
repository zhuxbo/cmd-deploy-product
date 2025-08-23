#!/bin/bash

# 证书管理系统生产环境安装脚本
# 功能：从 production-code 仓库安装系统

# 注意：使用了 set -e，任何返回非零的命令都会导致脚本退出
# 当前脚本中的函数都正常返回 0，pull_production_code 中的 exit 1 会终止脚本
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

# 获取脚本所在目录（deploy目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 获取站点根目录（site目录）
SITE_ROOT="$(dirname "$SCRIPT_DIR")"
# 源码目录
SOURCE_DIR="$SCRIPT_DIR/source"
# 备份目录
BACKUP_DIR="$SITE_ROOT/backup/install"

# 生产代码仓库（使用HTTPS地址，避免SSH密钥问题）
PRODUCTION_REPO_GITEE="https://gitee.com/zhuxbo/production-code.git"
PRODUCTION_REPO_GITHUB="https://github.com/zhuxbo/production-code.git"

# 解析命令行参数
FORCE_REPO=""
for arg in "$@"; do
    case $arg in
        gitee)
            FORCE_REPO="gitee"
            log_info "强制使用 Gitee 仓库"
            ;;
        github)
            FORCE_REPO="github"
            log_info "强制使用 GitHub 仓库"
            ;;
    esac
done

# 检测宝塔面板
check_bt_panel() {
    if [ -f "/www/server/panel/BT-Panel" ] || \
       [ -f "/www/server/panel/class/panelPlugin.py" ] || \
       [ -d "/www/server/panel" ] && [ -f "/www/server/panel/data/port.pl" ]; then
        return 0  # 是宝塔环境
    fi
    return 1  # 非宝塔环境
}

# 创建必要的目录
create_directories() {
    mkdir -p "$SOURCE_DIR" "$BACKUP_DIR" "$SITE_ROOT/backup/keeper" 2>/dev/null
}

# 拉取生产代码
pull_production_code() {
    log_info "获取生产代码..."
    
    cd "$SOURCE_DIR"
    
    if [ -d "production-code" ]; then
        cd production-code
        
        # 如果指定了强制仓库，先切换到指定仓库
        if [ -n "$FORCE_REPO" ]; then
            if [ "$FORCE_REPO" = "gitee" ]; then
                log_info "切换到 Gitee 仓库..."
                git remote set-url origin "$PRODUCTION_REPO_GITEE"
            elif [ "$FORCE_REPO" = "github" ]; then
                log_info "切换到 GitHub 仓库..."
                git remote set-url origin "$PRODUCTION_REPO_GITHUB"
            fi
        fi
        
        # 尝试从当前 origin 拉取
        if ! git fetch origin >/dev/null 2>&1; then
            if [ -n "$FORCE_REPO" ]; then
                # 如果指定了强制仓库但失败，直接报错
                log_error "无法从指定的 $FORCE_REPO 仓库拉取代码"
                exit 1
            fi
            
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
            if ! git fetch origin >/dev/null 2>&1; then
                log_error "无法从任何仓库拉取代码"
                exit 1
            fi
        fi
        git reset --hard origin/main >/dev/null 2>&1
    else
        # 首次克隆
        local clone_success=false
        
        if [ -n "$FORCE_REPO" ]; then
            # 如果指定了强制仓库，只尝试指定的仓库
            if [ "$FORCE_REPO" = "gitee" ]; then
                log_info "从 Gitee 克隆..."
                if git clone "$PRODUCTION_REPO_GITEE" production-code >/dev/null 2>&1; then
                    clone_success=true
                    log_success "从 Gitee 克隆成功"
                else
                    log_error "无法从 Gitee 克隆代码"
                    exit 1
                fi
            elif [ "$FORCE_REPO" = "github" ]; then
                log_info "从 GitHub 克隆..."
                if git clone "$PRODUCTION_REPO_GITHUB" production-code >/dev/null 2>&1; then
                    clone_success=true
                    log_success "从 GitHub 克隆成功"
                else
                    log_error "无法从 GitHub 克隆代码"
                    exit 1
                fi
            fi
        else
            # 未指定强制仓库，按原逻辑尝试
            # 优先尝试 Gitee（国内通常更快）
            log_info "尝试从 Gitee 克隆..."
            if git clone "$PRODUCTION_REPO_GITEE" production-code >/dev/null 2>&1; then
                clone_success=true
                log_success "从 Gitee 克隆成功"
            else
                log_warning "Gitee 克隆失败，尝试 GitHub..."
                if git clone "$PRODUCTION_REPO_GITHUB" production-code >/dev/null 2>&1; then
                    clone_success=true
                    log_success "从 GitHub 克隆成功"
                fi
            fi
            
            if [ "$clone_success" = false ]; then
                log_error "无法从任何仓库克隆代码"
                exit 1
            fi
        fi
        
        cd production-code
    fi
    
    # 读取版本信息（兼容无 jq 环境）
    if [ -f "config.json" ]; then
        if command -v jq >/dev/null 2>&1; then
            VERSION=$(jq -r '.version' config.json 2>/dev/null || true)
        else
            VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"\n]*\)".*/\1/p' config.json | head -n1)
        fi
        [ -z "$VERSION" ] && VERSION="unknown"
        log_success "版本: $VERSION"
    fi
    
    cd "$SCRIPT_DIR"
}

# 备份现有文件
backup_existing() {
    BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="$BACKUP_DIR/install_$BACKUP_TIMESTAMP"
    
    # 检查是否需要备份
    NEED_BACKUP=false
    for dir in backend frontend nginx; do
        if [ -d "$SITE_ROOT/$dir" ]; then
            NEED_BACKUP=true
            break
        fi
    done
    
    if [ "$NEED_BACKUP" = true ]; then
        log_info "备份现有文件..."
        mkdir -p "$BACKUP_PATH"
        
        # 备份现有目录
        for dir in backend frontend nginx; do
            if [ -d "$SITE_ROOT/$dir" ]; then
                cp -r "$SITE_ROOT/$dir" "$BACKUP_PATH/" 2>/dev/null
            fi
        done
        
        # 创建备份信息文件
        cat > "$BACKUP_PATH/backup_info.txt" <<EOF
备份时间: $(date)
备份原因: 全新安装
版本信息: $VERSION

恢复方法:
1. 停止Web服务: sudo systemctl stop nginx
2. 删除当前部署: rm -rf $SITE_ROOT/{backend,frontend,nginx}
3. 恢复备份文件: cp -r $BACKUP_PATH/* $SITE_ROOT/
4. 启动Web服务: sudo systemctl start nginx
EOF
        
        log_success "备份完成: $BACKUP_PATH"
        
        # 删除旧文件
        rm -rf "$SITE_ROOT/backend" "$SITE_ROOT/frontend" "$SITE_ROOT/nginx"
    fi
}

# 部署文件
deploy_files() {
    log_info "部署系统文件..."
    
    # 从源码目录复制文件
    SOURCE_PATH="$SOURCE_DIR/production-code"
    
    # 复制主要目录到站点根目录
    for dir in backend frontend nginx; do
        if [ -d "$SOURCE_PATH/$dir" ]; then
            cp -r "$SOURCE_PATH/$dir" "$SITE_ROOT/" 2>/dev/null
        fi
    done
    
    # 复制构建信息文件
    if [ -f "$SOURCE_PATH/config.json" ]; then
        cp "$SOURCE_PATH/config.json" "$SITE_ROOT/"
    fi
    
    log_success "部署完成"
}

# 更新nginx配置路径
update_nginx_config() {
    NGINX_CONF="$SITE_ROOT/nginx/manager.conf"
    
    if [ -f "$NGINX_CONF" ]; then
        # 替换项目根目录路径
        sed -i "s|__PROJECT_ROOT__|$SITE_ROOT|g" "$NGINX_CONF"
        log_success "Nginx 配置路径已更新"
    fi
}

# 初始化Laravel
initialize_laravel() {
    cd "$SITE_ROOT/backend"
    
    # 创建必要的存储目录
    mkdir -p storage/{app/public,framework/{cache,sessions,views},logs} 2>/dev/null
    mkdir -p bootstrap/cache 2>/dev/null
    
    cd "$SCRIPT_DIR"
}

# 设置文件权限
set_permissions() {
    log_info "设置文件权限..."

    # 获取站点目录的所有者信息
    SITE_OWNER=$(stat -c "%U" "$SITE_ROOT")
    SITE_GROUP=$(stat -c "%G" "$SITE_ROOT")

    # 设置后端权限
    if [ -d "$SITE_ROOT/backend" ]; then
        # 整体保持与站点目录一致的所有者
        sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend" 2>/dev/null || log_warning "backend目录所有者设置失败"

        # 设置基础目录权限为755
        sudo chmod 755 "$SITE_ROOT/backend" 2>/dev/null || log_warning "backend目录权限设置失败"

        # 代码文件设置为644（只读）
        find "$SITE_ROOT/backend" -type f \( \
            -name "*.php" -o -name "*.js" -o -name "*.css" -o -name "*.xml" -o \
            -name "*.yml" -o -name "*.yaml" -o -name "*.md" -o -name "*.txt" -o \
            -name ".env*" -o -name "*.json" \
        \) -not -path "$SITE_ROOT/backend/storage/*" -not -path "$SITE_ROOT/backend/bootstrap/cache/*" \
        -print0 | xargs -0 -r -n 100 sudo chmod 644 || log_warning "backend代码文件权限设置失败"

        # Laravel 特殊文件处理
        [ -f "$SITE_ROOT/backend/artisan" ] && sudo chmod 755 "$SITE_ROOT/backend/artisan" 2>/dev/null || log_warning "artisan文件权限设置失败"

        # Laravel 需要写入权限的目录
        if [ -d "$SITE_ROOT/backend/storage" ]; then
            sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend/storage" 2>/dev/null || log_warning "storage目录所有者设置失败"
            sudo chmod -R 775 "$SITE_ROOT/backend/storage" 2>/dev/null || log_warning "storage目录权限设置失败"
            find "$SITE_ROOT/backend/storage" -type f -exec sudo chmod 664 {} + 2>/dev/null || log_warning "storage文件权限设置失败"
        fi

        if [ -d "$SITE_ROOT/backend/bootstrap/cache" ]; then
            sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend/bootstrap/cache" 2>/dev/null || log_warning "bootstrap/cache目录所有者设置失败"
            sudo chmod -R 775 "$SITE_ROOT/backend/bootstrap/cache" 2>/dev/null || log_warning "bootstrap/cache目录权限设置失败"
        fi

        # 其他目录设置为755
        find "$SITE_ROOT/backend" -type d -not -path "$SITE_ROOT/backend/storage*" -not -path "$SITE_ROOT/backend/bootstrap/cache*" -exec sudo chmod 755 {} + 2>/dev/null || log_warning "backend其他目录权限设置失败"
    fi

    # 设置前端权限
    if [ -d "$SITE_ROOT/frontend" ]; then
        sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/frontend" 2>/dev/null || log_warning "frontend目录所有者设置失败"
        find "$SITE_ROOT/frontend" -type d -exec sudo chmod 755 {} + 2>/dev/null || log_warning "frontend目录权限设置失败"
        find "$SITE_ROOT/frontend" -type f -print0 | xargs -0 -r -n 100 sudo chmod 644 || log_warning "frontend文件权限设置失败"
    fi

    # 设置nginx目录权限
    if [ -d "$SITE_ROOT/nginx" ]; then
        sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/nginx" 2>/dev/null || log_warning "nginx目录所有者设置失败"
        sudo chmod -R 755 "$SITE_ROOT/nginx" 2>/dev/null || log_warning "nginx目录权限设置失败"
        find "$SITE_ROOT/nginx" -type f -print0 | xargs -0 -r -n 100 sudo chmod 644 || log_warning "nginx文件权限设置失败"
    fi

    log_success "权限设置完成"
}

# 记录定时任务配置（不自动配置）
setup_cron() {
    # 仅记录配置信息，稍后统一提示
    SITE_NAME=$(basename "$SITE_ROOT")
    CRON_CMD="* * * * * cd $SITE_ROOT/backend && php artisan schedule:run >> /dev/null 2>&1"
}

# 记录队列守护进程配置（不自动配置）
setup_queue() {
    # 仅记录配置信息，稍后统一提示
    SITE_NAME=$(basename "$SITE_ROOT")
}

# 主函数
main() {
    log_info "证书管理系统生产环境安装"
    log_info "站点目录: $SITE_ROOT"
    
    # 创建目录
    create_directories
    
    # 拉取生产代码
    echo
    pull_production_code
    
    # 备份现有文件
    echo
    backup_existing
    
    # 部署文件
    echo
    deploy_files
    
    # 更新nginx配置 静默
    update_nginx_config
    
    # 初始化Laravel 静默
    initialize_laravel
    
    # 设置权限
    echo
    set_permissions
    
    # 配置定时任务
    setup_cron
    
    # 配置队列守护进程
    setup_queue

    echo
    log_success "安装完成！版本: $VERSION"

    # 显示后续步骤
    echo
    log_warning "=== 重要配置步骤 ==="
    log_warning "1. Nginx 配置【必须手动配置】："
    if check_bt_panel; then
        log_warning "   宝塔面板："
        log_warning "   - 进入网站设置 -> 配置文件"
        log_warning "   - 在 root 下一行添加："
    else
        log_warning "   - 编辑您的站点配置文件"
        log_warning "   - 在 server 块内 root 指令下一行添加："
    fi
    echo
    echo "    include $SITE_ROOT/nginx/manager.conf;"
    echo
    log_warning "   - 保存并重载 Nginx 配置"
    log_warning ""
    log_warning "2. 访问安装向导: http://your-domain/install"
    log_warning "   （安装向导将自动处理数据库配置、迁移和初始化等）"
    
    # 询问是否执行依赖安装
    echo
    echo -n "是否需要检查并安装运行环境依赖？(y/n): "
    # 优先从控制终端读取（兼容 sudo 调用），如果失败则从标准输入读取
    { read -n 1 -r confirm < /dev/tty 2>/dev/null || read -n 1 -r confirm; } || confirm="n"
    echo
    if [[ $confirm =~ ^[Yy]$ ]]; then
        # 智能选择依赖安装脚本
        if check_bt_panel; then
            # 宝塔环境，使用宝塔专用脚本
            DEPS_SCRIPT="$SCRIPT_DIR/install-deps-bt.sh"
            log_info "检测到宝塔环境，使用宝塔专用依赖脚本"
        else
            # 普通环境，使用标准脚本
            DEPS_SCRIPT="$SCRIPT_DIR/install-deps.sh"
            log_info "标准Linux环境，使用通用依赖脚本"
        fi
        
        if [ -f "$DEPS_SCRIPT" ]; then
            echo
            log_info "执行依赖安装脚本..."
            bash "$DEPS_SCRIPT" || log_warning "依赖安装脚本执行完成，可能需要手动处理部分配置"
        else
            log_warning "依赖安装脚本不存在: $DEPS_SCRIPT"
            log_info "请手动安装以下依赖："
            log_info "- PHP 8.3+ 及相关扩展"
            log_info "- Nginx 1.8+ Web 服务器"
            log_info "- MySQL 5.7+ 数据库"
            log_info "- Redis 6.0+ 缓存服务"
            log_info "- Supervisor 任务管理器"
        fi
    else
        log_info "跳过依赖安装，请确保已安装必需的运行环境"
    fi
    
    # 定时任务和队列配置提示
    echo
    log_warning "=== 请手动配置以下服务 ==="
    log_warning ""
    log_warning "3. 定时任务配置："
    if check_bt_panel; then
        log_warning "   宝塔面板："
        log_warning "   - 任务类型: Shell脚本"
        log_warning "   - 执行周期: 1分钟"
        log_warning "   - 执行用户: www"
        log_warning "   - 脚本内容: php $SITE_ROOT/backend/artisan schedule:run"
    else
        log_warning "   使用 crontab -e 添加："
        log_warning "   $CRON_CMD"
    fi
    log_warning ""
    log_warning "4. 队列守护进程（可选）："
    if check_bt_panel; then
        log_warning "   宝塔面板 Supervisor："
        log_warning "   - 启动用户: www"
        log_warning "   - 启动命令: php artisan queue:work --queue Task"
        log_warning "   - 进程目录: $SITE_ROOT/backend"
    else
        log_warning "   Supervisor 配置："
        log_warning "   - 程序名: laravel-worker-$SITE_NAME"
        log_warning "   - 命令: php artisan queue:work --queue Task"
        log_warning "   - 目录: $SITE_ROOT/backend"
        log_warning "   - 用户: $(stat -c "%U" "$SITE_ROOT")"
    fi
    log_warning "================================="
    
    # 安装流程完成提示
    echo
    log_success "===== 安装流程已完成 ====="
}

# 执行主函数
main "$@"
