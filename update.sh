#!/bin/bash

# 证书管理系统更新脚本
# 功能：从 production-code 仓库更新系统

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
CONFIG_FILE="$DEPLOY_ROOT/update-config.json"
PRODUCTION_REPO="git@gitee.com:zhuxbo/production-code.git"

# 更新模块
UPDATE_MODULE="${1:-all}"
VALID_MODULES=("api" "admin" "user" "easy" "all")

if [[ ! " ${VALID_MODULES[@]} " =~ " ${UPDATE_MODULE} " ]]; then
    log_error "无效的更新模块: $UPDATE_MODULE"
    log_info "有效的模块: ${VALID_MODULES[*]}"
    exit 1
fi

# 加载配置
load_config() {
    # 如果配置文件不存在，创建默认配置
    if [ ! -f "$CONFIG_FILE" ]; then
        log_info "创建默认配置文件..."
        cat > "$CONFIG_FILE" <<'EOF'
{
  "preserve_files": {
    "backend": {
      "env_file": ".env",
      "user_data": [
        "storage/app/public",
        "storage/logs"
      ]
    },
    "frontend": {
      "admin": [
        "platform-config.json",
        "logo.svg"
      ],
      "user": [
        "platform-config.json",
        "logo.svg",
        "qrcode.png"
      ],
      "easy": [
        "config.json"
      ]
    }
  },
  "services": {
    "nginx": {
      "restart_command": "sudo systemctl restart nginx",
      "stop_command": "sudo systemctl stop nginx",
      "start_command": "sudo systemctl start nginx"
    },
    "queue": {
      "restart_command": "sudo supervisorctl restart laravel-worker:*",
      "status_command": "sudo supervisorctl status laravel-worker:*"
    }
  }
}
EOF
    fi
}

# 检查服务状态
check_services() {
    log_info "检查服务状态..."
    
    # 检查 Nginx
    if systemctl is-active --quiet nginx; then
        log_info "Nginx 服务运行中"
        NGINX_RUNNING=true
    else
        log_warning "Nginx 服务未运行"
        NGINX_RUNNING=false
    fi
    
    # 检查队列
    if command -v supervisorctl &> /dev/null; then
        if supervisorctl status | grep -q "laravel-worker"; then
            log_info "Laravel 队列运行中"
            QUEUE_RUNNING=true
        else
            log_warning "Laravel 队列未配置"
            QUEUE_RUNNING=false
        fi
    else
        QUEUE_RUNNING=false
    fi
}

# 停止服务
stop_services() {
    if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
        log_info "停止服务以进行更新..."
        
        # 停止 Nginx
        if [ "$NGINX_RUNNING" = true ]; then
            log_info "停止 Nginx..."
            STOP_CMD=$(jq -r '.services.nginx.stop_command' "$CONFIG_FILE")
            eval "$STOP_CMD" || log_warning "停止 Nginx 失败"
        fi
    fi
}

# 启动服务
start_services() {
    if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
        log_info "启动服务..."
        
        # 启动 Nginx
        if [ "$NGINX_RUNNING" = true ]; then
            log_info "启动 Nginx..."
            START_CMD=$(jq -r '.services.nginx.start_command' "$CONFIG_FILE")
            eval "$START_CMD" || log_warning "启动 Nginx 失败"
        fi
        
        # 重启队列
        if [ "$QUEUE_RUNNING" = true ]; then
            log_info "重启 Laravel 队列..."
            RESTART_CMD=$(jq -r '.services.queue.restart_command' "$CONFIG_FILE")
            eval "$RESTART_CMD" || log_warning "重启队列失败"
        fi
    fi
}

# 拉取最新代码
pull_latest_code() {
    log_info "拉取最新生产代码..."
    
    mkdir -p "$SOURCE_DIR"
    cd "$SOURCE_DIR"
    
    if [ -d "production-code" ]; then
        cd production-code
        git fetch origin
        
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
        log_info "克隆生产代码仓库..."
        git clone "$PRODUCTION_REPO" production-code
        cd production-code
    fi
    
    # 读取版本信息
    NEW_VERSION=$(cat VERSION 2>/dev/null || echo "unknown")
    log_success "新版本: $NEW_VERSION"
    
    cd "$SCRIPT_ROOT"
}

# 备份当前版本
backup_current() {
    log_info "备份当前版本..."
    
    BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_PATH="$BACKUP_DIR/update_$BACKUP_TIMESTAMP"
    mkdir -p "$BACKUP_PATH"
    
    # 记录当前版本
    if [ -f "$DEPLOY_ROOT/VERSION" ]; then
        CURRENT_VERSION=$(cat "$DEPLOY_ROOT/VERSION")
        echo "原版本: $CURRENT_VERSION" > "$BACKUP_PATH/backup_info.txt"
    fi
    
    echo "备份时间: $(date)" >> "$BACKUP_PATH/backup_info.txt"
    echo "更新模块: $UPDATE_MODULE" >> "$BACKUP_PATH/backup_info.txt"
    
    # 根据更新模块备份
    case "$UPDATE_MODULE" in
        all)
            for dir in backend frontend nginx; do
                if [ -d "$DEPLOY_ROOT/$dir" ]; then
                    cp -r "$DEPLOY_ROOT/$dir" "$BACKUP_PATH/"
                fi
            done
            ;;
        api)
            if [ -d "$DEPLOY_ROOT/backend" ]; then
                cp -r "$DEPLOY_ROOT/backend" "$BACKUP_PATH/"
            fi
            ;;
        admin|user|easy)
            if [ -d "$DEPLOY_ROOT/frontend/$UPDATE_MODULE" ]; then
                mkdir -p "$BACKUP_PATH/frontend"
                cp -r "$DEPLOY_ROOT/frontend/$UPDATE_MODULE" "$BACKUP_PATH/frontend/"
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
    
    # 保存后端文件
    if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
        if [ -d "$DEPLOY_ROOT/backend" ]; then
            # 保存 .env
            if [ -f "$DEPLOY_ROOT/backend/.env" ]; then
                cp "$DEPLOY_ROOT/backend/.env" "$TEMP_PRESERVE_DIR/"
            fi
            
            # 保存用户数据
            USER_DATA_PATHS=$(jq -r '.preserve_files.backend.user_data[]' "$CONFIG_FILE" 2>/dev/null)
            if [ -n "$USER_DATA_PATHS" ]; then
                while IFS= read -r path; do
                    if [ -e "$DEPLOY_ROOT/backend/$path" ]; then
                        mkdir -p "$TEMP_PRESERVE_DIR/backend/$(dirname "$path")"
                        cp -r "$DEPLOY_ROOT/backend/$path" "$TEMP_PRESERVE_DIR/backend/$path"
                    fi
                done <<< "$USER_DATA_PATHS"
            fi
        fi
    fi
    
    # 保存前端配置文件
    for component in admin user easy; do
        if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "$component" ]; then
            if [ -d "$DEPLOY_ROOT/frontend/$component" ]; then
                PRESERVE_FILES=$(jq -r ".preserve_files.frontend.$component[]" "$CONFIG_FILE" 2>/dev/null)
                if [ -n "$PRESERVE_FILES" ]; then
                    mkdir -p "$TEMP_PRESERVE_DIR/frontend/$component"
                    while IFS= read -r file; do
                        if [ -f "$DEPLOY_ROOT/frontend/$component/$file" ]; then
                            cp "$DEPLOY_ROOT/frontend/$component/$file" "$TEMP_PRESERVE_DIR/frontend/$component/"
                        fi
                    done <<< "$PRESERVE_FILES"
                fi
            fi
        fi
    done
    
    log_success "文件保存完成"
}

# 恢复保留的文件
restore_preserve_files() {
    log_info "恢复保留的文件..."
    
    if [ ! -d "$TEMP_PRESERVE_DIR" ]; then
        return
    fi
    
    # 恢复后端文件
    if [ -f "$TEMP_PRESERVE_DIR/.env" ]; then
        cp "$TEMP_PRESERVE_DIR/.env" "$DEPLOY_ROOT/backend/"
    fi
    
    # 恢复用户数据
    if [ -d "$TEMP_PRESERVE_DIR/backend" ]; then
        cp -r "$TEMP_PRESERVE_DIR/backend"/* "$DEPLOY_ROOT/backend/" 2>/dev/null || true
    fi
    
    # 恢复前端文件
    if [ -d "$TEMP_PRESERVE_DIR/frontend" ]; then
        cp -r "$TEMP_PRESERVE_DIR/frontend"/* "$DEPLOY_ROOT/frontend/" 2>/dev/null || true
    fi
    
    # 清理临时目录
    rm -rf "$TEMP_PRESERVE_DIR"
    
    log_success "文件恢复完成"
}

# 部署新文件
deploy_new_files() {
    log_info "部署新文件..."
    
    SOURCE_PATH="$SOURCE_DIR/production-code"
    
    case "$UPDATE_MODULE" in
        all)
            # 更新所有模块
            for dir in backend frontend nginx; do
                if [ -d "$SOURCE_PATH/$dir" ]; then
                    log_info "更新 $dir..."
                    rm -rf "$DEPLOY_ROOT/$dir"
                    cp -r "$SOURCE_PATH/$dir" "$DEPLOY_ROOT/"
                fi
            done
            
            # 复制版本文件
            cp "$SOURCE_PATH/VERSION" "$DEPLOY_ROOT/" 2>/dev/null || true
            cp "$SOURCE_PATH/BUILD_INFO.json" "$DEPLOY_ROOT/" 2>/dev/null || true
            ;;
            
        api)
            # 仅更新后端
            if [ -d "$SOURCE_PATH/backend" ]; then
                log_info "更新后端..."
                rm -rf "$DEPLOY_ROOT/backend"
                cp -r "$SOURCE_PATH/backend" "$DEPLOY_ROOT/"
            fi
            ;;
            
        admin|user|easy)
            # 更新特定前端
            if [ -d "$SOURCE_PATH/frontend/$UPDATE_MODULE" ]; then
                log_info "更新 $UPDATE_MODULE 前端..."
                rm -rf "$DEPLOY_ROOT/frontend/$UPDATE_MODULE"
                mkdir -p "$DEPLOY_ROOT/frontend"
                cp -r "$SOURCE_PATH/frontend/$UPDATE_MODULE" "$DEPLOY_ROOT/frontend/"
            fi
            ;;
    esac
    
    log_success "文件部署完成"
}

# 更新后处理
post_update() {
    # 清理安装文件
    if [ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]; then
        if [ -f "$DEPLOY_ROOT/backend/public/install.php" ]; then
            log_info "移除安装文件..."
            rm -f "$DEPLOY_ROOT/backend/public/install.php"
        fi
        
        # 优化 Composer 自动加载
        cd "$DEPLOY_ROOT/backend"
        log_info "优化 Composer 自动加载..."
        composer dump-autoload --optimize --no-dev
        
        # 运行包发现
        php artisan package:discover --ansi
        
        # 清理 Laravel 缓存
        log_info "清理并优化 Laravel 缓存..."
        php artisan cache:clear
        php artisan config:clear
        php artisan route:clear
        php artisan view:clear
        php artisan optimize
        
        cd "$SCRIPT_ROOT"
    fi
    
    # 更新 Nginx 配置路径
    if [ "$UPDATE_MODULE" = "all" ] && [ -f "$DEPLOY_ROOT/nginx/manager.conf" ]; then
        sed -i "s|__PROJECT_ROOT__|$DEPLOY_ROOT|g" "$DEPLOY_ROOT/nginx/manager.conf"
    fi
    
    # 设置权限
    set_permissions
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
        WEB_USER=$(whoami)
        WEB_GROUP=$(whoami)
    fi
    
    # 设置后端权限
    if [ -d "$DEPLOY_ROOT/backend" ] && ([ "$UPDATE_MODULE" = "all" ] || [ "$UPDATE_MODULE" = "api" ]); then
        sudo chown -R "$WEB_USER:$WEB_GROUP" "$DEPLOY_ROOT/backend/storage"
        sudo chown -R "$WEB_USER:$WEB_GROUP" "$DEPLOY_ROOT/backend/bootstrap/cache"
        sudo chmod -R 775 "$DEPLOY_ROOT/backend/storage"
        sudo chmod -R 775 "$DEPLOY_ROOT/backend/bootstrap/cache"
    fi
    
    log_success "权限设置完成"
}

# 主函数
main() {
    log_info "============================================"
    log_info "证书管理系统更新"
    log_info "更新模块: $UPDATE_MODULE"
    log_info "============================================"
    
    # 加载配置
    load_config
    
    # 检查服务状态
    check_services
    
    # 停止服务
    stop_services
    
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
    
    # 更新后处理
    post_update
    
    # 启动服务
    start_services
    
    log_success "============================================"
    log_success "更新完成！"
    log_success "新版本: $NEW_VERSION"
    log_success "============================================"
}

# 执行主函数
main "$@"