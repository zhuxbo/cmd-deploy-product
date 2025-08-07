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
    log_info "创建必要的目录..."
    mkdir -p "$SOURCE_DIR" "$BACKUP_DIR" "$SITE_ROOT/backup/keeper"
    log_success "目录创建完成"
}

# 拉取生产代码
pull_production_code() {
    log_info "拉取生产代码..."
    
    cd "$SOURCE_DIR"
    
    if [ -d "production-code" ]; then
        log_info "强制更新生产代码..."
        cd production-code
        git fetch origin
        git reset --hard origin/main
    else
        log_info "克隆生产代码仓库..."
        git clone "$PRODUCTION_REPO" production-code
        cd production-code
    fi
    
    # 读取版本信息
    if [ -f "info.json" ]; then
        VERSION=$(jq -r '.version' info.json 2>/dev/null || echo "unknown")
        log_success "生产代码版本: $VERSION"
    fi
    
    cd "$SCRIPT_DIR"
}

# 备份现有文件
backup_existing() {
    log_info "检查并备份现有文件..."
    
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
        log_info "创建备份: $BACKUP_PATH"
        mkdir -p "$BACKUP_PATH"
        
        # 备份现有目录
        for dir in backend frontend nginx; do
            if [ -d "$SITE_ROOT/$dir" ]; then
                log_info "备份 $dir 目录..."
                cp -r "$SITE_ROOT/$dir" "$BACKUP_PATH/"
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
        log_info "删除旧文件..."
        rm -rf "$SITE_ROOT/backend" "$SITE_ROOT/frontend" "$SITE_ROOT/nginx"
    else
        log_info "没有发现现有部署，跳过备份"
    fi
}

# 部署文件
deploy_files() {
    log_info "部署生产文件..."
    
    # 从源码目录复制文件
    SOURCE_PATH="$SOURCE_DIR/production-code"
    
    # 复制主要目录到站点根目录
    for dir in backend frontend nginx; do
        if [ -d "$SOURCE_PATH/$dir" ]; then
            log_info "部署 $dir..."
            cp -r "$SOURCE_PATH/$dir" "$SITE_ROOT/"
        fi
    done
    
    # 复制构建信息文件
    if [ -f "$SOURCE_PATH/info.json" ]; then
        cp "$SOURCE_PATH/info.json" "$SITE_ROOT/"
    fi
    
    log_success "文件部署完成"
}

# 更新nginx配置
update_nginx_config() {
    log_info "更新 Nginx 配置..."
    
    NGINX_CONF="$SITE_ROOT/nginx/manager.conf"
    
    if [ -f "$NGINX_CONF" ]; then
        # 替换项目根目录路径
        sed -i "s|__PROJECT_ROOT__|$SITE_ROOT|g" "$NGINX_CONF"
        log_success "Nginx 配置更新完成"
        
        if check_bt_panel; then
            log_info "宝塔环境检测到，请在安装完成后手动配置 Nginx"
        else
            log_info "自动配置 Nginx..."
            # 检查 sites-enabled 目录
            if [ -d "/etc/nginx/sites-enabled" ]; then
                sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/cert-manager.conf
                log_success "Nginx 配置已链接"
            elif [ -d "/etc/nginx/conf.d" ]; then
                sudo ln -sf "$NGINX_CONF" /etc/nginx/conf.d/cert-manager.conf
                log_success "Nginx 配置已链接"
            else
                log_warning "请手动将以下配置添加到 Nginx："
                log_warning "include $NGINX_CONF;"
            fi
            
            # 测试并重载配置
            if sudo nginx -t; then
                sudo systemctl reload nginx
                log_success "Nginx 配置已重载"
            else
                log_error "Nginx 配置测试失败，请检查配置"
            fi
        fi
    else
        log_warning "未找到 Nginx 配置文件"
    fi
}

# 初始化Laravel
initialize_laravel() {
    log_info "创建 Laravel 存储目录..."
    
    cd "$SITE_ROOT/backend"
    
    # 创建必要的存储目录
    mkdir -p storage/{app/public,framework/{cache,sessions,views},logs}
    mkdir -p bootstrap/cache
    
    log_success "存储目录创建完成"
    
    cd "$SCRIPT_DIR"
}

# 设置文件权限
set_permissions() {
    log_info "设置文件权限..."
    
    # 获取站点目录的所有者信息
    SITE_OWNER=$(stat -c "%U" "$SITE_ROOT")
    SITE_GROUP=$(stat -c "%G" "$SITE_ROOT")
    
    log_info "站点目录所有者: $SITE_OWNER:$SITE_GROUP"
    log_info "站点目录即为Web用户目录，storage和cache保持一致权限"
    
    # 设置后端权限
    if [ -d "$SITE_ROOT/backend" ]; then
        log_info "设置后端目录权限..."
        
        # 整体保持与站点目录一致的所有者
        sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend"
        
        # 设置基础目录权限为755
        sudo chmod 755 "$SITE_ROOT/backend"
        
        # 代码文件设置为644（只读）- 合并多个find命令提高性能
        find "$SITE_ROOT/backend" -type f \( \
            -name "*.php" -o -name "*.js" -o -name "*.css" -o -name "*.xml" -o \
            -name "*.yml" -o -name "*.yaml" -o -name "*.md" -o -name "*.txt" -o \
            -name ".env*" \
        \) -not -path "$SITE_ROOT/backend/storage/*" -not -path "$SITE_ROOT/backend/bootstrap/cache/*" \
        -exec sudo chmod 644 {} +
        
        # JSON文件特殊处理 - 某些可能需要写入权限
        find "$SITE_ROOT/backend" -type f -name "*.json" \
        -not -path "$SITE_ROOT/backend/storage/*" -not -path "$SITE_ROOT/backend/bootstrap/cache/*" \
        -exec sudo chmod 644 {} +
        
        # Laravel 特殊文件处理
        if [ -f "$SITE_ROOT/backend/artisan" ]; then
            sudo chmod 755 "$SITE_ROOT/backend/artisan"  # artisan需要执行权限
        fi
        
        # Laravel 需要写入权限的目录 - 保持与站点目录一致的用户
        if [ -d "$SITE_ROOT/backend/storage" ]; then
            sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend/storage"
            sudo chmod -R 775 "$SITE_ROOT/backend/storage"
            # storage内的文件设置为664
            find "$SITE_ROOT/backend/storage" -type f -exec sudo chmod 664 {} +
        fi
        
        if [ -d "$SITE_ROOT/backend/bootstrap/cache" ]; then
            sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/backend/bootstrap/cache"
            sudo chmod -R 775 "$SITE_ROOT/backend/bootstrap/cache"
        fi
        
        # 其他目录设置为755
        find "$SITE_ROOT/backend" -type d -not -path "$SITE_ROOT/backend/storage*" -not -path "$SITE_ROOT/backend/bootstrap/cache*" -exec sudo chmod 755 {} +
    fi
    
    # 设置前端权限
    if [ -d "$SITE_ROOT/frontend" ]; then
        log_info "设置前端目录权限..."
        
        # 前端保持与站点目录一致的所有者
        sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/frontend"
        
        # 目录权限755
        find "$SITE_ROOT/frontend" -type d -exec sudo chmod 755 {} +
        
        # 代码文件设置为644（只读）
        find "$SITE_ROOT/frontend" -type f \( \
            -name "*.html" -o -name "*.js" -o -name "*.css" -o -name "*.json" -o \
            -name "*.svg" -o -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o \
            -name "*.gif" -o -name "*.ico" -o -name "*.xml" -o -name "*.txt" -o -name "*.md" \
        \) -exec sudo chmod 644 {} +
    fi
    
    # 设置nginx目录权限
    if [ -d "$SITE_ROOT/nginx" ]; then
        log_info "设置nginx目录权限..."
        sudo chown -R "$SITE_OWNER:$SITE_GROUP" "$SITE_ROOT/nginx"
        sudo chmod -R 755 "$SITE_ROOT/nginx"
        find "$SITE_ROOT/nginx" -type f -exec sudo chmod 644 {} +
    fi
    
    log_success "权限设置完成"
    log_info "- 代码文件: 644 (只读)"
    log_info "- 目录: 755"  
    log_info "- Laravel写入目录: $SITE_OWNER:$SITE_GROUP 775"
    log_info "- 所有文件: $SITE_OWNER:$SITE_GROUP"
}

# 配置定时任务
setup_cron() {
    # 获取站点目录名用作标识
    SITE_NAME=$(basename "$SITE_ROOT")
    
    if check_bt_panel; then
        log_warning "=== 宝塔面板定时任务配置 ==="
        log_warning "请在宝塔面板中添加以下定时任务："
        log_warning ""
        log_warning "1. Laravel 调度器："
        log_warning "   名称: Laravel-$SITE_NAME"
        log_warning "   类型: Shell脚本"
        log_warning "   周期: 每分钟"
        log_warning "   脚本内容: cd $SITE_ROOT/backend && php artisan schedule:run >> /dev/null 2>&1"
        log_warning ""
        log_warning "2. 备份任务（可选）："
        log_warning "   名称: Backup-$SITE_NAME"
        log_warning "   类型: Shell脚本"
        log_warning "   周期: 每天凌晨2点"
        log_warning "   脚本内容: $SCRIPT_DIR/keeper.sh >> $SITE_ROOT/backup/keeper/keeper.log 2>&1"
        log_warning "========================="
    else
        log_info "配置系统定时任务（站点：$SITE_NAME）..."
        
        # Laravel 调度器 - 添加站点标识注释
        CRON_CMD="# Laravel-$SITE_NAME
* * * * * cd $SITE_ROOT/backend && php artisan schedule:run >> /dev/null 2>&1"
        
        # 检查是否已存在该站点的调度器
        if ! crontab -l 2>/dev/null | grep -q "Laravel-$SITE_NAME"; then
            (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
            log_success "Laravel 调度器定时任务已添加（$SITE_NAME）"
        else
            log_info "Laravel 调度器定时任务已存在（$SITE_NAME）"
        fi
        
        # 备份任务（可选）
        read -p "是否添加每日自动备份任务？(y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            BACKUP_CRON="# Backup-$SITE_NAME
0 2 * * * $SCRIPT_DIR/keeper.sh >> $SITE_ROOT/backup/keeper/keeper.log 2>&1"
            if ! crontab -l 2>/dev/null | grep -q "Backup-$SITE_NAME"; then
                (crontab -l 2>/dev/null; echo "$BACKUP_CRON") | crontab -
                log_success "备份定时任务已添加（$SITE_NAME，每天凌晨2点）"
            else
                log_info "备份定时任务已存在（$SITE_NAME）"
            fi
        fi
    fi
}

# 配置队列守护进程
setup_queue() {
    # 获取站点目录名用作标识
    SITE_NAME=$(basename "$SITE_ROOT")
    
    if check_bt_panel; then
        log_warning "=== 宝塔面板队列守护进程配置 ==="
        log_warning "请在宝塔面板中添加守护进程："
        log_warning ""
        log_warning "1. 进入【软件商店】->【Supervisor管理器】"
        log_warning "2. 添加守护进程："
        log_warning "   名称: laravel-worker-$SITE_NAME"
        log_warning "   启动用户: www"
        log_warning "   运行目录: $SITE_ROOT/backend"
        log_warning "   启动命令: php artisan queue:work --queue Task"
        log_warning "   进程数量: 1"
        log_warning "========================="
    else
        log_info "配置队列守护进程（站点：$SITE_NAME）..."
        
        if command -v supervisorctl &> /dev/null; then
            # 创建 supervisor 配置，使用站点名避免冲突
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
            
            # 重新加载 supervisor
            sudo supervisorctl reread
            sudo supervisorctl update
            sudo supervisorctl start laravel-worker-$SITE_NAME:*
            
            log_success "队列守护进程已配置（laravel-worker-$SITE_NAME）"
        else
            log_warning "Supervisor 未安装，请手动配置队列守护进程"
            log_info "安装命令: sudo apt-get install supervisor"
            log_info "配置名称: laravel-worker-$SITE_NAME"
        fi
    fi
}

# 主函数
main() {
    log_info "============================================"
    log_info "证书管理系统生产环境安装"
    log_info "站点目录: $SITE_ROOT"
    log_info "脚本目录: $SCRIPT_DIR"
    log_info "============================================"
    
    # 创建目录
    create_directories
    
    # 拉取生产代码
    pull_production_code
    
    # 备份现有文件
    backup_existing
    
    # 部署文件
    deploy_files
    
    # 更新nginx配置
    update_nginx_config
    
    # 初始化Laravel
    initialize_laravel
    
    # 设置权限
    set_permissions
    
    # 配置定时任务
    setup_cron
    
    # 配置队列守护进程
    setup_queue
    
    log_success "============================================"
    log_success "安装完成！"
    if [ -n "$VERSION" ]; then
        log_success "版本: $VERSION"
    fi
    log_success "============================================"
    
    # 显示后续步骤
    echo
    log_info "后续步骤："
    log_info "访问安装向导: http://your-domain/api/install.php"
    log_info "（安装向导将自动处理数据库配置、迁移和初始化等所有步骤）"
    
    # 询问是否执行依赖安装
    echo
    log_info "运行环境检查："
    read -p "是否需要检查并安装运行环境依赖？(y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        DEPS_SCRIPT="$SCRIPT_DIR/install-deps.sh"
        if [ -f "$DEPS_SCRIPT" ]; then
            log_info "执行依赖安装脚本..."
            bash "$DEPS_SCRIPT"
        else
            log_warning "依赖安装脚本不存在: $DEPS_SCRIPT"
            log_info "请手动安装以下依赖："
            log_info "- PHP 8.3+ 及相关扩展"
            log_info "- Nginx Web 服务器"
            log_info "- MySQL 8.0+ 数据库"
            log_info "- Redis 缓存服务"
            log_info "- Supervisor 队列管理器"
        fi
    else
        log_info "跳过依赖安装，请确保已安装必需的运行环境"
    fi
    
    # 宝塔面板特殊提示（放在最后）
    if check_bt_panel; then
        echo
        log_warning "=== 宝塔面板特殊配置提示 ==="
        log_warning "请在宝塔面板中手动完成以下配置："
        echo
        log_warning "1. Nginx 配置："
        log_warning "   - 进入网站设置 -> 配置文件"
        log_warning "   - 添加以下内容：include $SITE_ROOT/nginx/manager.conf;"
        log_warning "   - 保存并重载配置"
        echo
        log_warning "2. 定时任务："
        SITE_NAME=$(basename "$SITE_ROOT")
        log_warning "   - 名称: Laravel-$SITE_NAME"
        log_warning "   - 类型: Shell脚本"
        log_warning "   - 周期: 每分钟"
        log_warning "   - 内容: cd $SITE_ROOT/backend && php artisan schedule:run"
        echo
        log_warning "3. 队列守护进程："
        log_warning "   - 进入软件商店 -> Supervisor管理器"
        log_warning "   - 名称: laravel-worker-$SITE_NAME"
        log_warning "   - 目录: $SITE_ROOT/backend"
        log_warning "   - 命令: php artisan queue:work --queue Task"
        log_warning "   - 进程数: 1"
        log_warning "============================"
    fi
}

# 执行主函数
main "$@"