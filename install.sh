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

# 脚本根目录
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$SCRIPT_ROOT"
SOURCE_DIR="$DEPLOY_ROOT/source"
BACKUP_DIR="$DEPLOY_ROOT/backup"
PRODUCTION_REPO="git@gitee.com:zhuxbo/production-code.git"

# 创建必要的目录
create_directories() {
    log_info "创建必要的目录..."
    mkdir -p "$SOURCE_DIR" "$BACKUP_DIR"
    log_success "目录创建完成"
}

# 拉取生产代码
pull_production_code() {
    log_info "拉取生产代码..."
    
    cd "$SOURCE_DIR"
    
    if [ -d "production-code" ]; then
        log_info "更新现有生产代码..."
        cd production-code
        git pull origin main
    else
        log_info "克隆生产代码仓库..."
        git clone "$PRODUCTION_REPO" production-code
        cd production-code
    fi
    
    # 读取版本信息
    if [ -f "VERSION" ]; then
        VERSION=$(cat VERSION)
        log_success "生产代码版本: $VERSION"
    fi
    
    cd "$SCRIPT_ROOT"
}

# 备份现有文件
backup_existing() {
    log_info "检查并备份现有文件..."
    
    BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="$BACKUP_DIR/backup_$BACKUP_TIMESTAMP"
    
    # 检查是否需要备份
    NEED_BACKUP=false
    for dir in backend frontend nginx; do
        if [ -d "$DEPLOY_ROOT/$dir" ]; then
            NEED_BACKUP=true
            break
        fi
    done
    
    if [ "$NEED_BACKUP" = true ]; then
        log_info "创建备份: $BACKUP_PATH"
        mkdir -p "$BACKUP_PATH"
        
        # 备份现有目录
        for dir in backend frontend nginx; do
            if [ -d "$DEPLOY_ROOT/$dir" ]; then
                log_info "备份 $dir 目录..."
                mv "$DEPLOY_ROOT/$dir" "$BACKUP_PATH/"
            fi
        done
        
        # 创建备份信息文件
        cat > "$BACKUP_PATH/backup_info.txt" <<EOF
备份时间: $(date)
备份原因: 安装新版本
版本信息: $VERSION

恢复方法:
1. 停止Web服务: sudo systemctl stop nginx
2. 删除当前部署: rm -rf $DEPLOY_ROOT/{backend,frontend,nginx}
3. 恢复备份文件: cp -r $BACKUP_PATH/* $DEPLOY_ROOT/
4. 启动Web服务: sudo systemctl start nginx
EOF
        
        log_success "备份完成: $BACKUP_PATH"
    else
        log_info "没有发现现有部署，跳过备份"
    fi
}

# 部署文件
deploy_files() {
    log_info "部署生产文件..."
    
    # 从源码目录复制文件
    SOURCE_PATH="$SOURCE_DIR/production-code"
    
    # 复制主要目录
    for dir in backend frontend nginx; do
        if [ -d "$SOURCE_PATH/$dir" ]; then
            log_info "部署 $dir..."
            cp -r "$SOURCE_PATH/$dir" "$DEPLOY_ROOT/"
        fi
    done
    
    # 复制版本文件
    if [ -f "$SOURCE_PATH/VERSION" ]; then
        cp "$SOURCE_PATH/VERSION" "$DEPLOY_ROOT/"
    fi
    
    if [ -f "$SOURCE_PATH/BUILD_INFO.json" ]; then
        cp "$SOURCE_PATH/BUILD_INFO.json" "$DEPLOY_ROOT/"
    fi
    
    log_success "文件部署完成"
}

# 更新nginx配置
update_nginx_config() {
    log_info "更新 Nginx 配置..."
    
    NGINX_CONF="$DEPLOY_ROOT/nginx/manager.conf"
    
    if [ -f "$NGINX_CONF" ]; then
        # 替换项目根目录路径
        sed -i "s|__PROJECT_ROOT__|$DEPLOY_ROOT|g" "$NGINX_CONF"
        log_success "Nginx 配置更新完成"
        
        log_info "请将 Nginx 配置链接到系统配置目录："
        log_info "sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/cert-manager.conf"
        log_info "sudo nginx -t && sudo systemctl reload nginx"
    else
        log_warning "未找到 Nginx 配置文件"
    fi
}

# 初始化Laravel
initialize_laravel() {
    log_info "初始化 Laravel 应用..."
    
    cd "$DEPLOY_ROOT/backend"
    
    # 创建 .env 文件
    if [ ! -f ".env" ] && [ -f ".env.example" ]; then
        log_info "创建 .env 配置文件..."
        cp .env.example .env
        log_warning "请编辑 .env 文件配置数据库等信息"
    fi
    
    # 创建必要的目录
    mkdir -p storage/{app/public,framework/{cache,sessions,views},logs}
    mkdir -p bootstrap/cache
    
    # 优化自动加载
    log_info "优化 Composer 自动加载..."
    composer dump-autoload --optimize --no-dev
    
    # 创建存储链接
    if [ -L "public/storage" ]; then
        rm public/storage
    fi
    php artisan storage:link
    
    # 运行包发现
    php artisan package:discover --ansi
    
    log_success "Laravel 初始化完成"
    
    # 提示用户后续步骤
    log_warning "=== 重要提示 ==="
    log_warning "1. 请编辑 $DEPLOY_ROOT/backend/.env 配置数据库连接"
    log_warning "2. 访问 /install.php 完成系统安装"
    log_warning "3. 安装完成后删除 public/install.php 文件"
    
    cd "$SCRIPT_ROOT"
}

# 设置文件权限
set_permissions() {
    log_info "设置文件权限..."
    
    # 检测 Web 用户
    if id "www-data" &>/dev/null; then
        WEB_USER="www-data"
        WEB_GROUP="www-data"
    elif id "nginx" &>/dev/null; then
        WEB_USER="nginx"
        WEB_GROUP="nginx"
    else
        log_warning "未检测到 Web 用户，使用当前用户"
        WEB_USER=$(whoami)
        WEB_GROUP=$(whoami)
    fi
    
    # 设置后端权限
    if [ -d "$DEPLOY_ROOT/backend" ]; then
        log_info "设置后端目录权限..."
        
        # Laravel 需要写入的目录
        sudo chown -R "$WEB_USER:$WEB_GROUP" "$DEPLOY_ROOT/backend/storage"
        sudo chown -R "$WEB_USER:$WEB_GROUP" "$DEPLOY_ROOT/backend/bootstrap/cache"
        
        # 设置目录权限
        sudo chmod -R 775 "$DEPLOY_ROOT/backend/storage"
        sudo chmod -R 775 "$DEPLOY_ROOT/backend/bootstrap/cache"
        
        # 其他文件设置为只读
        sudo chmod -R 755 "$DEPLOY_ROOT/backend"
        
        # 确保日志目录可写
        sudo chmod -R 775 "$DEPLOY_ROOT/backend/storage/logs"
    fi
    
    # 设置前端权限（只读）
    if [ -d "$DEPLOY_ROOT/frontend" ]; then
        log_info "设置前端目录权限..."
        sudo chmod -R 755 "$DEPLOY_ROOT/frontend"
    fi
    
    log_success "权限设置完成"
}

# 主函数
main() {
    log_info "============================================"
    log_info "证书管理系统生产环境安装"
    log_info "============================================"
    
    # 检查是否有必要的权限
    if [ "$EUID" -eq 0 ]; then
        log_error "请不要使用 root 用户运行此脚本"
        exit 1
    fi
    
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
    
    log_success "============================================"
    log_success "安装完成！"
    if [ -n "$VERSION" ]; then
        log_success "版本: $VERSION"
    fi
    log_success "============================================"
    
    # 显示后续步骤
    echo
    log_info "后续步骤："
    log_info "1. 配置数据库: vim $DEPLOY_ROOT/backend/.env"
    log_info "2. 配置 Nginx: sudo ln -sf $DEPLOY_ROOT/nginx/manager.conf /etc/nginx/sites-enabled/"
    log_info "3. 重启 Nginx: sudo systemctl restart nginx"
    log_info "4. 访问安装向导: http://your-domain/install.php"
    log_info "5. 完成后删除: rm $DEPLOY_ROOT/backend/public/install.php"
}

# 执行主函数
main "$@"