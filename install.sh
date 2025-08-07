#!/bin/bash

# 证书管理系统生产环境安装脚本
# 功能：从 production-code 仓库安装系统

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
PRODUCTION_REPO="https://gitee.com/zhuxbo/production-code.git"

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
        git fetch origin >/dev/null 2>&1
        git reset --hard origin/main >/dev/null 2>&1
    else
        git clone "$PRODUCTION_REPO" production-code >/dev/null 2>&1
        cd production-code
    fi
    
    # 读取版本信息
    if [ -f "info.json" ]; then
        VERSION=$(jq -r '.version' info.json 2>/dev/null || echo "unknown")
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
    if [ -f "$SOURCE_PATH/info.json" ]; then
        cp "$SOURCE_PATH/info.json" "$SITE_ROOT/"
    fi
    
    log_success "部署完成"
}

# 更新nginx配置
update_nginx_config() {
    NGINX_CONF="$SITE_ROOT/nginx/manager.conf"
    
    if [ -f "$NGINX_CONF" ]; then
        # 替换项目根目录路径
        sed -i "s|__PROJECT_ROOT__|$SITE_ROOT|g" "$NGINX_CONF"
        
        if ! check_bt_panel; then
            # 非宝塔环境自动配置
            if [ -d "/etc/nginx/sites-enabled" ]; then
                sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/cert-manager.conf
            elif [ -d "/etc/nginx/conf.d" ]; then
                sudo ln -sf "$NGINX_CONF" /etc/nginx/conf.d/cert-manager.conf
            fi
            
            # 测试并重载配置
            if sudo nginx -t >/dev/null 2>&1; then
                sudo systemctl reload nginx >/dev/null 2>&1
            fi
        fi
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
        sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend" 2>/dev/null
        
        # 设置基础目录权限为755
        sudo chmod 755 "$SITE_ROOT/backend" 2>/dev/null
        
        # 代码文件设置为644（只读）
        find "$SITE_ROOT/backend" -type f \( \
            -name "*.php" -o -name "*.js" -o -name "*.css" -o -name "*.xml" -o \
            -name "*.yml" -o -name "*.yaml" -o -name "*.md" -o -name "*.txt" -o \
            -name ".env*" -o -name "*.json" \
        \) -not -path "$SITE_ROOT/backend/storage/*" -not -path "$SITE_ROOT/backend/bootstrap/cache/*" \
        -exec sudo chmod 644 {} + 2>/dev/null
        
        # Laravel 特殊文件处理
        if [ -f "$SITE_ROOT/backend/artisan" ]; then
            sudo chmod 755 "$SITE_ROOT/backend/artisan" 2>/dev/null
        fi
        
        # Laravel 需要写入权限的目录
        if [ -d "$SITE_ROOT/backend/storage" ]; then
            sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend/storage" 2>/dev/null
            sudo chmod -R 775 "$SITE_ROOT/backend/storage" 2>/dev/null
            find "$SITE_ROOT/backend/storage" -type f -exec sudo chmod 664 {} + 2>/dev/null
        fi
        
        if [ -d "$SITE_ROOT/backend/bootstrap/cache" ]; then
            sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend/bootstrap/cache" 2>/dev/null
            sudo chmod -R 775 "$SITE_ROOT/backend/bootstrap/cache" 2>/dev/null
        fi
        
        # 其他目录设置为755
        find "$SITE_ROOT/backend" -type d -not -path "$SITE_ROOT/backend/storage*" -not -path "$SITE_ROOT/backend/bootstrap/cache*" -exec sudo chmod 755 {} + 2>/dev/null
    fi
    
    # 设置前端权限
    if [ -d "$SITE_ROOT/frontend" ]; then
        sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/frontend" 2>/dev/null
        find "$SITE_ROOT/frontend" -type d -exec sudo chmod 755 {} + 2>/dev/null
        find "$SITE_ROOT/frontend" -type f -exec sudo chmod 644 {} + 2>/dev/null
    fi
    
    # 设置nginx目录权限
    if [ -d "$SITE_ROOT/nginx" ]; then
        sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/nginx" 2>/dev/null
        sudo chmod -R 755 "$SITE_ROOT/nginx" 2>/dev/null
        find "$SITE_ROOT/nginx" -type f -exec sudo chmod 644 {} + 2>/dev/null
    fi
    
    log_success "权限设置完成"
}

# 配置定时任务
setup_cron() {
    SITE_NAME=$(basename "$SITE_ROOT")
    
    if ! check_bt_panel; then
        # 非宝塔环境自动配置
        CRON_CMD="# Laravel-$SITE_NAME
* * * * * cd $SITE_ROOT/backend && php artisan schedule:run >> /dev/null 2>&1"
        
        if ! crontab -l 2>/dev/null | grep -q "Laravel-$SITE_NAME"; then
            (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
            log_success "定时任务已配置"
        fi
    fi
}

# 配置队列守护进程
setup_queue() {
    SITE_NAME=$(basename "$SITE_ROOT")
    
    if ! check_bt_panel; then
        # 非宝塔环境自动配置
        if command -v supervisorctl &> /dev/null; then
            SUPERVISOR_CONF="/etc/supervisor/conf.d/laravel-worker-$SITE_NAME.conf"
            
            sudo tee "$SUPERVISOR_CONF" > /dev/null <<EOF
[program:laravel-worker-$SITE_NAME]
process_name=%(program_name)s_%(process_num)02d
command=php artisan queue:work --queue Task
directory=$SITE_ROOT/backend
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=$SITE_OWNER
numprocs=1
redirect_stderr=true
stdout_logfile=$SITE_ROOT/backend/storage/logs/worker.log
stopwaitsecs=3600
EOF
            
            sudo supervisorctl reread >/dev/null 2>&1
            sudo supervisorctl update >/dev/null 2>&1
            sudo supervisorctl start laravel-worker-$SITE_NAME:* >/dev/null 2>&1
            
            log_success "队列守护进程已配置"
        fi
    fi
}

# 主函数
main() {
    echo
    log_info "证书管理系统生产环境安装"
    log_info "站点目录: $SITE_ROOT"
    
    # 创建目录
    echo
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
    echo
    setup_cron
    
    # 配置队列守护进程
    echo
    setup_queue
    
    log_success "安装完成！版本: $VERSION"
    
    # 显示后续步骤
    echo
    log_warning "后续步骤："
    log_warning "1. Nginx 配置【重要】："
    log_warning "   - 进入网站设置 -> 配置文件"
    log_warning "   - 注释掉或删除现有的 root 配置行"
    log_warning "   - 在 下一行 添加：include $SITE_ROOT/nginx/manager.conf;"
    log_warning "   - 保存并重载配置"
    log_warning "2. 访问安装向导: http://your-domain/api/install.php"
    log_warning "（安装向导将自动处理数据库配置、迁移和初始化等其他安装步骤）"
    
    # 询问是否执行依赖安装
    echo
    log_info "运行环境检查："
    read -p "是否需要检查并安装运行环境依赖？(y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        DEPS_SCRIPT="$SCRIPT_DIR/install-deps.sh"
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
    
    # 宝塔面板特殊提示（放在最后）
    if check_bt_panel; then
        echo
        log_warning "=== 请在宝塔面板中手动完成以下配置 ==="
        echo
        log_warning "1. 定时任务："
        log_warning "   任务类型 Shell脚本"
        log_warning "   执行周期 1分钟"
        log_warning "   执行用户 www"
        log_warning "   脚本内容 cd $SITE_ROOT/backend && php artisan schedule:run"
        echo
        log_warning "2. 队列守护进程："
        log_warning "   启动用户 www"
        log_warning "   启动命令 php artisan queue:work --queue Task"
        log_warning "   进程目录 $SITE_ROOT/backend"
        log_warning "================================="
    fi
    
    # 安装流程完成提示
    echo
    log_success "===== 安装流程已完成 ====="
}

# 执行主函数
main "$@"
